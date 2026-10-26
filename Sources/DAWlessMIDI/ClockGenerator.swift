import Foundation
import DAWlessCore

/// The internal MIDI clock. A thread hands Core MIDI each tick a little
/// before it's due, with its exact time on it, so the timing comes from
/// Core MIDI rather than from how promptly the thread wakes.
final class ClockGenerator: @unchecked Sendable {
    /// How far ahead ticks are scheduled.
    static let lookahead = 0.015
    /// How far ahead a start, stop or continue is sent.
    static let leadTime = 0.003

    private let condition = NSCondition()
    private var timeline = ClockTimeline(bpm: 120, startingAt: 0)
    private var enabled = false
    private var playing = false
    private var whileStopped = true
    private let send: ([UInt8], Double) -> Void

    init(send: @escaping ([UInt8], Double) -> Void) {
        self.send = send
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "DAWless MIDI clock"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private var ticking: Bool { enabled && (playing || whileStopped) }

    var isPlaying: Bool {
        condition.lock()
        defer { condition.unlock() }
        return playing
    }

    func configure(enabled: Bool, bpm: Double, whileStopped: Bool) {
        condition.lock()
        defer { condition.unlock() }
        let wasTicking = ticking
        if !enabled && self.enabled && playing {
            send([0xFC], timeline.earliestEvent(now: HostTime.now, leadTime: Self.leadTime))
            playing = false
        }
        self.enabled = enabled
        self.whileStopped = whileStopped
        timeline.setBPM(bpm)
        if ticking && !wasTicking {
            timeline.restart(at: timeline.earliestEvent(now: HostTime.now, leadTime: Self.leadTime))
        }
        condition.signal()
    }

    /// Start from the top: a Start message, then the first tick with it.
    func start() { begin(with: 0xFA) }

    /// Carry on from where the receivers stopped.
    func resume() { begin(with: 0xFB) }

    private func begin(with message: UInt8) {
        condition.lock()
        defer { condition.unlock() }
        guard enabled else { return }
        let at = timeline.earliestEvent(now: HostTime.now, leadTime: Self.leadTime)
        send([message], at)
        timeline.restart(at: at + 0.0002)
        playing = true
        condition.signal()
    }

    func stop() {
        condition.lock()
        defer { condition.unlock() }
        guard enabled, playing else { return }
        send([0xFC], timeline.earliestEvent(now: HostTime.now, leadTime: Self.leadTime))
        playing = false
        condition.signal()
    }

    private func run() {
        condition.lock()
        while true {
            guard ticking else {
                condition.wait()
                continue
            }
            let now = HostTime.now
            for t in timeline.ticks(through: now + Self.lookahead, now: now) { send([0xF8], t) }
            // Wake again when the next tick is half the look-ahead away.
            let wake = max(0.001, timeline.nextTick - Self.lookahead / 2 - now)
            condition.wait(until: Date(timeIntervalSinceNow: wake))
        }
    }
}
