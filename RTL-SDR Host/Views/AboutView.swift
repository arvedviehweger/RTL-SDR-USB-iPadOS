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
                    Text("RTLBridge")
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
                    DeveloperView()
                } label: {
                    Label("Use RTLBridge in Your App", systemImage: "hammer")
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

/// How other apps can use the receiver: through the rtl_tcp server or directly
/// through the dext's user client (RTL-SDR/include/README.md in the repository).
struct DeveloperView: View {

    private let guideURL = URL(string: "https://github.com/arvedviehweger/RTL-SDR-USB-iPadOS/blob/main/RTL-SDR/include/README.md")!
    private let headerURL = URL(string: "https://github.com/arvedviehweger/RTL-SDR-USB-iPadOS/blob/main/RTL-SDR/include/RTLSDRShared.h")!

    var body: some View {
        Form {
            Section {
                Text("Your own app can use the RTL-SDR through RTLBridge. RTLBridge stays installed and provides the driver; your app does not need to bundle one. The driver has to be enabled under Settings → Apps → RTLBridge.")
            }

            Section {
                Text("Start the rtl_tcp server on the Network tab and connect your app to the address shown there, for example 127.0.0.1 on this iPad. Any rtl_tcp client works, and no special entitlement is needed.")
            } header: {
                Text("Over rtl_tcp")
            }

            Section {
                Text("Open the driver's DriverKit user client (IOUserClient) from your app with IOServiceOpen and IOConnectCall… to tune, set gain and sample rate, and read the raw IQ samples from a shared ring buffer, without the network in between.")
                CodeRow(label: "Service name", value: "RTL_SDR")
                CodeRow(label: "Header", value: "RTLSDRShared.h")
                CodeRow(label: "Entitlement", value: "com.apple.developer.driverkit.communicates-with-drivers")
                Link(destination: guideURL) {
                    Label("Integration Guide", systemImage: "book")
                }
                Link(destination: headerURL) {
                    Label("RTLSDRShared.h on GitHub", systemImage: "doc.plaintext")
                }
            } header: {
                Text("Directly from the Driver")
            } footer: {
                Text("The entitlement has to be requested from Apple. The header is licensed under the Apache License 2.0 and may be used in open and closed source apps. Only one app should stream at a time, so stop the RTLBridge server and radio while your app reads samples.")
            }
        }
        .navigationTitle("For Developers")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A label with a selectable, monospaced value below it.
private struct CodeRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
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
        Component(name: "RTLBridge", license: "Apache License 2.0",
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
                Text("The copyright notices of all components are listed under RTLBridge.")
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
