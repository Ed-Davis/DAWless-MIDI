import Foundation
import SwiftUI
import DAWlessCore

/// A row or column of the matrix: a device, connected or not.
struct DeviceRow: Identifiable, Hashable {
    let device: DeviceID
    let online: Bool
    var id: DeviceID { device }
    var name: String { device.name }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sources: [Endpoint] = []
    @Published private(set) var destinations: [Endpoint] = []
    @Published var patch: Patch {
        didSet {
            guard patch != oldValue else { return }
            save()
            push()
        }
    }
    @Published private(set) var playing = false
    @Published private(set) var externalBPM: Double?
    @Published private(set) var externalPlaying = false
    @Published private(set) var litInputs: Set<DeviceID> = []
    @Published private(set) var litOutputs: Set<DeviceID> = []
    @Published var problem: String?

    private let engine: MIDIEngine?
    private var clock: ClockGenerator!
    private var tapTempo = TapTempo()
    private var timer: Timer?
    private static let patchKey = "patch"

    init() {
        var startupProblem: String?
        var engine: MIDIEngine?
        do {
            engine = try MIDIEngine()
        } catch {
            startupProblem = error.localizedDescription
        }
        self.engine = engine
        if let data = UserDefaults.standard.data(forKey: Self.patchKey),
           let saved = try? JSONDecoder().decode(Patch.self, from: data) {
            patch = saved
        } else {
            patch = Patch()
        }
        problem = startupProblem
        clock = ClockGenerator { [weak engine] bytes, time in engine?.sendClock(bytes, at: time) }
        engine?.onDevicesChanged = { [weak self] in
            Task { @MainActor in self?.rescan() }
        }
        rescan()
        push()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Devices

    /// Inputs down the side: connected ones, then any the setup uses that aren't plugged in.
    var inputRows: [DeviceRow] {
        let online = sources.map { DeviceRow(device: $0.device, online: true) }
        let ids = Set(sources.map(\.device.uniqueID))
        let offline = patch.inputsUsed.filter { !ids.contains($0.uniqueID) }.map { DeviceRow(device: $0, online: false) }
        return online + offline
    }

    /// Outputs across the top, the same way.
    var outputRows: [DeviceRow] {
        let online = destinations.map { DeviceRow(device: $0.device, online: true) }
        let ids = Set(destinations.map(\.device.uniqueID))
        let offline = patch.outputsUsed.filter { !ids.contains($0.uniqueID) }.map { DeviceRow(device: $0, online: false) }
        return online + offline
    }

    func rescan() {
        sources = MIDIEngine.sources()
        destinations = MIDIEngine.destinations()
        engine?.listen(to: sources)
        var p = patch
        if p.rebind(sources: sources.map(\.device), destinations: destinations.map(\.device)) {
            patch = p        // pushes the new routing
        } else {
            push()
        }
    }

    private func push() {
        engine?.apply(patch, sources: sources, destinations: destinations)
        clock.configure(enabled: patch.clockSource == .internal, bpm: patch.bpm, whileStopped: patch.clockWhileStopped)
        playing = clock.isPlaying
    }

    private func save() {
        if let data = try? JSONEncoder().encode(patch) {
            UserDefaults.standard.set(data, forKey: Self.patchKey)
        }
    }

    private func poll() {
        guard let engine else { return }
        let lit = engine.activity(within: 0.12)
        if lit.inputs != litInputs { litInputs = lit.inputs }
        if lit.outputs != litOutputs { litOutputs = lit.outputs }
        if case .input = patch.clockSource {
            let ext = engine.externalClock()
            let rounded = ext.bpm.map { ($0 * 10).rounded() / 10 }
            if rounded != externalBPM { externalBPM = rounded }
            if ext.playing != externalPlaying { externalPlaying = ext.playing }
        } else if externalBPM != nil || externalPlaying {
            externalBPM = nil
            externalPlaying = false
        }
    }

    // MARK: Routes

    func isRouted(_ from: DeviceID, _ to: DeviceID) -> Bool { patch.route(from: from, to: to) != nil }

    func toggleRoute(_ from: DeviceID, _ to: DeviceID) {
        patch.setRouted(!isRouted(from, to), from: from, to: to)
    }

    func filter(_ from: DeviceID, _ to: DeviceID) -> Binding<RouteFilter> {
        Binding(
            get: { self.patch.route(from: from, to: to)?.filter ?? RouteFilter() },
            set: { self.patch.setFilter($0, from: from, to: to) }
        )
    }

    func clearRoutes(from input: DeviceID) {
        patch.routes.removeAll { $0.from == input }
    }

    func clearRoutes(to output: DeviceID) {
        patch.routes.removeAll { $0.to == output }
    }

    /// Takes a device that isn't plugged in out of the setup altogether.
    func forget(input: DeviceID) {
        clearRoutes(from: input)
        if patch.clockSource == .input(input) { patch.clockSource = .off }
    }

    func forget(output: DeviceID) {
        clearRoutes(to: output)
        patch.setClock(false, to: output)
    }

    // MARK: Clock

    var clockSourceName: String {
        switch patch.clockSource {
        case .off: return "Off"
        case .internal: return "Internal"
        case .input(let d): return d.name
        }
    }

    func clockBinding(_ output: DeviceID) -> Binding<Bool> {
        Binding(get: { self.patch.sendsClock(to: output) }, set: { self.patch.setClock($0, to: output) })
    }

    var bpm: Binding<Double> {
        Binding(get: { self.patch.bpm }, set: { self.patch.setBPM($0) })
    }

    func nudgeBPM(_ by: Double) { patch.setBPM(patch.bpm.rounded() + by) }

    func tap() {
        if let bpm = tapTempo.tap(at: HostTime.now) { patch.setBPM(bpm) }
    }

    func start() {
        clock.start()
        playing = clock.isPlaying
    }

    func resume() {
        clock.resume()
        playing = clock.isPlaying
    }

    func stop() {
        clock.stop()
        playing = clock.isPlaying
    }

    func togglePlay() { playing ? stop() : start() }

    var canPlay: Bool { patch.clockSource == .internal }

    func panic() {
        engine?.panic(destinations)
    }
}
