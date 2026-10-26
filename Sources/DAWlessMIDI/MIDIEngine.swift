import CoreMIDI
import Foundation
import DAWlessCore

/// A connected MIDI input (source) or output (destination).
struct Endpoint: Hashable, Identifiable {
    let ref: MIDIEndpointRef
    let device: DeviceID
    var id: DeviceID { device }
    var name: String { device.name }
}

/// Mach host time, in seconds and back.
enum HostTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    static func ticks(_ seconds: Double) -> UInt64 {
        guard seconds > 0 else { return 0 }
        return UInt64(seconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }

    static var now: Double { seconds(mach_absolute_time()) }
}

/// Moves MIDI between devices with Core MIDI. Incoming messages are routed on
/// Core MIDI's own thread, straight away, from a snapshot of the routing that
/// the app replaces whenever it changes.
final class MIDIEngine: @unchecked Sendable {
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()

    /// The routing as the MIDI thread needs it.
    private struct Table {
        struct Out { let ref: MIDIEndpointRef; let device: DeviceID; let filter: RouteFilter }
        var routes: [Int32: [Out]] = [:]           // by source unique ID
        var clockSourceID: Int32?                  // an input whose clock is followed
        var clockOutputs: [(MIDIEndpointRef, DeviceID)] = []
    }

    private let lock = NSLock()
    private var table = Table()
    private var parsers: [Int: MIDIStreamParser] = [:]
    private var tokens: [Int: DeviceID] = [:]          // connection token → source
    private var connected: [MIDIEndpointRef: Int] = [:]
    private var nextToken = 1
    private var tempo = TempoMeter()
    private var lastClockTick: Double = 0
    private var externalPlaying = false

    private let activityLock = NSLock()
    private var inActivity: [DeviceID: Double] = [:]
    private var outActivity: [DeviceID: Double] = [:]

    /// Called on the main thread when devices come or go.
    var onDevicesChanged: (() -> Void)?

    init() throws {
        var status = MIDIClientCreateWithBlock("DAWless MIDI" as CFString, &client) { [weak self] notification in
            guard notification.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async { self?.onDevicesChanged?() }
        }
        guard status == noErr else { throw EngineError.coreMIDI("Couldn't start Core MIDI", status) }

        status = MIDIInputPortCreateWithBlock(client, "Inputs" as CFString, &inPort) { [weak self] list, refCon in
            guard let self, let refCon else { return }
            self.receive(list, token: Int(bitPattern: refCon))
        }
        guard status == noErr else { throw EngineError.coreMIDI("Couldn't open MIDI inputs", status) }

        status = MIDIOutputPortCreate(client, "Outputs" as CFString, &outPort)
        guard status == noErr else { throw EngineError.coreMIDI("Couldn't open MIDI outputs", status) }
    }

