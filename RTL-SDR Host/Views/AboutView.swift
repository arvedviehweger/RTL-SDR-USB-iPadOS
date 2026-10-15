//
//  AboutView.swift
//  RTL-SDR Host
//
//  Version, source code and the licenses of everything the app ships.
//  The license texts are the repository's own files, copied into the app
//  bundle's Licenses folder by the "Copy Licenses" build phases.
//

import SwiftUI

struct AboutView: View {

    private let sourceURL = URL(string: "https://github.com/arvedviehweger/RTL-SDR-USB-iPadOS")!

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("RTL-SDR Radio")
                        .font(.title2.bold())
                    Text("Version \(RTLSDRClient.appVersion)")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                Link(destination: sourceURL) {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                NavigationLink {
                    LicensesView()
                } label: {
                    Label("Licenses", systemImage: "doc.text")
                }
            } footer: {
                Text("A USB driver for RTL2832U-based RTL-SDR receivers on iPad. Not affiliated with Realtek or RTL-SDR Blog.\n\nCopyright 2026 Arved Viehweger. Licensed under the Apache License 2.0.")
            }
        }
        .navigationTitle("About")
    }
}

/// A component the app is built from and the files with its license.
private struct Component: Identifiable {
    let name: String
    let license: String
    let files: [String]         // paths below Licenses/ in the app bundle
    var id: String { name }
}

struct LicensesView: View {

    private let components = [
        Component(name: "RTL-SDR Radio", license: "Apache License 2.0",
                  files: ["NOTICE", "LICENSE"]),
        Component(name: "RTL2832Device from gnuradio4-blocks", license: "MIT License",
                  files: ["gnuradio4-blocks/LICENSE"]),
        Component(name: "webrtlsdr", license: "Apache License 2.0",
                  files: ["LICENSE.webrtlsdr"]),
    ]

    var body: some View {
        List {
            Section {
                ForEach(components) { component in
                    NavigationLink {
                        LicenseTextView(title: component.name,
                                        text: LicensesView.text(of: component.files))
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(component.name)
                            Text(component.license)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("The copyright notices of all components are listed under RTL-SDR Radio.")
            }
        }
        .navigationTitle("Licenses")
    }

    /// The files' contents, one after the other.
    private static func text(of files: [String]) -> String {
        let base = Bundle.main.resourceURL?.appending(path: "Licenses")
        return files
            .compactMap { file in
                base.flatMap { try? String(contentsOf: $0.appending(path: file), encoding: .utf8) }
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n\n\n")
    }
}

private struct LicenseTextView: View {

    let title: String
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
