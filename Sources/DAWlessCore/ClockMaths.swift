import Foundation

/// When the internal clock's ticks fall, in seconds (24 per quarter note).
/// The clock thread asks for the ticks due a little ahead of now and gives
/// them to Core MIDI with exact timestamps, so the thread itself doesn't
/// have to wake at exactly the right moment.
public struct ClockTimeline: Sendable {
    public static let ticksPerQuarter = 24.0
    /// If the thread falls further behind than this, ticks are skipped
    /// rather than sent in a burst (a burst would speed up the receivers).
    public static let maxLag = 0.05

    public private(set) var bpm: Double
    public private(set) var nextTick: Double
    /// The last tick handed out, so a restart never lands before it.
    public private(set) var lastTick: Double?

    public init(bpm: Double, startingAt time: Double) {
        self.bpm = Self.clamp(bpm)
        self.nextTick = time
    }

    public var interval: Double { 60 / (bpm * Self.ticksPerQuarter) }

    public mutating func setBPM(_ value: Double) { bpm = Self.clamp(value) }

    /// Starts the grid again from `time` (on Start, the first tick goes with it).
    public mutating func restart(at time: Double) { nextTick = time }

    /// The ticks due up to and including `horizon`, in order.
    public mutating func ticks(through horizon: Double, now: Double) -> [Double] {
        if nextTick < now - Self.maxLag { nextTick = now }
        var out: [Double] = []
        while nextTick <= horizon {
            out.append(nextTick)
            lastTick = nextTick
            nextTick += interval
        }
        return out
    }

    /// The earliest a transport message (start, stop, continue) can be sent
    /// without landing before a tick that's already been scheduled.
    public func earliestEvent(now: Double, leadTime: Double) -> Double {
        max(now + leadTime, (lastTick ?? -.infinity) + 0.0005)
    }

    static func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return 120 }
        return min(max(v, Patch.bpmRange.lowerBound), Patch.bpmRange.upperBound)
    }
}

/// Works out the tempo of incoming clock from the time between ticks.
public struct TempoMeter: Sendable {
    private var last: Double?
    private var intervals: [Double] = []
    /// Ticks averaged: two beats, so the reading is steady but still follows changes.
    public static let window = 48

    public init() {}

    /// Notes a tick at `time` (seconds). Returns the tempo once there's enough to go on.
    @discardableResult
    public mutating func tick(at time: Double) -> Double? {
        defer { last = time }
        guard let last else { return nil }
        let gap = time - last
        // Faster than 1000 BPM or slower than 5 BPM: not a running clock.
        guard gap > 60 / (1000 * 24), gap < 60 / (5 * 24) else {
            intervals.removeAll()
            return nil
        }
        intervals.append(gap)
        if intervals.count > Self.window { intervals.removeFirst(intervals.count - Self.window) }
        return bpm
    }

    /// The current reading, if there have been enough ticks.
    public var bpm: Double? {
        guard intervals.count >= 6 else { return nil }
        let average = intervals.reduce(0, +) / Double(intervals.count)
        return 60 / (average * ClockTimeline.ticksPerQuarter)
    }

    public mutating func reset() {
        last = nil
        intervals.removeAll()
    }
}

/// Tap tempo: the average of the last few taps.
public struct TapTempo: Sendable {
    private var taps: [Double] = []
    /// A gap longer than this starts a new count.
    public static let timeout = 2.0

    public init() {}

    public mutating func tap(at time: Double) -> Double? {
        if let last = taps.last, time - last > Self.timeout || time <= last { taps.removeAll() }
        taps.append(time)
        if taps.count > 5 { taps.removeFirst(taps.count - 5) }
        guard taps.count >= 2, let first = taps.first, let last = taps.last else { return nil }
        let beat = (last - first) / Double(taps.count - 1)
        return ClockTimeline.clamp(60 / beat)
    }
}
