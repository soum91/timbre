import Foundation
import WebKit
import UIKit

enum EngineState: String {
    case idle, active, drm, cors, silent, error, off

    var priority: Int {
        switch self {
        case .silent: return 7
        case .active: return 6
        case .drm: return 5
        case .cors: return 4
        case .error: return 3
        case .off: return 2
        case .idle: return 1
        }
    }
}

struct EngineStatus: Equatable {
    var state: EngineState = .idle
    var streams = 0
    var detail = ""

    var label: String {
        switch state {
        case .idle: return "Waiting for audio"
        case .active: return streams > 1 ? "EQ live · \(streams) streams" : "EQ live"
        case .drm: return "DRM audio, can't EQ"
        case .cors: return "Cross-origin audio, can't EQ"
        case .silent: return "WebKit won't pass this stream to the EQ"
        case .error: return "Engine error"
        case .off: return "Off for this site"
        }
    }

    var symbol: String {
        switch state {
        case .idle: return "waveform"
        case .active: return "slider.vertical.3"
        case .drm: return "lock.fill"
        case .cors: return "nosign"
        case .silent: return "speaker.slash.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .off: return "pause.circle"
        }
    }
}

struct PopupItem: Identifiable {
    let id = UUID()
    let webView: WKWebView
}

private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

@MainActor
final class WebController: NSObject, ObservableObject {
    @Published private(set) var url: URL?
    @Published private(set) var title = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = EngineStatus()
    @Published var popup: PopupItem?

    let webView: WKWebView
    private(set) var vault: CookieVault!
    private var ready = false
    private var pendingLoads: [URLRequest] = []
    var desktopMode = false
    var onSpectrum: (([Float]) -> Void)?
    var onSampleRate: ((Double) -> Void)?
    var onNeedIR: ((String) -> Void)?
    var onIRError: ((String) -> Void)?

    private var frameStates: [String: EngineStatus] = [:]
    private var observers: [NSKeyValueObservation] = []
    private static let engineSource: String = {
        guard let u = Bundle.main.url(forResource: "engine", withExtension: "js"),
              let s = try? String(contentsOf: u, encoding: .utf8) else { return "" }
        return s
    }()

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsPictureInPictureMediaPlayback = true
        cfg.allowsAirPlayForMediaPlayback = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        vault = CookieVault(store: cfg.websiteDataStore.httpCookieStore)
        Task { @MainActor in
            await self.vault.restore()
            self.ready = true
            let queued = self.pendingLoads
            self.pendingLoads = []
            queued.forEach { self.webView.load($0) }
        }
        cfg.userContentController.add(WeakMessageHandler(self), name: "timbre")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        webView.customUserAgent = Self.userAgent(desktop: false)

        observers = [
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in Task { @MainActor in self?.url = wv.url } },
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in Task { @MainActor in self?.title = wv.title ?? "" } },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in Task { @MainActor in self?.canGoBack = wv.canGoBack } },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in Task { @MainActor in self?.canGoForward = wv.canGoForward } },
            webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in Task { @MainActor in self?.isLoading = wv.isLoading } },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in Task { @MainActor in self?.progress = wv.estimatedProgress } }
        ]
    }

    // MARK: user agent

    static func userAgent(desktop: Bool) -> String {
        let v = UIDevice.current.systemVersion.split(separator: ".")
        let major = v.first.map(String.init) ?? "18"
        let minor = v.count > 1 ? String(v[1]) : "0"
        if desktop {
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).\(minor) Safari/605.1.15"
        }
        let os = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad; CPU OS" : "iPhone; CPU iPhone OS"
        return "Mozilla/5.0 (\(device) \(os) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).\(minor) Mobile/15E148 Safari/604.1"
    }

    func setDesktop(_ on: Bool, reload: Bool) {
        desktopMode = on
        webView.customUserAgent = Self.userAgent(desktop: on)
        if reload, webView.url != nil { webView.reload() }
    }

    // MARK: engine plumbing

    private struct Boot: Encodable {
        let config: DSPConfig
        let disabledHosts: [String]
        let compatHosts: [String]
        let background: Bool
    }

    /// Rebuilds the document-start script so new pages and frames boot with current settings.
    func installScripts(config: DSPConfig, disabledHosts: [String], compatHosts: [String], background: Bool) {
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        guard let data = try? JSONEncoder().encode(Boot(config: config, disabledHosts: disabledHosts, compatHosts: compatHosts, background: background)),
              let json = String(data: data, encoding: .utf8) else { return }
        let src = "window.__TIMBRE_BOOT=\(json);\n" + Self.engineSource
        ucc.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    /// Pushes config live into the running page (main frame relays to iframes).
    func push(config: DSPConfig) {
        guard webView.url != nil,
              let data = try? JSONEncoder().encode(config),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__timbre&&window.__timbre.apply(\(json));", completionHandler: nil)
    }

    func sendIR(id: String, base64: String) {
        let idJSON = (try? JSONEncoder().encode(id)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        webView.evaluateJavaScript("window.__timbre&&window.__timbre.setIR(\(idJSON),'\(base64)');", completionHandler: nil)
    }

    // MARK: navigation

    func load(_ input: String) {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var target: URL?
        if t.contains("://"), let u = URL(string: t) { target = u }
        else if !t.contains(" "), t.contains("."), let u = URL(string: "https://" + t) { target = u }
        else {
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: t)]
            target = c.url
        }
        if let u = target { open(URLRequest(url: u)) }
    }

    func load(url: URL) { open(URLRequest(url: url)) }

    /// Holds loads until saved sign-in cookies are back in the store.
    private func open(_ r: URLRequest) {
        if ready { webView.load(r) } else { pendingLoads.append(r) }
    }

    func saveSession() async { await vault.save() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stop() { webView.stopLoading() }

    func clearWebsiteData() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        vault.wipe()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
        webView.reload()
    }

    private func recomputeStatus() {
        let best = frameStates.values.max { $0.state.priority < $1.state.priority } ?? EngineStatus()
        let streams = frameStates.values.filter { $0.state == .active }.reduce(0) { $0 + $1.streams }
        var s = best
        if s.state == .active { s.streams = max(1, streams) }
        if s != status { status = s }
    }
}

