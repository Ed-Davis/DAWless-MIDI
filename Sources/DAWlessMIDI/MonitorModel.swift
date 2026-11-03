import Foundation
import AppKit
import CoreMIDI
import UniformTypeIdentifiers
import DAWlessCore

// The MIDI Flicker side of the app: the per-channel monitor, the log, the
// SysEx recorder and player, and the test chord.

struct SlotStats {
    var count = 0
    var lastTime: Date?
    var lastBytes: [UInt8] = []
    var lastSourceName: String?
}

struct SourceStats {
    var count = 0
    var firstTime: Date?
    var lastTime: Date?
    var lastBytes: [UInt8] = []
    var channels: Set<Int> = []
}

@MainActor
final class MonitorModel: ObservableObject {
    private let engine: MIDIEngine?

    // MARK: Devices (kept up to date by AppModel)
    @Published private(set) var sources: [Endpoint] = []
    @Published private(set) var destinations: [Endpoint] = []

    // MARK: Monitor
    /// nil shows every channel mixed together.
    @Published var selectedSlot: Slot? { didSet { refreshVisibleLog() } }
    /// nil listens to every input; otherwise just this one.
    @Published var focusSourceID: MIDIUniqueIDValue? { didSet { refreshVisibleLog() } }
    @Published var paused = false
    @Published var hideRealTime = Prefs.bool("hideRealTime", default: true) {
        didSet { UserDefaults.standard.set(hideRealTime, forKey: "hideRealTime") }
    }
    @Published var middleCOctave = Prefs.int("middleCOctave", default: 3) {
        didSet { UserDefaults.standard.set(middleCOctave, forKey: "middleCOctave") }
    }
    @Published private(set) var stats: [Slot: SlotStats] = [:]
    @Published private(set) var activeSlots: Set<Slot> = []
    @Published private(set) var visibleLog: [MIDIEvent] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var clockBPM: Double?
    @Published var errorMessage: String?

    @Published private(set) var sourceStats: [MIDIUniqueIDValue: SourceStats] = [:]
    @Published private(set) var activeSources: Set<MIDIUniqueIDValue> = []
    @Published private(set) var lastSourceName: String?

    private var logs: [Slot: [MIDIEvent]] = [:]
    private var allLog: [MIDIEvent] = []
    private var nextID: UInt64 = 1
    private var timer: Timer?
    private var lastClockTime: Date?
    private var clockInterval: Double?

    static let logLimit = 5000
    private static let activityWindow: TimeInterval = 0.12

    /// Sample data for the screenshot: lights stay lit and live devices are ignored.
    private var demoMode = false

    // MARK: SysEx recorder
    @Published var isRecording = false
    @Published private(set) var recorded: [[UInt8]] = []
    @Published private(set) var recordedBytes = 0

    // MARK: SysEx player
    @Published private(set) var playerMessages: [[UInt8]] = []
    @Published private(set) var playerFileName: String?
    @Published var playerDestinationID: MIDIUniqueIDValue?
    @Published var messageDelayMs: Double = 100
    @Published var throttleToWireSpeed = true
    @Published private(set) var isSending = false
    @Published private(set) var sendProgress: Double = 0
    @Published private(set) var sendStatus = ""
    private var sendTask: Task<Void, Never>?

    // MARK: Test output
    @Published var testDestinationID: MIDIUniqueIDValue?
    @Published var testChannel = 0          // 0...15
    @Published private(set) var testNoteSounding = false
    @Published private(set) var testStatus = ""
    /// C, E and G around middle C (notes 60, 64, 67).
    static let testChord: [UInt8] = [60, 64, 67]

