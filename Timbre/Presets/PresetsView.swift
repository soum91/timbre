import SwiftUI
import UniformTypeIdentifiers

struct PresetsView: View {
    @EnvironmentObject var model: AppModel
    @State private var saving = false
    @State private var importing = false
    @State private var renaming: Preset?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.activePresetName ?? "Custom").font(.headline)
                            Text("\(model.config.bands.count) bands · preamp \(Fmt.db(model.config.preamp))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Save…") { saving = true }.buttonStyle(.borderedProminent)
                    }
                } header: { Text("Current") }

                Section {
                    NavigationLink { AutoEqSearchView() } label: {
                        Label("Find my headphones (AutoEq)", systemImage: "headphones")
                    }
                    Button { importing = true } label: { Label("Import EqualizerAPO / Winamp file…", systemImage: "square.and.arrow.down") }
                } footer: {
                    Text("AutoEq has measured corrections for thousands of headphones and IEMs. Imports read EqualizerAPO / Peace parametric configs and Winamp .eqf libraries.")
                }

                if !model.presets.isEmpty {
                    Section("My presets") {
                        ForEach(model.presets) { p in
                            row(p)
                                .contextMenu {
                                    Button { renameText = p.name; renaming = p } label: { Label("Rename", systemImage: "pencil") }
                                    ShareLink(item: PresetIO.exportAPO(preamp: p.preamp, bands: p.bands)) {
                                        Label("Export", systemImage: "square.and.arrow.up")
                                    }
                                    Button(role: .destructive) { model.presets.removeAll { $0.id == p.id } } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                        .onDelete { model.presets.remove(atOffsets: $0) }
                        .onMove { model.presets.move(fromOffsets: $0, toOffset: $1) }
                    }
                }

                Section("Built-in") {
                    ForEach(Preset.builtIns) { row($0) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { EditButton() }
            .sheet(isPresented: $saving) { SavePresetSheet() }
            .alert("Rename preset", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let r = renaming, let i = model.presets.firstIndex(where: { $0.id == r.id }) {
                        model.presets[i].name = renameText
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .data]) { r in
                if case .success(let url) = r { model.importFile(url) }
            }
        }
    }

    private func row(_ p: Preset) -> some View {
        Button { model.apply(p) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).foregroundStyle(.primary)
                    Text("\(p.bands.count) bands\(p.effects != nil ? " + effects" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                PresetSparkline(preset: p).frame(width: 70, height: 24)
                if model.activePresetName == p.name {
                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                }
            }
        }
    }
}

struct PresetSparkline: View {
    let preset: Preset
    private static let freqs = FilterMath.logFreqs(count: 40)

    var body: some View {
        Canvas { ctx, size in
            let r = FilterMath.response(bands: preset.bands, preamp: 0, freqs: Self.freqs, fs: 48000)
            let m = max(6, r.map { abs($0) }.max() ?? 0)
            var p = Path()
            for (i, v) in r.enumerated() {
                let pt = CGPoint(x: CGFloat(i) / CGFloat(r.count - 1) * size.width, y: size.height / 2 - CGFloat(v / m) * size.height / 2)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(Theme.accent.opacity(0.8)), lineWidth: 1.5)
        }
    }
}

struct SavePresetSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var includeEffects = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Preset name", text: $name)
                Toggle("Include effects (reverb, spatial, crossfeed…)", isOn: $includeEffects)
            }
            .navigationTitle("Save preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.saveCurrent(as: name.trimmingCharacters(in: .whitespaces), includeEffects: includeEffects)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { name = model.activePresetName ?? "" }
        }
        .presentationDetents([.medium])
    }
}

struct AutoEqSearchView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var applying: String?

    var body: some View {
        AutoEqList(index: model.autoEq, query: $query, applying: $applying)
            .navigationTitle("AutoEq")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Sennheiser HD 650, AirPods Pro…")
            .task { await model.autoEq.load() }
    }
}

private struct AutoEqList: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var index: AutoEqIndex
    @Binding var query: String
    @Binding var applying: String?

    var body: some View {
        List {
            if index.loading {
                HStack { ProgressView(); Text("Loading headphone database…").foregroundStyle(.secondary) }
            } else if let e = index.error {
                VStack(alignment: .leading) {
                    Text(e).foregroundStyle(.secondary)
                    Button("Retry") { Task { await index.load(force: true) } }
                }
            } else if query.isEmpty {
                Text("\(index.entries.count) profiles. Search by brand or model.").foregroundStyle(.secondary)
            } else {
                let results = Array(index.search(query).prefix(150))
                if results.isEmpty { Text("Nothing matches.").foregroundStyle(.secondary) }
                ForEach(results) { e in
                    Button {
                        applying = e.id
                        Task { await model.applyAutoEq(e); applying = nil }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.name).foregroundStyle(.primary)
                                Text(e.source).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if applying == e.id { ProgressView() }
                        }
                    }
                    .disabled(applying != nil)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
    }
}
