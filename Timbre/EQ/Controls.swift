import SwiftUI

/// Slider with title, live value readout and tap-to-type exact entry.
struct ParamSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var log = false
    var step: Double? = nil
    var format: (Double) -> String = { String(format: "%.1f", $0) }
    var disabled = false

    @State private var editing = false
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Button(format(value)) {
                    text = String(format: "%g", value)
                    editing = true
                }
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(disabled ? Color.secondary : Theme.accent)
            }
            Slider(value: sliderBinding, in: 0...1)
                .disabled(disabled)
        }
        .opacity(disabled ? 0.5 : 1)
        .alert(title, isPresented: $editing) {
            TextField(title, text: $text).keyboardType(.numbersAndPunctuation)
            Button("Set") {
                if let v = Double(text.replacingOccurrences(of: ",", with: ".")) { value = v.clamped(range.lowerBound, range.upperBound) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: {
                let v = value.clamped(range.lowerBound, range.upperBound)
                if log { return (Foundation.log(v) - Foundation.log(range.lowerBound)) / (Foundation.log(range.upperBound) - Foundation.log(range.lowerBound)) }
                return (v - range.lowerBound) / (range.upperBound - range.lowerBound)
            },
            set: { t in
                var v: Double
                if log { v = exp(Foundation.log(range.lowerBound) + t * (Foundation.log(range.upperBound) - Foundation.log(range.lowerBound))) }
                else { v = range.lowerBound + t * (range.upperBound - range.lowerBound) }
                if let s = step { v = (v / s).rounded() * s }
                value = v
            })
    }
}

enum Fmt {
    static func hz(_ f: Double) -> String { f >= 1000 ? String(format: f >= 10000 ? "%.1f kHz" : "%.2f kHz", f / 1000) : String(format: "%.0f Hz", f) }
    static func db(_ g: Double) -> String { String(format: "%@%.1f dB", g > 0.05 ? "+" : "", g) }
    static func q(_ q: Double) -> String { String(format: "Q %.2f", q) }
    static func ms(_ v: Double) -> String { v < 10 ? String(format: "%.1f ms", v) : String(format: "%.0f ms", v) }
    static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
    static func deg(_ v: Double) -> String { String(format: "%.0f°", v) }
    static func ratio(_ v: Double) -> String { String(format: "%.1f:1", v) }
    static func sec(_ v: Double) -> String { String(format: "%.2f s", v) }
}

struct ChipRow<Item: Identifiable>: View {
    let items: [Item]
    let title: (Item) -> String
    let action: (Item) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { it in
                    Button(title(it)) { action(it) }
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }
            }
        }
    }
}
