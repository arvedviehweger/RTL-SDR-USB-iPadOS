//
//  SpectrumView.swift
//  RTL-SDR Host
//
//  The radio's spectrum and waterfall: about 1 MHz of the FM band around
//  the station, a new line 25 times per second. Tapping a signal tunes to
//  it.
//
//  The waterfall is a bitmap that scrolls down one row per frame. After
//  tuning, its rows are shifted sideways by the frequency change, so the
//  history lines up with the new axis.
//

import SwiftUI
import UIKit

struct SpectrumPanel: View {

    @Environment(ReceiverModel.self) private var model
    @State private var holder = WaterfallHolder()

    var body: some View {
        WaterfallRepresentable(view: holder.view)
            .overlay { overlay }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onAppear {
                let view = holder.view
                model.setSpectrumHandler { [weak view] frame in view?.add(frame) }
            }
            .onDisappear { model.setSpectrumHandler(nil) }
            .accessibilityElement()
            .accessibilityLabel("Spectrum")
            .accessibilityHint("Tap a signal to tune to it.")
    }

    /// Frequency axis, the station's channel, and tap to tune.
    private var overlay: some View {
        let station = Double(model.frequency)
        let span = Double(FMDemodulator.inputRate)
        let low = station + Double(FMDemodulator.tuningOffset) - span / 2
        let playing = model.radioState == .playing

        return GeometryReader { geometry in
            let width = geometry.size.width
            // The axis strip sits between spectrum and waterfall.
            let axisTop = geometry.size.height * WaterfallView.spectrumFraction - WaterfallView.axisHeight
            let spectrumHeight = axisTop
            let x = { (hz: Double) in CGFloat((hz - low) / span) * width }

            ZStack {
                Canvas { context, size in
                    // Grid every 100 kHz, labelled every 200 kHz.
                    let step = 100_000.0
                    var f = (low / step).rounded(.up) * step
                    while f < low + span {
                        var line = Path()
                        line.move(to: CGPoint(x: x(f), y: 0))
                        line.addLine(to: CGPoint(x: x(f), y: spectrumHeight))
                        context.stroke(line, with: .color(.white.opacity(0.08)), lineWidth: 1)
                        // Labels need room for "101.8"; none half off the edge.
                        if Int(f / step) % 2 == 0, x(f) > 22, x(f) < size.width - 22 {
                            context.draw(Text(Format.mhz(UInt32(f)))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.white.opacity(0.55)),
                                         at: CGPoint(x: x(f), y: axisTop + WaterfallView.axisHeight / 2))
                        }
                        f += step
                    }
                    // The station's 200 kHz channel and its centre.
                    let band = CGRect(x: x(station - 100_000), y: 0,
                                      width: x(station + 100_000) - x(station - 100_000),
                                      height: size.height)
                    context.fill(Path(band), with: .color(.accentColor.opacity(0.14)))
                    var center = Path()
                    center.move(to: CGPoint(x: x(station), y: 0))
                    center.addLine(to: CGPoint(x: x(station), y: size.height))
                    context.stroke(center, with: .color(.accentColor), lineWidth: 1.5)
                }

                if !playing {
                    Text("Play to see the spectrum")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard playing else { return }
                let hz = low + Double(location.x / width) * span
                model.tune(to: UInt32(clamping: Int64(hz)))
            }
        }
    }
}

/// Keeps one waterfall view for the life of the panel.
private final class WaterfallHolder {
    lazy var view = WaterfallView()
}

private struct WaterfallRepresentable: UIViewRepresentable {
    let view: WaterfallView
    func makeUIView(context: Context) -> WaterfallView { view }
    func updateUIView(_ view: WaterfallView, context: Context) {}
}

final class WaterfallView: UIView {

    /// Share of the height for the spectrum line and the frequency axis
    /// below it; the waterfall gets the rest.
    static let spectrumFraction: CGFloat = 0.38
    static let axisHeight: CGFloat = 18

    private static let columns = SpectrumAnalyzer.size
    private static let rows = 256                   // about 10 s
    private static let range: Float = 55            // dB from noise to top
    private static let black: UInt32 = 0xFF00_0000

    /// Black → blue → cyan → yellow → red → white, as 0xAARRGGBB.
    private static let palette: [UInt32] = {
        let stops: [(Double, (Double, Double, Double))] = [
            (0.00, (0.00, 0.00, 0.00)),
            (0.15, (0.04, 0.06, 0.24)),
            (0.35, (0.12, 0.31, 0.85)),
            (0.55, (0.13, 0.76, 0.90)),
            (0.75, (0.96, 0.84, 0.23)),
            (0.90, (0.94, 0.35, 0.16)),
            (1.00, (1.00, 1.00, 1.00)),
        ]
        return (0..<256).map { i in
            let t = Double(i) / 255
            let upper = stops.firstIndex { $0.0 >= t } ?? stops.count - 1
            let lower = max(upper - 1, 0)
            let (t0, c0) = stops[lower], (t1, c1) = stops[upper]
            let u = t1 > t0 ? (t - t0) / (t1 - t0) : 0
            func channel(_ a: Double, _ b: Double) -> UInt32 { UInt32(((a + (b - a) * u) * 255).rounded()) }
            return black | channel(c0.0, c1.0) << 16 | channel(c0.1, c1.1) << 8 | channel(c0.2, c1.2)
        }
    }()