extension WebController: WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let isMain = message.frameInfo.isMainFrame
        let frameKey = (isMain ? "main:" : "sub:") + ((body["frame"] as? String) ?? "")
        let bins = (body["bins"] as? [NSNumber])?.map { $0.floatValue }
        let state = body["state"] as? String
        let streams = (body["streams"] as? NSNumber)?.intValue ?? 0
        let detail = body["detail"] as? String ?? ""
        let rate = (body["sampleRate"] as? NSNumber)?.doubleValue ?? 0
        let id = body["id"] as? String
        do {
            switch type {
            case "spectrum":
                if let bins = bins { self.onSpectrum?(bins) }
            case "status":
                if let state = state, let st = EngineState(rawValue: state) {
                    self.frameStates[frameKey] = EngineStatus(state: st, streams: streams, detail: detail)
                    self.recomputeStatus()
                }
                if rate > 0 { self.onSampleRate?(rate) }
            case "needIR":
                if let id = id { self.onNeedIR?(id) }
            case "irError":
                if let id = id { self.onIRError?(id) }
            default: break
            }
        }
    }
}

extension WebController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.preferredContentMode = desktopMode ? .desktop : .mobile
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        if !["http", "https", "about", "blob", "data", "javascript", "file"].contains(scheme) {
            // Block app deep links (amazonmusic://, spotify://, itms-apps://) so we stay in the browser.
            decisionHandler(.cancel, preferences)
            return
        }
        // Allow without handing off to the native app via universal links.
        let noAppLink = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow
        decisionHandler(noAppLink, preferences)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        frameStates.removeAll()
        recomputeStatus()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

extension WebController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Plain target=_blank links just open in place; script popups (sign-in flows) get a real window.
        if action.navigationType == .linkActivated {
            webView.load(action.request)
            return nil
        }
        let wv = WKWebView(frame: .zero, configuration: configuration)
        wv.customUserAgent = self.webView.customUserAgent
        wv.uiDelegate = self
        wv.navigationDelegate = self
        if #available(iOS 16.4, *) { wv.isInspectable = true }
        popup = PopupItem(webView: wv)
        return wv
    }

    func webViewDidClose(_ webView: WKWebView) {
        if popup?.webView === webView { popup = nil }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        present(alert: UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert),
                actions: [UIAlertAction(title: "OK", style: .default) { _ in completionHandler() }],
                fallback: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        present(alert: UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert),
                actions: [UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) },
                          UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) }],
                fallback: { completionHandler(false) })
    }

    private func present(alert: UIAlertController, actions: [UIAlertAction], fallback: @escaping () -> Void) {
        actions.forEach(alert.addAction)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }),
              var top = window.rootViewController else {
            fallback()
            return
        }
        while let p = top.presentedViewController { top = p }
        top.present(alert, animated: true)
    }
}