    init(engine: MIDIEngine?) {
        self.engine = engine
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Devices

    func update(sources: [Endpoint], destinations: [Endpoint]) {
        if demoMode { return }
        self.sources = sources
        self.destinations = destinations
        let ids = Set(destinations.map(\.device.uniqueID))
        if let d = playerDestinationID, !ids.contains(d) { playerDestinationID = nil }
        if playerDestinationID == nil { playerDestinationID = destinations.first?.device.uniqueID }
        if let d = testDestinationID, !ids.contains(d) { testDestinationID = nil }
        if testDestinationID == nil { testDestinationID = destinations.first?.device.uniqueID }
        if let f = focusSourceID, !sources.contains(where: { $0.device.uniqueID == f }) { focusSourceID = nil }
    }

    func destination(_ id: MIDIUniqueIDValue?) -> Endpoint? {
        destinations.first { $0.device.uniqueID == id }
    }

    var focusedSource: Endpoint? {
        sources.first { $0.device.uniqueID == focusSourceID }
    }

    // MARK: - Monitor

    private func isActive(_ time: Date?, now: Date) -> Bool {
        guard let time else { return false }
        return demoMode || now.timeIntervalSince(time) < Self.activityWindow
    }

    private func tick() {
        let now = Date()
        if let incoming = engine?.drainMonitor(), !incoming.isEmpty, !demoMode {
            process(incoming)
        }

        var active = Set<Slot>()
        for (slot, s) in stats where isActive(s.lastTime, now: now) { active.insert(slot) }
        if active != activeSlots { activeSlots = active }

        var activeSrc = Set<MIDIUniqueIDValue>()
        for (id, s) in sourceStats where isActive(s.lastTime, now: now) { activeSrc.insert(id) }
        if activeSrc != activeSources { activeSources = activeSrc }

        if !demoMode, clockBPM != nil, let last = lastClockTime, now.timeIntervalSince(last) > 1.0 {
            clockBPM = nil
            clockInterval = nil
        }
    }

    /// Takes in a batch of messages and publishes the result once.
    private func process(_ incoming: [RawMIDIEvent]) {
        var newStats = stats
        var newSourceStats = sourceStats
        var newRecorded: [[UInt8]] = []
        var added = 0
        var logChanged = false
        var latestSender = lastSourceName

        for raw in incoming {
            if let focus = focusSourceID, raw.sourceID != focus { continue }

            var ss = newSourceStats[raw.sourceID] ?? SourceStats()
            ss.count += 1
            if ss.firstTime == nil { ss.firstTime = raw.time }
            ss.lastTime = raw.time
            ss.lastBytes = raw.bytes
            if let status = raw.bytes.first, status < 0xF0 { ss.channels.insert(Int(status & 0x0F)) }
            newSourceStats[raw.sourceID] = ss

            let slot = Slot.of(raw.bytes)
            let event = MIDIEvent(id: nextID, time: raw.time, sourceID: raw.sourceID,
                                  sourceName: raw.sourceName, bytes: raw.bytes, slot: slot)
            nextID &+= 1
            added += 1

            var s = newStats[slot] ?? SlotStats()
            s.count += 1
            s.lastTime = raw.time
            s.lastBytes = raw.bytes
            s.lastSourceName = raw.sourceName
            newStats[slot] = s

            if raw.bytes == [0xF8] { trackClock(raw.time) }
            if isRecording && slot == .sysex { newRecorded.append(raw.bytes) }

            if !paused && !(hideRealTime && event.isRealTimeNoise) {
                logs[slot, default: []].append(event)
                allLog.append(event)
                logChanged = true
            }
            // Whoever sent the latest "real" message (not clock or active sensing).
            if !event.isRealTimeNoise { latestSender = raw.sourceName }
        }

        guard added > 0 else { return }
        stats = newStats
        sourceStats = newSourceStats
        totalCount += added
        if latestSender != lastSourceName { lastSourceName = latestSender }
        if !newRecorded.isEmpty {
            recorded.append(contentsOf: newRecorded)
            recordedBytes += newRecorded.reduce(0) { $0 + $1.count }
        }
        if logChanged {
            trimLogs()
            refreshVisibleLog()
        }
    }

    private func trackClock(_ time: Date) {
        if let last = lastClockTime {
            let dt = time.timeIntervalSince(last)
            if dt > 0.0005 && dt < 0.5 {
                clockInterval = clockInterval.map { $0 * 0.92 + dt * 0.08 } ?? dt
            }
        }
        lastClockTime = time
        if let interval = clockInterval {
            let bpm = (60.0 / (interval * 24.0) * 10).rounded() / 10
            if bpm != clockBPM { clockBPM = bpm }
        }
    }

    private func trimLogs() {
        let slack = 500
        if allLog.count > Self.logLimit + slack { allLog.removeFirst(allLog.count - Self.logLimit) }
        for key in Array(logs.keys) {
            if let count = logs[key]?.count, count > Self.logLimit + slack {
                logs[key]!.removeFirst(count - Self.logLimit)
            }
        }
    }

    private func refreshVisibleLog() {
        visibleLog = selectedSlot.map { logs[$0] ?? [] } ?? allLog
    }

    func clear() {
        logs = [:]
        allLog = []
        stats = [:]
        sourceStats = [:]
        activeSources = []
        lastSourceName = nil
        totalCount = 0
        activeSlots = []
        clockBPM = nil
        clockInterval = nil
        lastClockTime = nil
        refreshVisibleLog()
    }

    func describe(_ bytes: [UInt8]) -> MIDIDescription {
        MIDIDescriber.describe(bytes, middleCOctave: middleCOctave)
    }

    // MARK: - Files

    private static var syxType: UTType { UTType(filenameExtension: "syx") ?? .data }

    private func askSaveURL(defaultName: String, types: [UTType]) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    func saveSysEx(_ messages: [[UInt8]], defaultName: String) {
        guard !messages.isEmpty, let url = askSaveURL(defaultName: defaultName, types: [Self.syxType]) else { return }
        do {
            try SysExFile.save(messages, to: url)
        } catch {
            errorMessage = "Couldn't save the file: \(error.localizedDescription)"
        }
    }

    func exportLog() {
        let name = (selectedSlot?.title ?? "All Channels") + " Log.txt"
        guard let url = askSaveURL(defaultName: name, types: [.plainText]) else { return }
        var lines = ["Time\tSource\tChannel\tType\tDetail\tBytes"]
        for e in visibleLog {
            let d = describe(e.bytes)
            let ch: String
            if case .channel(let c) = e.slot { ch = "\(c + 1)" } else { ch = e.slot.title }
            lines.append([TimeFormat.formatter.string(from: e.time), e.sourceName, ch, d.type, d.detail, Hex.string(e.bytes)].joined(separator: "\t"))
        }
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Couldn't export the log: \(error.localizedDescription)"
        }
    }

