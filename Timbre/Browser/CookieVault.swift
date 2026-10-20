import Foundation
import WebKit

/// Keeps sign-ins alive across app restarts.
///
/// Sites like Amazon issue session cookies (no expiry) for parts of the login. WebKit drops those
/// whenever the web content process or the app dies, which logs you out. The vault promotes session
/// cookies to persistent ones (30 days, refreshed on every change) and keeps a copy on disk that gets
/// restored before the first page loads, in case WebKit's own store didn't flush before the app was killed.
@MainActor
final class CookieVault: NSObject, WKHTTPCookieStoreObserver {
    private let store: WKHTTPCookieStore
    private var saveTask: Task<Void, Never>?
    private var promoting = false
    private static let sessionLifetime: TimeInterval = 30 * 86400

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cookies.plist")
    }

    init(store: WKHTTPCookieStore) {
        self.store = store
        super.init()
        store.add(self)
    }

    // MARK: restore

    func restore() async {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { return }
        let existing = await store.allCookies()
        let have = Set(existing.map { Self.key($0) })
        let now = Date()
        for raw in list {
            var props: [HTTPCookiePropertyKey: Any] = [:]
            for (k, v) in raw { props[HTTPCookiePropertyKey(k)] = v }
            guard let c = HTTPCookie(properties: props) else { continue }
            if let exp = c.expiresDate, exp < now { continue }
            if have.contains(Self.key(c)) { continue }
            await store.setCookie(c)
        }
    }

    // MARK: observe + save

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in self.scheduleSave() }
    }

    private func scheduleSave() {
        guard !promoting else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    /// Promotes session cookies to persistent and writes everything to disk.
    func save() async {
        promoting = true
        defer { promoting = false }
        var all = await store.allCookies()
        let expiry = Date().addingTimeInterval(Self.sessionLifetime)
        var promoted: [HTTPCookie] = []
        for c in all where c.isSessionOnly || c.expiresDate == nil {
            guard var props = c.properties else { continue }
            props[.expires] = expiry
            props[.discard] = nil
            props.removeValue(forKey: HTTPCookiePropertyKey("Max-Age"))
            if let p = HTTPCookie(properties: props) {
                await store.setCookie(p)
                promoted.append(p)
            }
        }
        if !promoted.isEmpty {
            let keys = Set(promoted.map { Self.key($0) })
            all = all.filter { !keys.contains(Self.key($0)) } + promoted
        }
        let list: [[String: Any]] = all.compactMap { c in
            guard let p = c.properties else { return nil }
            var out: [String: Any] = [:]
            for (k, v) in p where v is String || v is Date || v is NSNumber { out[k.rawValue] = v }
            return out
        }
        if let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0) {
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func wipe() {
        saveTask?.cancel()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func key(_ c: HTTPCookie) -> String { c.domain + "|" + c.path + "|" + c.name }
}
