//
//  ReceiverModel.swift
//  RTL-SDR Host
//
//  The app's state around the one RTL-SDR: whether it is plugged in, and
//  which feature is using it. The rtl_tcp server and the connection test
//  share the same user client, so only one of them runs at a time.
//

import Foundation
import Observation
import UIKit

struct LogLine: Identifiable {
    let id: Int
    let text: String
}

@Observable
final class ReceiverModel {

    enum Activity { case idle, server, test }
    enum ServerState { case stopped, starting, running }

    /// What the rtl_tcp client is connected from and has tuned to.
    struct ServerClient {
        var address: String
        var frequency: UInt32?
        var sampleRate: UInt32?
    }

    let port: UInt16 = 1234

    // Device
    private(set) var isDevicePresent = RTLSDRClient.isServicePresent
    private(set) var receiver: ReceiverSummary?
    private(set) var activity: Activity = .idle

    // rtl_tcp server
    private(set) var serverState: ServerState = .stopped
    private(set) var serverError: String?
    private(set) var serverClient: ServerClient?
    private(set) var addresses: [String] = []
    private(set) var serverLog: [LogLine] = []

    // Connection test
    private(set) var testSteps: [TestStep] = []
    private(set) var testLog: [LogLine] = []

    @ObservationIgnored private let client = RTLSDRClient()
    @ObservationIgnored private lazy var server = RTLTCPServer(client: client)
    @ObservationIgnored private let keeper = BackgroundAudioKeeper()

    // The rtl_tcp server logs every client command, and clients with their
    // own AGC send several per second. Keep the log bounded and publish it
    // at most every 100 ms so the UI does not compete with the SDR client
    // for CPU.
    @ObservationIgnored private let maxLogLines = 500
    @ObservationIgnored private var pendingLog: [LogLine] = []
    @ObservationIgnored private var logFlushPending = false
    @ObservationIgnored private var nextLogID = 0

    init() {
        server.log = { [weak self] line in self?.appendServerLog(line) }
        server.event = { [weak self] event in self?.handle(event) }

        // Plugging in or unplugging the RTL-SDR updates the state right away.
        rtlsdrhost_watch_service { [weak self] in
            MainActor.assumeIsolated { self?.serviceChanged() }
        }
        refreshDevice()
    }

    // MARK: - Device

    /// Re-reads whether the RTL-SDR is there, e.g. coming back from Settings
    /// where the driver may have been switched on.
    func refreshDevice() {
        isDevicePresent = RTLSDRClient.isServicePresent
        guard isDevicePresent else {
            receiver = nil
            return
        }
        // The server and the test hold the user client; ask only when idle.
        guard activity == .idle, receiver == nil else { return }
        let probe = RTLSDRClient()
        guard probe.open() else { return }
        receiver = probe.summary()
        probe.close()
    }

    /// The RTL_SDR service appeared or went away. Checks once more a moment
    /// later, in case a service that is shutting down is still listed.
    private func serviceChanged() {
        receiver = nil
        refreshDevice()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshDevice()
        }
    }

    // MARK: - rtl_tcp server

    func startServer() {
        guard activity == .idle else { return }
        activity = .server
        serverState = .starting
        serverError = nil
        serverClient = nil
        appendServerLog("")
        appendServerLog("──────── rtl_tcp server ────────")
        server.start(port: port)
    }

    func stopServer() {
        guard activity == .server else { return }
        server.stop()
    }

    private func handle(_ event: RTLTCPServer.Event) {
        switch event {
        case .started:
            serverState = .running
            addresses = RTLTCPServer.localIPAddresses()
            // Keep the app - and therefore the rtl_tcp server - alive:
            //  • audio background mode survives switching to another app,
            //  • disabling the idle timer keeps the screen from locking.
            keeper.start()
            UIApplication.shared.isIdleTimerDisabled = true
        case .stopped, .failed:
            if case .failed(let message) = event { serverError = message }
            serverState = .stopped
            serverClient = nil
            if activity == .server { activity = .idle }
            keeper.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            refreshDevice()
        case .clientConnected(let address):
            serverClient = ServerClient(address: address)
        case .clientDisconnected:
            serverClient = nil
        case .frequency(let hz):
            serverClient?.frequency = hz
        case .sampleRate(let hz):
            serverClient?.sampleRate = hz
        }
    }

    func clearServerLog() {
        pendingLog.removeAll()
        serverLog.removeAll()
    }

    private func appendServerLog(_ text: String) {
        pendingLog.append(LogLine(id: nextLogID, text: text))
        nextLogID += 1
        guard !logFlushPending else { return }
        logFlushPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.flushServerLog()
        }
    }

    private func flushServerLog() {
        logFlushPending = false
        var lines = serverLog
        lines.append(contentsOf: pendingLog)
        pendingLog.removeAll()
        if lines.count > maxLogLines {
            lines.removeFirst(lines.count - maxLogLines)
        }
        serverLog = lines
    }

    // MARK: - Connection test

    func runTest() {
        guard activity == .idle else { return }
        activity = .test
        testSteps = []
        testLog = []

        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            client.runConnectionTest(log: { line in
                DispatchQueue.main.async { self?.appendTestLog(line) }
            }, step: { step in
                DispatchQueue.main.async { self?.testSteps.append(step) }
            })
            DispatchQueue.main.async {
                guard let self else { return }
                self.activity = .idle
                self.receiver = nil
                self.refreshDevice()
            }
        }
    }

    private func appendTestLog(_ text: String) {
        testLog.append(LogLine(id: nextLogID, text: text))
        nextLogID += 1
    }
}
