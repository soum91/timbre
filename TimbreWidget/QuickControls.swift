import SwiftUI
import WidgetKit
import AppIntents
@available(iOS 18.0, *) struct TimbreControlProvider: ControlValueProvider {
    var previewValue: TimbreQuickSnapshot { .init() }
    func currentValue() async throws -> TimbreQuickSnapshot { .load() }
}
@available(iOS 18.0, *) struct TimbreEQControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.soum91.timbre.eq", provider: TimbreControlProvider()) { state in
            ControlWidgetToggle("Timbre EQ", isOn: state.eq, action: TimbreSwitchIntent("eq")) { Label($0 ? "Enabled" : "Bypassed", systemImage: "slider.vertical.3") }
        }.displayName("Timbre EQ").description("Enable or bypass Timbre's own equalizer.")
    }
}
@available(iOS 18.0, *) struct TimbreSpatialControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.soum91.timbre.spatial", provider: TimbreControlProvider()) { state in
            ControlWidgetToggle("Spatial audio", isOn: state.spatial, action: TimbreSwitchIntent("spatial")) { Label($0 ? "On" : "Off", systemImage: "spatialaudio") }
        }.displayName("Timbre spatial").description("Enable or disable Timbre spatialization.")
    }
}
@available(iOS 18.0, *) struct TimbreReverbControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.soum91.timbre.reverb", provider: TimbreControlProvider()) { state in
            ControlWidgetToggle("Reverb", isOn: state.reverb, action: TimbreSwitchIntent("reverb")) { Label($0 ? "On" : "Off", systemImage: "waveform.path") }
        }.displayName("Timbre reverb").description("Enable or disable Timbre reverb.")
    }
}
@available(iOS 18.0, *) struct TimbrePresetControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "com.soum91.timbre.preset", intent: TimbrePresetConfig.self) { config in
            ControlWidgetButton(action: TimbreQuickIntent("preset:\(config.preset?.id ?? "")")) { Label(config.preset?.name ?? "Choose preset", systemImage: "slider.horizontal.3") }
        }.displayName("Timbre preset").description("Apply a saved EQ preset.")
    }
}
