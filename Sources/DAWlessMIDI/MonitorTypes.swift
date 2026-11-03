import Foundation

// Brought over from MIDI Flicker: the message types and decoding the monitor uses.

/// Which monitor tile a message belongs to.
enum Slot: Hashable, Identifiable {
    case channel(Int)   // 0...15
    case system         // System Common + Real-Time (clock, start/stop, song position…)
    case sysex          // System Exclusive

    var id: String {
        switch self {
        case .channel(let c): return "ch\(c)"
        case .system: return "sys"
        case .sysex: return "sysex"
        }
    }

    var title: String {
        switch self {
        case .channel(let c): return "Channel \(c + 1)"
        case .system: return "System"
        case .sysex: return "SysEx"
        }
    }

    var shortTitle: String {
        switch self {
        case .channel(let c): return "CH \(c + 1)"
        case .system: return "SYSTEM"
        case .sysex: return "SYSEX"
        }
    }

    static let channels: [Slot] = (0..<16).map { .channel($0) }

    /// Classify a complete MIDI 1.0 message by its status byte.
    static func of(_ bytes: [UInt8]) -> Slot {
        guard let status = bytes.first else { return .system }
        if status == 0xF0 { return .sysex }
        if status >= 0xF0 { return .system }
        return .channel(Int(status & 0x0F))
    }
}

/// One received MIDI 1.0 message (complete, including status byte).
struct MIDIEvent: Identifiable {
    let id: UInt64
    let time: Date
    let sourceID: MIDIUniqueIDValue
    let sourceName: String
    let bytes: [UInt8]
    let slot: Slot

    var isRealTimeNoise: Bool {
        guard bytes.count == 1 else { return false }
        return bytes[0] == 0xF8 || bytes[0] == 0xFE   // Timing Clock, Active Sensing
    }
}

typealias MIDIUniqueIDValue = Int32

// MARK: - Formatting helpers

enum TimeFormat {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

enum Hex {
    private static let table: [String] = (0..<256).map { String(format: "%02X", $0) }

    static func byte(_ b: UInt8) -> String { table[Int(b)] }

    static func string(_ bytes: [UInt8], limit: Int? = nil) -> String {
        if let limit, bytes.count > limit {
            return bytes.prefix(limit).map { table[Int($0)] }.joined(separator: " ") + " … (+\(bytes.count - limit))"
        }
        return bytes.map { table[Int($0)] }.joined(separator: " ")
    }

    /// Classic 16-bytes-per-line hex dump with offsets.
    static func dump(_ bytes: [UInt8]) -> String {
        var lines: [String] = []
        lines.reserveCapacity(bytes.count / 16 + 1)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 16, bytes.count)
            let chunk = bytes[offset..<end]
            let hex = chunk.map { table[Int($0)] }.joined(separator: " ")
            let ascii = String(chunk.map { ($0 >= 0x20 && $0 < 0x7F) ? Character(UnicodeScalar($0)) : "." })
            let pad = String(repeating: " ", count: (16 - chunk.count) * 3)
            lines.append(String(format: "%06X  ", offset) + hex + pad + "  " + ascii)
            offset = end
        }
        return lines.joined(separator: "\n")
    }
}

enum ByteCount {
    static func string(_ n: Int) -> String {
        if n < 1024 { return "\(n) bytes" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        return String(format: "%.2f MB", Double(n) / 1024 / 1024)
    }
}

// MARK: - Human-readable descriptions

struct MIDIDescription {
    let type: String
    let detail: String
}

enum MIDIDescriber {
    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// - Parameter middleCOctave: 3 → note 60 is "C3" (Yamaha/Akai/Roland style), 4 → "C4".
    static func noteName(_ note: UInt8, middleCOctave: Int) -> String {
        let n = Int(note)
        let octave = n / 12 - (5 - middleCOctave)
        return "\(noteNames[n % 12])\(octave)"
    }

