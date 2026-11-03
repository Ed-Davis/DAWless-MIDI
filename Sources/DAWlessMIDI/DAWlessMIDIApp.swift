import SwiftUI
import AppKit

@main
struct DAWlessMIDIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("DAWless MIDI", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.monitor)
                .frame(minWidth: 1000, minHeight: 640)
                .task {
                    if Screenshot.isActive { await Screenshot.run(model: model) }
                }
        }
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Open SysEx File…") { model.monitor.openSysExFile() }
                    .keyboardShortcut("o")
                Button("Export Log…") { model.monitor.exportLog() }
                    .keyboardShortcut("e")
            }
            CommandGroup(replacing: .appInfo) {
                Button("About DAWless MIDI") { AppInfo.showAbout() }
            }
            CommandMenu("Clock") {
                Button(model.playing ? "Stop" : "Start") { model.togglePlay() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canPlay)
                Button("Continue") { model.resume() }
                    .disabled(!model.canPlay || model.playing)
                Button("Tap Tempo") { model.tap() }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(!model.canPlay)
                Divider()
                Button("Faster") { model.nudgeBPM(1) }
                    .keyboardShortcut("=", modifiers: .command)
                    .disabled(!model.canPlay)
                Button("Slower") { model.nudgeBPM(-1) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(!model.canPlay)
                Divider()
                Button("All Notes Off") { model.panic() }
                    .keyboardShortcut(".", modifiers: .command)
            }
            MonitorCommands(monitor: model.monitor)
        }

        Window("MIDI Sources", id: "sources") {
            SourcesView()
                .environmentObject(model.monitor)
        }
        .defaultSize(width: 620, height: 440)

        // Stays in the menu bar while the window's closed, so the routing
        // keeps running in the background.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            Image(systemName: model.playing ? "metronome.fill" : "pianokeys")
        }
    }
}

/// The Monitor menu, from MIDI Flicker.
struct MonitorCommands: Commands {
    @ObservedObject var monitor: MonitorModel

    var body: some Commands {
        CommandMenu("Monitor") {
            Button(monitor.paused ? "Resume Log" : "Pause Log") { monitor.paused.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Clear Log") { monitor.clear() }
                .keyboardShortcut("k")
            Divider()
            Button("Show All Channels") { monitor.selectedSlot = nil }
                .keyboardShortcut("0")
            Button("Show System") { monitor.selectedSlot = .system }
            Button("Show SysEx") { monitor.selectedSlot = .sysex }
            Divider()
            Button("Monitor All Inputs") { monitor.focusSourceID = nil }
                .disabled(monitor.focusSourceID == nil)
            Divider()
            Button(monitor.isRecording ? "Stop Recording SysEx" : "Record SysEx") { monitor.isRecording.toggle() }
                .keyboardShortcut("r")
            Button("Send Test Chord") { monitor.sendTestChord() }
                .disabled(monitor.testDestinationID == nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Screenshot.isActive {
            // Run as a bare executable on the build machine: show a normal window.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Closing the window doesn't stop the routing: the app carries on in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch model.patch.clockSource {
        case .off:
            Text("Clock off")
        case .internal:
            Text("Internal clock — \(BPMFormat.string(model.patch.bpm)) BPM")
            Button(model.playing ? "Stop" : "Start") { model.togglePlay() }
            if !model.playing { Button("Continue") { model.resume() } }
        case .input(let d):
            Text("Following \(d.name)\(model.externalBPM.map { " — \(BPMFormat.string($0)) BPM" } ?? "")")
        }
        Divider()
        Button("All Notes Off") { model.panic() }
        Divider()
        Button("Show DAWless MIDI") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit DAWless MIDI") { NSApp.terminate(nil) }
    }
}

enum BPMFormat {
    static func string(_ bpm: Double) -> String {
        bpm == bpm.rounded() ? String(format: "%.0f", bpm) : String(format: "%.1f", bpm)
    }
}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
    static let credit = "by Ed Davis"
    static let copyright = "Copyright © 2026 Ed Davis. All rights reserved."

    static func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "DAWless MIDI",
            .applicationVersion: version,
            .version: "build \(build)",
            .credits: NSAttributedString(string: "MIDI routing, clock and monitoring for playing without a DAW, \(credit).",
                                         attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]),
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): copyright,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}
