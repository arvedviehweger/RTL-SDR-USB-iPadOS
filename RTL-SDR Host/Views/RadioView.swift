//
//  RadioView.swift
//  RTL-SDR Host
//
//  The FM radio: frequency, tuning scale, play / pause and favorites.
//

import AVKit
import SwiftUI

struct RadioView: View {

    @Environment(ReceiverModel.self) private var model

    var body: some View {
        Group {
            if model.activity == .server {
                ContentUnavailableView {
                    Label("Receiver in Use", systemImage: "network")
                } description: {
                    Text("The network server is using the RTL-SDR. Turn it off to listen to the radio.")
                } actions: {
                    Button("Turn Off Server") { model.stopServer() }
                        .buttonStyle(.borderedProminent)
                }
            } else if model.activity == .test {
                ContentUnavailableView {
                    Label("Testing Connection", systemImage: "stethoscope")
                } description: {
                    Text("The radio is available again when the test has finished.")
                }
            } else if !model.isDevicePresent && model.radioState == .stopped {
                NoReceiverView()
            } else {
                player
            }
        }
        .navigationTitle("Radio")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(model.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                       systemImage: model.isFavorite ? "star.fill" : "star") {
                    model.toggleFavorite()
                }
                RoutePicker()
                    .frame(width: 32, height: 32)
                OptionsMenu()
            }
        }
    }

    private var player: some View {
        ScrollView {
            VStack(spacing: 36) {
                StationDisplay()
                TuningScale(frequency: model.frequency,
                            onTune: { model.tune(to: $0) },
                            onStep: { model.step(by: $0) })
                controls
                if let error = model.radioError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                FavoritesSection()
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
    }

    private var controls: some View {
        HStack(spacing: 32) {
            Button("Tune Down", systemImage: "chevron.backward") { model.step(by: -1) }
                .buttonRepeatBehavior(.enabled)
                .modifier(StepButtonStyle())

            Button {
                model.toggleRadio()
            } label: {
                Group {
                    if model.radioState == .starting {
                        ProgressView()
                    } else {
                        Image(systemName: model.radioState == .playing ? "pause.fill" : "play.fill")
                    }
                }
                .font(.system(size: 34, weight: .semibold))
                .frame(width: 72, height: 72)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(model.radioState == .starting)
            .accessibilityLabel(model.radioState == .playing ? "Pause" : "Play")
            .keyboardShortcut(.space, modifiers: [])

            Button("Tune Up", systemImage: "chevron.forward") { model.step(by: 1) }
                .buttonRepeatBehavior(.enabled)
                .modifier(StepButtonStyle())
        }
    }
}

private struct StepButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .labelStyle(.iconOnly)
            .font(.title2.weight(.semibold))
            .frame(width: 32, height: 32)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
    }
}

/// Station name, frequency in large digits, reception and radio text.
private struct StationDisplay: View {

    @Environment(ReceiverModel.self) private var model
    @State private var showsDetails = false

    var body: some View {
        VStack(spacing: 12) {
            // Lines keep their height while empty, so nothing jumps when RDS
            // arrives.
            Text(model.displayName ?? " ")
                .font(.title.weight(.semibold))
                .foregroundStyle(model.stationName == nil ? .secondary : .primary)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(.default, value: model.displayName)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Format.mhz(model.frequency))
                    .font(.system(size: 96, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(model.frequency)))
                    .animation(.snappy, value: model.frequency)
                Text("MHz")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Format.station(model.frequency))

            Button {
                showsDetails.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "cellularbars", variableValue: playing ? model.signalQuality : 0)
                        .foregroundStyle(playing ? .primary : .tertiary)
                        .accessibilityLabel("Reception")
                        .accessibilityValue(model.signalQuality.formatted(.percent.precision(.fractionLength(0))))
                        .accessibilityHidden(!playing)
                    Text(status)
                        .foregroundStyle(.secondary)
                }
                .font(.headline)
            }
            .buttonStyle(.plain)
            .disabled(!playing)
            .accessibilityHint("Shows reception details")
            .popover(isPresented: $showsDetails) {
                ReceptionDetails()
                    .presentationCompactAdaptation(.popover)
            }

            Text(model.radioText ?? " ")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
                .animation(.default, value: model.radioText)
        }
    }

    private var playing: Bool { model.radioState == .playing }

    private var status: LocalizedStringKey {
        switch model.radioState {
        case .stopped:  return "Paused"
        case .starting: return "Tuning …"
        case .playing:  return model.isStereo ? "FM · Stereo" : "FM · Mono"
        }
    }
}

/// What the reception indicator is based on: the estimated
/// carrier-to-noise ratio, the stereo pilot and RDS.
private struct ReceptionDetails: View {

