import Foundation

enum ImportError: LocalizedError {
    case empty, unsupported(String)
    var errorDescription: String? {
        switch self {
        case .empty: return "No filters found in that file."
        case .unsupported(let s): return s
        }
    }
}

enum PresetIO {
    // MARK: Equalizer APO / AutoEq ParametricEQ.txt

    /// Parses lines like:
    ///   Preamp: -6.1 dB
    ///   Filter 1: ON PK Fc 8800 Hz Gain 5.1 dB Q 1.42
    ///   Filter: ON LS Fc 105 Hz Gain 6.4 dB
    ///   Filter 3: ON PK Fc 1000 Hz Gain -3 dB BW Oct 1.0
    static func parseAPO(_ text: String) throws -> (preamp: Double, bands: [Band]) {
        var preamp = 0.0
        var bands: [Band] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("preamp:") {
                let toks = line.dropFirst(7).split(separator: " ")
                if let v = toks.first.flatMap({ Double($0) }) { preamp = v }
                continue
            }
            if lower.hasPrefix("graphiceq:") {
                throw ImportError.unsupported("GraphicEQ files aren't supported, use the ParametricEQ version of the profile.")
            }
            guard lower.hasPrefix("filter"), let colon = line.firstIndex(of: ":") else { continue }
            let toks = line[line.index(after: colon)...].split(separator: " ").map(String.init)
            guard toks.count >= 2 else { continue }
            var i = 0
            var on = true
            if toks[i].uppercased() == "ON" { i += 1 } else if toks[i].uppercased() == "OFF" { on = false; i += 1 }
            guard i < toks.count else { continue }
            let code = toks[i].uppercased(); i += 1
            let type: FilterType
            var defaultQ = 0.707
            switch code {
            case "PK", "PEQ", "MODAL": type = .peaking; defaultQ = 1.0
            case "LS", "LSC", "LSQ", "LS 6DB", "LS 12DB": type = .lowshelf
            case "HS", "HSC", "HSQ", "HS 6DB", "HS 12DB": type = .highshelf
            case "LP", "LPQ": type = .lowpass
            case "HP", "HPQ": type = .highpass
            case "BP": type = .bandpass
            case "NO": type = .notch; defaultQ = 4
            case "AP": type = .allpass
            default: continue
            }
            var fc: Double?, gain = 0.0, q: Double?
            while i < toks.count {
                let key = toks[i].lowercased()
                func next(_ o: Int = 1) -> Double? { i + o < toks.count ? Double(toks[i + o]) : nil }
                switch key {
                case "fc": fc = next(); i += 2
                case "gain": gain = next() ?? 0; i += 2
                case "q": q = next(); i += 2
                case "bw":
                    if i + 2 < toks.count, toks[i + 1].lowercased() == "oct", let n = Double(toks[i + 2]) {
                        q = FilterMath.q(fromOctaves: n); i += 3
                    } else { i += 1 }
                default: i += 1
                }
            }
            guard let f = fc, f > 0 else { continue }
            bands.append(Band(on: on, type: type, freq: f, gain: gain, q: q ?? defaultQ))
        }
        if bands.isEmpty { throw ImportError.empty }
        return (preamp, bands)
    }

    static func exportAPO(preamp: Double, bands: [Band]) -> String {
        var out = String(format: "Preamp: %.1f dB\n", preamp)
        for (n, b) in bands.enumerated() {
            out += String(format: "Filter %d: %@ %@ Fc %.0f Hz Gain %.1f dB Q %.2f\n",
                          n + 1, b.on ? "ON" : "OFF", b.type.code, b.freq, b.gain, b.q)
        }
        return out
    }

    // MARK: Winamp .EQF

    /// Winamp EQ library: 31 byte header, then entries of 257 byte name + 10 band bytes + 1 preamp byte.
    /// Slider values 0...63, 0 = top (+12 dB), 63 = bottom (-12 dB).
    static let winampFreqs: [Double] = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000]

    static func parseWinamp(_ data: Data) throws -> [Preset] {
        let bytes = [UInt8](data)
        let header = "Winamp EQ library file v1.1"
        guard bytes.count >= 31 + 268,
              String(bytes: bytes[0..<header.count], encoding: .ascii) == header else {
            throw ImportError.unsupported("That isn't a Winamp EQF file.")
        }
        func db(_ v: UInt8) -> Double { (31.5 - Double(min(v, 63))) / 31.5 * 12 }
        var presets: [Preset] = []
        var off = 31
        while off + 268 <= bytes.count {
            let nameBytes = bytes[off..<off + 257].prefix { $0 != 0 }
            let name = String(bytes: nameBytes, encoding: .isoLatin1) ?? "Winamp"
            let vals = bytes[off + 257..<off + 267]
            let pre = db(bytes[off + 267])
            let bands = zip(winampFreqs, vals).map { Band(type: .peaking, freq: $0.0, gain: (db($0.1) * 10).rounded() / 10, q: 1.41) }
            presets.append(Preset(name: name.isEmpty ? "Winamp" : name, preamp: (pre * 10).rounded() / 10, bands: bands))
            off += 268
        }
        if presets.isEmpty { throw ImportError.empty }
        return presets
    }
}
