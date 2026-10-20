import Foundation

enum FilterType: String, Codable, CaseIterable, Identifiable {
    case peaking, lowshelf, highshelf, lowpass, highpass, bandpass, notch, allpass

    var id: String { rawValue }

    var label: String {
        switch self {
        case .peaking: return "Peak"
        case .lowshelf: return "Low Shelf"
        case .highshelf: return "High Shelf"
        case .lowpass: return "Low Pass"
        case .highpass: return "High Pass"
        case .bandpass: return "Band Pass"
        case .notch: return "Notch"
        case .allpass: return "All Pass"
        }
    }

    /// Equalizer APO / AutoEq short code.
    var code: String {
        switch self {
        case .peaking: return "PK"
        case .lowshelf: return "LSC"
        case .highshelf: return "HSC"
        case .lowpass: return "LPQ"
        case .highpass: return "HPQ"
        case .bandpass: return "BP"
        case .notch: return "NO"
        case .allpass: return "AP"
        }
    }

    var usesGain: Bool { self == .peaking || self == .lowshelf || self == .highshelf }
}

struct Band: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var on: Bool = true
    var type: FilterType = .peaking
    var freq: Double = 1000
    var gain: Double = 0
    var q: Double = 1.0
}

struct CompressorSettings: Codable, Equatable {
    var on = false
    var threshold: Double = -24
    var knee: Double = 6
    var ratio: Double = 3
    var attack: Double = 10     // ms
    var release: Double = 150   // ms
    var makeup: Double = 0      // dB
}

struct CrossfeedSettings: Codable, Equatable {
    var on = false
    var level: Double = -6      // dB of opposite channel
    var cutoff: Double = 700    // Hz
    var delay: Double = 0.3     // ms
}

struct WidthSettings: Codable, Equatable {
    var on = false
    var width: Double = 1       // 0 mono, 1 normal, >1 wider
    var balance: Double = 0     // -1 left ... 1 right
    var mono = false
    var swap = false
}

struct SpatialSettings: Codable, Equatable {
    var on = false
    var angle: Double = 30      // virtual speaker angle, degrees
    var amount: Double = 0.8
    var distance: Double = 1
    var elevation: Double = 0
}

struct ReverbSettings: Codable, Equatable {
    var on = false
    var decay: Double = 1.8     // s (RT60)
    var predelay: Double = 20   // ms
    var damping: Double = 6000  // Hz
    var width: Double = 1
    var mix: Double = 0.25
    var irID: String? = nil
    var irName: String? = nil
}

struct LimiterSettings: Codable, Equatable {
    var on = true
    var ceiling: Double = -1
}

struct DSPConfig: Codable, Equatable {
    var enabled = true
    var preamp: Double = 0
    var output: Double = 0
    var spectrum = true
    var bands: [Band] = []
    var comp = CompressorSettings()
    var crossfeed = CrossfeedSettings()
    var width = WidthSettings()
    var spatial = SpatialSettings()
    var reverb = ReverbSettings()
    var limiter = LimiterSettings()
}

struct Preset: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var preamp: Double
    var bands: [Band]
    /// nil = EQ-only preset (applying it leaves effects alone)
    var effects: EffectsSnapshot?
    var builtIn = false
}

struct EffectsSnapshot: Codable, Equatable {
    var output: Double
    var comp: CompressorSettings
    var crossfeed: CrossfeedSettings
    var width: WidthSettings
    var spatial: SpatialSettings
    var reverb: ReverbSettings
    var limiter: LimiterSettings

    init(from c: DSPConfig) {
        output = c.output; comp = c.comp; crossfeed = c.crossfeed; width = c.width
        spatial = c.spatial; reverb = c.reverb; limiter = c.limiter
    }

    func apply(to c: inout DSPConfig) {
        c.output = output; c.comp = comp; c.crossfeed = crossfeed; c.width = width
        c.spatial = spatial; c.reverb = reverb; c.limiter = limiter
    }
}

extension Preset {
    static func pk(_ f: Double, _ g: Double, _ q: Double = 1.41) -> Band { Band(type: .peaking, freq: f, gain: g, q: q) }

    static let builtIns: [Preset] = [
        Preset(id: "builtin.flat", name: "Flat", preamp: 0, bands: [], builtIn: true),
        Preset(id: "builtin.bass", name: "Bass Boost", preamp: -6, bands: [
            Band(type: .lowshelf, freq: 105, gain: 6, q: 0.7), Preset.pk(40, 1.5, 1.0)
        ], builtIn: true),
        Preset(id: "builtin.vshape", name: "V-Shape", preamp: -5, bands: [
            Band(type: .lowshelf, freq: 120, gain: 5, q: 0.7), Preset.pk(1500, -2.5, 0.8),
            Band(type: .highshelf, freq: 8000, gain: 4, q: 0.7)
        ], builtIn: true),
        Preset(id: "builtin.vocal", name: "Vocal Presence", preamp: -3, bands: [
            Band(type: .highpass, freq: 60, gain: 0, q: 0.707), Preset.pk(250, -2, 1.0),
            Preset.pk(2500, 3, 1.2), Preset.pk(5000, 1.5, 2.0)
        ], builtIn: true),
        Preset(id: "builtin.treble", name: "Treble Boost", preamp: -4, bands: [
            Band(type: .highshelf, freq: 6000, gain: 4, q: 0.7)
        ], builtIn: true),
        Preset(id: "builtin.loudness", name: "Late Night Loudness", preamp: -6, bands: [
            Band(type: .lowshelf, freq: 90, gain: 6, q: 0.6), Band(type: .highshelf, freq: 10000, gain: 4, q: 0.7)
        ], effects: {
            var c = DSPConfig()
            c.comp = CompressorSettings(on: true, threshold: -30, knee: 10, ratio: 4, attack: 5, release: 200, makeup: 0)
            return EffectsSnapshot(from: c)
        }(), builtIn: true)
    ]
}

struct ReverbPreset: Identifiable {
    let id: String
    let decay: Double, predelay: Double, damping: Double, mix: Double

    static let all: [ReverbPreset] = [
        ReverbPreset(id: "Room", decay: 0.6, predelay: 6, damping: 7000, mix: 0.2),
        ReverbPreset(id: "Studio", decay: 1.0, predelay: 12, damping: 6000, mix: 0.2),
        ReverbPreset(id: "Plate", decay: 1.6, predelay: 4, damping: 10000, mix: 0.25),
        ReverbPreset(id: "Hall", decay: 2.6, predelay: 28, damping: 4500, mix: 0.25),
        ReverbPreset(id: "Cathedral", decay: 5.5, predelay: 60, damping: 3000, mix: 0.3)
    ]
}
