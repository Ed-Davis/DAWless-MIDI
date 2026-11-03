import SwiftUI
import AppKit

// The monitor, brought over from MIDI Flicker: a tile for each channel, the
// log, and the full detail of whichever message you click.

struct MonitorPane: View {
    @EnvironmentObject private var monitor: MonitorModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                PanelHeading(title: "Monitor",
                             detail: monitor.focusedSource.map { "only \($0.name)" } ?? "all inputs")
                ChannelTiles()
            }
            .padding(16)
            PanelRule()
            LogView()
        }
        .alert("DAWless MIDI", isPresented: Binding(get: { monitor.errorMessage != nil },
                                                   set: { if !$0 { monitor.errorMessage = nil } })) {
            Button("OK", role: .cancel) { monitor.errorMessage = nil }
        } message: {
            Text(monitor.errorMessage ?? "")
        }
    }
}

// MARK: - Toolbar

/// Which device is sending right now. Every input is listened to; the sender
/// is worked out from the data, so nothing needs choosing.
struct DetectedSourceBadge: View {
    @EnvironmentObject private var monitor: MonitorModel

    var body: some View {
        HStack(spacing: 7) {
            Lamp(lit: !monitor.activeSources.isEmpty, size: 8)
            if monitor.sources.isEmpty {
                Text("No MIDI inputs connected").foregroundStyle(.secondary)
            } else if let focused = monitor.focusedSource {
                Text("Monitoring only").foregroundStyle(.secondary)
                Text(focused.name).fontWeight(.semibold).lineLimit(1)
            } else if let name = monitor.lastSourceName {
                Text("Receiving from").foregroundStyle(.secondary)
                Text(name).fontWeight(.semibold).lineLimit(1)
            } else {
                Text("Listening on all \(monitor.sources.count) input\(monitor.sources.count == 1 ? "" : "s")…")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .frame(minWidth: 220, alignment: .leading)
        .help(monitor.focusSourceID == nil ? "The device that sent the most recent message" : "The monitor is showing one input only")
    }
}

struct FocusMenu: View {
    @EnvironmentObject private var monitor: MonitorModel

    var body: some View {
        Menu {
            Button("All Inputs") { monitor.focusSourceID = nil }
            Divider()
            ForEach(monitor.sources) { source in
                Button(source.name) { monitor.focusSourceID = source.device.uniqueID }
            }
        } label: {
            Label("Focus Input", systemImage: "scope")
        }
        .disabled(monitor.sources.isEmpty)
        .help(monitor.focusSourceID == nil ? "Monitor one input only" : "The monitor is showing one input only")
    }
}

// MARK: - Channel tiles

struct ChannelTiles: View {
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)

    var body: some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Slot.channels) { SlotTile(slot: $0) }
            }
            HStack(spacing: 6) {
                AllTile()
                SlotTile(slot: .system)
                SlotTile(slot: .sysex)
            }
        }
    }
}

private struct TileFace: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(selected ? VCS3.panelLit : VCS3.panelRaised))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(selected ? VCS3.lampAmber : VCS3.rule, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct SlotTile: View {
    @EnvironmentObject private var monitor: MonitorModel
    let slot: Slot

    private var lampColour: Color {
        switch slot {
        case .channel: return VCS3.lampGreen
        case .system: return VCS3.lampAmber
        case .sysex: return VCS3.lampViolet
        }
    }

    private var summary: String {
        if slot == .system, let bpm = monitor.clockBPM {
            return String(format: "Clock %.1f BPM", bpm)
        }
        guard let bytes = monitor.stats[slot]?.lastBytes, !bytes.isEmpty else { return "—" }
        if slot == .sysex {
            return "\(MIDIDescriber.manufacturer(bytes)) · \(ByteCount.string(bytes.count))"
        }
        let d = monitor.describe(bytes)
        return d.detail.isEmpty ? d.type : "\(d.type) \(d.detail)"
    }

    var body: some View {
        let selected = monitor.selectedSlot == slot
        Button {
            monitor.selectedSlot = selected ? nil : slot
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Lamp(lit: monitor.activeSlots.contains(slot), colour: lampColour)
                    Legend(slot.shortTitle, size: 9.5, colour: VCS3.legend)
                    Spacer(minLength: 2)
                    Text("\(monitor.stats[slot]?.count ?? 0)")
                        .font(VCS3.mono(9))
                        .foregroundStyle(VCS3.legendDim)
                }
                Text(summary)
                    .font(.system(size: 9.5))
                    .foregroundStyle(VCS3.legend.opacity(0.75))
                    .lineLimit(1)
                Text(monitor.stats[slot]?.lastSourceName ?? " ")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(VCS3.legendFaint)
                    .lineLimit(1)
            }
            .modifier(TileFace(selected: selected))
        }
        .buttonStyle(.plain)
        .help("Show the \(slot.title) log")
    }
}

