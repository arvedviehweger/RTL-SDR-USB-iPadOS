//
//  DABView.swift
//  RTL-SDR Host
//
//  The DAB+ radio: the service playing with its slideshow and dynamic
//  label, play / pause and previous / next, and the stations found by the
//  Band III scan, grouped by ensemble.
//

import SwiftUI

struct DABPlayer: View {

    @Environment(ReceiverModel.self) private var model

    var body: some View {
        VStack(spacing: 32) {
            DABStationDisplay()
            controls
            if let error = model.radioError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            DABStationList()
        }
    }

    private var controls: some View {
        HStack(spacing: 32) {
            Button("Previous Station", systemImage: "backward.fill") { model.switchFavorite(forward: false) }
                .modifier(StepButtonStyle())
                .disabled(model.dabStations.count < 2 || model.dabScan != nil)

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
            .disabled(model.radioState == .starting || model.dabScan != nil || model.dabStation == nil)
            .accessibilityLabel(model.radioState == .playing ? "Pause" : "Play")
            .keyboardShortcut(.space, modifiers: [])

            Button("Next Station", systemImage: "forward.fill") { model.switchFavorite(forward: true) }
                .modifier(StepButtonStyle())
                .disabled(model.dabStations.count < 2 || model.dabScan != nil)
        }
    }
}

/// Slideshow picture, service and ensemble, reception and dynamic label.
private struct DABStationDisplay: View {

    @Environment(ReceiverModel.self) private var model
    @State private var showsDetails = false

    var body: some View {
        VStack(spacing: 12) {
            slide
            Text(model.dabStation?.label ?? " ")
                .font(.title.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(ensembleLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

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
                DABReceptionDetails()
                    .presentationCompactAdaptation(.popover)
            }

            Text(model.dabLabel ?? " ")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3, reservesSpace: true)
                .animation(.default, value: model.dabLabel)
        }
    }

    /// 4:3 like DAB slideshows; the radio symbol until a picture arrives.
    private var slide: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.quaternary)
            .aspectRatio(4 / 3, contentMode: .fit)
            .frame(maxWidth: 320)
            .overlay {
                if let image = model.dabSlide {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .transition(.opacity)
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 64, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .animation(.default, value: model.dabSlide)
            .accessibilityHidden(model.dabSlide == nil)
            .accessibilityLabel("Station picture")
    }

    private var ensembleLine: String {
        guard let station = model.dabStation else { return " " }
        return [station.ensemble, String(localized: "Channel \(station.channel)")]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var playing: Bool { model.radioState == .playing }

    private var status: LocalizedStringKey {
        switch model.radioState {
        case .stopped:
            return "Paused"
        case .starting:
            return "Tuning …"
        case .playing:
            guard let reception = model.dabReception else { return "Tuning …" }
            if !reception.isSynced { return "No signal" }
            if let format = reception.format { return "DAB+ · \(format)" }
            return "Searching for the station …"
        }
    }
}

/// Signal quality, error rates and the audio format, plus the gain.
private struct DABReceptionDetails: View {

    @Environment(ReceiverModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let r = model.dabReception
        VStack(alignment: .leading, spacing: 12) {
            Text("Reception")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                row("Channel", r?.channel ?? "–")
                row("Signal quality (MER)", r.map { "\(Int($0.mer.rounded())) dB" } ?? "–")
                row("FIC errors", r.map { percent($0.ficErrors) } ?? "–")
                row("Audio errors", r.map { percent($0.audioErrors) } ?? "–")
                row("Audio", r?.format ?? "–")
                row("Bit rate", r?.bitrate.map { "\($0) kbit/s" } ?? "–")
                row("Protection", r?.protection ?? "–")
                row("Frequency offset", r.map { "\(Int($0.frequencyOffset.rounded())) Hz" } ?? "–")
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

            Text("Audio needs about 5 dB; from 15 dB on reception is perfect. Audio errors are lost frames, heard as short gaps.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 360)
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
        }
    }

    private func percent(_ v: Double) -> String {
        v.formatted(.percent.precision(.fractionLength(0...1)))
    }
}

/// The stations of the last scan, grouped by ensemble, and the scan itself.
private struct DABStationList: View {

    @Environment(ReceiverModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Stations")
                    .font(.title3.weight(.semibold))
                Spacer()
                if let scan = model.dabScan {
                    Button("Stop", role: .cancel) { model.cancelScan() }
                        .buttonStyle(.bordered)
                    ProgressView(value: Double(scan.channel), total: Double(scan.total))
                        .frame(width: 80)
                        .accessibilityLabel("Searching")
                } else {
                    Button("Search", systemImage: "arrow.clockwise") { model.scanDAB() }
                        .buttonStyle(.bordered)
                        .disabled(model.activity != .idle && model.activity != .radio)
                }
            }

            if let scan = model.dabScan {
                Text("Searching channel \(DAB.channels[min(scan.channel, scan.total - 1)].name) …")
                    .foregroundStyle(.secondary)
            } else if model.dabStations.isEmpty {
                Text("No stations yet. Search Band III for DAB+ ensembles; it takes about a minute.")
                    .foregroundStyle(.secondary)
            }

            ForEach(ensembles, id: \.self) { ensemble in
                VStack(alignment: .leading, spacing: 8) {
                    Text(ensemble)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                        ForEach(stations(in: ensemble)) { station in
                            Button {
                                model.selectDAB(station)
                            } label: {
                                HStack(spacing: 4) {
                                    if model.dabFavorites.contains(station.id) {
                                        Image(systemName: "star.fill")
                                            .font(.caption)
                                            .accessibilityLabel("Favorite")
                                    }
                                    Text(station.label)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, minHeight: 36)
                            }
                            .buttonStyle(.bordered)
                            .tint(station.id == model.dabStation?.id ? Color.accentColor : Color.secondary)
                            .disabled(model.dabScan != nil)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Ensemble · 5C", in channel order.
    private var ensembles: [String] {
        var seen: [String] = []
        let ordered = model.dabStations.sorted { ($0.channelIndex ?? 0) < ($1.channelIndex ?? 0) }
        for s in ordered where !seen.contains(title(s)) { seen.append(title(s)) }
        return seen
    }

    private func stations(in ensemble: String) -> [ReceiverModel.DABStation] {
        model.dabStations.filter { title($0) == ensemble }
    }

    private func title(_ s: ReceiverModel.DABStation) -> String {
        "\(s.ensemble ?? String(localized: "Ensemble")) · \(s.channel)"
    }
}
