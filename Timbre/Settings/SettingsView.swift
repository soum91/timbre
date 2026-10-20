import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Keep playing in background", isOn: $model.backgroundPlay)
                    Toggle("Desktop sites by default", isOn: $model.desktopMode)
                    Toggle("Live spectrum on EQ graph", isOn: $model.config.spectrum)
                    LiveActivityToggle(center: model.nowPlaying)
                } footer: {
                    Text("Background mode tells pages they're always visible, so players like YouTube Music don't pause when you lock the phone. Takes effect on reload.")
                }

                Section {
                    if model.disabledHosts.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(model.disabledHosts, id: \.self) { Text($0) }
                        .onDelete { model.disabledHosts.remove(atOffsets: $0) }
                } header: {
                    Text("Timbre is off on")
                } footer: {
                    Text("Sites listed here play untouched. Use this for DRM services that go silent when routed through the EQ.")
                }

                Section {
                    ForEach(model.compatHosts, id: \.self) { Text($0) }
                        .onDelete { model.compatHosts.remove(atOffsets: $0) }
                } header: {
                    Text("Compatibility mode")
                } footer: {
                    Text("Hides MediaSource from these sites so they stream in a format iOS WebKit lets the EQ process.")
                }

                Section {
                    Button("Clear cookies & website data", role: .destructive) { confirmClear = true }
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    Text("Timbre EQs audio from web players through Web Audio inside WebKit. Streams protected with DRM (FairPlay/EME) can't be processed by any browser-based EQ.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("This signs you out of every site.", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear everything", role: .destructive) { Task { await model.web.clearWebsiteData() } }
            }
        }
    }
}

private struct LiveActivityToggle: View {
    @ObservedObject var center: NowPlayingCenter
    var body: some View {
        Toggle("Live Activity while playing", isOn: $center.liveActivityEnabled)
    }
}
