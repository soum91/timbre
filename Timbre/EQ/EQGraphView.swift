import SwiftUI

/// Interactive frequency-response graph: drag nodes to move freq/gain, pinch to change Q,
/// double-tap empty space to add a band, tap a node to select it.
struct EQGraphView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var spectrum: SpectrumModel
    var compact = false

    private static let freqs = FilterMath.logFreqs(count: 220)
    private static let gridFreqs: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
    private let lo = log(20.0), hi = log(20000.0)

    @State private var dragID: String?
    @State private var dragOffset: CGSize = .zero
    @State private var pinchStartQ: Double?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let plot = plotRect(size)
            let range = gainRange
            Canvas { ctx, _ in
                drawGrid(ctx, plot: plot, range: range)
                drawSpectrum(ctx, plot: plot)
                drawSelected(ctx, plot: plot, range: range)
                drawCurve(ctx, plot: plot, range: range)
                drawNodes(ctx, plot: plot, range: range)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(plot: plot, range: range))
            .simultaneousGesture(pinchGesture)
            .simultaneousGesture(
                SpatialTapGesture(count: 2).onEnded { v in
                    if hitNode(v.location, plot: plot, range: range) == nil {
                        let f = xToFreq(v.location.x, plot)
                        let g = (yToGain(v.location.y, plot, range) * 10).rounded() / 10
                        model.addBand(freq: (f).rounded(), gain: g)
                    }
                }
                .exclusively(before: SpatialTapGesture(count: 1).onEnded { v in
                    model.selectedBandID = hitNode(v.location, plot: plot, range: range)
                })
            )
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(model.config.enabled ? 1 : 0.45)
    }

    // MARK: geometry

    private func plotRect(_ s: CGSize) -> CGRect {
        CGRect(x: 30, y: 10, width: max(10, s.width - 40), height: max(10, s.height - (compact ? 22 : 28)))
    }

    private var curve: [Double] {
        FilterMath.response(bands: model.config.bands, preamp: 0, freqs: Self.freqs, fs: model.sampleRate)
    }

    private var gainRange: Double {
        let m = max(curve.map { abs($0) }.max() ?? 0, model.config.bands.map { abs($0.gain) }.max() ?? 0)
        return min(30, max(12, ((m + 2) / 6).rounded(.up) * 6))
    }

    private func freqToX(_ f: Double, _ p: CGRect) -> CGFloat {
        p.minX + CGFloat((log(max(f, 20)) - lo) / (hi - lo)) * p.width
    }
    private func xToFreq(_ x: CGFloat, _ p: CGRect) -> Double {
        exp(lo + Double((x - p.minX) / p.width) * (hi - lo)).clamped(20, 20000)
    }
    private func gainToY(_ g: Double, _ p: CGRect, _ r: Double) -> CGFloat {
        p.midY - CGFloat(g / r) * p.height / 2
    }
    private func yToGain(_ y: CGFloat, _ p: CGRect, _ r: Double) -> Double {
        (Double((p.midY - y) / (p.height / 2)) * r).clamped(-r, r)
    }

    private func nodePoint(_ b: Band, _ p: CGRect, _ r: Double) -> CGPoint {
        let g: Double
        if b.type.usesGain { g = b.gain }
        else { g = FilterMath.response(band: b, freqs: [b.freq], fs: model.sampleRate)[0] }
        return CGPoint(x: freqToX(b.freq, p), y: gainToY(g.clamped(-r, r), p, r))
    }

    private func hitNode(_ pt: CGPoint, plot: CGRect, range: Double) -> String? {
        var best: (String, CGFloat)?
        for b in model.config.bands {
            let n = nodePoint(b, plot, range)
            let d = hypot(n.x - pt.x, n.y - pt.y)
            if d < 34, d < (best?.1 ?? .infinity) { best = (b.id, d) }
        }
        return best?.0
    }

    // MARK: gestures

    private func dragGesture(plot: CGRect, range: Double) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                if dragID == nil {
                    guard let id = hitNode(v.startLocation, plot: plot, range: range),
                          let b = model.config.bands.first(where: { $0.id == id }) else { return }
                    dragID = id
                    model.selectedBandID = id
                    let n = nodePoint(b, plot, range)
                    dragOffset = CGSize(width: n.x - v.startLocation.x, height: n.y - v.startLocation.y)
                }
                guard let id = dragID, let bind = model.binding(for: id) else { return }
                var b = bind.wrappedValue
                let x = v.location.x + dragOffset.width, y = v.location.y + dragOffset.height
                let f = xToFreq(x, plot)
                b.freq = f < 1000 ? f.rounded() : (f / 10).rounded() * 10
                if b.type.usesGain { b.gain = (yToGain(y, plot, range) * 10).rounded() / 10 }
                bind.wrappedValue = b
            }
            .onEnded { _ in dragID = nil }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                guard let id = model.selectedBandID, let bind = model.binding(for: id) else { return }
                if pinchStartQ == nil { pinchStartQ = bind.wrappedValue.q }
                var b = bind.wrappedValue
                b.q = ((pinchStartQ ?? 1) / Double(scale)).clamped(0.1, 20)
                b.q = (b.q * 100).rounded() / 100
                bind.wrappedValue = b
            }
            .onEnded { _ in pinchStartQ = nil }
    }

    // MARK: drawing

    private func label(_ f: Double) -> String {
        f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
    }

    private func drawGrid(_ ctx: GraphicsContext, plot: CGRect, range: Double) {
        var grid = Path()
        for f in Self.gridFreqs {
            let x = freqToX(f, plot)
            grid.move(to: CGPoint(x: x, y: plot.minY)); grid.addLine(to: CGPoint(x: x, y: plot.maxY))
            ctx.draw(Text(label(f)).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(.secondary),
                     at: CGPoint(x: x, y: plot.maxY + 9))
        }
        let step = range > 18 ? 12.0 : 6.0
        var g = -range
        while g <= range + 0.01 {
            let y = gainToY(g, plot, range)
            grid.move(to: CGPoint(x: plot.minX, y: y)); grid.addLine(to: CGPoint(x: plot.maxX, y: y))
            ctx.draw(Text(g > 0 ? "+\(Int(g))" : "\(Int(g))").font(.system(size: 9, design: .rounded)).foregroundColor(.secondary),
                     at: CGPoint(x: plot.minX - 14, y: y))
            g += step
        }
        ctx.stroke(grid, with: .color(Theme.grid), lineWidth: 1)
        var zero = Path()
        let y0 = gainToY(0, plot, range)
        zero.move(to: CGPoint(x: plot.minX, y: y0)); zero.addLine(to: CGPoint(x: plot.maxX, y: y0))
        ctx.stroke(zero, with: .color(.white.opacity(0.18)), lineWidth: 1)
    }

    private func drawSpectrum(_ ctx: GraphicsContext, plot: CGRect) {
        let bins = spectrum.bins
        guard model.config.spectrum, bins.count > 1 else { return }
        var p = Path()
        p.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        for (i, v) in bins.enumerated() {
            let x = plot.minX + CGFloat(i) / CGFloat(bins.count - 1) * plot.width
            let norm = CGFloat(((Double(v) + 100) / 90).clamped(0, 1))
            p.addLine(to: CGPoint(x: x, y: plot.maxY - norm * plot.height * 0.85))
        }
        p.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        p.closeSubpath()
        ctx.fill(p, with: .linearGradient(Gradient(colors: [.white.opacity(0.16), .white.opacity(0.02)]),
                                          startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
    }

    private func path(_ values: [Double], plot: CGRect, range: Double) -> Path {
        var p = Path()
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: freqToX(Self.freqs[i], plot), y: gainToY(v.clamped(-range * 1.2, range * 1.2), plot, range))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }

    private func drawSelected(_ ctx: GraphicsContext, plot: CGRect, range: Double) {
        guard let id = model.selectedBandID,
              let i = model.config.bands.firstIndex(where: { $0.id == id }) else { return }
        let b = model.config.bands[i]
        let r = FilterMath.response(band: b, freqs: Self.freqs, fs: model.sampleRate)
        var p = path(r, plot: plot, range: range)
        let y0 = gainToY(0, plot, range)
        p.addLine(to: CGPoint(x: plot.maxX, y: y0)); p.addLine(to: CGPoint(x: plot.minX, y: y0)); p.closeSubpath()
        ctx.fill(p, with: .color(Theme.color(i).opacity(b.on ? 0.22 : 0.08)))
    }

    private func drawCurve(_ ctx: GraphicsContext, plot: CGRect, range: Double) {
        let p = path(curve, plot: plot, range: range)
        var glow = ctx
        glow.addFilter(.blur(radius: 6))
        glow.stroke(p, with: .color(Theme.accent.opacity(0.5)), lineWidth: 4)
        ctx.stroke(p, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
    }

    private func drawNodes(_ ctx: GraphicsContext, plot: CGRect, range: Double) {
        for (i, b) in model.config.bands.enumerated() {
            let n = nodePoint(b, plot, range)
            let sel = b.id == model.selectedBandID
            let r: CGFloat = sel ? 11 : 8
            let rect = CGRect(x: n.x - r, y: n.y - r, width: 2 * r, height: 2 * r)
            let c = Theme.color(i)
            ctx.fill(Path(ellipseIn: rect), with: .color(b.on ? c : c.opacity(0.3)))
            if sel { ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(.white.opacity(0.9)), lineWidth: 1.5) }
            ctx.draw(Text("\(i + 1)").font(.system(size: sel ? 11 : 9, weight: .bold, design: .rounded)).foregroundColor(.black),
                     at: n)
        }
    }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}
