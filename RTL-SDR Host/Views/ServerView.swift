//
//  ServerView.swift
//  RTL-SDR Host
//
//  The rtl_tcp server: on/off, the addresses to connect to and the client.
//

import SwiftUI

struct ServerView: View {

    @Environment(ReceiverModel.self) private var model

    var body: some View {
        Group {
            if !model.isDevicePresent && model.serverState == .stopped {
                NoReceiverView()
            } else {
                form
            }
        }
        .navigationTitle("Network Server")
    }

    private var form: some View {
        Form {
            Section {
                ReceiverRow()
            }

            Section {
                Toggle(isOn: serverBinding) {
                    HStack {
                        Text("rtl_tcp Server")
                        if model.serverState == .starting {
                            ProgressView().padding(.leading, 4)
                        }
                    }
                }
                .disabled(model.activity == .test || model.serverState == .starting)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if let error = model.serverError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    if model.activity == .test {
                        Text("The connection test is using the receiver.")
                    }
                    Text("Shares the receiver with SDR apps such as SDR++, GQRX or SDRangel, on this iPad or on other devices in your network. The server keeps running when you switch to another app.")
                }
            }

            if model.serverState == .running {
                Section {
                    ForEach(model.addresses, id: \.self) { ip in
                        AddressRow(label: "Network", address: "\(ip):\(model.port)")
                    }
                    AddressRow(label: "This iPad", address: "127.0.0.1:\(model.port)")
                } header: {
                    Text("Connect To")
                } footer: {
                    Text("In your SDR app, add an rtl_tcp source with one of these addresses.")
                }

                Section("Client") {
                    if let client = model.serverClient {
                        LabeledContent("Address", value: client.address)
                        LabeledContent("Frequency",
                                       value: client.frequency.map { Format.frequency($0) } ?? "–")
                        LabeledContent("Sample Rate",
                                       value: client.sampleRate.map { Format.sampleRate($0) } ?? "–")
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Waiting for a client …")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                NavigationLink {
                    LogView(title: "Activity", lines: model.serverLog,
                            clear: model.clearServerLog)
                } label: {
                    Label("Activity", systemImage: "list.bullet.rectangle")
                }
            }
        }
    }

    private var serverBinding: Binding<Bool> {
        Binding(
            get: { model.serverState != .stopped },
            set: { on in on ? model.startServer() : model.stopServer() }
        )
    }
}

/// An address to type into an SDR app, with a button to copy it.
private struct AddressRow: View {

    let label: LocalizedStringKey
    let address: String

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 12) {
                Text(address)
                    .monospacedDigit()
                    .textSelection(.enabled)
                Button("Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = address
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        }
    }
}
