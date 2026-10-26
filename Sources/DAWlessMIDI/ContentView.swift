import SwiftUI
import DAWlessCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ClockBar()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            if model.inputRows.isEmpty && model.outputRows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cable.connector")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("No MIDI devices")
                        .font(.headline)
                    Text("Plug in a synth, controller or interface and it'll appear here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    RoutingMatrix()
                        .padding(16)
                }
            }
            Divider()
            HStack {
                Text("Click a square to send an input to an output. Right-click it for channels and filters.")
                Spacer()
                Text("DAWless MIDI \(AppInfo.version) (\(AppInfo.build)) \(AppInfo.credit)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .alert("DAWless MIDI can't use MIDI", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
    }
}

// MARK: - Clock

struct ClockBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Picker("Clock", selection: $model.patch.clockSource) {
                Text("Off").tag(ClockSource.off)
                Text("Internal").tag(ClockSource.internal)
                if !model.inputRows.isEmpty {
                    Divider()
                    ForEach(model.inputRows) { row in
                        Text("From \(row.name)\(row.online ? "" : " (not connected)")").tag(ClockSource.input(row.device))
                    }
                }
            }
            .frame(width: 240)
            .help("Where clock comes from. Clock goes only to the outputs ticked in the Clock row; clock from any other input is not passed on.")

            switch model.patch.clockSource {
            case .off:
                Text("No clock is sent.")
                    .foregroundStyle(.secondary)
            case .internal:
                internalControls
            case .input:
                followingStatus
            }

            Spacer(minLength: 8)

            Button {
                model.panic()
            } label: {
                Label("All Notes Off", systemImage: "exclamationmark.octagon")
            }
            .help("Sends all notes off, all sound off and sustain off on every channel of every output (⌘.)")
        }
    }

    @ViewBuilder private var internalControls: some View {
        HStack(spacing: 6) {
            TextField("BPM", value: model.bpm, format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
            Stepper("BPM", onIncrement: { model.nudgeBPM(1) }, onDecrement: { model.nudgeBPM(-1) })
                .labelsHidden()
            Text("BPM")
                .foregroundStyle(.secondary)
            Button("Tap") { model.tap() }
                .help("Tap a few times in time to set the tempo (⌘T)")
        }

        HStack(spacing: 6) {
            Button {
                model.togglePlay()
            } label: {
                Label(model.playing ? "Stop" : "Start", systemImage: model.playing ? "stop.fill" : "play.fill")
                    .frame(minWidth: 52)
            }
            .help(model.playing ? "Send Stop (⌘↩)" : "Send Start, so sequencers play from the top (⌘↩)")
            if !model.playing {
                Button("Continue") { model.resume() }
                    .help("Send Continue, so sequencers carry on from where they stopped")
            }
        }

        Toggle("Clock while stopped", isOn: $model.patch.clockWhileStopped)
            .toggleStyle(.checkbox)
            .help("Keep sending clock when stopped, so arpeggiators, LFOs and delays stay in time")
    }

    private var followingStatus: some View {
        HStack(spacing: 6) {
            Image(systemName: model.externalPlaying ? "play.fill" : "stop.fill")
                .foregroundStyle(model.externalPlaying ? Color.green : Color.secondary)
            if let bpm = model.externalBPM {
                Text("\(BPMFormat.string(bpm)) BPM")
                    .monospacedDigit()
            } else {
                Text("Waiting for clock…")
                    .foregroundStyle(.secondary)
            }
        }
        .help("The tempo and transport of the input you're following")
    }
}

// MARK: - Matrix

struct RoutingMatrix: View {
    @EnvironmentObject private var model: AppModel
    static let cellWidth: CGFloat = 78
    static let nameWidth: CGFloat = 190

    var body: some View {
        let inputs = model.inputRows
        let outputs = model.outputRows
        Grid(alignment: .center, horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("To →").font(.caption).foregroundStyle(.secondary)
                    Text("From ↓").font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: Self.nameWidth, alignment: .leading)
                ForEach(outputs) { OutputHeader(row: $0) }
            }

            if inputs.isEmpty {
                GridRow {
                    Text("No inputs connected")
                        .foregroundStyle(.secondary)
                        .frame(width: Self.nameWidth, alignment: .leading)
                }
            }
            ForEach(inputs) { input in
                GridRow {
                    InputLabel(row: input)
                    ForEach(outputs) { output in
                        RouteCell(input: input, output: output)
                    }
                }
            }

            GridRow {
                Divider().gridCellColumns(outputs.count + 1)
            }

            GridRow {
                HStack(spacing: 6) {
                    Image(systemName: "metronome")
                    Text("Clock")
                        .fontWeight(.medium)
                    Text("from \(model.clockSourceName)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: Self.nameWidth, alignment: .leading)
                ForEach(outputs) { ClockCell(row: $0) }
            }
        }
    }
}

