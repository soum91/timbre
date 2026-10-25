import SwiftUI
import WidgetKit
import AppIntents

@available(iOS 18.0, *)
struct TimbreGainUpControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.soum91.timbre.TimbreGainUpControl") {
            ControlWidgetButton(action: TimbreQuickIntent("gain:up")) { Label("Timbre gain up", systemImage: "plus") }
        }.displayName("Timbre gain up").description("Timbre gain up")
    }
}
@available(iOS 18.0, *)
struct TimbreGainDownControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.soum91.timbre.TimbreGainDownControl") {
            ControlWidgetButton(action: TimbreQuickIntent("gain:down")) { Label("Timbre gain down", systemImage: "minus") }
        }.displayName("Timbre gain down").description("Timbre gain down")
    }
}
