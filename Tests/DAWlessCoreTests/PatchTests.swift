import XCTest
@testable import DAWlessCore

final class PatchTests: XCTestCase {
    let keyStepIn = DeviceID(uniqueID: 100, name: "KeyStep Pro")
    let keyStepOut = DeviceID(uniqueID: 101, name: "KeyStep Pro")
    let tr8 = DeviceID(uniqueID: 200, name: "TR-8S")
    let s2800 = DeviceID(uniqueID: 300, name: "MIDI Interface Port 1")

    func testRoutingToggles() {
        var p = Patch()
        p.setRouted(true, from: keyStepIn, to: tr8)
        p.setRouted(true, from: keyStepIn, to: tr8)
        XCTAssertEqual(p.routes.count, 1)
        p.setFilter(RouteFilter(channel: 10), from: keyStepIn, to: tr8)
        XCTAssertEqual(p.route(from: keyStepIn, to: tr8)?.filter.channel, 10)
        p.setRouted(false, from: keyStepIn, to: tr8)
        XCTAssertTrue(p.routes.isEmpty)
    }

    func testClockOutputs() {
        var p = Patch()
        p.setClock(true, to: tr8)
        p.setClock(true, to: tr8)
        p.setClock(true, to: s2800)
        XCTAssertEqual(p.clockOutputs, [tr8, s2800])
        p.setClock(false, to: tr8)
        XCTAssertFalse(p.sendsClock(to: tr8))
        XCTAssertTrue(p.sendsClock(to: s2800))
    }

    func testBPMIsClampedAndRounded() {
        var p = Patch()
        p.setBPM(1000)
        XCTAssertEqual(p.bpm, 300)
        p.setBPM(5)
        XCTAssertEqual(p.bpm, 20)
        p.setBPM(123.456)
        XCTAssertEqual(p.bpm, 123.46)
        p.setBPM(.nan)
        XCTAssertEqual(p.bpm, 123.46)
    }

