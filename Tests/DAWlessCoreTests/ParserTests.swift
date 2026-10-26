import XCTest
@testable import DAWlessCore

final class ParserTests: XCTestCase {
    private func parse(_ chunks: [[UInt8]]) -> [[UInt8]] {
        var parser = MIDIStreamParser()
        var out: [[UInt8]] = []
        for c in chunks { parser.feed(c) { out.append($0) } }
        return out
    }

    func testWholeMessages() {
        XCTAssertEqual(parse([[0x90, 60, 100, 0xB3, 7, 127, 0xC0, 5]]),
                       [[0x90, 60, 100], [0xB3, 7, 127], [0xC0, 5]])
    }

    func testRunningStatus() {
        XCTAssertEqual(parse([[0x91, 60, 100, 62, 90, 64, 0]]),
                       [[0x91, 60, 100], [0x91, 62, 90], [0x91, 64, 0]])
    }

    func testMessageSplitAcrossPackets() {
        XCTAssertEqual(parse([[0x90, 60], [100]]), [[0x90, 60, 100]])
    }

    func testClockInsideANote() {
        XCTAssertEqual(parse([[0x90, 60, 0xF8, 100]]), [[0xF8], [0x90, 60, 100]])
    }

    func testSysExAcrossPacketsWithClockInside() {
        let out = parse([[0xF0, 0x47, 0x00], [0xF8, 0x01, 0xF7]])
        XCTAssertEqual(out, [[0xF8], [0xF0, 0x47, 0x00, 0x01, 0xF7]])
    }

    func testUnterminatedSysExIsClosedByNextStatus() {
        XCTAssertEqual(parse([[0xF0, 1, 2, 0x90, 60, 1]]), [[0xF0, 1, 2, 0xF7], [0x90, 60, 1]])
    }

    func testSystemCommonCancelsRunningStatus() {
        XCTAssertEqual(parse([[0x90, 60, 100, 0xF2, 0, 0, 62, 90]]), [[0x90, 60, 100], [0xF2, 0, 0]])
    }

    func testStrayDataBytesAreIgnored() {
        XCTAssertEqual(parse([[1, 2, 3, 0xFA]]), [[0xFA]])
    }

    func testTuneRequestAndSongSelect() {
        XCTAssertEqual(parse([[0xF6, 0xF3, 4]]), [[0xF6], [0xF3, 4]])
    }

    func testRealTimeDoesNotBreakRunningStatus() {
        XCTAssertEqual(parse([[0xB0, 1, 2, 0xF8, 1, 3]]), [[0xB0, 1, 2], [0xF8], [0xB0, 1, 3]])
    }
}

final class FilterTests: XCTestCase {
    func testKinds() {
        XCTAssertEqual(MessageKind.of([0x90, 1, 1]), .notes)
        XCTAssertEqual(MessageKind.of([0x8F, 1, 1]), .notes)
        XCTAssertEqual(MessageKind.of([0xB0, 1, 1]), .controllers)
        XCTAssertEqual(MessageKind.of([0xC0, 1]), .programChanges)
        XCTAssertEqual(MessageKind.of([0xD0, 1]), .aftertouch)
        XCTAssertEqual(MessageKind.of([0xA0, 1, 1]), .aftertouch)
        XCTAssertEqual(MessageKind.of([0xE0, 0, 64]), .pitchBend)
        XCTAssertEqual(MessageKind.of([0xF0, 1, 0xF7]), .sysEx)
        for b: UInt8 in [0xF8, 0xFA, 0xFB, 0xFC] { XCTAssertEqual(MessageKind.of([b]), .clock) }
        XCTAssertEqual(MessageKind.of([0xF2, 0, 0]), .clock)
        XCTAssertEqual(MessageKind.of([0xFE]), .other)
    }

    func testDefaultPassesEverythingButClock() {
        let f = RouteFilter()
        XCTAssertEqual(f.apply([0x93, 60, 1]), [0x93, 60, 1])
        XCTAssertEqual(f.apply([0xF0, 1, 0xF7]), [0xF0, 1, 0xF7])
        XCTAssertEqual(f.apply([0xFE]), [0xFE])
        XCTAssertNil(f.apply([0xF8]))
        XCTAssertNil(f.apply([0xFA]))
        XCTAssertNil(f.apply([0xF2, 0, 0]))
    }

    func testChannelFilterAndRemap() {
        let f = RouteFilter(channel: 2, sendOn: 10)
        XCTAssertEqual(f.apply([0x91, 36, 127]), [0x99, 36, 127])
        XCTAssertNil(f.apply([0x90, 36, 127]))
        XCTAssertEqual(f.apply([0xFE]), [0xFE], "non-channel messages aren't filtered by channel")
    }

    func testRemapOnly() {
        XCTAssertEqual(RouteFilter(sendOn: 1).apply([0xBF, 7, 100]), [0xB0, 7, 100])
    }

    func testBlockedKinds() {
        let f = RouteFilter(blocked: [.programChanges, .sysEx])
        XCTAssertNil(f.apply([0xC0, 3]))
        XCTAssertNil(f.apply([0xF0, 1, 0xF7]))
        XCTAssertNotNil(f.apply([0x90, 1, 1]))
    }

    func testSummary() {
        XCTAssertNil(RouteFilter().summary)
        XCTAssertEqual(RouteFilter(channel: 1).summary, "1")
        XCTAssertEqual(RouteFilter(channel: 1, sendOn: 3).summary, "1→3")
        XCTAssertEqual(RouteFilter(sendOn: 3).summary, "→3")
        XCTAssertEqual(RouteFilter(blocked: [.sysEx]).summary, "filtered")
        XCTAssertEqual(RouteFilter(channel: 4, blocked: [.sysEx]).summary, "4 •")
    }
}
