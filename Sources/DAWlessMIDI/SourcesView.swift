import SwiftUI

/// A window listing every MIDI input by name, with its device and live activity.
/// Brought over from MIDI Flicker.
struct SourcesView: View {
    @EnvironmentObject private var monitor: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                PanelHeading(title: "MIDI inputs", detail: "\(monitor.sources.count) connected")
                HStack(spacing: 6) {
                    Legend("Last message from", size: 8.5)
                    Text(monitor.lastSourceName ?? "—")
                        .fontWeight(.semibold)
                        .foregroundStyle(VCS3.legend)
                        .lineLimit(1)
                }
                .font(.callout)
            }
            .padding(16)

            PanelRule()

            if monitor.sources.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cable.connector")
                        .font(.system(size: 30))
                        .foregroundStyle(VCS3.legendFaint)
                    Legend("No MIDI inputs found", size: 11, colour: VCS3.legendDim)
                    Text("Plug in a MIDI interface or device. It'll appear here automatically.")
                        .font(.caption)
                        .foregroundStyle(VCS3.legendFaint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !detected.isEmpty {
                        Section("Sending MIDI") {
                            ForEach(detected) { SourceRow(source: $0).padding(.vertical, 4) }
                        }
                    }
                    if !silent.isEmpty {
                        Section("Connected, nothing received yet") {
                            ForEach(silent) { SourceRow(source: $0).padding(.vertical, 4) }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minWidth: 460, minHeight: 300)
        .background(VCS3.panel)
        .preferredColorScheme(.dark)
    }

    /// Inputs that have sent something, in the order they were first heard
    /// (a steady order, so rows don't jump about while several are busy).
    private var detected: [Endpoint] {
        monitor.sources
            .filter { count($0) > 0 }
            .sorted { firstSeen($0) < firstSeen($1) }
    }

    private var silent: [Endpoint] { monitor.sources.filter { count($0) == 0 } }

    private func count(_ source: Endpoint) -> Int { monitor.sourceStats[source.device.uniqueID]?.count ?? 0 }

    private func firstSeen(_ source: Endpoint) -> Date {
        monitor.sourceStats[source.device.uniqueID]?.firstTime ?? .distantFuture
    }
}

private struct SourceRow: View {
    @EnvironmentObject private var monitor: MonitorModel
    let source: Endpoint

    private var deviceLine: String {
        let d = MIDIEngine.details(source.ref)
        if d.isVirtual { return "Virtual source (from software)" }
        var parts: [String] = []
        if let device = d.deviceName, device != source.name { parts.append("Device: \(device)") }
        let maker = [d.manufacturer, d.model].compactMap { $0 }.joined(separator: " ")
        if !maker.isEmpty { parts.append(maker) }
        if let port = d.portName, port != source.name, port != d.deviceName { parts.append("Port: \(port)") }
        return parts.isEmpty ? "Hardware MIDI input" : parts.joined(separator: "  ·  ")
    }

    private var activityLine: String {
        guard let s = monitor.sourceStats[source.device.uniqueID], s.count > 0 else { return "No messages yet" }
        var parts = ["\(s.count) message\(s.count == 1 ? "" : "s")"]
        if !s.channels.isEmpty {
            let list = s.channels.sorted().map { "\($0 + 1)" }.joined(separator: ", ")
            parts.append((s.channels.count == 1 ? "Channel " : "Channels ") + list)
        }
        if !s.lastBytes.isEmpty {
            let d = monitor.describe(s.lastBytes)
            parts.append("Last: " + (d.detail.isEmpty ? d.type : "\(d.type) \(d.detail)"))
        }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Lamp(lit: monitor.activeSources.contains(source.device.uniqueID), size: 9)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(VCS3.legend)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(deviceLine)
                    .font(.callout)
                    .foregroundStyle(VCS3.legendDim)
                    .lineLimit(1)
                Text(activityLine)
                    .font(.caption)
                    .foregroundStyle(VCS3.legendDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
    }
}