    func testRoundTrip() throws {
        var p = Patch(clockSource: .input(keyStepIn), bpm: 97.5, clockWhileStopped: false)
        p.setRouted(true, from: keyStepIn, to: tr8)
        p.setFilter(RouteFilter(channel: 1, sendOn: 10, blocked: [.sysEx]), from: keyStepIn, to: tr8)
        p.setClock(true, to: tr8)
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(Patch.self, from: data), p)
        p.clockSource = .internal
        XCTAssertEqual(try JSONDecoder().decode(Patch.self, from: JSONEncoder().encode(p)).clockSource, .internal)
    }

    func testForgivingDecode() throws {
        let p = try JSONDecoder().decode(Patch.self, from: Data(#"{"bpm": 9999, "future": true}"#.utf8))
        XCTAssertEqual(p.bpm, 300)
        XCTAssertTrue(p.routes.isEmpty)
        XCTAssertEqual(p.clockSource, .internal)
        XCTAssertTrue(p.clockWhileStopped)
    }

    func testRebindNewUniqueIDByName() {
        var p = Patch(clockSource: .input(keyStepIn))
        p.setRouted(true, from: keyStepIn, to: tr8)
        p.setClock(true, to: tr8)
        let newIn = DeviceID(uniqueID: 900, name: "KeyStep Pro")
        let newTR = DeviceID(uniqueID: 901, name: "TR-8S")
        XCTAssertTrue(p.rebind(sources: [newIn], destinations: [keyStepOut, newTR]))
        XCTAssertEqual(p.routes, [Route(from: newIn, to: newTR)])
        XCTAssertEqual(p.clockOutputs, [newTR])
        XCTAssertEqual(p.clockSource, .input(newIn))
    }

    func testRebindDoesNotMixInputsAndOutputs() {
        var p = Patch()
        p.setRouted(true, from: keyStepIn, to: tr8)
        // Only the KeyStep's *output* is around: the input route mustn't move to it.
        XCTAssertFalse(p.rebind(sources: [], destinations: [keyStepOut, tr8]))
        XCTAssertEqual(p.routes.first?.from, keyStepIn)
    }

    func testRebindRenamed() {
        var p = Patch()
        p.setRouted(true, from: keyStepIn, to: tr8)
        let renamed = DeviceID(uniqueID: 200, name: "TR-8S Drums")
        XCTAssertTrue(p.rebind(sources: [keyStepIn], destinations: [renamed]))
        XCTAssertEqual(p.routes.first?.to, renamed)
    }

    func testRebindLeavesIdenticalTwinsAlone() {
        // Two of the same synth: one stored, both online with their own IDs.
        let a = DeviceID(uniqueID: 1, name: "volca"), b = DeviceID(uniqueID: 2, name: "volca")
        var p = Patch()
        p.setRouted(true, from: keyStepIn, to: a)
        XCTAssertFalse(p.rebind(sources: [keyStepIn], destinations: [a, b]))
        XCTAssertEqual(p.routes.first?.to, a)
    }

    func testRebindNothingToDo() {
        var p = Patch()
        p.setRouted(true, from: keyStepIn, to: tr8)
        XCTAssertFalse(p.rebind(sources: [keyStepIn], destinations: [tr8]))
        XCTAssertFalse(p.rebind(sources: [], destinations: []), "offline devices keep their routes")
        XCTAssertEqual(p.routes.count, 1)
    }

    func testUsedDevices() {
        var p = Patch(clockSource: .input(s2800))
        p.setRouted(true, from: keyStepIn, to: tr8)
        p.setClock(true, to: keyStepOut)
        XCTAssertEqual(p.inputsUsed, [keyStepIn, s2800])
        XCTAssertEqual(p.outputsUsed, [tr8, keyStepOut])
    }
}

final class ClockMathsTests: XCTestCase {
    func testTicksAt120() {
        var t = ClockTimeline(bpm: 120, startingAt: 10)
        let ticks = t.ticks(through: 10.5 + 1e-9, now: 10)
        XCTAssertEqual(ticks.count, 25)              // a beat is 0.5 s: 24 intervals, 25 ticks
        XCTAssertEqual(ticks.last!, 10.5, accuracy: 1e-9)
        XCTAssertEqual(ticks[1] - ticks[0], 0.5 / 24, accuracy: 1e-9)
        XCTAssertTrue(t.ticks(through: 10.5, now: 10.4).isEmpty, "no tick is handed out twice")
    }

    func testTempoChangeAppliesToNextTicks() {
        var t = ClockTimeline(bpm: 120, startingAt: 0)
        _ = t.ticks(through: 0, now: 0)
        t.setBPM(60)
        let next = t.ticks(through: 0.1, now: 0)
        XCTAssertEqual(next.first!, 0.5 / 24, accuracy: 1e-9)   // the one already due at 120
        XCTAssertEqual(next[1] - next[0], 1.0 / 24, accuracy: 1e-9)
    }

    func testFallingBehindSkipsInsteadOfBursting() {
        var t = ClockTimeline(bpm: 120, startingAt: 0)
        let ticks = t.ticks(through: 5.01, now: 5)
        XCTAssertLessThanOrEqual(ticks.count, 2)
        XCTAssertGreaterThanOrEqual(ticks.first!, 5)
    }

    func testTransportNeverLandsBeforeAScheduledTick() {
        var t = ClockTimeline(bpm: 120, startingAt: 0)
        _ = t.ticks(through: 0.015, now: 0)
        let at = t.earliestEvent(now: 0, leadTime: 0.005)
        XCTAssertGreaterThan(at, t.lastTick!)
    }

    func testNoDriftOverAnHour() {
        var t = ClockTimeline(bpm: 133, startingAt: 50_000)
        var last = 0.0
        var n = 0
        var now = 50_000.0
        while now < 53_600 {
            let ticks = t.ticks(through: now + 0.015, now: now)
            n += ticks.count
            last = ticks.last ?? last
            now += 0.0075
        }
        XCTAssertEqual(last, 50_000 + Double(n - 1) * 60 / (133 * 24), accuracy: 1e-6)
    }

    func testTempoMeter() {
        var m = TempoMeter()
        var bpm: Double?
        for i in 0..<48 { bpm = m.tick(at: Double(i) * (60 / (128.0 * 24))) }
        XCTAssertEqual(bpm!, 128, accuracy: 0.01)
        XCTAssertNil(m.tick(at: 100), "a long gap starts over")
        m.reset()
        XCTAssertNil(m.bpm)
    }

    func testTapTempo() {
        var tap = TapTempo()
        XCTAssertNil(tap.tap(at: 0))
        XCTAssertEqual(tap.tap(at: 0.5)!, 120, accuracy: 0.001)
        XCTAssertEqual(tap.tap(at: 1.0)!, 120, accuracy: 0.001)
        XCTAssertNil(tap.tap(at: 10), "after a pause it starts counting again")
        XCTAssertEqual(tap.tap(at: 11)!, 60, accuracy: 0.001)
    }
}
