import SwiftUI
import UniformTypeIdentifiers

private struct NamedPreset<T>: Identifiable {
    let id: String
    let value: T
}

struct EffectsView: View {
    @EnvironmentObject var model: AppModel
    @State private var importingIR = false

    private let crossfeedPresets: [NamedPreset<(Double, Double)>] = [
        NamedPreset(id: "Subtle", value: (-9.5, 650)),
        NamedPreset(id: "Natural", value: (-6, 700)),
        NamedPreset(id: "Speakers", value: (-4.5, 750)),
        NamedPreset(id: "Strong", value: (-3, 850))
    ]
    private let spatialPresets: [NamedPreset<(Double, Double, Double)>] = [
        NamedPreset(id: "Front stage", value: (15, 1.0, 0.7)),
        NamedPreset(id: "Near-field monitors", value: (30, 1.0, 0.8)),
        NamedPreset(id: "Wide room", value: (55, 2.0, 0.9)),
        NamedPreset(id: "Surround-ish", value: (80, 1.5, 1.0))
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Timbre enabled", isOn: $model.config.enabled)
                }

                Section {
                    Toggle("Spatial", isOn: $model.config.spatial.on)
                    if model.config.spatial.on {
                        ChipRow(items: spatialPresets, title: { $0.id }) { p in
                            model.config.spatial.angle = p.value.0
                            model.config.spatial.distance = p.value.1
                            model.config.spatial.amount = p.value.2
                        }
                        ParamSlider(title: "Speaker angle", value: $model.config.spatial.angle, range: 5...90, step: 1, format: Fmt.deg)
                        ParamSlider(title: "Distance", value: $model.config.spatial.distance, range: 0.3...5, step: 0.1, format: { String(format: "%.1f m", $0) })
                        ParamSlider(title: "Elevation", value: $model.config.spatial.elevation, range: -45...45, step: 1, format: Fmt.deg)
                        ParamSlider(title: "Amount", value: $model.config.spatial.amount, range: 0...1, step: 0.01, format: Fmt.pct)
                    }
                } footer: {
                    Text("Renders left and right as virtual speakers in front of you using HRTF. Headphones only.")
                }

                Section {
                    Toggle("Reverb", isOn: $model.config.reverb.on)
                    if model.config.reverb.on {
                        ChipRow(items: ReverbPreset.all, title: { $0.id }) { p in
                            model.config.reverb.irID = nil
                            model.config.reverb.irName = nil
                            model.config.reverb.decay = p.decay
                            model.config.reverb.predelay = p.predelay
                            model.config.reverb.damping = p.damping
                            model.config.reverb.mix = p.mix
                        }
                        ParamSlider(title: "Mix", value: $model.config.reverb.mix, range: 0...1, step: 0.01, format: Fmt.pct)
                        if let name = model.config.reverb.irName {
                            HStack {
                                Label(name, systemImage: "waveform.path")
                                Spacer()
                                Button("Remove", role: .destructive) { model.clearIR() }.buttonStyle(.borderless)
                            }
                        } else {
                            ParamSlider(title: "Decay", value: $model.config.reverb.decay, range: 0.2...8, log: true, format: Fmt.sec)
                            ParamSlider(title: "Pre-delay", value: $model.config.reverb.predelay, range: 0...200, step: 1, format: Fmt.ms)
                            ParamSlider(title: "Damping", value: $model.config.reverb.damping, range: 1000...16000, log: true, format: Fmt.hz)
                            ParamSlider(title: "Stereo width", value: $model.config.reverb.width, range: 0...1, step: 0.01, format: Fmt.pct)
                        }
                        Button { importingIR = true } label: { Label("Load impulse response…", systemImage: "square.and.arrow.down") }
                    }
                } footer: {
                    Text("Load any WAV/AIFF impulse response (rooms, cabinets, Dolby-style virtualizer IRs) or use the built-in generator.")
                }

                Section {
                    Toggle("Crossfeed", isOn: $model.config.crossfeed.on)
                    if model.config.crossfeed.on {
                        ChipRow(items: crossfeedPresets, title: { $0.id }) { p in
                            model.config.crossfeed.level = p.value.0
                            model.config.crossfeed.cutoff = p.value.1
                        }
                        ParamSlider(title: "Level", value: $model.config.crossfeed.level, range: -20 ... -1, step: 0.5, format: Fmt.db)
                        ParamSlider(title: "Cutoff", value: $model.config.crossfeed.cutoff, range: 300...1500, step: 10, format: Fmt.hz)
                        ParamSlider(title: "Delay", value: $model.config.crossfeed.delay, range: 0...0.8, step: 0.01, format: { String(format: "%.2f ms", $0) })
                    }
                } footer: {
                    Text("Bleeds a little of each channel into the other like speakers do, so hard-panned mixes stop feeling inside your skull.")
                }

                Section("Stereo") {
                    Toggle("Stereo tools", isOn: $model.config.width.on)
                    if model.config.width.on {
                        ParamSlider(title: "Width", value: $model.config.width.width, range: 0...2.5, step: 0.01, format: Fmt.pct, disabled: model.config.width.mono)
                        ParamSlider(title: "Balance", value: $model.config.width.balance, range: -1...1, step: 0.01, format: { v in
                            abs(v) < 0.01 ? "Center" : String(format: "%@ %.0f%%", v < 0 ? "L" : "R", abs(v) * 100)
                        })
                        Toggle("Mono", isOn: $model.config.width.mono)
                        Toggle("Swap left / right", isOn: $model.config.width.swap)
                    }
                }

                Section {
                    Toggle("Compressor", isOn: $model.config.comp.on)
                    if model.config.comp.on {
                        ParamSlider(title: "Threshold", value: $model.config.comp.threshold, range: -60...0, step: 0.5, format: Fmt.db)
                        ParamSlider(title: "Ratio", value: $model.config.comp.ratio, range: 1...20, log: true, format: Fmt.ratio)
                        ParamSlider(title: "Knee", value: $model.config.comp.knee, range: 0...40, step: 0.5, format: Fmt.db)
                        ParamSlider(title: "Attack", value: $model.config.comp.attack, range: 0.1...200, log: true, format: Fmt.ms)
                        ParamSlider(title: "Release", value: $model.config.comp.release, range: 10...1000, log: true, format: Fmt.ms)
                        ParamSlider(title: "Makeup", value: $model.config.comp.makeup, range: -12...24, step: 0.1, format: Fmt.db)
                    }
                } footer: {
                    Text("WebKit's compressor adds some automatic makeup gain of its own. Trim with Makeup if it gets loud.")
                }

                Section("Output") {
                    ParamSlider(title: "Output gain", value: $model.config.output, range: -24...12, step: 0.1, format: Fmt.db)
                    Toggle("Limiter", isOn: $model.config.limiter.on)
                    if model.config.limiter.on {
                        ParamSlider(title: "Ceiling", value: $model.config.limiter.ceiling, range: -12...0, step: 0.1, format: Fmt.db)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Effects")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $importingIR, allowedContentTypes: [.audio, .wav, .aiff]) { r in
                if case .success(let url) = r { model.importIR(url) }
            }
        }
    }
}
