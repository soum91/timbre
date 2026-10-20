import Foundation
import SwiftUI

@MainActor
final class SpectrumModel: ObservableObject {
    @Published var bins: [Float] = []
    private var lastUpdate = Date.distantPast

    func update(_ b: [Float]) {
        // the graph only needs ~15 fps
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) > 0.05 else { return }
        lastUpdate = now
        bins = b
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var config: DSPConfig { didSet { if config != oldValue { configChanged() } } }
    @Published var presets: [Preset] { didSet { save(presets, key: Keys.presets) } }
    @Published var activePresetName: String? {
        didSet {
            UserDefaults.standard.set(activePresetName, forKey: Keys.activeName)
            syncNowPlayingEQ()
        }
    }
    @Published var desktopMode: Bool {
        didSet {
            UserDefaults.standard.set(desktopMode, forKey: Keys.desktop)
            web.setDesktop(desktopMode, reload: true)
        }
    }
    @Published var backgroundPlay: Bool {
        didSet { UserDefaults.standard.set(backgroundPlay, forKey: Keys.background); reinstallScripts() }
    }
    @Published var disabledHosts: [String] {
        didSet { save(disabledHosts, key: Keys.disabled); reinstallScripts() }
    }
    @Published var compatHosts: [String] {
        didSet { save(compatHosts, key: Keys.compat); reinstallScripts() }
    }
    @Published var selectedBandID: String?
    @Published var toast: String?

    let web = WebController()
    let spectrum = SpectrumModel()
    let autoEq = AutoEqIndex()
    let nowPlaying = NowPlayingCenter()
    @Published private(set) var sampleRate: Double = 48000

    private enum Keys {
        static let config = "timbre.config", presets = "timbre.presets", activeName = "timbre.activePreset"
        static let desktop = "timbre.desktop", background = "timbre.background", disabled = "timbre.disabledHosts", compat = "timbre.compatHosts"
    }

    private var pushScheduled = false
    private var saveWork: DispatchWorkItem?
    private var scriptWork: DispatchWorkItem?

    init() {
        let d = UserDefaults.standard
        config = Self.load(DSPConfig.self, key: Keys.config) ?? DSPConfig()
        presets = Self.load([Preset].self, key: Keys.presets) ?? []
        activePresetName = d.string(forKey: Keys.activeName)
        desktopMode = d.bool(forKey: Keys.desktop)
        backgroundPlay = d.object(forKey: Keys.background) as? Bool ?? true
        disabledHosts = Self.load([String].self, key: Keys.disabled) ?? []
        compatHosts = Self.load([String].self, key: Keys.compat) ?? ["youtube.com"]

        web.setDesktop(desktopMode, reload: false)
        web.onSpectrum = { [weak self] b in self?.spectrum.update(b) }
        web.onSampleRate = { [weak self] r in if self?.sampleRate != r { self?.sampleRate = r } }
        web.onNeedIR = { [weak self] id in self?.sendIR(id) }
        web.onIRError = { [weak self] _ in self?.toast = "Couldn't decode that impulse response." }
        web.installScripts(config: config, disabledHosts: disabledHosts, compatHosts: compatHosts, background: backgroundPlay)
        web.onNowPlaying = { [weak self] body, site in self?.nowPlaying.ingest(body, site: site) }
        web.onPageChanged = { [weak self] in self?.nowPlaying.pageChanged() }
        CommandBus.handler = { [weak self] cmd in self?.handleCommand(cmd) }
        Self.listenForWidgetCommands()
        syncNowPlayingEQ()
        drainPendingCommand()
        AppModel.shared = self
    }

    // MARK: persistence

    private static func load<T: Decodable>(_ t: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ v: T, key: String) {
        if let data = try? JSONEncoder().encode(v) { UserDefaults.standard.set(data, forKey: key) }
    }

    // MARK: widget / Live Activity commands

    func handleCommand(_ cmd: String) {
        if cmd == "eq" { config.enabled.toggle() } else { web.command(cmd) }
    }

    func drainPendingCommand() {
        guard let d = SharedStore.defaults, let cmd = d.string(forKey: "pendingCommand") else { return }
        d.removeObject(forKey: "pendingCommand")
        handleCommand(cmd)
    }

    private func syncNowPlayingEQ() {
        nowPlaying.setEQ(on: config.enabled, preset: activePresetName ?? "Custom")
    }

