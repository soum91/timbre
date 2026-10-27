import SwiftUI
import WidgetKit

// Read-only Lock Screen status, built exactly like DewPoint's 1x1 temperature widget,
// the one Lock Screen widget that renders on iOS 27 beta 4 with sideloaded builds:
// static configuration, cached data only (no network in the timeline), no buttons,
// no accessory background. Tapping it opens the app.
struct TimbreLockEntry: TimelineEntry {
    var date: Date
    var state: NowPlayingState
    var icon: String { state.playing ? "waveform" : "music.note" }
    var short: String { state.eqOn ? "EQ on" : "EQ off" }
    var title: String { state.hasMedia ? (state.artist.isEmpty ? state.site : state.artist) : "Timbre" }
    var headline: String { state.hasMedia ? state.title : "Nothing playing" }
    var detail: String { state.eqOn ? (state.preset.isEmpty ? "EQ on" : "EQ \(state.preset)") : "EQ bypassed" }
    static func make() -> TimbreLockEntry { .init(date: .now, state: SharedStore.load()) }
}

struct TimbreLockProvider: TimelineProvider {
    func placeholder(in context: Context) -> TimbreLockEntry { TimbreLockEntry.make() }
    func getSnapshot(in context: Context, completion: @escaping (TimbreLockEntry) -> Void) { completion(TimbreLockEntry.make()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TimbreLockEntry>) -> Void) {
        completion(Timeline(entries: [TimbreLockEntry.make()], policy: .after(.now.addingTimeInterval(900))))
    }
}

struct TimbreLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TimbreLockStatusV1", provider: TimbreLockProvider()) { entry in
            TimbreLockView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Now playing")
        .description("What is playing and the EQ state. Tap to open Timbre.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct TimbreLockView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TimbreLockEntry

    var body: some View {
        Group {
            if family == .accessoryCircular {
                VStack(spacing: 1) {
                    Image(systemName: entry.icon)
                        .font(.system(size: 16, weight: .semibold))
                    Text(entry.short)
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: entry.icon)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title).font(.caption2).lineLimit(1)
                        Text(entry.headline).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                        if !entry.detail.isEmpty {
                            Text(entry.detail).font(.caption2).lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}
