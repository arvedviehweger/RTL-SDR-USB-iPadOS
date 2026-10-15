//
//  Components.swift
//  RTL-SDR Host
//
//  Views shared by several screens.
//

import SwiftUI

/// Shown instead of a screen's content while no RTL-SDR is available.
struct NoReceiverView: View {

    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("No Receiver Connected", systemImage: "antenna.radiowaves.left.and.right.slash")
        } description: {
            Text("Plug in an RTL-SDR. If it is already plugged in, turn on its driver in Settings › Apps › RTLBridge.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// The plugged-in receiver and whether it can be used.
struct ReceiverRow: View {

    @Environment(ReceiverModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(model.isDevicePresent ? Color.accentColor : .secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(model.isDevicePresent ? "Connected" : "Not Connected",
                  systemImage: "circle.fill")
                .labelStyle(StatusLabelStyle())
                .foregroundStyle(model.isDevicePresent ? .green : .orange)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        guard let r = model.receiver, !r.name.isEmpty else { return "RTL-SDR" }
        return r.name
    }

    private var subtitle: String {
        guard model.isDevicePresent else { return "Plug in the receiver" }
        return model.receiver?.tuner ?? "RTL2832U"
    }
}

/// A small coloured dot in front of the status text.
private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 8))
            configuration.title
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// A log with the newest line at the bottom, to read, copy and share.
struct LogView: View {

    let title: LocalizedStringKey
    let lines: [LogLine]
    var clear: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.footnote.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
            .padding()
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .overlay {
            if lines.isEmpty {
                ContentUnavailableView("No Entries", systemImage: "text.alignleft")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let clear {
                Button("Clear", systemImage: "trash", action: clear)
                    .disabled(lines.isEmpty)
            }
            ShareLink(item: lines.map(\.text).joined(separator: "\n"))
                .disabled(lines.isEmpty)
        }
    }
}

enum Format {
    /// "100.000 MHz"
    static func frequency(_ hz: UInt32) -> String {
        (Double(hz) / 1e6).formatted(.number.precision(.fractionLength(3))) + " MHz"
    }

    /// "98.4 MHz", a broadcast station.
    static func station(_ hz: UInt32) -> String {
        mhz(hz) + " MHz"
    }

    /// "98.4", the number alone.
    static func mhz(_ hz: UInt32) -> String {
        (Double(hz) / 1e6).formatted(.number.precision(.fractionLength(1)))
    }

    /// Many stations separate title and artist in the radio text with a
    /// run of spaces; that becomes " – " unless a separator is already
    /// there.
    static func radioText(_ text: String) -> String {
        let separators = "-–—/:|·"
        var result = ""
        var spaces = 0
        for ch in text {
            if ch == " " {
                spaces += 1
                continue
            }
            if spaces > 0 {
                let marked = separators.contains(ch) || result.last.map { separators.contains($0) } ?? false
                result += spaces >= 2 && !marked ? " – " : " "
                spaces = 0
            }
            result.append(ch)
        }
        return result
    }

    /// "2.048 MS/s"
    static func sampleRate(_ hz: UInt32) -> String {
        (Double(hz) / 1e6).formatted(.number.precision(.fractionLength(3))) + " MS/s"
    }
}