    static func describe(_ bytes: [UInt8], middleCOctave: Int) -> MIDIDescription {
        guard let status = bytes.first else { return MIDIDescription(type: "Empty", detail: "") }
        let d1 = bytes.count > 1 ? bytes[1] : 0
        let d2 = bytes.count > 2 ? bytes[2] : 0

        if status < 0xF0 {
            switch status & 0xF0 {
            case 0x80:
                return .init(type: "Note Off", detail: "\(noteName(d1, middleCOctave: middleCOctave)) (\(d1))  vel \(d2)")
            case 0x90:
                if d2 == 0 {
                    return .init(type: "Note Off", detail: "\(noteName(d1, middleCOctave: middleCOctave)) (\(d1))  vel 0")
                }
                return .init(type: "Note On", detail: "\(noteName(d1, middleCOctave: middleCOctave)) (\(d1))  vel \(d2)")
            case 0xA0:
                return .init(type: "Poly Pressure", detail: "\(noteName(d1, middleCOctave: middleCOctave)) (\(d1))  \(d2)")
            case 0xB0:
                if let mode = channelModeName(d1) {
                    return .init(type: "Channel Mode", detail: "\(mode)  \(d2)")
                }
                return .init(type: "Control Change", detail: "CC \(d1)\(ccName(d1).map { " \($0)" } ?? "")  = \(d2)")
            case 0xC0:
                return .init(type: "Program Change", detail: "\(Int(d1) + 1)  (\(d1))")
            case 0xD0:
                return .init(type: "Channel Pressure", detail: "\(d1)")
            case 0xE0:
                let value = (Int(d2) << 7 | Int(d1)) - 8192
                return .init(type: "Pitch Bend", detail: value > 0 ? "+\(value)" : "\(value)")
            default:
                break
            }
        }

        switch status {
        case 0xF0:
            return .init(type: "SysEx", detail: sysexSummary(bytes))
        case 0xF1:
            let kind = ["Frames lo", "Frames hi", "Secs lo", "Secs hi", "Mins lo", "Mins hi", "Hours lo", "Hours hi/rate"]
            return .init(type: "MTC Quarter Frame", detail: "\(kind[Int(d1 >> 4) & 7]) = \(d1 & 0x0F)")
        case 0xF2:
            let beats = Int(d2) << 7 | Int(d1)
            let bar = beats / 16 + 1
            let beat = (beats % 16) / 4 + 1
            let sixteenth = beats % 4 + 1
            return .init(type: "Song Position", detail: "\(beats) (≈ \(bar).\(beat).\(sixteenth) in 4/4)")
        case 0xF3: return .init(type: "Song Select", detail: "\(d1)")
        case 0xF6: return .init(type: "Tune Request", detail: "")
        case 0xF7: return .init(type: "End of SysEx", detail: "")
        case 0xF8: return .init(type: "Timing Clock", detail: "")
        case 0xFA: return .init(type: "Start", detail: "")
        case 0xFB: return .init(type: "Continue", detail: "")
        case 0xFC: return .init(type: "Stop", detail: "")
        case 0xFE: return .init(type: "Active Sensing", detail: "")
        case 0xFF: return .init(type: "System Reset", detail: "")
        default:   return .init(type: "Undefined", detail: Hex.string(bytes))
        }
    }

    static func sysexSummary(_ bytes: [UInt8]) -> String {
        var parts: [String] = [ByteCount.string(bytes.count)]
        if bytes.count > 1 {
            parts.append(manufacturer(bytes))
        }
        if bytes.last != 0xF7 { parts.append("⚠︎ no F7") }
        return parts.joined(separator: "  ·  ")
    }

    static func manufacturer(_ bytes: [UInt8]) -> String {
        guard bytes.count > 1 else { return "" }
        let id = bytes[1]
        if id == 0x00 {
            guard bytes.count > 3 else { return "Extended ID" }
            let ext = (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
            let known: [UInt32: String] = [
                0x2029: "Novation", 0x2032: "Behringer", 0x2033: "Clavia",
                0x203C: "Elektron", 0x206B: "Arturia"
            ]
            let hex = "00 \(Hex.byte(bytes[2])) \(Hex.byte(bytes[3]))"
            if let name = known[ext] { return "\(name) [\(hex)]" }
            return "Manufacturer [\(hex)]"
        }
        let names: [UInt8: String] = [
            0x01: "Sequential", 0x04: "Moog", 0x06: "Lexicon", 0x07: "Kurzweil",
            0x0F: "Ensoniq", 0x10: "Oberheim", 0x18: "E-mu", 0x1A: "ART",
            0x40: "Kawai", 0x41: "Roland", 0x42: "Korg", 0x43: "Yamaha",
            0x44: "Casio", 0x47: "Akai", 0x48: "Victor/JVC", 0x4C: "Sony",
            0x52: "Zoom",
            0x7D: "Non-commercial", 0x7E: "Universal Non-Real-Time", 0x7F: "Universal Real-Time"
        ]
        return "\(names[id] ?? "Manufacturer") [\(Hex.byte(id))]"
    }

    static func channelModeName(_ cc: UInt8) -> String? {
        switch cc {
        case 120: return "All Sound Off"
        case 121: return "Reset All Controllers"
        case 122: return "Local Control"
        case 123: return "All Notes Off"
        case 124: return "Omni Off"
        case 125: return "Omni On"
        case 126: return "Mono On"
        case 127: return "Poly On"
        default: return nil
        }
    }

    static func ccName(_ cc: UInt8) -> String? {
        switch cc {
        case 0: return "Bank Select MSB"
        case 1: return "Mod Wheel"
        case 2: return "Breath"
        case 4: return "Foot"
        case 5: return "Portamento Time"
        case 6: return "Data Entry MSB"
        case 7: return "Volume"
        case 8: return "Balance"
        case 10: return "Pan"
        case 11: return "Expression"
        case 32: return "Bank Select LSB"
        case 38: return "Data Entry LSB"
        case 64: return "Sustain"
        case 65: return "Portamento"
        case 66: return "Sostenuto"
        case 67: return "Soft Pedal"
        case 71: return "Resonance"
        case 72: return "Release"
        case 73: return "Attack"
        case 74: return "Cutoff"
        case 84: return "Portamento Ctrl"
        case 91: return "Reverb"
        case 93: return "Chorus"
        case 96: return "Data +1"
        case 97: return "Data −1"
        case 98: return "NRPN LSB"
        case 99: return "NRPN MSB"
        case 100: return "RPN LSB"
        case 101: return "RPN MSB"
        default: return nil
        }
    }
}
