import SwiftUI
import WebKit
import AVKit

struct Site: Identifiable {
    let name: String
    let url: String
    let symbol: String
    let drm: Bool
    var id: String { url }

    static let all: [Site] = [
        Site(name: "YouTube Music", url: "https://music.youtube.com", symbol: "play.circle.fill", drm: false),
        Site(name: "YouTube", url: "https://m.youtube.com", symbol: "play.rectangle.fill", drm: false),
        Site(name: "SoundCloud", url: "https://soundcloud.com", symbol: "cloud.fill", drm: false),
        Site(name: "Bandcamp", url: "https://bandcamp.com", symbol: "music.note.house.fill", drm: false),
        Site(name: "Deezer", url: "https://www.deezer.com", symbol: "waveform", drm: false),
        Site(name: "Mixcloud", url: "https://www.mixcloud.com", symbol: "dot.radiowaves.left.and.right", drm: false),
        Site(name: "Amazon Music", url: "https://music.amazon.com", symbol: "music.note", drm: true),
        Site(name: "Spotify", url: "https://open.spotify.com", symbol: "circle.hexagongrid.fill", drm: true),
        Site(name: "Apple Music", url: "https://music.apple.com", symbol: "applelogo", drm: true),
        Site(name: "Tidal", url: "https://listen.tidal.com", symbol: "water.waves", drm: true)
    ]
}

struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { BrowserContent(web: model.web) }
}

private struct BrowserContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var web: WebController
    @State private var address = ""
    @FocusState private var addressFocused: Bool
    @State private var showHome = false
    @State private var quickEQ = false

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            ZStack {
                WebViewHost(webView: web.webView)
                    .ignoresSafeArea(.container, edges: .bottom)
                if web.url == nil || showHome {
                    StartPage { site in
                        showHome = false
                        web.load(site.url)
                    }
                    .transition(.opacity)
                }
            }
            if let banner = bannerText {
                banner
            }
            toolbar
        }
        .background(Theme.bg)
        .sheet(item: $web.popup) { item in
            NavigationStack {
                WebViewHost(webView: item.webView)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .navigationTitle(item.webView.url?.host ?? "")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { web.popup = nil } } }
            }
        }
        .sheet(isPresented: $quickEQ) { QuickEQSheet() }
        .onChange(of: web.url) { u in if !addressFocused { address = u?.absoluteString ?? "" } }
    }

    private var addressBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: web.url?.scheme == "https" ? "lock.fill" : "globe")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Search or enter address", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.webSearch)
                        .submitLabel(.go)
                        .focused($addressFocused)
                        .onSubmit {
                            showHome = false
                            web.load(address)
                        }
                    if addressFocused && !address.isEmpty {
                        Button { address = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button { web.isLoading ? web.stop() : web.reload() } label: {
                    Image(systemName: web.isLoading ? "xmark" : "arrow.clockwise")
                }
                .disabled(web.url == nil)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            ProgressView(value: web.isLoading ? web.progress : 0)
                .progressViewStyle(.linear)
                .opacity(web.isLoading ? 1 : 0)
                .frame(height: 2)
        }
    }

    private var bannerText: AnyView? {
        let host = model.currentHost
        switch web.status.state {
        case .silent:
            let compat = model.isCompat(host: host)
            let why = web.status.detail.hasPrefix("mse")
                ? "This player streams through MediaSource, which iOS WebKit won't hand to the EQ."
                : "Audio went silent once Timbre took over (\(web.status.detail.isEmpty ? "unknown source" : web.status.detail))."
            if !compat {
                return AnyView(StatusBanner(text: why + " Compatibility mode makes the site use a stream WebKit can EQ.",
                                            action: "Try compatibility mode") { model.toggleCompat() })
            }
            return AnyView(StatusBanner(text: why + " Compatibility mode is already on and didn't help here.",
                                        action: "Turn Timbre off for \(host ?? "this site")") { model.toggleCurrentSite() })
        case .drm:
            return AnyView(StatusBanner(text: "This stream is DRM-protected. WebKit won't let any EQ touch it.", action: nil, perform: {}))
        default:
            return nil
        }
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            Button { web.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!web.canGoBack).frame(maxWidth: .infinity)
            Button { web.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!web.canGoForward).frame(maxWidth: .infinity)
            Button { quickEQ = true } label: { StatusPill(status: web.status, enabled: model.config.enabled) }
                .frame(maxWidth: .infinity)
            RoutePicker()
                .frame(width: 30, height: 30).frame(maxWidth: .infinity)
            Button { withAnimation { showHome.toggle() } } label: { Image(systemName: showHome ? "xmark.square" : "square.grid.2x2") }
                .frame(maxWidth: .infinity)
            Menu {
                Toggle(isOn: $model.desktopMode) { Label("Desktop site", systemImage: "desktopcomputer") }
                if model.currentHost != nil {
                    Button { model.toggleCurrentSite() } label: {
                        model.isDisabled(host: model.currentHost)
                            ? Label("Turn Timbre on for this site", systemImage: "slider.vertical.3")
                            : Label("Turn Timbre off for this site", systemImage: "pause.circle")
                    }
                }
                if model.currentHost != nil {
                    Button { model.toggleCompat() } label: {
                        model.isCompat(host: model.currentHost)
                            ? Label("Compatibility mode: on", systemImage: "checkmark.circle")
                            : Label("Compatibility mode: off", systemImage: "circle")
                    }
                }
                if let u = web.url {
                    ShareLink(item: u) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button { UIApplication.shared.open(u) } label: { Label("Open in Safari", systemImage: "safari") }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .frame(maxWidth: .infinity)
        }
        .font(.system(size: 18))
        .padding(.vertical, 8)
        .background(Theme.panel)
    }
}