    private static func listenForWidgetCommands() {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            Task { @MainActor in AppModel.shared?.drainPendingCommand() }
        }, SharedStore.darwinCommand as CFString, nil, .deliverImmediately)
    }

    static weak var shared: AppModel?

    private func configChanged() {
        syncNowPlayingEQ()
        // live push, throttled to ~30 Hz while dragging
        if !pushScheduled {
            pushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) { [weak self] in
                guard let self else { return }
                self.pushScheduled = false
                self.web.push(config: self.config)
            }
        }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.save(self.config, key: Keys.config)
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
        reinstallScripts()
    }

    private func reinstallScripts() {
        scriptWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.web.installScripts(config: self.config, disabledHosts: self.disabledHosts, compatHosts: self.compatHosts, background: self.backgroundPlay)
        }
        scriptWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    // MARK: bands

    func addBand(freq: Double = 1000, gain: Double = 0, type: FilterType = .peaking) {
        let b = Band(type: type, freq: freq, gain: gain, q: type == .peaking ? 1.0 : 0.707)
        config.bands.append(b)
        selectedBandID = b.id
        activePresetName = nil
    }

    func removeBand(_ id: String) {
        config.bands.removeAll { $0.id == id }
        if selectedBandID == id { selectedBandID = nil }
        activePresetName = nil
    }

    func flatten() {
        config.bands = []
        config.preamp = 0
        selectedBandID = nil
        activePresetName = "Flat"
    }

    func binding(for id: String) -> Binding<Band>? {
        guard config.bands.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.config.bands.first { $0.id == id } ?? Band() },
            set: { [weak self] nb in
                guard let self, let i = self.config.bands.firstIndex(where: { $0.id == id }) else { return }
                self.config.bands[i] = nb
                self.activePresetName = nil
            })
    }

    /// Peak of the EQ curve (dB) across the audible range.
    func curvePeak() -> Double {
        let r = FilterMath.response(bands: config.bands, preamp: 0, freqs: FilterMath.logFreqs(count: 400), fs: sampleRate)
        return r.max() ?? 0
    }

    func autoPreamp() {
        config.preamp = -(max(0, curvePeak()) * 10).rounded(.up) / 10
    }

    // MARK: presets

    func apply(_ p: Preset) {
        var c = config
        c.preamp = p.preamp
        c.bands = p.bands.map { var b = $0; b.id = UUID().uuidString; return b }
        p.effects?.apply(to: &c)
        config = c
        selectedBandID = nil
        activePresetName = p.name
    }

    func saveCurrent(as name: String, includeEffects: Bool) {
        let p = Preset(name: name, preamp: config.preamp, bands: config.bands,
                       effects: includeEffects ? EffectsSnapshot(from: config) : nil)
        presets.removeAll { $0.name == name }
        presets.insert(p, at: 0)
        activePresetName = name
    }

    func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let name = url.deletingPathExtension().lastPathComponent
            if url.pathExtension.lowercased() == "eqf" {
                let ps = try PresetIO.parseWinamp(data)
                presets.insert(contentsOf: ps, at: 0)
                if let first = ps.first { apply(first) }
                toast = ps.count == 1 ? "Imported \(ps[0].name)" : "Imported \(ps.count) Winamp presets"
            } else {
                let r = try PresetIO.parseAPO(String(decoding: data, as: UTF8.self))
                let p = Preset(name: name, preamp: r.preamp, bands: r.bands)
                presets.removeAll { $0.name == name }
                presets.insert(p, at: 0)
                apply(p)
                toast = "Imported \(name) · \(r.bands.count) filters"
            }
        } catch {
            toast = error.localizedDescription
        }
    }

    func applyAutoEq(_ e: AutoEqEntry) async {
        do {
            let r = try await autoEq.fetch(e)
            let p = Preset(name: e.name, preamp: r.preamp, bands: r.bands)
            presets.removeAll { $0.name == p.name }
            presets.insert(p, at: 0)
            apply(p)
            toast = "\(e.name) · \(r.bands.count) filters"
        } catch {
            toast = error.localizedDescription
        }
    }

    // MARK: per-site

    var currentHost: String? {
        guard var h = web.url?.host?.lowercased() else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    func isDisabled(host: String?) -> Bool {
        guard let host else { return false }
        return disabledHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func toggleCurrentSite() {
        guard let h = currentHost else { return }
        if isDisabled(host: h) { disabledHosts.removeAll { h == $0 || h.hasSuffix("." + $0) } }
        else { disabledHosts.append(h) }
        // scripts reinstall is debounced; reload after it lands
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.web.reload() }
    }

    func isCompat(host: String?) -> Bool {
        guard let host else { return false }
        return compatHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func toggleCompat() {
        guard let h = currentHost else { return }
        if isCompat(host: h) { compatHosts.removeAll { h == $0 || h.hasSuffix("." + $0) } }
        else { compatHosts.append(h) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.web.reload() }
    }

    // MARK: impulse responses

    private var irDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("IR", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func importIR(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let id = UUID().uuidString
        let dest = irDir.appendingPathComponent(id + "." + (url.pathExtension.isEmpty ? "wav" : url.pathExtension))
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 25_000_000 else { toast = "That IR is too big (max 25 MB)."; return }
            try data.write(to: dest)
            config.reverb.irID = id
            config.reverb.irName = url.deletingPathExtension().lastPathComponent
            config.reverb.on = true
        } catch {
            toast = error.localizedDescription
        }
    }

    func clearIR() {
        if let id = config.reverb.irID, let f = irFile(id) { try? FileManager.default.removeItem(at: f) }
        config.reverb.irID = nil
        config.reverb.irName = nil
    }

    private func irFile(_ id: String) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: irDir, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.hasPrefix(id) }
    }

    private func sendIR(_ id: String) {
        guard let f = irFile(id), let data = try? Data(contentsOf: f) else { return }
        web.sendIR(id: id, base64: data.base64EncodedString())
    }
}
