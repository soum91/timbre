import Foundation

/// RBJ cookbook biquads. Matches what the Web Audio engine actually applies
/// (verified against WebKit/Chromium getFrequencyResponse).
enum FilterMath {
    struct Coeffs { var b0, b1, b2, a0, a1, a2: Double }

    static func coeffs(_ band: Band, fs: Double) -> Coeffs {
        let f = min(max(band.freq, 10), fs * 0.49)
        let q = min(max(band.q, 0.05), 40)
        let A = pow(10, band.gain / 40)
        let w0 = 2 * Double.pi * f / fs
        let c = cos(w0), s = sin(w0)
        let al = s / (2 * q)
        let sA = 2 * sqrt(A) * al
        switch band.type {
        case .peaking:
            return Coeffs(b0: 1 + al * A, b1: -2 * c, b2: 1 - al * A, a0: 1 + al / A, a1: -2 * c, a2: 1 - al / A)
        case .lowpass:
            return Coeffs(b0: (1 - c) / 2, b1: 1 - c, b2: (1 - c) / 2, a0: 1 + al, a1: -2 * c, a2: 1 - al)
        case .highpass:
            return Coeffs(b0: (1 + c) / 2, b1: -(1 + c), b2: (1 + c) / 2, a0: 1 + al, a1: -2 * c, a2: 1 - al)
        case .bandpass:
            return Coeffs(b0: al, b1: 0, b2: -al, a0: 1 + al, a1: -2 * c, a2: 1 - al)
        case .notch:
            return Coeffs(b0: 1, b1: -2 * c, b2: 1, a0: 1 + al, a1: -2 * c, a2: 1 - al)
        case .allpass:
            return Coeffs(b0: 1 - al, b1: -2 * c, b2: 1 + al, a0: 1 + al, a1: -2 * c, a2: 1 - al)
        case .lowshelf:
            return Coeffs(b0: A * ((A + 1) - (A - 1) * c + sA),
                          b1: 2 * A * ((A - 1) - (A + 1) * c),
                          b2: A * ((A + 1) - (A - 1) * c - sA),
                          a0: (A + 1) + (A - 1) * c + sA,
                          a1: -2 * ((A - 1) + (A + 1) * c),
                          a2: (A + 1) + (A - 1) * c - sA)
        case .highshelf:
            return Coeffs(b0: A * ((A + 1) + (A - 1) * c + sA),
                          b1: -2 * A * ((A - 1) + (A + 1) * c),
                          b2: A * ((A + 1) + (A - 1) * c - sA),
                          a0: (A + 1) - (A - 1) * c + sA,
                          a1: 2 * ((A - 1) - (A + 1) * c),
                          a2: (A + 1) - (A - 1) * c - sA)
        }
    }

    /// Magnitude in dB of one biquad at frequency f.
    static func magnitude(_ k: Coeffs, f: Double, fs: Double) -> Double {
        let w = 2 * Double.pi * f / fs
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = k.b0 + k.b1 * c1 + k.b2 * c2, ni = -(k.b1 * s1 + k.b2 * s2)
        let dr = k.a0 + k.a1 * c1 + k.a2 * c2, di = -(k.a1 * s1 + k.a2 * s2)
        let num = nr * nr + ni * ni, den = dr * dr + di * di
        guard den > 0, num > 0 else { return -120 }
        return max(-120, 10 * log10(num / den))
    }

    static func logFreqs(count: Int, lo: Double = 20, hi: Double = 20000) -> [Double] {
        let a = log(lo), b = log(hi)
        return (0..<count).map { exp(a + (b - a) * Double($0) / Double(count - 1)) }
    }

    /// Total response (dB) of all enabled bands plus preamp.
    static func response(bands: [Band], preamp: Double, freqs: [Double], fs: Double) -> [Double] {
        let ks = bands.filter { $0.on }.map { coeffs($0, fs: fs) }
        return freqs.map { f in ks.reduce(preamp) { $0 + magnitude($1, f: f, fs: fs) } }
    }

    static func response(band: Band, freqs: [Double], fs: Double) -> [Double] {
        let k = coeffs(band, fs: fs)
        return freqs.map { magnitude(k, f: $0, fs: fs) }
    }

    /// Q from bandwidth in octaves.
    static func q(fromOctaves n: Double) -> Double {
        let p = pow(2, n)
        return sqrt(p) / (p - 1)
    }
}
