import Foundation

/// Headphone correction profiles from github.com/jaakkopasanen/AutoEq
struct AutoEqEntry: Identifiable, Hashable {
    let name: String
    let source: String   // e.g. "oratory1990" or "crinacle on 711"
    let path: String     // percent-encoded relative path, e.g. "oratory1990/over-ear/Sennheiser%20HD%20650"
    var id: String { path }
}

@MainActor
final class AutoEqIndex: ObservableObject {
    @Published private(set) var entries: [AutoEqEntry] = []
    @Published private(set) var loading = false
    @Published var error: String?

    private static let base = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/"
    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("autoeq-index.md")
    }

    func load(force: Bool = false) async {
        if !entries.isEmpty && !force { return }
        if !force, let text = try? String(contentsOf: cacheURL, encoding: .utf8),
           let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let date = attrs[.modificationDate] as? Date, Date().timeIntervalSince(date) < 7 * 86400 {
            entries = Self.parse(text)
            if !entries.isEmpty { return }
        }
        loading = true
        defer { loading = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: URL(string: Self.base + "INDEX.md")!)
            let text = String(decoding: data, as: UTF8.self)
            try? data.write(to: cacheURL)
            entries = Self.parse(text)
            error = entries.isEmpty ? "Couldn't read the AutoEq index." : nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    nonisolated static func parse(_ text: String) -> [AutoEqEntry] {
        var out: [AutoEqEntry] = []
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("- ["), let close = line.range(of: "](./") else { continue }
            let name = String(line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound])
            let rest = line[close.upperBound...]
            guard let by = rest.range(of: ") by ", options: .backwards) else { continue }
            let path = String(rest[..<by.lowerBound])
            let source = String(rest[by.upperBound...])
            out.append(AutoEqEntry(name: name, source: source, path: path))
        }
        return out
    }

    func search(_ q: String) -> [AutoEqEntry] {
        let terms = q.lowercased().split(separator: " ")
        guard !terms.isEmpty else { return [] }
        return entries.filter { e in
            let hay = (e.name + " " + e.source).lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
    }

    func fetch(_ e: AutoEqEntry) async throws -> (preamp: Double, bands: [Band]) {
        let last = e.path.split(separator: "/").last.map(String.init) ?? ""
        guard let url = URL(string: Self.base + e.path + "/" + last + "%20ParametricEQ.txt") else {
            throw ImportError.unsupported("Bad AutoEq path.")
        }
        let (data, resp) = try await URLSession.shared.data(from: url)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            throw ImportError.unsupported("AutoEq has no parametric profile for this one (HTTP \(h.statusCode)).")
        }
        return try PresetIO.parseAPO(String(decoding: data, as: UTF8.self))
    }
}
