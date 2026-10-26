import Foundation

/// Splits a raw MIDI byte stream into whole messages.
///
/// Handles running status, real-time bytes (clock, start, stop…) that can
/// turn up in the middle of another message, and SysEx that arrives over
/// several packets. Keep one parser per input, since a message can be split
/// across packets.
public struct MIDIStreamParser: Sendable {
    /// SysEx longer than this is cut short rather than growing without end.
    public static let maxSysExLength = 1 << 20

    private var runningStatus: UInt8 = 0
    private var message: [UInt8] = []
    private var expected = 0
    private var inSysEx = false

    public init() {}

    public mutating func feed<C: Collection>(_ bytes: C, emit: ([UInt8]) -> Void) where C.Element == UInt8 {
        for b in bytes {
            // Real-time messages are one byte and can appear anywhere,
            // even inside another message or SysEx. Pass them straight on.
            if b >= 0xF8 {
                emit([b])
                continue
            }

            if inSysEx {
                if b < 0x80 {
                    if message.count < Self.maxSysExLength { message.append(b) }
                    continue
                }
                // F7 ends it; any other status byte ends it too (unterminated).
                message.append(0xF7)
                emit(message)
                message = []
                inSysEx = false
                if b == 0xF7 { continue }
            }

            if b >= 0x80 {
                switch b {
                case 0xF0:
                    inSysEx = true
                    message = [b]
                    runningStatus = 0
                    expected = 0
                case 0xF1, 0xF3:            // MTC quarter frame, song select
                    runningStatus = 0
                    message = [b]
                    expected = 2
                case 0xF2:                  // song position pointer
                    runningStatus = 0
                    message = [b]
                    expected = 3
                case 0xF6:                  // tune request
                    runningStatus = 0
                    message = []
                    expected = 0
                    emit([b])
                case 0xF4, 0xF5, 0xF7:      // undefined, or a stray end of SysEx
                    runningStatus = 0
                    message = []
                    expected = 0
                default:                    // channel voice
                    runningStatus = b
                    message = [b]
                    expected = Self.length(of: b)
                }
                continue
            }

            // A data byte.
            if message.isEmpty {
                guard runningStatus != 0 else { continue }
                message = [runningStatus]
                expected = Self.length(of: runningStatus)
            }
            guard expected > 0 else { continue }
            message.append(b)
            if message.count == expected {
                emit(message)
                message = []
            }
        }
    }

    /// The length of a channel voice message, status byte included.
    static func length(of status: UInt8) -> Int {
        switch status & 0xF0 {
        case 0xC0, 0xD0: return 2
        default: return 3
        }
    }
}