struct ActivityLight: View {
    let lit: Bool
    let online: Bool

    var body: some View {
        Circle()
            .fill(lit ? Color.green : Color.secondary.opacity(online ? 0.25 : 0.1))
            .frame(width: 7, height: 7)
    }
}

struct OutputHeader: View {
    @EnvironmentObject private var model: AppModel
    let row: DeviceRow

    var body: some View {
        VStack(spacing: 4) {
            Text(row.name)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            if !row.online {
                Text("not connected").font(.caption2).foregroundStyle(.secondary)
            }
            ActivityLight(lit: model.litOutputs.contains(row.device), online: row.online)
        }
        .frame(width: RoutingMatrix.cellWidth)
        .opacity(row.online ? 1 : 0.55)
        .help(row.name)
        .contextMenu {
            Button("Remove All Routes to \(row.name)") { model.clearRoutes(to: row.device) }
            if !row.online {
                Button("Forget \(row.name)") { model.forget(output: row.device) }
            }
        }
    }
}

struct InputLabel: View {
    @EnvironmentObject private var model: AppModel
    let row: DeviceRow

    var body: some View {
        HStack(spacing: 6) {
            ActivityLight(lit: model.litInputs.contains(row.device), online: row.online)
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if !row.online {
                Text("not connected").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: RoutingMatrix.nameWidth, alignment: .leading)
        .opacity(row.online ? 1 : 0.55)
        .help(row.name)
        .contextMenu {
            Button("Remove All Routes from \(row.name)") { model.clearRoutes(from: row.device) }
            if !row.online {
                Button("Forget \(row.name)") { model.forget(input: row.device) }
            }
        }
    }
}

struct RouteCell: View {
    @EnvironmentObject private var model: AppModel
    let input: DeviceRow
    let output: DeviceRow

    var body: some View {
        let routed = model.isRouted(input.device, output.device)
        let summary = routed ? model.filter(input.device, output.device).wrappedValue.summary : nil
        Button {
            model.toggleRoute(input.device, output.device)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(routed ? Color.accentColor : Color.secondary.opacity(0.12))
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(routed ? 0 : 0.25))
                if let summary {
                    Text(summary)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 3)
                } else if routed {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: RoutingMatrix.cellWidth, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(input.online && output.online ? 1 : 0.5)
        .help(routed ? "\(input.name) → \(output.name)\(summary.map { " (\($0))" } ?? ""). Right-click for channels and filters."
                     : "Send \(input.name) to \(output.name)")
        .contextMenu { RouteMenu(input: input.device, output: output.device) }
    }
}

struct RouteMenu: View {
    @EnvironmentObject private var model: AppModel
    let input: DeviceID
    let output: DeviceID

    var body: some View {
        if model.isRouted(input, output) {
            let filter = model.filter(input, output)
            Picker("Listen to", selection: filter.channel) {
                Text("All Channels").tag(Int?.none)
                Divider()
                ForEach(1...16, id: \.self) { Text("Channel \($0)").tag(Int?.some($0)) }
            }
            Picker("Send On", selection: filter.sendOn) {
                Text("Same Channel").tag(Int?.none)
                Divider()
                ForEach(1...16, id: \.self) { Text("Channel \($0)").tag(Int?.some($0)) }
            }
            Menu("Let Through") {
                ForEach(MessageKind.filterable, id: \.self) { kind in
                    Toggle(kind.label, isOn: Binding(
                        get: { !filter.wrappedValue.blocked.contains(kind) },
                        set: { on in
                            var f = filter.wrappedValue
                            if on { f.blocked.remove(kind) } else { f.blocked.insert(kind) }
                            filter.wrappedValue = f
                        }))
                }
            }
            Divider()
            Button("Reset Channels and Filters") { filter.wrappedValue = RouteFilter() }
                .disabled(filter.wrappedValue.isDefault)
            Button("Remove Route") { model.toggleRoute(input, output) }
        } else {
            Button("Send \(input.name) to \(output.name)") { model.toggleRoute(input, output) }
        }
    }
}

struct ClockCell: View {
    @EnvironmentObject private var model: AppModel
    let row: DeviceRow

    var body: some View {
        let off = model.patch.clockSource == .off
        let on = model.patch.sendsClock(to: row.device)
        Button {
            model.clockBinding(row.device).wrappedValue.toggle()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(on ? Color.orange.opacity(off ? 0.35 : 1) : Color.secondary.opacity(0.12))
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(on ? 0 : 0.25))
                if on {
                    Image(systemName: "metronome.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: RoutingMatrix.cellWidth, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(row.online ? 1 : 0.5)
        .help(off ? "Clock is off. Choose a clock source at the top to send clock to \(row.name)."
                  : on ? "\(row.name) gets clock from \(model.clockSourceName)" : "Send clock to \(row.name)")
    }
}
