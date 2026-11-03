import Foundation

public enum SysExFile {
    public static let sysex7Type: UInt32 = 0x0002_0002 // kMIDIPropertySysEx
    public static let sysex8Type: UInt32 = 0x0002_0003 // kMIDIPropertySysEx8

    /// Split raw bytes (e.g. a .syx file) into complete F0 … F7 messages.
    /// Bytes outside a message are ignored; a message cut short by a new F0 is dropped.
    public static func split(_ data: [UInt8]) -> [[UInt8]] {
        var messages: [[UInt8]] = []
        var current: [UInt8]? = nil
        for b in data {
            if b == 0xF0 {
                current = [0xF0]
            } else if b == 0xF7 {
                if var msg = current {
                    msg.append(0xF7)
                    messages.append(msg)
                }
                current = nil
            } else if b >= 0xF8 {
                // Real-time bytes may legally interleave a SysEx stream; skip them.
                continue
            } else if b & 0x80 != 0 {
                // Any other status byte terminates an unfinished message.
                current = nil
            } else {
                current?.append(b)
            }
        }
        return messages
    }

    public static func load(_ url: URL) throws -> [[UInt8]] {
        let data = try Data(contentsOf: url)
        return split([UInt8](data))
    }

    public static func save(_ messages: [[UInt8]], to url: URL) throws {
        var out = Data()
        out.reserveCapacity(messages.reduce(0) { $0 + $1.count })
        for m in messages { out.append(contentsOf: m) }
        try out.write(to: url, options: .atomic)
    }
}

/// Universal MIDI Packet helpers (MIDI 1.0 protocol, group 0).
public enum UMP {
    public static let sysex7Type: UInt32 = 0x3 << 28
    public static let channelVoiceType: UInt32 = 0x2 << 28

    /// Number of 32-bit words in a UMP, from its message type nibble.
    public static func wordCount(messageType mt: UInt32) -> Int {
        switch mt {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4   // 0x5, 0xD, 0xE, 0xF
        }
    }

    /// Encode one SysEx message (with or without F0/F7) as 64-bit Data (SysEx7) UMPs.
    /// Returns a flat array of words: two words per packet.
    public static func sysex7Words(_ message: [UInt8], group: UInt32 = 0) -> [UInt32] {
        var payload = message[...]
        if payload.first == 0xF0 { payload = payload.dropFirst() }
        if payload.last == 0xF7 { payload = payload.dropLast() }
        let bytes = Array(payload)

        var words: [UInt32] = []
        if bytes.isEmpty {
            // A complete, empty SysEx in one packet.
            words.append(UMP.sysex7Type | (group << 24))
            words.append(0)
            return words
        }

        let chunkCount = (bytes.count + 5) / 6
        words.reserveCapacity(chunkCount * 2)
        for i in 0..<chunkCount {
            let start = i * 6
            let end = min(start + 6, bytes.count)
            let n = UInt32(end - start)
            let status: UInt32
            if chunkCount == 1 { status = 0x0 }          // complete in one
            else if i == 0 { status = 0x1 }              // start
            else if i == chunkCount - 1 { status = 0x3 } // end
            else { status = 0x2 }                        // continue

            var b = [UInt32](repeating: 0, count: 6)
            for j in start..<end { b[j - start] = UInt32(bytes[j] & 0x7F) }

            var w0: UInt32 = UMP.sysex7Type | (group << 24)
            w0 |= status << 20
            w0 |= n << 16
            w0 |= b[0] << 8
            w0 |= b[1]
            var w1: UInt32 = b[2] << 24
            w1 |= b[3] << 16
            w1 |= b[4] << 8
            w1 |= b[5]
            words.append(w0)
            words.append(w1)
        }
        return words
    }
}
