import SwiftUI
import DAWlessCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var monitor: MonitorModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showSysExPanel") private var showSysEx = true

    var body: some View {
        VStack(spacing: 0) {
            ClockBar()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            PanelRule()
            HSplitView {
                patchbayPane
                    .frame(minWidth: 320, idealWidth: Patchbay.width(outputs: model.outputRows.count) + 40,
                           maxWidth: .infinity, maxHeight: .infinity)
                MonitorPane()
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                if showSysEx {
                    SysExPanel()
                        .frame(minWidth: 270, idealWidth: 300, maxWidth: 420, maxHeight: .infinity)
                }
            }
            PanelRule()
            HStack {
                Legend("Click a hole to patch. Right-click a pin for channels and filters.", size: 8.5, colour: VCS3.legendFaint)
                Spacer()
                Legend("DAWless MIDI \(AppInfo.version) (\(AppInfo.build)) \(AppInfo.credit)", size: 8.5, colour: VCS3.legendFaint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(VCS3.panel)
        .preferredColorScheme(.dark)
        .collectScreenshotAnchors()
        .toolbarBackground(VCS3.panel, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                DetectedSourceBadge()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    openWindow(id: "sources")
                } label: {
                    Label("MIDI Sources", systemImage: "cable.connector")
                }
                .help("Show every MIDI input, with its device and what it's sending")

                Toggle(isOn: $monitor.paused) {
                    Label(monitor.paused ? "Resume" : "Pause", systemImage: monitor.paused ? "play.fill" : "pause.fill")
                }
                .help("Pause the log (counters, lights and SysEx recording keep going)")

                Button {
                    monitor.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .help("Clear the log and counters")

                Button {
                    monitor.exportLog()
                } label: {
                    Label("Export Log", systemImage: "square.and.arrow.up")
                }
                .help("Save the log you're looking at as a text file")

                Menu {
                    Toggle("Hide Clock & Active Sensing", isOn: $monitor.hideRealTime)
                    Picker("Middle C (note 60)", selection: $monitor.middleCOctave) {
                        Text("C3  (Akai, Yamaha, Roland)").tag(3)
                        Text("C4  (scientific)").tag(4)
                    }
                } label: {
                    Label("Options", systemImage: "slider.horizontal.3")
                }

                FocusMenu()

                Toggle(isOn: $showSysEx) {
                    Label("SysEx & Test", systemImage: "sidebar.right")
                }
                .help(showSysEx ? "Hide the SysEx and test panel" : "Show the SysEx and test panel")
            }
        }
        .alert("DAWless MIDI can't use MIDI", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
    }

    @ViewBuilder private var patchbayPane: some View {
        if model.inputRows.isEmpty && model.outputRows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 30))
                    .foregroundStyle(VCS3.legendFaint)
                Legend("No MIDI devices", size: 11, colour: VCS3.legend)
                Text("Plug in a synth, controller or interface and it'll appear here.")
                    .font(.caption)
                    .foregroundStyle(VCS3.legendDim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.horizontal, .vertical]) {
                Patchbay()
                    .screenshotAnchor("patchbay")
            }
        }
    }
}

struct PanelRule: View {
    var body: some View {
        Rectangle().fill(Color.black.opacity(0.6)).frame(height: 1)
            .overlay(alignment: .bottom) { Rectangle().fill(VCS3.legend.opacity(0.06)).frame(height: 1).offset(y: 1) }
    }
}

// MARK: - Clock

/// A labelled group of controls on the panel.
struct PanelControl<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Legend(title, size: 8.5)
            HStack(spacing: 6) { content }
                .frame(minHeight: 24)
        }
    }
}

struct ClockBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 22) {
            PanelControl("Clock source") {
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
                .labelsHidden()
                .frame(width: 220)
                .help("Where clock comes from. Clock goes only to the outputs with a red pin in the Clock row; clock from any other input is not passed on.")
            }

            switch model.patch.clockSource {
            case .off:
                PanelControl("Clock") {
                    Text("No clock is sent.")
                        .font(.callout)
                        .foregroundStyle(VCS3.legendDim)
                }
            case .internal:
                internalControls
            case .input:
                followingStatus
            }

            Spacer(minLength: 8)

            PanelControl("Panic") {
                Button {
                    model.panic()
                } label: {
                    Label("All Notes Off", systemImage: "exclamationmark.octagon")
                }
                .help("Sends all notes off, all sound off and sustain off on every channel of every output (⌘.)")
            }
        }
    }

    @ViewBuilder private var internalControls: some View {
        PanelControl("Tempo") {
            HStack(spacing: 4) {
                TextField("BPM", value: model.bpm, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.plain)
                    .font(VCS3.mono(15, weight: .semibold))
                    .foregroundStyle(VCS3.lampAmber)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 62)
                Legend("BPM", size: 8)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(VCS3.well))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(VCS3.rule, lineWidth: 1))
            Stepper("BPM", onIncrement: { model.nudgeBPM(1) }, onDecrement: { model.nudgeBPM(-1) })
                .labelsHidden()
            Button("Tap") { model.tap() }
                .help("Tap a few times in time to set the tempo (⌘T)")
        }

        PanelControl("Transport") {
            Lamp(lit: model.playing, colour: VCS3.lampGreen, size: 8)
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
            Toggle("Clock while stopped", isOn: $model.patch.clockWhileStopped)
                .toggleStyle(.checkbox)
                .font(.callout)
                .help("Keep sending clock when stopped, so arpeggiators, LFOs and delays stay in time")
        }
    }

    private var followingStatus: some View {
        PanelControl("Following") {
            Lamp(lit: model.externalPlaying, colour: VCS3.lampGreen, size: 8)
            if let bpm = model.externalBPM {
                Text("\(BPMFormat.string(bpm)) BPM")
                    .font(VCS3.mono(15, weight: .semibold))
                    .foregroundStyle(VCS3.lampAmber)
            } else {
                Text("Waiting for clock…")
                    .font(.callout)
                    .foregroundStyle(VCS3.legendDim)
            }
        }
        .help("The tempo and transport of the input you're following")
    }
}

// MARK: - Route menu

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