struct StatusPill: View {
    let status: EngineStatus
    let enabled: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: enabled ? status.symbol : "power")
            if status.state == .active && enabled {
                Text("EQ").font(.caption.weight(.bold))
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.15), in: Capsule())
    }

    private var color: Color {
        guard enabled else { return .secondary }
        switch status.state {
        case .active: return Theme.accent
        case .drm, .silent, .cors, .error: return .red
        default: return .secondary
        }
    }
}

struct StatusBanner: View {
    let text: String
    let action: String?
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.footnote)
                if let a = action { Button(a, action: perform).font(.footnote.weight(.semibold)) }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.red.opacity(0.12))
    }
}

struct StartPage: View {
    let open: (Site) -> Void
    private let cols = [GridItem(.adaptive(minimum: 100), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Timbre").font(.largeTitle.weight(.heavy))
                section("EQ works", Site.all.filter { !$0.drm })
                section("DRM, EQ probably blocked", Site.all.filter { $0.drm })
                Text("Sign in like normal, your logins stay saved. DRM streams (Widevine/FairPlay) are decrypted where no browser EQ can reach them.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .background(Theme.bg)
    }

    private func section(_ title: String, _ sites: [Site]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: cols, spacing: 14) {
                ForEach(sites) { s in
                    Button { open(s) } label: {
                        VStack(spacing: 8) {
                            Image(systemName: s.symbol).font(.system(size: 26))
                                .foregroundStyle(s.drm ? Color.secondary : Theme.accent)
                            Text(s.name).font(.caption.weight(.medium)).foregroundStyle(.primary)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 84)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
    }
}

struct QuickEQSheet: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                EQGraphView(spectrum: model.spectrum, compact: true).frame(height: 200)
                ParamSlider(title: "Preamp", value: $model.config.preamp, range: -30...12, step: 0.1, format: Fmt.db)
                HStack(spacing: 10) {
                    fxToggle("Spatial", $model.config.spatial.on)
                    fxToggle("Reverb", $model.config.reverb.on)
                    fxToggle("Crossfeed", $model.config.crossfeed.on)
                    fxToggle("Comp", $model.config.comp.on)
                }
                HStack {
                    Text(model.web.status.label).font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    RoutePicker().frame(width: 34, height: 34)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .background(Theme.bg)
            .navigationTitle(model.activePresetName ?? "Timbre")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Toggle("On", isOn: $model.config.enabled).labelsHidden() } }
        }
        .presentationDetents([.medium, .large])
    }

    private func fxToggle(_ t: String, _ b: Binding<Bool>) -> some View {
        Button { b.wrappedValue.toggle() } label: {
            Text(t).font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(b.wrappedValue ? Theme.accent.opacity(0.25) : Color.white.opacity(0.07), in: Capsule())
                .foregroundStyle(b.wrappedValue ? Theme.accent : Color.primary)
        }
    }
}

/// System AirPlay / Bluetooth output picker. Everything Timbre plays, EQ included, follows the route.
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(Theme.accent)
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}