    enum EngineError: LocalizedError {
        case coreMIDI(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case let .coreMIDI(what, status): return "\(what) (error \(status))."
            }
        }
    }

    // MARK: Devices

    static func sources() -> [Endpoint] {
        (0..<MIDIGetNumberOfSources()).compactMap { endpoint(MIDIGetSource($0)) }
    }

    static func destinations() -> [Endpoint] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { endpoint(MIDIGetDestination($0)) }
    }

    private static func endpoint(_ ref: MIDIEndpointRef) -> Endpoint? {
        guard ref != 0 else { return nil }
        var offline: Int32 = 0
        if MIDIObjectGetIntegerProperty(ref, kMIDIPropertyOffline, &offline) == noErr, offline != 0 { return nil }
        var uid: Int32 = 0
        MIDIObjectGetIntegerProperty(ref, kMIDIPropertyUniqueID, &uid)
        return Endpoint(ref: ref, device: DeviceID(uniqueID: uid, name: displayName(ref)))
    }

    private static func displayName(_ ref: MIDIObjectRef) -> String {
        for key in [kMIDIPropertyDisplayName, kMIDIPropertyName] {
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(ref, key, &name) == noErr, let name {
                let s = name.takeRetainedValue() as String
                if !s.isEmpty { return s }
            }
        }
        return "Unnamed MIDI port"
    }

    /// Listens to every input in `sources` and stops listening to any that went.
    func listen(to sources: [Endpoint]) {
        lock.lock()
        defer { lock.unlock() }
        let wanted = Set(sources.map(\.ref))
        for (ref, token) in connected where !wanted.contains(ref) {
            MIDIPortDisconnectSource(inPort, ref)
            connected[ref] = nil
            tokens[token] = nil
            parsers[token] = nil
        }
        for source in sources {
            if let token = connected[source.ref] {
                tokens[token] = source.device       // its name may have changed
                continue
            }
            let token = nextToken
            nextToken += 1
            guard MIDIPortConnectSource(inPort, source.ref, UnsafeMutableRawPointer(bitPattern: token)) == noErr else { continue }
            connected[source.ref] = token
            tokens[token] = source.device
            parsers[token] = MIDIStreamParser()
        }
    }

    /// Puts a new routing in place.
    func apply(_ patch: Patch, sources: [Endpoint], destinations: [Endpoint]) {
        func dest(_ d: DeviceID) -> MIDIEndpointRef? { destinations.first { $0.device.uniqueID == d.uniqueID }?.ref }
        var t = Table()
        for route in patch.routes {
            guard let ref = dest(route.to) else { continue }
            t.routes[route.from.uniqueID, default: []].append(.init(ref: ref, device: route.to, filter: route.filter))
        }
        if case .input(let d) = patch.clockSource, sources.contains(where: { $0.device.uniqueID == d.uniqueID }) {
            t.clockSourceID = d.uniqueID
        }
        if patch.clockSource != .off {
            t.clockOutputs = patch.clockOutputs.compactMap { d in dest(d).map { ($0, d) } }
        }
        lock.lock()
        if t.clockSourceID != table.clockSourceID {
            tempo.reset()
            externalPlaying = false
        }
        table = t
        lock.unlock()
    }

    // MARK: Incoming

    private func receive(_ list: UnsafePointer<MIDIPacketList>, token: Int) {
        var messages: [([UInt8], MIDITimeStamp)] = []
        lock.lock()
        guard let device = tokens[token], var parser = parsers[token] else {
            lock.unlock()
            return
        }
        Self.forEachPacket(list) { timeStamp, bytes in
            let ts = timeStamp == 0 ? mach_absolute_time() : timeStamp
            parser.feed(bytes) { messages.append(($0, ts)) }
        }
        parsers[token] = parser
        let table = self.table
        let followingThis = table.clockSourceID == device.uniqueID
        if followingThis {
            for (m, ts) in messages {
                switch m.first {
                case 0xF8:
                    tempo.tick(at: HostTime.seconds(ts))
                    lastClockTick = HostTime.now
                case 0xFA, 0xFB: externalPlaying = true
                case 0xFC: externalPlaying = false
                default: break
                }
            }
        }
        lock.unlock()

        guard !messages.isEmpty else { return }
        noteActivity(in: device)
        let outs = table.routes[device.uniqueID] ?? []
        for (message, ts) in messages {
            if MessageKind.of(message) == .clock {
                // Only the chosen clock input's clock goes anywhere, and only
                // to the clock outputs. Everyone else's clock stops here.
                guard followingThis else { continue }
                for (ref, d) in table.clockOutputs { send(message, to: ref, device: d, at: ts) }
            } else {
                for out in outs {
                    if let m = out.filter.apply(message) { send(m, to: out.ref, device: out.device, at: ts) }
                }
            }
        }
    }

    private static func forEachPacket(_ list: UnsafePointer<MIDIPacketList>, _ body: (MIDITimeStamp, UnsafeBufferPointer<UInt8>) -> Void) {
        let count = list.pointee.numPackets
        guard count > 0 else { return }
        let first = UnsafeRawPointer(list).advanced(by: MemoryLayout<MIDIPacketList>.offset(of: \MIDIPacketList.packet) ?? 4)
        var packet = UnsafeMutablePointer(mutating: first.assumingMemoryBound(to: MIDIPacket.self))
        let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data) ?? 10
        for _ in 0..<count {
            let length = Int(packet.pointee.length)
            let data = UnsafeRawPointer(packet).advanced(by: dataOffset).assumingMemoryBound(to: UInt8.self)
            body(packet.pointee.timeStamp, UnsafeBufferPointer(start: data, count: length))
            packet = MIDIPacketNext(packet)
        }
    }

    // MARK: Outgoing

    private func send(_ bytes: [UInt8], to ref: MIDIEndpointRef, device: DeviceID, at timeStamp: MIDITimeStamp) {
        guard !bytes.isEmpty else { return }
        let size = bytes.count + 64
        withUnsafeTemporaryAllocation(byteCount: size, alignment: 8) { raw in
            let list = raw.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
            var packet: UnsafeMutablePointer<MIDIPacket>? = MIDIPacketListInit(list)
            bytes.withUnsafeBufferPointer { b in
                packet = MIDIPacketListAdd(list, size, packet!, timeStamp, b.count, b.baseAddress!)
            }
            if packet != nil { MIDISend(outPort, ref, list) }
        }
        noteActivity(out: device)
    }

    /// Sends a clock or transport message from the internal clock to the clock outputs.
    func sendClock(_ bytes: [UInt8], at time: Double) {
        lock.lock()
        let outs = table.clockOutputs
        lock.unlock()
        let ts = HostTime.ticks(time)
        for (ref, d) in outs { send(bytes, to: ref, device: d, at: ts) }
    }

    /// All notes off, all sound off and sustain off, on every channel of every output.
    func panic(_ destinations: [Endpoint]) {
        for d in destinations {
            for ch: UInt8 in 0..<16 {
                send([0xB0 | ch, 64, 0, 0xB0 | ch, 123, 0, 0xB0 | ch, 120, 0], to: d.ref, device: d.device, at: 0)
            }
        }
    }

    // MARK: What the window shows

    private func noteActivity(in device: DeviceID) {
        activityLock.lock()
        inActivity[device] = HostTime.now
        activityLock.unlock()
    }

    private func noteActivity(out device: DeviceID) {
        activityLock.lock()
        outActivity[device] = HostTime.now
        activityLock.unlock()
    }

    /// Devices that sent or received something in the last `window` seconds.
    func activity(within window: Double) -> (inputs: Set<DeviceID>, outputs: Set<DeviceID>) {
        let cutoff = HostTime.now - window
        activityLock.lock()
        defer { activityLock.unlock() }
        return (Set(inActivity.filter { $0.value > cutoff }.keys), Set(outActivity.filter { $0.value > cutoff }.keys))
    }

    /// The tempo and transport of the input being followed for clock.
    func externalClock() -> (bpm: Double?, playing: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard table.clockSourceID != nil, HostTime.now - lastClockTick < 1 else { return (nil, externalPlaying) }
        return (tempo.bpm, externalPlaying)
    }
}
