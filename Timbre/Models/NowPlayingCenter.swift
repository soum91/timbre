import Foundation
import UIKit
import WidgetKit
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Tracks what the page is playing and mirrors it to the widget and the Live Activity.
@MainActor
final class NowPlayingCenter: ObservableObject {
    @Published private(set) var state = NowPlayingState()
    @Published var liveActivityEnabled: Bool {
        didSet {
            UserDefaults.standard.set(liveActivityEnabled, forKey: "timbre.liveActivity")
            if liveActivityEnabled { syncActivity() } else { endActivity() }
        }
    }

    private var artworkSource = ""
    private var artworkTask: Task<Void, Never>?
    private var widgetReload: DispatchWorkItem?
    private var idleEnd: DispatchWorkItem?
    private var activityID: String?

    init() {
        liveActivityEnabled = UserDefaults.standard.object(forKey: "timbre.liveActivity") as? Bool ?? true
        state = SharedStore.load()
        state.playing = false
        endStaleActivities()
        publish()
    }

    // MARK: input

    func ingest(_ b: [String: Any], site: String) {
        let playing = (b["playing"] as? Bool) ?? false
        // a paused frame shouldn't override another frame that's playing
        if !playing && state.playing && (b["title"] as? String ?? "") != state.title { return }
        var s = state
        s.title = (b["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        s.artist = b["artist"] as? String ?? ""
        s.site = site
        s.playing = playing
        s.canNext = (b["canNext"] as? Bool) ?? false
        s.canPrev = (b["canPrev"] as? Bool) ?? false
        let art = b["artwork"] as? String ?? ""
        if art != artworkSource {
            artworkSource = art
            loadArtwork(art)
        }
        if s != state { state = s; publish() }
    }

    func setEQ(on: Bool, preset: String) {
        guard state.eqOn != on || state.preset != preset else { return }
        state.eqOn = on
        state.preset = preset
        publish()
    }

    func pageChanged() {
        guard state.playing else { return }
        state.playing = false
        publish()
    }

    // MARK: artwork

    private func loadArtwork(_ src: String) {
        artworkTask?.cancel()
        guard let url = URL(string: src), url.scheme?.hasPrefix("http") == true else {
            setArtwork(nil)
            return
        }
        artworkTask = Task { [weak self] in
            guard let res = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled,
                  case let data = res.0,
                  let img = UIImage(data: data) else { return }
            let side: CGFloat = 200
            let r = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
            let thumb = r.jpegData(withCompressionQuality: 0.8) { _ in
                let s = img.size, scale = max(side / s.width, side / s.height)
                let w = s.width * scale, h = s.height * scale
                img.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
            }
            await MainActor.run { self?.storeArtwork(thumb) }
        }
    }

    private func storeArtwork(_ data: Data) {
        guard let dir = SharedStore.container else { return }
        let name = "art-\(UUID().uuidString.prefix(8)).jpg"
        do {
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            setArtwork(name)
        } catch {}
    }

    private func setArtwork(_ name: String?) {
        let old = state.artwork
        state.artwork = name
        publish()
        if let old, old != name, let u = SharedStore.artworkURL(old) {
            // give the widget/Live Activity a moment to switch before deleting
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { try? FileManager.default.removeItem(at: u) }
        }
    }

    // MARK: output

    private func publish() {
        SharedStore.save(state)
        widgetReload?.cancel()
        let w = DispatchWorkItem { WidgetCenter.shared.reloadAllTimelines() }
        widgetReload = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
        syncActivity()
    }

    private func syncActivity() {
        guard #available(iOS 17.0, *) else { return }
        guard liveActivityEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else { endActivity(); return }
        if state.playing {
            idleEnd?.cancel(); idleEnd = nil
        } else if idleEnd == nil {
            // paused for 10 minutes: get off the lock screen
            let w = DispatchWorkItem { [weak self] in self?.endActivity() }
            idleEnd = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: w)
        }
        let content = ActivityContent(state: state, staleDate: nil)
        if let a = current() {
            Task { await a.update(content) }
        } else if state.playing && state.hasMedia {
            if let a = try? Activity.request(attributes: TimbreActivityAttributes(), content: content, pushType: nil) {
                activityID = a.id
            }
        }
    }

    @available(iOS 17.0, *)
    private func current() -> Activity<TimbreActivityAttributes>? {
        Activity<TimbreActivityAttributes>.activities.first { $0.id == activityID } ?? Activity<TimbreActivityAttributes>.activities.first
    }

    func endActivity() {
        idleEnd?.cancel(); idleEnd = nil
        guard #available(iOS 17.0, *) else { return }
        let final = ActivityContent(state: state, staleDate: nil)
        for a in Activity<TimbreActivityAttributes>.activities {
            Task { await a.end(final, dismissalPolicy: .immediate) }
        }
        activityID = nil
    }

    private func endStaleActivities() {
        guard #available(iOS 17.0, *) else { return }
        for a in Activity<TimbreActivityAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
