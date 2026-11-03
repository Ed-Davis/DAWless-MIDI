import SwiftUI

/// The right-hand panel, brought over from MIDI Flicker: test an output,
/// record a SysEx dump, and send a SysEx file.
struct SysExPanel: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TestOutputSection()
                RecorderSection()
                PlayerSection()
            }
            .padding(14)
        }
        .background(VCS3.panel)
    }
}

/// An output picker that lists the outputs that are plugged in.
private struct OutputPicker: View {
    @EnvironmentObject private var monitor: MonitorModel
    let title: String
    @Binding var selection: MIDIUniqueIDValue?

    var body: some View {
        Picker(title, selection: $selection) {
            Text("Choose…").tag(MIDIUniqueIDValue?.none)
            ForEach(monitor.destinations) { dest in
                Text(dest.name).tag(Optional(dest.device.uniqueID))
            }
        }
    }
}

private struct TestOutputSection: View {
    @EnvironmentObject private var monitor: MonitorModel

    private var chordLabel: String {
        MonitorModel.testChord
            .map { MIDIDescriber.noteName($0, middleCOctave: monitor.middleCOctave) }
            .joined(separator: " · ")
    }

    var body: some View {
        PanelModule("Test output") {
            OutputPicker(title: "Output", selection: $monitor.testDestinationID)
            Picker("Channel", selection: $monitor.testChannel) {
                ForEach(0..<16, id: \.self) { Text("\($0 + 1)").tag($0) }
            }
            HStack(spacing: 10) {
                Button {
                    monitor.sendTestChord()
                } label: {
                    Label("Send \(chordLabel)", systemImage: "pianokeys")
                }
                .disabled(monitor.testDestinationID == nil || monitor.testNoteSounding)
                .help("Plays C, E and G together at velocity 127 for about half a second")
                Lamp(lit: monitor.testNoteSounding, size: 8)
                Spacer()
            }
            if !monitor.testStatus.isEmpty {
                Text(monitor.testStatus)
                    .font(.caption)
                    .foregroundStyle(VCS3.legendDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct RecorderSection: View {
    @EnvironmentObject private var monitor: MonitorModel

    var body: some View {
        PanelModule("Record SysEx dump") {
            HStack(spacing: 10) {
                Button {
                    monitor.isRecording.toggle()
                } label: {
                    Label(monitor.isRecording ? "Stop" : "Record",
                          systemImage: monitor.isRecording ? "stop.fill" : "record.circle")
                        .frame(minWidth: 70)
                }
                .controlSize(.large)
                .tint(monitor.isRecording ? Color.red : nil)
                .buttonStyle(.borderedProminent)
                Lamp(lit: monitor.isRecording, colour: VCS3.lampRed, size: 9)
                if monitor.isRecording {
                    Legend("Recording", size: 9, colour: VCS3.lampRed)
                }
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(monitor.recorded.count)")
                    .font(VCS3.mono(18, weight: .semibold))
                    .foregroundStyle(VCS3.lampAmber)
                Legend("message\(monitor.recorded.count == 1 ? "" : "s")", size: 8.5)
                Text(ByteCount.string(monitor.recordedBytes))
                    .font(.caption)
                    .foregroundStyle(VCS3.legendDim)
            }

            HStack {
                Button("Save .syx…") { monitor.saveRecording() }
                    .disabled(monitor.recorded.isEmpty)
                Button("Clear") { monitor.clearRecording() }
                    .disabled(monitor.recorded.isEmpty || monitor.isRecording)
            }

            Text("Arm Record, then start the dump on your device. SysEx from any input is captured, even while the log is paused.")
                .font(.caption)
                .foregroundStyle(VCS3.legendDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PlayerSection: View {
    @EnvironmentObject private var monitor: MonitorModel

    var body: some View {
        PanelModule("Play SysEx file") {
            Button {
                monitor.openSysExFile()
            } label: {
                Label("Open File…", systemImage: "folder")
            }

            if let name = monitor.playerFileName {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VCS3.legend)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(monitor.playerMessages.count) message\(monitor.playerMessages.count == 1 ? "" : "s") · \(ByteCount.string(monitor.playerBytes))")
                        .font(.caption)
                        .foregroundStyle(VCS3.legendDim)
                }
            } else {
                Text("No file loaded")
                    .font(.caption)
                    .foregroundStyle(VCS3.legendDim)
            }

            OutputPicker(title: "Send to", selection: $monitor.playerDestinationID)

            HStack(spacing: 6) {
                Text("Gap between messages")
                Spacer()
                TextField("ms", value: $monitor.messageDelayMs, format: .number.precision(.fractionLength(0)))
                    .frame(width: 56)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: $monitor.messageDelayMs, in: 0...5000, step: 10)
                    .labelsHidden()
                Text("ms").foregroundStyle(VCS3.legendDim)
            }
            .font(.callout)

            Toggle("Limit to MIDI cable speed", isOn: $monitor.throttleToWireSpeed)
                .font(.callout)
                .help("Sends no faster than a 5-pin MIDI cable can carry, so slower hardware and USB interfaces with small buffers don't drop data")

            HStack {
                Button {
                    monitor.sendPlayerFile()
                } label: {
                    Label("Send File", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(monitor.playerMessages.isEmpty || monitor.isSending || monitor.playerDestinationID == nil)

                Button("Send Recording") { monitor.sendRecording() }
                    .disabled(monitor.recorded.isEmpty || monitor.isSending || monitor.playerDestinationID == nil)
            }

            if monitor.isSending {
                ProgressView(value: monitor.sendProgress)
                HStack {
                    Text(monitor.sendStatus).font(.caption).foregroundStyle(VCS3.legendDim)
                    Spacer()
                    Button("Cancel") { monitor.cancelSending() }
                        .controlSize(.small)
                }
            } else if !monitor.sendStatus.isEmpty {
                Text(monitor.sendStatus)
                    .font(.caption)
                    .foregroundStyle(VCS3.legendDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