struct AllTile: View {
    @EnvironmentObject private var monitor: MonitorModel

    var body: some View {
        let selected = monitor.selectedSlot == nil
        Button {
            monitor.selectedSlot = nil
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Lamp(lit: !monitor.activeSlots.isEmpty, colour: VCS3.lampBlue)
                    Legend("All", size: 9.5, colour: VCS3.legend)
                    Spacer(minLength: 2)
                    Text("\(monitor.totalCount)")
                        .font(VCS3.mono(9))
                        .foregroundStyle(VCS3.legendDim)
                }
                Text(monitor.sources.isEmpty ? "No MIDI inputs found" : "From: \(monitor.lastSourceName ?? "—")")
                    .font(.system(size: 9.5))
                    .foregroundStyle(VCS3.legend.opacity(0.75))
                    .lineLimit(1)
                Text("Listening on \(monitor.sources.count) input\(monitor.sources.count == 1 ? "" : "s")")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(VCS3.legendFaint)
                    .lineLimit(1)
            }
            .modifier(TileFace(selected: selected))
        }
        .buttonStyle(.plain)
        .help("Show every message mixed together")
    }
}

// MARK: - Log

struct LogView: View {
    @EnvironmentObject private var monitor: MonitorModel
    @State private var follow = true
    @State private var selection: UInt64?

    private var selectedEvent: MIDIEvent? {
        guard let id = selection else { return nil }
        return monitor.visibleLog.last { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Legend(monitor.selectedSlot?.title ?? "All channels", size: 10, colour: VCS3.legend)
                if monitor.paused {
                    Legend("Paused", size: 8.5, colour: VCS3.panel)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(VCS3.lampAmber))
                }
                Text("\(monitor.visibleLog.count) messages")
                    .font(.caption)
                    .foregroundStyle(VCS3.legendDim)
                Spacer()
                Toggle("Follow newest", isOn: $follow)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)

            LogHeader()

            ScrollViewReader { proxy in
                List(monitor.visibleLog, selection: $selection) { event in
                    LogRow(event: event, description: monitor.describe(event.bytes))
                        .id(event.id)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(VCS3.well)
                .environment(\.defaultMinListRowHeight, 18)
                .onChange(of: monitor.visibleLog.last?.id) { newest in
                    if follow, let newest { proxy.scrollTo(newest, anchor: .bottom) }
                }
                .onChange(of: follow) { on in
                    if on, let newest = monitor.visibleLog.last?.id {
                        selection = nil
                        proxy.scrollTo(newest, anchor: .bottom)
                    }
                }
                .onChange(of: monitor.selectedSlot) { _ in
                    selection = nil
                    if let newest = monitor.visibleLog.last?.id { proxy.scrollTo(newest, anchor: .bottom) }
                }
            }
            .onChange(of: selection) { sel in
                if sel != nil { follow = false }
            }
            .overlay {
                if monitor.visibleLog.isEmpty {
                    EmptyLogMessage(slot: monitor.selectedSlot, noSources: monitor.sources.isEmpty)
                }
            }

            if let event = selectedEvent {
                PanelRule()
                EventDetailView(event: event)
                    .frame(height: 190)
            }
        }
    }
}

private struct EmptyLogMessage: View {
    let slot: Slot?
    let noSources: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform.path")
                .font(.system(size: 26))
                .foregroundStyle(VCS3.legendFaint)
            Legend(noSources ? "No MIDI inputs found" : "Waiting for MIDI", size: 10.5, colour: VCS3.legendDim)
            Text(noSources ? "Connect a MIDI interface or device. It'll appear automatically."
                           : "Play something on \(slot?.title.lowercased() ?? "any channel").")
                .font(.caption)
                .foregroundStyle(VCS3.legendFaint)
        }
        .allowsHitTesting(false)
    }
}

