import XCTest
@testable import DAWlessCore

final class SysExFileTests: XCTestCase {

    // MARK: - SysExFile.split

    func testSplitSingleCompleteMessage() {
        let data: [UInt8] = [0xF0, 0x42, 0x10, 0xF7]
        let messages = SysExFile.split(data)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0], [0xF0, 0x42, 0x10, 0xF7])
    }

    func testSplitMultipleCompleteMessages() {
        let data: [UInt8] = [0xF0, 0x42, 0xF7, 0xF0, 0x7E, 0xF7]
        let messages = SysExFile.split(data)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0], [0xF0, 0x42, 0xF7])
        XCTAssertEqual(messages[1], [0xF0, 0x7E, 0xF7])
    }

    func testSplitMessageWithPayload() {
        let data: [UInt8] = [0xF0, 0x7E, 0x7F, 0x09, 0x01, 0xF7]
        let messages = SysExFile.split(data)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].count, 6)
        XCTAssertEqual(messages[0].first, 0xF0)
        XCTAssertEqual(messages[0].last, 0xF7)
    }

    func testSplitEmptyData() {
        let messages = SysExFile.split([])
        XCTAssertEqual(messages.count, 0)
    }

    func testSplitNoStartByte() {
        let data: [UInt8] = [0x42, 0x10, 0x55, 0xF7]
        let messages = SysExFile.split(data)
        XCTAssertEqual(messages.count, 0)
    }

    func testSplitUnterminatedMessageIsDropped() {
        let data: [UInt8] = [0xF0, 0x42, 0x10] // no F7
        let messages = SysExFile.split(data)
        XCTAssertEqual(messages.count, 0)
    }

    func testSplitF7WithoutF0IsIgnored() {
        let data: [UInt8] = [0xF7, 0xF0, 0x42, 0xF7]
        let messages = SysExFile.split(data)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0], [0xF0, 0x42, 0xF7])
    }

    func testSplitInterleavedRealTimeBytesAreSkipped() {
        // 0xF8 (timing clock) may interleave between F0 and F7.
        let data: [UInt8] = [0xF0, 0x42, 0xF8, 0xF7]
        let messages = SysExFile.split(data)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0], [0xF0, 0x42, 0xF7])
    }

    func testSplitStatusByteTerminatesUnfinishedMessage() {
        // 0x90 (Note On status) terminates the open F0 message.
        let data: [UInt8] = [0xF0, 0x42, 0x90, 0x42, 0xF7]
        let messages = SysExFile.split(data)
        XCTAssertEqual(messages.count, 0)
    }

    func testSplitNewF0DropsUnfinishedMessage() {
        let data: [UInt8] = [0xF0, 0x42, 0xF0, 0x7E, 0xF7]
        let messages = SysExFile.split(data)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0], [0xF0, 0x7E, 0xF7])
    }

    // MARK: - SysExFile.load / save round-trip

    func testSaveAndLoadRoundTrip() throws {
        let messages: [[UInt8]] = [
            [0xF0, 0x42, 0x10, 0xF7],
            [0xF0, 0x7E, 0x7F, 0xF7]
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).syx")
        defer { try? FileManager.default.removeItem(at: url) }

        try SysExFile.save(messages, to: url)
        let loaded = try SysExFile.load(url)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0], messages[0])
        XCTAssertEqual(loaded[1], messages[1])
    }

    // MARK: - UMP.wordCount

    func testWordCountFor1WordTypes() {
        XCTAssertEqual(UMP.wordCount(messageType: 0x0), 1) // 1.0 Note Off
        XCTAssertEqual(UMP.wordCount(messageType: 0x1), 1) // 1.0 Note On
        XCTAssertEqual(UMP.wordCount(messageType: 0x2), 1) // 1.0 Poly Key Press
        XCTAssertEqual(UMP.wordCount(messageType: 0x6), 1) // 1.0 Program Change (MIDI2)
        XCTAssertEqual(UMP.wordCount(messageType: 0x7), 1) // 1.0 MIDI Time
    }

    func testWordCountFor2WordTypes() {
        XCTAssertEqual(UMP.wordCount(messageType: 0x3), 2) // 1.0 Control Change
        XCTAssertEqual(UMP.wordCount(messageType: 0x4), 2) // 1.0 Channel Pressure
        XCTAssertEqual(UMP.wordCount(messageType: 0x8), 2) // 1.0 MNC
        XCTAssertEqual(UMP.wordCount(messageType: 0x9), 2) // 1.0 MNP
        XCTAssertEqual(UMP.wordCount(messageType: 0xA), 2) // 1.0 RPN
    }

    func testWordCountFor3WordTypes() {
        XCTAssertEqual(UMP.wordCount(messageType: 0xB), 3) // Per-Note
        XCTAssertEqual(UMP.wordCount(messageType: 0xC), 3) // 2.0 Per-Note
    }

    func testWordCountFor4WordTypes() {
        XCTAssertEqual(UMP.wordCount(messageType: 0x5), 4) // SysEx7
        XCTAssertEqual(UMP.wordCount(messageType: 0xD), 4) // SysEx8
        XCTAssertEqual(UMP.wordCount(messageType: 0xE), 4) // MIDI 2.0
        XCTAssertEqual(UMP.wordCount(messageType: 0xF), 4) // Stream
    }

    func testWordCountForUnknownType() {
        XCTAssertEqual(UMP.wordCount(messageType: 0x10), 4) // defaults to 4
    }

    // MARK: - UMP.sysex7Words

    func testSysex7WordsEmptyMessage() {
        let words = UMP.sysex7Words([0xF0, 0xF7])
        XCTAssertEqual(words.count, 2) // one packet = two words
    }

    func testSysex7WordsSinglePacket() {
        let message: [UInt8] = [0xF0, 0x7E, 0x7F, 0xF7]
        let words = UMP.sysex7Words(message)
        XCTAssertEqual(words.count, 2)
        // status should be 0x0 (complete in one packet)
        let status = (words[0] >> 20) & 0xF
        XCTAssertEqual(status, 0x0)
    }

    func testSysex7WordsMultiplePackets() {
        // 13 bytes of payload → splits into 3 chunks (6 + 6 + 1)
        let payload = (0..<13).map { UInt8($0) }
        let message = [0xF0] + payload + [0xF7]
        let words = UMP.sysex7Words(message)
        XCTAssertEqual(words.count, 6) // 3 packets × 2 words each

        // Check status bytes: start, continue, end
        let s0 = (words[0] >> 20) & 0xF
        let s2 = (words[2] >> 20) & 0xF
        let s4 = (words[4] >> 20) & 0xF
        XCTAssertEqual(s0, 0x1) // start
        XCTAssertEqual(s2, 0x2) // continue
        XCTAssertEqual(s4, 0x3) // end
    }

    func testSysex7WordsStripsFramingBytes() {
        let payload: [UInt8] = [0x42, 0x10, 0x7E]
        let wordsWith = UMP.sysex7Words([0xF0] + payload + [0xF7])
        let wordsWithout = UMP.sysex7Words(payload)
        XCTAssertEqual(wordsWith, wordsWithout)
    }

    func testSysex7WordsGroupDefaultsToZero() {
        let words = UMP.sysex7Words([0xF0, 0x42, 0xF7])
        // Group is bits 24-27 of w0; should be 0.
        XCTAssertEqual(words[0] & 0x0F000000, 0)
    }
}
