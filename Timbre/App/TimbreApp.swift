import SwiftUI
import AVFoundation
import AppIntents

@main
struct TimbreApp: App {
    @StateObject private var model = AppModel.shared

    init() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [])
        try? s.setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

enum Theme {
    static let accent = Color(red: 1.0, green: 0.70, blue: 0.25)
    static let bg = Color(red: 0.055, green: 0.058, blue: 0.07)
    static let panel = Color(red: 0.10, green: 0.105, blue: 0.125)
    static let grid = Color.white.opacity(0.07)
    static let bandColors: [Color] = [
        Color(red: 1.0, green: 0.70, blue: 0.25), Color(red: 0.36, green: 0.78, blue: 1.0),
        Color(red: 0.55, green: 0.90, blue: 0.45), Color(red: 1.0, green: 0.45, blue: 0.55),
        Color(red: 0.75, green: 0.55, blue: 1.0), Color(red: 0.30, green: 0.92, blue: 0.82),
        Color(red: 1.0, green: 0.85, blue: 0.35), Color(red: 1.0, green: 0.55, blue: 0.30)
    ]
    static func color(_ i: Int) -> Color { bandColors[((i % bandColors.count) + bandColors.count) % bandColors.count] }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            BrowserView()
                .tabItem { Label("Browse", systemImage: "globe") }.tag(0)
            EQView()
                .tabItem { Label("EQ", systemImage: "slider.vertical.3") }.tag(1)
            EffectsView()
                .tabItem { Label("Effects", systemImage: "sparkles") }.tag(2)
            PresetsView()
                .tabItem { Label("Presets", systemImage: "square.stack.3d.up") }.tag(3)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(4)
        }
        .overlay(alignment: .top) { ToastView() }
        .onChange(of: scenePhase) { phase in
            guard phase != .active else { return }
            // flush sign-ins to disk before iOS can kill us
            let bg = UIApplication.shared.beginBackgroundTask(withName: "save-cookies")
            Task { @MainActor in
                await model.web.saveSession()
                UIApplication.shared.endBackgroundTask(bg)
            }
        }
    }
}

struct ToastView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let t = model.toast {
            Text(t)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { model.toast = nil }
                .task(id: t) {
                    try? await Task.sleep(nanoseconds: 2_600_000_000)
                    if model.toast == t { withAnimation { model.toast = nil } }
                }
        }
    }
}


/// App-only actions run in the main process, not Timbre's widget extension.
struct ToggleTimbreEQShortcutIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Timbre EQ"
    func perform() async throws -> some IntentResult {
        await CommandBus.send("eq")
        return .result()
    }
}
struct ToggleTimbreSpatialShortcutIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Spatial Audio"
    func perform() async throws -> some IntentResult {
        let enabled = TimbreQuickSnapshot.load().spatial
        await CommandBus.send(enabled ? "spatial:off" : "spatial:on")
        return .result()
    }
}
struct ToggleTimbreReverbShortcutIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Reverb"
    func perform() async throws -> some IntentResult {
        let enabled = TimbreQuickSnapshot.load().reverb
        await CommandBus.send(enabled ? "reverb:off" : "reverb:on")
        return .result()
    }
}
struct TimbreShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .orange

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleTimbreEQShortcutIntent(), phrases: [
            "Toggle equalizer in \(.applicationName)",
        ], shortTitle: "EQ Switch", systemImageName: "slider.vertical.3")
        AppShortcut(intent: ToggleTimbreSpatialShortcutIntent(), phrases: [
            "Toggle spatial audio in \(.applicationName)",
        ], shortTitle: "Spatial Audio", systemImageName: "waveform")
        AppShortcut(intent: ToggleTimbreReverbShortcutIntent(), phrases: [
            "Toggle reverb in \(.applicationName)",
        ], shortTitle: "Reverb", systemImageName: "waveform.path")
    }
}