private enum LogColumns {
    static let time: CGFloat = 88
    static let source: CGFloat = 120
    static let channel: CGFloat = 34
    static let type: CGFloat = 118
    static let detail: CGFloat = 200
}

private struct LogHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Legend("Time", size: 8.5).frame(width: LogColumns.time, alignment: .leading)
            Legend("Source", size: 8.5).frame(width: LogColumns.source, alignment: .leading)
            Legend("Ch", size: 8.5).frame(width: LogColumns.channel, alignment: .leading)
            Legend("Message", size: 8.5).frame(width: LogColumns.type, alignment: .leading)
            Legend("Value", size: 8.5).frame(width: LogColumns.detail, alignment: .leading)
            Legend("Bytes (hex)", size: 8.5).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(VCS3.panelRaised)
    }
}

struct LogRow: View {
    let event: MIDIEvent
    let description: MIDIDescription

    private var channelText: String {
        switch event.slot {
        case .channel(let c): return "\(c + 1)"
        case .system: return "SYS"
        case .sysex: return "SX"
        }
    }

    private var typeColour: Color {
        guard let status = event.bytes.first else { return VCS3.legend }
        if status == 0xF0 { return VCS3.lampViolet }
        if status >= 0xF0 { return VCS3.lampAmber }
        switch status & 0xF0 {
        case 0x90: return event.bytes.count > 2 && event.bytes[2] == 0 ? VCS3.legendDim : VCS3.lampGreen
        case 0x80: return VCS3.legendDim
        case 0xB0: return VCS3.lampBlue
        case 0xC0: return .pink
        case 0xE0: return .teal
        default: return VCS3.legend
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(TimeFormat.formatter.string(from: event.time))
                .frame(width: LogColumns.time, alignment: .leading)
                .foregroundStyle(VCS3.legendDim)
            Text(event.sourceName)
                .frame(width: LogColumns.source, alignment: .leading)
                .lineLimit(1)
                .foregroundStyle(VCS3.legendDim)
            Text(channelText)
                .frame(width: LogColumns.channel, alignment: .leading)
                .foregroundStyle(VCS3.legend)
            Text(description.type)
                .frame(width: LogColumns.type, alignment: .leading)
                .foregroundStyle(typeColour)
                .lineLimit(1)
            Text(description.detail)
                .frame(width: LogColumns.detail, alignment: .leading)
                .foregroundStyle(VCS3.legend)
                .lineLimit(1)
            Text(Hex.string(event.bytes, limit: 16))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .foregroundStyle(VCS3.legendDim)
        }
        .font(VCS3.mono(10.5))
    }
}

struct EventDetailView: View {
    @EnvironmentObject private var monitor: MonitorModel
    let event: MIDIEvent

    private static let dumpLimit = 64 * 1024

    var body: some View {
        let d = monitor.describe(event.bytes)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(d.type).font(.headline).foregroundStyle(VCS3.legend)
                Text(d.detail).foregroundStyle(VCS3.legendDim).lineLimit(1)
                Spacer()
                Button("Copy Hex") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Hex.string(event.bytes), forType: .string)
                }
                if event.slot == .sysex {
                    Button("Save as .syx…") {
                        monitor.saveSysEx([event.bytes], defaultName: "SysEx Message.syx")
                    }
                }
            }
            Text("\(event.sourceName) · \(TimeFormat.formatter.string(from: event.time)) · \(ByteCount.string(event.bytes.count))")
                .font(.caption)
                .foregroundStyle(VCS3.legendDim)
            // A two-way scroll view centres anything smaller than itself, so
            // keep the dump at the top left by making it fill the space.
            GeometryReader { geo in
                ScrollView([.vertical, .horizontal]) {
                    Text(dumpText)
                        .font(VCS3.mono(10.5))
                        .foregroundStyle(VCS3.legend)
                        .textSelection(.enabled)
                        .padding(6)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                }
            }
            .background(RoundedRectangle(cornerRadius: 4).fill(VCS3.well))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(VCS3.rule, lineWidth: 1))
        }
        .padding(10)
    }

    private var dumpText: String {
        if event.bytes.count > Self.dumpLimit {
            return Hex.dump(Array(event.bytes.prefix(Self.dumpLimit))) +
                "\n… \(ByteCount.string(event.bytes.count - Self.dumpLimit)) more (use Save or Copy Hex for the whole message)"
        }
        return Hex.dump(event.bytes)
    }
}
