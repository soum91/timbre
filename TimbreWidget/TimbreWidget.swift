import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents
import UIKit

private let accent = Color(red: 1.0, green: 0.70, blue: 0.25)
private let panel = Color(red: 0.08, green: 0.085, blue: 0.10)

@main
struct TimbreWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        TimbreLiveActivity()
    }
}

// MARK: - shared bits

private func artwork(_ name: String?) -> UIImage? {
    guard let u = SharedStore.artworkURL(name) else { return nil }
    return UIImage(contentsOfFile: u.path)
}

private struct Artwork: View {
    let name: String?
    var size: CGFloat
    var radius: CGFloat = 10

    var body: some View {
        Group {
            if let img = artwork(name) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [accent.opacity(0.5), accent.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "waveform").font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

private struct EQBadge: View {
    let s: NowPlayingState
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: s.eqOn ? "slider.vertical.3" : "power")
            Text(s.eqOn ? (s.preset.isEmpty ? "EQ" : s.preset) : "EQ off").lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(s.eqOn ? accent : .secondary)
    }
}

private struct Controls: View {
    let s: NowPlayingState
    var size: CGFloat = 20
    var showEQ = true

    var body: some View {
        HStack(spacing: size * 1.1) {
            Button(intent: TimbreMediaIntent("prev")) { Image(systemName: s.canPrev ? "backward.fill" : "gobackward.15") }
            Button(intent: TimbreMediaIntent("toggle")) { Image(systemName: s.playing ? "pause.fill" : "play.fill").font(.system(size: size * 1.25)) }
            Button(intent: TimbreMediaIntent("next")) { Image(systemName: s.canNext ? "forward.fill" : "goforward.15") }
            if showEQ {
                Button(intent: TimbreEQIntent()) {
                    Image(systemName: "slider.vertical.3")
                        .foregroundStyle(s.eqOn ? accent : .secondary)
                }
            }
        }
        .font(.system(size: size, weight: .semibold))
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

// MARK: - home / lock screen widget

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let state: NowPlayingState
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, state: NowPlayingState(title: "Song title", artist: "Artist", site: "music.youtube.com", playing: true, eqOn: true, preset: "Bass Boost"))
    }
    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : NowPlayingEntry(date: .now, state: SharedStore.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        completion(Timeline(entries: [NowPlayingEntry(date: .now, state: SharedStore.load())], policy: .never))
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TimbreNowPlaying", provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(s: entry.state)
        }
        .configurationDisplayName("Timbre")
        .description("What's playing, playback controls and the EQ switch.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let s: NowPlayingState

    var body: some View {
        content.containerBackground(for: .widget) {
            if family == .accessoryRectangular { Color.clear } else { panel }
        }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(s.hasMedia ? s.title : "Timbre").font(.headline).lineLimit(1)
                if !s.artist.isEmpty { Text(s.artist).font(.caption).lineLimit(1) }
                Text(s.eqOn ? "EQ · \(s.preset)" : "EQ off").font(.caption2).lineLimit(1)
            }
        case .systemMedium:
            HStack(spacing: 14) {
                Artwork(name: s.artwork, size: 112, radius: 14)
                VStack(alignment: .leading, spacing: 4) {
                    title
                    Spacer(minLength: 4)
                    Controls(s: s, size: 20)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Artwork(name: s.artwork, size: 52)
                    Spacer()
                    Button(intent: TimbreMediaIntent("toggle")) {
                        Image(systemName: s.playing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 34)).foregroundStyle(accent)
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                title
            }
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.hasMedia ? s.title : "Nothing playing").font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(.white)
            if !s.artist.isEmpty { Text(s.artist).font(.caption).lineLimit(1).foregroundStyle(.secondary) }
            EQBadge(s: s)
        }
    }
}

// MARK: - Live Activity

struct TimbreLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimbreActivityAttributes.self) { ctx in
            let s = ctx.state
            HStack(spacing: 12) {
                Artwork(name: s.artwork, size: 56, radius: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.title.isEmpty ? "Timbre" : s.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(s.artist.isEmpty ? s.site : s.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    EQBadge(s: s)
                }
                Spacer(minLength: 6)
                Controls(s: s, size: 18, showEQ: true)
            }
            .padding(14)
            .activityBackgroundTint(panel)
            .activitySystemActionForegroundColor(accent)
        } dynamicIsland: { ctx in
            let s = ctx.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Artwork(name: s.artwork, size: 52, radius: 12).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: TimbreEQIntent()) {
                        Image(systemName: "slider.vertical.3").font(.title3)
                            .foregroundStyle(s.eqOn ? accent : .secondary)
                    }.buttonStyle(.plain).padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(s.title.isEmpty ? "Timbre" : s.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(s.artist.isEmpty ? s.site : s.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        EQBadge(s: s)
                        Spacer()
                        Controls(s: s, size: 20, showEQ: false)
                    }
                    .padding(.horizontal, 8)
                }
            } compactLeading: {
                Artwork(name: s.artwork, size: 22, radius: 6)
            } compactTrailing: {
                Image(systemName: s.playing ? (s.eqOn ? "slider.vertical.3" : "waveform") : "pause.fill")
                    .foregroundStyle(s.eqOn ? accent : .white)
            } minimal: {
                Image(systemName: s.eqOn ? "slider.vertical.3" : "waveform").foregroundStyle(accent)
            }
            .keylineTint(accent)
        }
    }
}