    @Environment(ReceiverModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let reception = model.reception
        VStack(alignment: .leading, spacing: 12) {
            Text("Reception")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    Text("Signal-to-noise ratio")
                        .foregroundStyle(.secondary)
                    Text(reception.map { "\(Int($0.cnr.rounded())) dB" } ?? "–")
                        .monospacedDigit()
                }
                GridRow {
                    Text("Stereo pilot")
                        .foregroundStyle(.secondary)
                    Text(reception?.pilotDetected == true ? "Detected" : "Not detected")
                }
                GridRow {
                    Text("RDS")
                        .foregroundStyle(.secondary)
                    Text(reception?.rdsReceiving == true ? "Receiving" : "Not received")
                }
                GridRow {
                    Text("Input level")
                        .foregroundStyle(.secondary)
                    if let reception, reception.isOverloaded {
                        Label("Overloaded", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text(reception.map { "\(Int($0.inputLevel.rounded())) dBFS" } ?? "–")
                            .monospacedDigit()
                    }
                }
            }

            Divider()

            Picker("Gain", selection: $model.automaticGain) {
                Text("Automatic Gain").tag(true)
                Text("Manual Gain").tag(false)
            }
            .pickerStyle(.segmented)
            if !model.automaticGain {
                HStack {
                    Slider(value: $model.manualGain, in: 0...50, step: 1) {
                        Text("Gain")
                    }
                    Text("\(Int(model.manualGain)) dB")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
            }

            Text("Full stereo needs about 28 dB; below that the audio blends to mono, fully at 18 dB. If the input overloads, lower the gain; a weak station may need more.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 360)
    }
}

/// A horizontal scale with a tick per channel. Dragging it tunes, like the
/// dial of a radio.
private struct TuningScale: View {

    let frequency: UInt32
    let onTune: (UInt32) -> Void
    let onStep: (Int) -> Void

    @State private var dragStart: UInt32?

    /// Points per 100 kHz channel.
    private let spacing: CGFloat = 12

    var body: some View {
        let band = ReceiverModel.band
        let step = ReceiverModel.channelStep
        let center = Int(frequency / step)
        let spacing = self.spacing

        Canvas { context, size in
            let mid = size.width / 2
            let visible = Int(size.width / spacing / 2) + 1
            for k in -visible...visible {
                let channel = center + k
                guard channel >= 0, band.contains(UInt32(channel) * step) else { continue }
                let x = mid + CGFloat(k) * spacing
                let major = channel % 10 == 0           // whole MHz
                let medium = channel % 5 == 0
                let height: CGFloat = major ? 26 : medium ? 18 : 10
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: 0))
                tick.addLine(to: CGPoint(x: x, y: height))
                context.stroke(tick, with: .style(.secondary), lineWidth: major ? 2 : 1)
                if major {
                    context.draw(Text("\(channel / 10)").font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary),
                                 at: CGPoint(x: x, y: height + 12))
                }
            }
            var needle = Path()
            needle.move(to: CGPoint(x: mid, y: 0))
            needle.addLine(to: CGPoint(x: mid, y: size.height))
            context.stroke(needle, with: .style(.tint), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        .frame(height: 56)
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .black, location: 0.2),
                                   .init(color: .black, location: 0.8),
                                   .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let start = dragStart ?? frequency
                    if dragStart == nil { dragStart = start }
                    let channels = Int((-value.translation.width / spacing).rounded())
                    onTune(UInt32(clamping: Int64(start) + Int64(channels) * Int64(step)))
                }
                .onEnded { _ in dragStart = nil }
        )
        .sensoryFeedback(.selection, trigger: frequency)
        .accessibilityElement()
        .accessibilityLabel("Tuning")
        .accessibilityValue(Format.station(frequency))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onStep(1)
            case .decrement: onStep(-1)
            @unknown default: break
            }
        }
    }
}

private struct FavoritesSection: View {

    @Environment(ReceiverModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Favorites")
                .font(.title3.weight(.semibold))
            if model.favorites.isEmpty {
                Text("Tap the star to save the current station.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                    ForEach(model.favorites, id: \.self) { f in
                        Button {
                            model.tune(to: f)
                        } label: {
                            VStack(spacing: 2) {
                                Text(model.stationNames[f] ?? Format.station(f))
                                    .lineLimit(1)
                                if model.stationNames[f] != nil {
                                    Text(Format.station(f))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                        .tint(f == model.frequency ? Color.accentColor : Color.secondary)
                        .contextMenu {
                            Button("Remove from Favorites", systemImage: "star.slash", role: .destructive) {
                                model.removeFavorite(f)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OptionsMenu: View {

    @Environment(ReceiverModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu("Options", systemImage: "ellipsis") {
            Toggle("Stereo", systemImage: "headphones", isOn: $model.stereoEnabled)
            Picker("De-emphasis", selection: $model.deemphasis) {
                Text("50 µs · Europe, Asia, Africa").tag(ReceiverModel.Deemphasis.europe)
                Text("75 µs · Americas, South Korea").tag(ReceiverModel.Deemphasis.americas)
            }
            .pickerStyle(.inline)
        }
    }
}

/// The system's AirPlay and Bluetooth output picker.
private struct RoutePicker: UIViewRepresentable {

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        // Like the toolbar's other buttons; tinted only while routing.
        view.tintColor = .label
        view.activeTintColor = .tintColor
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
