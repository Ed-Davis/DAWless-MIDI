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
                .frame(minWidth: 560, minHeight: 360)
        }
        .defaultSize(width: 860, height: 520)
        .commands {
            CommandGroup(replacing: .newItem) {}
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
        }

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

final class AppDelegate: NSObject, NSApplicationDelegate {
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
            .credits: NSAttributedString(string: "MIDI routing and clock for playing without a DAW, \(credit).",
                                         attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]),
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): copyright,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}