    // MARK: - SysEx recorder

    func clearRecording() {
        recorded = []
        recordedBytes = 0
    }

    func saveRecording() { saveSysEx(recorded, defaultName: "SysEx Dump.syx") }

    // MARK: - Test output

    /// Plays C, E and G at velocity 127 for about half a second, then lets go.
    func sendTestChord() {
        guard !testNoteSounding else { return }
        guard let engine, let dest = destination(testDestinationID) else {
            errorMessage = "Choose a MIDI output to test."
            return
        }
        let channel = UInt8(testChannel & 0x0F)
        let ons: [UInt8] = Self.testChord.flatMap { note -> [UInt8] in [0x90 | channel, note, 127] }
        let offs: [UInt8] = Self.testChord.flatMap { note -> [UInt8] in [0x80 | channel, note, 0] }
        engine.sendNow(ons, to: dest.ref, device: dest.device)
        testNoteSounding = true
        let names = Self.testChord.map { MIDIDescriber.noteName($0, middleCOctave: middleCOctave) }.joined(separator: " ")
        testStatus = "Sent \(names) at velocity 127 on channel \(testChannel + 1) to \(dest.name)."

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            engine.sendNow(offs, to: dest.ref, device: dest.device)
            self?.testNoteSounding = false
        }
    }

    // MARK: - SysEx player

    func openSysExFile() {
        let panel = NSOpenPanel()
        panel.title = "Open SysEx File"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadPlayerFile(url)
    }

    func loadPlayerFile(_ url: URL) {
        do {
            let messages = try SysExFile.load(url)
            guard !messages.isEmpty else {
                errorMessage = "No SysEx messages (F0 … F7) were found in \(url.lastPathComponent)."
                return
            }
            playerMessages = messages
            playerFileName = url.lastPathComponent
            sendStatus = ""
        } catch {
            errorMessage = "Couldn't open the file: \(error.localizedDescription)"
        }
    }

    var playerBytes: Int { playerMessages.reduce(0) { $0 + $1.count } }

    func sendPlayerFile() { send(playerMessages) }
    func sendRecording() { send(recorded) }
    func cancelSending() { sendTask?.cancel() }

    private func send(_ messages: [[UInt8]]) {
        guard !isSending, !messages.isEmpty else { return }
        guard let engine, let dest = destination(playerDestinationID) else {
            errorMessage = "Choose a MIDI output to send to."
            return
        }

        isSending = true
        sendProgress = 0
        sendStatus = "Sending…"
        let totalBytes = max(1, messages.reduce(0) { $0 + $1.count })
        let gapMs = max(0, messageDelayMs)
        let throttle = throttleToWireSpeed
        let wordsPerChunk = 64          // 32 packets × 6 bytes = 192 SysEx bytes per burst
        let wireBytesPerSecond = 3000.0 // a MIDI cable carries 3125 bytes/s; leave a little room

        sendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var sentBytes = 0
            var failed: OSStatus?

            outer: for (index, message) in messages.enumerated() {
                let words = UMP.sysex7Words(message)
                var start = 0
                while start < words.count {
                    if Task.isCancelled { break outer }
                    let end = min(start + wordsPerChunk, words.count)
                    let status = engine.sendSysExWords(words[start..<end], to: dest.ref, device: dest.device)
                    if status != noErr {
                        failed = status
                        break outer
                    }
                    if throttle {
                        let chunkBytes = Double((end - start) / 2 * 6)
                        try? await Task.sleep(nanoseconds: UInt64(chunkBytes / wireBytesPerSecond * 1_000_000_000))
                    }
                    start = end
                }
                sentBytes += message.count
                self.sendProgress = Double(sentBytes) / Double(totalBytes)
                self.sendStatus = "Message \(index + 1) of \(messages.count)"
                if index < messages.count - 1 && gapMs > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(gapMs * 1_000_000))
                }
            }

            if let failed {
                self.sendStatus = "Send failed (error \(failed))."
            } else if Task.isCancelled {
                self.sendStatus = "Cancelled after \(ByteCount.string(sentBytes))."
            } else {
                self.sendStatus = "Sent \(messages.count) message\(messages.count == 1 ? "" : "s"), \(ByteCount.string(sentBytes)) to \(dest.name)."
            }
            self.isSending = false
            self.sendTask = nil
        }
    }
}

