import Foundation

/// A MIDI input or output, remembered across launches and replugging.
/// Core MIDI's unique ID tells two identical devices apart; the name is the
/// fallback for devices that come back with a new ID.
public struct DeviceID: Codable, Hashable, Sendable {
    public var uniqueID: Int32
    public var name: String

    public init(uniqueID: Int32, name: String) {
        self.uniqueID = uniqueID
        self.name = name
    }
}

/// What kind of message something is, for routing and filtering.
public enum MessageKind: String, Codable, CaseIterable, Hashable, Sendable {
    case notes
    case controllers
    case programChanges
    case pitchBend
    case aftertouch
    case sysEx
    /// Clock, start, stop, continue and song position. These never go
    /// through routes: the Clock row decides where they go.
    case clock
    /// Everything else (active sensing, MTC, song select…): always passed.
    case other

    /// The kinds a route can block.
    public static let filterable: [MessageKind] = [.notes, .controllers, .programChanges, .pitchBend, .aftertouch, .sysEx]

    public var label: String {
        switch self {
        case .notes: return "Notes"
        case .controllers: return "Control changes"
        case .programChanges: return "Program changes"
        case .pitchBend: return "Pitch bend"
        case .aftertouch: return "Aftertouch"
        case .sysEx: return "SysEx"
        case .clock: return "Clock and transport"
        case .other: return "Other"
        }
    }

    public static func of(_ message: [UInt8]) -> MessageKind {
        guard let s = message.first else { return .other }
        switch s {
        case 0xF8, 0xFA, 0xFB, 0xFC, 0xF2: return .clock
        case 0xF0: return .sysEx
        case 0x80...0xEF:
            switch s & 0xF0 {
            case 0x80, 0x90: return .notes
            case 0xA0, 0xD0: return .aftertouch
            case 0xB0: return .controllers
            case 0xC0: return .programChanges
            default: return .pitchBend
            }
        default: return .other
        }
    }
}

/// What a route lets through, and on which channel it sends.
public struct RouteFilter: Codable, Hashable, Sendable {
    /// Only this channel (1–16) gets through; nil for all channels.
    public var channel: Int?
    /// Channel messages are moved to this channel (1–16); nil to keep theirs.
    public var sendOn: Int?
    /// Kinds of message that don't get through.
    public var blocked: Set<MessageKind>

    public init(channel: Int? = nil, sendOn: Int? = nil, blocked: Set<MessageKind> = []) {
        self.channel = channel
        self.sendOn = sendOn
        self.blocked = blocked
    }

    public var isDefault: Bool { channel == nil && sendOn == nil && blocked.isEmpty }

    /// The message as it leaves this route, or nil if it doesn't get through.
    public func apply(_ message: [UInt8]) -> [UInt8]? {
        let kind = MessageKind.of(message)
        if kind == .clock || blocked.contains(kind) { return nil }
        guard let status = message.first, (0x80...0xEF).contains(status) else { return message }
        let ch = Int(status & 0x0F) + 1
        if let channel, channel != ch { return nil }
        guard let sendOn, (1...16).contains(sendOn) else { return message }
        var out = message
        out[0] = (status & 0xF0) | UInt8(sendOn - 1)
        return out
    }

    /// A few characters for the matrix cell: "1", "1→3", "→3", with "•" if
    /// some messages are blocked. Nil when everything passes unchanged.
    public var summary: String? {
        var text: String
        switch (channel, sendOn) {
        case (nil, nil): text = ""
        case let (c?, nil): text = "\(c)"
        case let (nil, s?): text = "→\(s)"
        case let (c?, s?): text = c == s ? "\(c)" : "\(c)→\(s)"
        }
        if !blocked.isEmpty { text += text.isEmpty ? "filtered" : " •" }
        return text.isEmpty ? nil : text
    }
}

public struct Route: Codable, Hashable, Sendable {
    public var from: DeviceID
    public var to: DeviceID
    public var filter: RouteFilter

    public init(from: DeviceID, to: DeviceID, filter: RouteFilter = RouteFilter()) {
        self.from = from
        self.to = to
        self.filter = filter
    }
}

/// Where clock comes from.
public enum ClockSource: Codable, Hashable, Sendable {
    /// No clock is sent anywhere.
    case off
    /// The app's own clock (BPM, start and stop here).
    case `internal`
    /// Clock from one of the inputs, passed on to the clock outputs.
    case input(DeviceID)
}

/// The whole setup: routes, where clock comes from and where it goes.
public struct Patch: Codable, Equatable, Sendable {
    public var routes: [Route]
    public var clockSource: ClockSource
    public var clockOutputs: [DeviceID]
    public var bpm: Double
    /// Keep sending clock while stopped, so arpeggiators and delays stay in time.
    public var clockWhileStopped: Bool

    public static let bpmRange: ClosedRange<Double> = 20...300

