import SwiftUI
import UniformTypeIdentifiers

struct EQView: View {
    @EnvironmentObject var model: AppModel
    @State private var importing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                EQGraphView(spectrum: model.spectrum)
                    .frame(height: 250)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                List {
                    if let id = model.selectedBandID, let bind = model.binding(for: id) {
                        Section {
                            BandEditor(band: bind, index: model.config.bands.firstIndex { $0.id == id } ?? 0)
                        } header: {
                            HStack {
                                Text("Band \((model.config.bands.firstIndex { $0.id == id } ?? 0) + 1)")
                                Spacer()
                                Button("Done") { model.selectedBandID = nil }.font(.footnote.weight(.semibold))
                            }
                        }
                    } else {
                        Section {
                            Text("Double-tap the graph to add a band. Drag a node to move it, pinch to change its Q.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        ParamSlider(title: "Preamp", value: $model.config.preamp, range: -30...12, step: 0.1, format: Fmt.db)
                        HStack {
                            let headroom = model.curvePeak() + model.config.preamp
                            Label(headroom > 0.05 ? String(format: "Clips by %.1f dB (limiter catches it)", headroom) : "No clipping",
                                  systemImage: headroom > 0.05 ? "exclamationmark.triangle" : "checkmark.circle")
                                .font(.footnote)
                                .foregroundStyle(headroom > 0.05 ? Color.orange : Color.secondary)
                            Spacer()
                            Button("Auto") { model.autoPreamp() }.font(.footnote.weight(.semibold))
                        }
                    }

                    Section {
                        ForEach(Array(model.config.bands.enumerated()), id: \.element.id) { i, b in
                            BandRow(band: b, index: i, selected: b.id == model.selectedBandID,
                                    toggle: { model.binding(for: b.id)?.wrappedValue.on.toggle() })
                                .contentShape(Rectangle())
                                .onTapGesture { model.selectedBandID = b.id }
                        }
                        .onDelete { idx in
                            let ids = idx.map { model.config.bands[$0].id }
                            for id in ids { model.removeBand(id) }
                        }
                        .onMove { from, to in model.config.bands.move(fromOffsets: from, toOffset: to) }
                        Button { model.addBand() } label: { Label("Add band", systemImage: "plus") }
                    } header: {
                        Text("\(model.config.bands.count) bands")
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .background(Theme.bg)
            .navigationTitle(model.activePresetName ?? "Equalizer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Toggle("On", isOn: $model.config.enabled).labelsHidden()
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Button { model.addBand(type: .lowshelf) } label: { Label("Add low shelf", systemImage: "arrow.down.left") }
                        Button { model.addBand(type: .highshelf) } label: { Label("Add high shelf", systemImage: "arrow.up.right") }
                        Button { model.addBand(freq: 30, type: .highpass) } label: { Label("Add high pass", systemImage: "line.diagonal") }
                        Divider()
                        Button { importing = true } label: { Label("Import EQ file…", systemImage: "square.and.arrow.down") }
                        ShareLink(item: PresetIO.exportAPO(preamp: model.config.preamp, bands: model.config.bands)) {
                            Label("Export as EqualizerAPO", systemImage: "square.and.arrow.up")
                        }
                        Divider()
                        Button(role: .destructive) { model.flatten() } label: { Label("Reset to flat", systemImage: "arrow.counterclockwise") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    Button { model.addBand() } label: { Image(systemName: "plus") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .data]) { r in
                if case .success(let url) = r { model.importFile(url) }
            }
        }
    }
}

struct BandRow: View {
    let band: Band
    let index: Int
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundColor(.black)
                .frame(width: 22, height: 22)
                .background(Theme.color(index).opacity(band.on ? 1 : 0.3), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(band.type.label).font(.subheadline.weight(selected ? .semibold : .regular))
                Text([Fmt.hz(band.freq), band.type.usesGain ? Fmt.db(band.gain) : nil, Fmt.q(band.q)].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: toggle) {
                Image(systemName: band.on ? "power.circle.fill" : "power.circle")
                    .font(.title3)
                    .foregroundStyle(band.on ? Theme.accent : Color.secondary)
            }
            .buttonStyle(.plain)
        }
        .opacity(band.on ? 1 : 0.6)
    }
}

struct BandEditor: View {
    @EnvironmentObject var model: AppModel
    @Binding var band: Band
    let index: Int

    var body: some View {
        Picker("Type", selection: $band.type) {
            ForEach(FilterType.allCases) { Text($0.label).tag($0) }
        }
        ParamSlider(title: "Frequency", value: $band.freq, range: 20...20000, log: true, format: Fmt.hz)
        ParamSlider(title: "Gain", value: $band.gain, range: -24...24, step: 0.1, format: Fmt.db, disabled: !band.type.usesGain)
        ParamSlider(title: "Q", value: $band.q, range: 0.1...20, log: true, format: { String(format: "%.2f", $0) })
        HStack {
            Toggle("Enabled", isOn: $band.on)
            Spacer()
            Button(role: .destructive) { model.removeBand(band.id) } label: { Label("Delete", systemImage: "trash") }
                .buttonStyle(.borderless)
        }
    }
}
