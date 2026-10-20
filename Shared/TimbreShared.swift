import Foundation
import AppIntents
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Shared between the app and the widget extension (App Group).
enum SharedStore {
    static let group = "group.com.soum91.timbre"
    static let darwinCommand = "com.soum91.timbre.cmd"

    static var defaults: UserDefaults? { UserDefaults(suiteName: group) }

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    static func artworkURL(_ name: String?) -> URL? {
        guard let name, !name.isEmpty else { return nil }
        return container?.appendingPathComponent(name)
    }

    static func save(_ s: NowPlayingState) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        defaults?.set(d, forKey: "nowPlaying")
    }

    static func load() -> NowPlayingState {
        guard let d = defaults?.data(forKey: "nowPlaying"),
              let s = try? JSONDecoder().decode(NowPlayingState.self, from: d) else { return NowPlayingState() }
        return s
    }
}

struct NowPlayingState: Codable, Hashable {
    var title = ""
    var artist = ""
    var site = ""
    var playing = false
    var eqOn = true
    var preset = ""
    var artwork: String?
    var canNext = false
    var canPrev = false

    var hasMedia: Bool { !title.isEmpty || playing }
}

/// Routes widget / Live Activity button presses into the running app.
enum CommandBus {
    @MainActor static var handler: ((String) -> Void)?

    static func send(_ cmd: String) async {
        let handled: Bool = await MainActor.run {
            guard let h = handler else { return false }
            h(cmd)
            return true
        }
        if handled { return }
        // Running in the widget process: hand the command to the app through the App Group.
        SharedStore.defaults?.set(cmd, forKey: "pendingCommand")
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(SharedStore.darwinCommand as CFString), nil, nil, true)
    }
}

@available(iOS 17.0, *)
struct TimbreMediaIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Control Timbre playback"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Command") var command: String

    init() { command = "toggle" }
    init(_ command: String) { self.command = command }

    func perform() async throws -> some IntentResult {
        await CommandBus.send(command)
        return .result()
    }
}

@available(iOS 17.0, *)
struct TimbreEQIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Toggle Timbre EQ"
    static var isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        await CommandBus.send("eq")
        return .result()
    }
}

#if canImport(ActivityKit)
@available(iOS 16.1, *)
struct TimbreActivityAttributes: ActivityAttributes {
    typealias ContentState = NowPlayingState
}
#endif