    public init(routes: [Route] = [], clockSource: ClockSource = .internal, clockOutputs: [DeviceID] = [],
                bpm: Double = 120, clockWhileStopped: Bool = true) {
        self.routes = routes
        self.clockSource = clockSource
        self.clockOutputs = clockOutputs
        self.bpm = bpm
        self.clockWhileStopped = clockWhileStopped
    }

    // Forgiving decoding, so a setup saved by another version still loads.
    private enum CodingKeys: String, CodingKey { case routes, clockSource, clockOutputs, bpm, clockWhileStopped }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        routes = (try? c.decodeIfPresent([Route].self, forKey: .routes)) ?? []
        clockSource = (try? c.decodeIfPresent(ClockSource.self, forKey: .clockSource)) ?? .internal
        clockOutputs = (try? c.decodeIfPresent([DeviceID].self, forKey: .clockOutputs)) ?? []
        let bpm = (try? c.decodeIfPresent(Double.self, forKey: .bpm)) ?? 120
        self.bpm = bpm.isFinite ? min(max(bpm, Self.bpmRange.lowerBound), Self.bpmRange.upperBound) : 120
        clockWhileStopped = (try? c.decodeIfPresent(Bool.self, forKey: .clockWhileStopped)) ?? true
    }

    // MARK: Routes

    public func route(from: DeviceID, to: DeviceID) -> Route? {
        routes.first { $0.from == from && $0.to == to }
    }

    public mutating func setRouted(_ on: Bool, from: DeviceID, to: DeviceID) {
        let exists = route(from: from, to: to) != nil
        if on && !exists {
            routes.append(Route(from: from, to: to))
        } else if !on && exists {
            routes.removeAll { $0.from == from && $0.to == to }
        }
    }

    public mutating func setFilter(_ filter: RouteFilter, from: DeviceID, to: DeviceID) {
        guard let i = routes.firstIndex(where: { $0.from == from && $0.to == to }) else { return }
        routes[i].filter = filter
    }

    // MARK: Clock

    public func sendsClock(to output: DeviceID) -> Bool { clockOutputs.contains(output) }

    public mutating func setClock(_ on: Bool, to output: DeviceID) {
        if on, !clockOutputs.contains(output) {
            clockOutputs.append(output)
        } else if !on {
            clockOutputs.removeAll { $0 == output }
        }
    }

    public mutating func setBPM(_ value: Double) {
        guard value.isFinite else { return }
        bpm = (min(max(value, Self.bpmRange.lowerBound), Self.bpmRange.upperBound) * 100).rounded() / 100
    }

    // MARK: Devices that come back

    /// Every input and output the setup mentions.
    public var inputsUsed: [DeviceID] {
        var out = routes.map(\.from)
        if case .input(let d) = clockSource { out.append(d) }
        return Self.unique(out)
    }

    public var outputsUsed: [DeviceID] { Self.unique(routes.map(\.to) + clockOutputs) }

    /// Points the setup at the devices that are connected now: a device whose
    /// name changed keeps its routes, and one that came back with a new
    /// unique ID (some USB devices do) is found by name. Inputs and outputs
    /// are matched separately. Returns true if anything changed.
    @discardableResult
    public mutating func rebind(sources: [DeviceID], destinations: [DeviceID]) -> Bool {
        let inMap = Self.mapping(stored: inputsUsed, online: sources)
        let outMap = Self.mapping(stored: outputsUsed, online: destinations)
        guard !inMap.isEmpty || !outMap.isEmpty else { return false }
        for i in routes.indices {
            if let d = inMap[routes[i].from] { routes[i].from = d }
            if let d = outMap[routes[i].to] { routes[i].to = d }
        }
        if case .input(let d) = clockSource, let new = inMap[d] { clockSource = .input(new) }
        clockOutputs = Self.unique(clockOutputs.map { outMap[$0] ?? $0 })
        // Two stored routes may now be the same one.
        var seen = Set<String>()
        routes = routes.filter { seen.insert("\($0.from.uniqueID)>\($0.to.uniqueID)").inserted }
        return true
    }

    static func mapping(stored: [DeviceID], online: [DeviceID]) -> [DeviceID: DeviceID] {
        var map: [DeviceID: DeviceID] = [:]
        let storedIDs = Set(stored.map(\.uniqueID))
        var claimed = Set<Int32>()
        // Same unique ID, new name.
        for s in stored {
            if let o = online.first(where: { $0.uniqueID == s.uniqueID }) {
                claimed.insert(o.uniqueID)
                if o.name != s.name { map[s] = o }
            }
        }
        // Gone, but a device with the same name is here that nothing else uses.
        for s in stored where !online.contains(where: { $0.uniqueID == s.uniqueID }) {
            if let o = online.first(where: { $0.name == s.name && !storedIDs.contains($0.uniqueID) && !claimed.contains($0.uniqueID) }) {
                claimed.insert(o.uniqueID)
                map[s] = o
            }
        }
        return map
    }

    static func unique(_ ids: [DeviceID]) -> [DeviceID] {
        var seen = Set<DeviceID>()
        return ids.filter { seen.insert($0).inserted }
    }
}
