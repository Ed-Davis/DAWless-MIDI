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
    /// The MIDI Flicker side: monitor, log, SysEx and test chord.
    let monitor: MonitorModel
    /// Sample devices for the screenshot: nothing is saved or sent.
    private(set) var demoMode = false
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
        monitor = MonitorModel(engine: engine)
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
        if demoMode { return }
        sources = MIDIEngine.sources()
        destinations = MIDIEngine.destinations()
        engine?.listen(to: sources)
        monitor.update(sources: sources, destinations: destinations)
        var p = patch
        if p.rebind(sources: sources.map(\.device), destinations: destinations.map(\.device)) {
            patch = p        // pushes the new routing
        } else {
            push()
        }
    }

    private func push() {
        if demoMode { return }
        engine?.apply(patch, sources: sources, destinations: destinations)
        clock.configure(enabled: patch.clockSource == .internal, bpm: patch.bpm, whileStopped: patch.clockWhileStopped)
        playing = clock.isPlaying
    }

    private func save() {
        if demoMode { return }
        if let data = try? JSONEncoder().encode(patch) {
            UserDefaults.standard.set(data, forKey: Self.patchKey)
        }
    }

    private func poll() {
        guard let engine, !demoMode else { return }
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

    // MARK: Screenshot

    /// Fills the window with made-up devices and routes, for the screenshot.
    /// Nothing is saved and nothing is sent.
    func loadDemo() {
        demoMode = true
        func ep(_ id: Int32, _ name: String) -> Endpoint { Endpoint(ref: 0, device: DeviceID(uniqueID: id, name: name)) }
        let keystep = ep(101, "KeyStep 37"), launchkey = ep(102, "Launchkey Mini MK3"), tr8 = ep(103, "TR-8S")
        let s2800 = ep(104, "MIDISPORT 2x2 Port A"), fm1 = ep(105, "FM-1")
        sources = [keystep, launchkey, tr8, s2800, fm1]
        let outA = ep(201, "MIDISPORT 2x2 Port A"), outB = ep(202, "MIDISPORT 2x2 Port B")
        let volca = ep(203, "volca bass"), td3 = ep(204, "TD-3"), dx = ep(205, "TX7 via UM-ONE")
        let tr8Out = ep(206, "TR-8S"), mc = ep(207, "Microfreak"), cv = ep(208, "OCTEX CV-12")
        let fm1Out = ep(209, "FM-1")
        destinations = [outA, outB, volca, td3, dx, tr8Out, mc, cv, fm1Out]

        var p = Patch(clockSource: .internal, bpm: 122)
        p.setRouted(true, from: keystep.device, to: volca.device)
        p.setRouted(true, from: keystep.device, to: mc.device)
        p.setRouted(true, from: keystep.device, to: dx.device)
        p.setFilter(RouteFilter(channel: 1, sendOn: 2), from: keystep.device, to: dx.device)
        p.setRouted(true, from: launchkey.device, to: tr8Out.device)
        p.setRouted(true, from: launchkey.device, to: cv.device)
        p.setFilter(RouteFilter(blocked: [.sysEx, .programChanges]), from: launchkey.device, to: cv.device)
        p.setRouted(true, from: tr8.device, to: td3.device)
        p.setRouted(true, from: s2800.device, to: outB.device)
        p.setRouted(true, from: fm1.device, to: outA.device)
        p.setRouted(true, from: fm1.device, to: fm1Out.device)
        p.setFilter(RouteFilter(channel: 10), from: fm1.device, to: fm1Out.device)
        for o in [volca, td3, tr8Out, mc, fm1Out] { p.setClock(true, to: o.device) }
        patch = p
        playing = true
        litInputs = [keystep.device, tr8.device]
        litOutputs = [volca.device, mc.device, td3.device]
        monitor.loadDemoData(sources: sources, destinations: destinations)
    }
}
