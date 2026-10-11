//
//  DiagnosticsView.swift
//  RTL-SDR Host
//
//  The receiver's details and the connection test, which checks the whole
//  chain from the app through the driver to the RTL-SDR's IQ stream.
//

import SwiftUI

struct DiagnosticsView: View {

    @Environment(ReceiverModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                ReceiverRow()
                if let receiver = model.receiver {
                    LabeledContent("Driver Version",
                                   value: receiver.driverVersion.isEmpty ? "Unknown"
                                                                         : receiver.driverVersion)
                }
                LabeledContent("App Version", value: RTLSDRClient.appVersion)
            } header: {
                Text("Receiver")
            } footer: {
                if !model.isDevicePresent {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("If the RTL-SDR is plugged in, turn on its driver in Settings › Apps › RTL-SDR-Host.")
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        }
                        .font(.footnote.weight(.semibold))
                    }
                } else if let receiver = model.receiver, !receiver.driverMatchesApp {
                    Label("The running driver is not the one in this app. Replug the RTL-SDR.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    model.runTest()
                } label: {
                    HStack {
                        Text("Run Connection Test")
                        Spacer()
                        if model.activity == .test { ProgressView() }
                    }
                }
                .disabled(model.activity != .idle)
            } footer: {
                if model.activity == .server {
                    Text("Turn off the network server to run the test.")
                } else if model.activity == .radio {
                    Text("Pause the radio to run the test.")
                } else {
                    Text("Configures the receiver, streams for one second and checks that samples arrive.")
                }
            }

            if !model.testSteps.isEmpty {
                Section("Results") {
                    ForEach(model.testSteps) { step in
                        TestStepRow(step: step)
                    }
                }
            }

            if !model.testLog.isEmpty {
                Section {
                    NavigationLink {
                        LogView(title: "Test Log", lines: model.testLog)
                    } label: {
                        Label("Test Log", systemImage: "list.bullet.rectangle")
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
    }
}

private struct TestStepRow: View {

    let step: TestStep

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                if let detail = step.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch step.result {
        case .passed:  return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed:  return "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch step.result {
        case .passed:  return .green
        case .warning: return .orange
        case .failed:  return .red
        }
    }
}