    /// The noise floor's colour: the scale starts 5 dB below it. History
    /// shifted in after tuning gets it, so no black patches appear.
    private static let floorColor = palette[Int(5 / range * 255)]

    private let line = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let waterfall = CALayer()
    private let bitmap: CGContext
    private var smoothed: [Float] = []
    private var floor: Float?
    private var lastCenter: UInt32?

    init() {
        bitmap = CGContext(data: nil, width: WaterfallView.columns, height: WaterfallView.rows,
                           bitsPerComponent: 8, bytesPerRow: WaterfallView.columns * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                       | CGBitmapInfo.byteOrder32Little.rawValue)!
        super.init(frame: .zero)
        backgroundColor = .black
        pixels.update(repeating: WaterfallView.black, count: WaterfallView.columns * WaterfallView.rows)

        waterfall.magnificationFilter = .linear
        waterfall.minificationFilter = .linear
        fill.fillColor = UIColor.white.withAlphaComponent(0.12).cgColor
        line.fillColor = nil
        line.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        line.lineWidth = 1
        line.lineJoin = .round
        layer.addSublayer(waterfall)
        layer.addSublayer(fill)
        layer.addSublayer(line)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private var pixels: UnsafeMutablePointer<UInt32> {
        bitmap.data!.assumingMemoryBound(to: UInt32.self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let top = bounds.height * WaterfallView.spectrumFraction
        line.frame = CGRect(x: 0, y: 0, width: bounds.width, height: top - WaterfallView.axisHeight)
        fill.frame = line.frame
        waterfall.frame = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
        CATransaction.commit()
    }

    func add(_ frame: FMReceiver.SpectrumFrame) {
        let columns = WaterfallView.columns
        guard frame.levels.count == columns else { return }

        if let lastCenter, lastCenter != frame.center {
            shift(by: Double(Int64(frame.center) - Int64(lastCenter)) / frame.span * Double(columns))
            smoothed = []
        }
        lastCenter = frame.center

        // Scale from the noise floor: the lower quartile, followed slowly.
        let quartile = frame.levels.sorted()[columns / 4]
        let floor = self.floor.map { $0 + 0.1 * (quartile - $0) } ?? quartile
        self.floor = floor
        let low = floor - 5

        // Scroll down one row and draw the new one at the top.
        let p = pixels
        p.advanced(by: columns).update(from: p, count: columns * (WaterfallView.rows - 1))
        for c in 0..<columns {
            let v = (frame.levels[c] - low) / WaterfallView.range
            p[c] = WaterfallView.palette[Int(min(max(v, 0), 1) * 255)]
        }

        if smoothed.count != columns { smoothed = frame.levels }
        for c in 0..<columns { smoothed[c] += 0.5 * (frame.levels[c] - smoothed[c]) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        waterfall.contents = bitmap.makeImage()
        let (stroke, area) = paths(low: low)
        line.path = stroke
        fill.path = area
        CATransaction.commit()
    }

    private func paths(low: Float) -> (CGPath, CGPath) {
        let width = line.bounds.width, height = line.bounds.height
        let stroke = CGMutablePath()
        for (c, level) in smoothed.enumerated() {
            let v = CGFloat(min(max((level - low) / WaterfallView.range, 0), 1))
            let point = CGPoint(x: CGFloat(c) / CGFloat(smoothed.count - 1) * width,
                                y: height * (1 - v))
            c == 0 ? stroke.move(to: point) : stroke.addLine(to: point)
        }
        let area = stroke.mutableCopy()!
        area.addLine(to: CGPoint(x: width, y: height))
        area.addLine(to: CGPoint(x: 0, y: height))
        area.closeSubpath()
        return (stroke, area)
    }

    /// Moves the history sideways after tuning; positive is to the left.
    private func shift(by columns: Double) {
        let n = WaterfallView.columns
        let s = Int(columns.rounded())
        guard s != 0 else { return }
        for r in 0..<WaterfallView.rows {
            let row = pixels.advanced(by: r * n)
            if abs(s) >= n {
                row.update(repeating: WaterfallView.floorColor, count: n)
            } else if s > 0 {
                row.update(from: row.advanced(by: s), count: n - s)
                row.advanced(by: n - s).update(repeating: WaterfallView.floorColor, count: s)
            } else {
                row.advanced(by: -s).update(from: row, count: n + s)
                row.update(repeating: WaterfallView.floorColor, count: -s)
            }
        }
    }
}