enum Prefs {
    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    static func int(_ key: String, default value: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? value
    }
}

// MARK: - Sample data for the screenshot

extension MonitorModel {
    func loadDemoData(sources: [Endpoint], destinations: [Endpoint]) {
        demoMode = true
        errorMessage = nil
        clear()
        self.sources = sources
        self.destinations = destinations
        testDestinationID = destinations.first?.device.uniqueID
        playerDestinationID = destinations.dropFirst().first?.device.uniqueID

        // A fixed time keeps the picture the same from build to build.
        var time = Date(timeIntervalSinceReferenceDate: 812_500_000)
        var batch: [RawMIDIEvent] = []
        func send(_ i: Int, _ bytes: [UInt8], after gap: Double = 0.09) {
            time += gap
            let s = sources[i % sources.count].device
            batch.append(RawMIDIEvent(time: time, sourceID: s.uniqueID, sourceName: s.name, bytes: bytes))
        }

        send(2, [0xFA])
        for _ in 0..<48 { send(2, [0xF8], after: 60.0 / 120.0 / 24.0) }
        send(1, [0xC1, 5])
        send(1, [0xB1, 7, 100])
        send(1, [0x91, 48, 96]); send(1, [0x81, 48, 0], after: 0.25)
        for note: UInt8 in [36, 42, 38, 42] { send(2, [0x99, note, 110]); send(2, [0x89, note, 0], after: 0.05) }
        send(0, [0xB2, 74, 82])
        let roland: [UInt8] = [0xF0, 0x41, 0x10, 0x42, 0x12, 0x40, 0x00, 0x7F, 0x00, 0x41, 0xF7]
        var akai: [UInt8] = [0xF0, 0x47, 0x00, 0x05, 0x48, 0x00, 0x00]
        akai += (0..<96).map { UInt8(($0 * 37 + 11) & 0x7F) }
        akai.append(0xF7)
        isRecording = true
        send(1, akai)
        send(1, roland)
        process(batch)
        batch = []
        isRecording = false
        for note: UInt8 in [60, 64, 67] { send(0, [0x90, note, 100], after: 0.02) }
        send(0, [0xB0, 1, 45])
        send(0, [0xE0, 0x00, 0x50])
        for note: UInt8 in [60, 64, 67] { send(0, [0x80, note, 0], after: 0.02) }
        send(0, [0x90, 72, 88])
        process(batch)

        testStatus = "Sent C3 E3 G3 at velocity 127 on channel 1 to \(destinations.first?.name ?? "")."
        playerMessages = [akai, roland, roland]
        playerFileName = "S2800 Program Bank.syx"
        selectedSlot = nil
    }
}
