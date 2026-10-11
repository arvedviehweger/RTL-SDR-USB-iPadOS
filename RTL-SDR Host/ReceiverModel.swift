//
//  ReceiverModel.swift
//  RTL-SDR Host
//
//  The app's state around the one RTL-SDR: whether it is plugged in, and
//  which feature is using it. The radio, the rtl_tcp server and the
//  connection test share the same user client, so only one of them runs at
//  a time.
//

import AVFoundation
import Foundation
import Observation
import UIKit

struct LogLine: Identifiable {
    let id: Int
    let text: String
}

@Observable
final class ReceiverModel {

    enum Activity { case idle, radio, server, test }
    enum ServerState { case stopped, starting, running }
    enum RadioState { case stopped, starting, playing }

    /// FM de-emphasis time constant, which differs by region.
    enum Deemphasis: String, CaseIterable, Identifiable {
        case europe = "50"
        case americas = "75"

        var id: String { rawValue }
        var tau: Double { self == .europe ? 50e-6 : 75e-6 }

        static var forCurrentRegion: Deemphasis {
            let americas: Set<String> = ["US", "CA", "MX", "BR", "AR", "CO", "PE", "VE", "CL",
                                         "EC", "BO", "PY", "UY", "GT", "HN", "SV", "NI", "CR",
                                         "PA", "CU", "DO", "PR", "KR", "TW", "PH"]
            return americas.contains(Locale.current.region?.identifier ?? "") ? .americas : .europe
        }
    }

    /// What the rtl_tcp client is connected from and has tuned to.
    struct ServerClient {
        var address: String
        var frequency: UInt32?
        var sampleRate: UInt32?
    }

    let port: UInt16 = 1234

    /// FM broadcast band in Hz; Japan starts at 76 MHz.
    static let band: ClosedRange<UInt32> =
        Locale.current.region?.identifier == "JP" ? 76_000_000...108_000_000
                                                  : 87_500_000...108_000_000
    static let channelStep: UInt32 = 100_000

    // Device
    private(set) var isDevicePresent = RTLSDRClient.isServicePresent
    private(set) var receiver: ReceiverSummary?
    private(set) var activity: Activity = .idle

    // Radio
    private(set) var radioState: RadioState = .stopped
    private(set) var radioError: String?
    private(set) var frequency: UInt32
    private(set) var favorites: [UInt32]
    private(set) var signalQuality = 0.0
    private(set) var isStereo = false
    var deemphasis: Deemphasis {
        didSet {
            UserDefaults.standard.set(deemphasis.rawValue, forKey: Keys.deemphasis)
            fm.setDeemphasis(deemphasis.tau)
        }
    }
    var stereoEnabled: Bool {
        didSet {
            UserDefaults.standard.set(stereoEnabled, forKey: Keys.stereo)
            fm.setStereo(stereoEnabled)
        }
    }
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
    @ObservationIgnored private lazy var fm = FMReceiver(client: client)
    @ObservationIgnored private let keeper = BackgroundAudioKeeper()
    @ObservationIgnored private let nowPlaying = NowPlaying()
    @ObservationIgnored private var showsNowPlaying = false
    @ObservationIgnored private var resumeAfterInterruption = false

    // The rtl_tcp server logs every client command, and clients with their
    // own AGC send several per second. Keep the log bounded and publish it
    // at most every 100 ms so the UI does not compete with the SDR client
    // for CPU.
    @ObservationIgnored private let maxLogLines = 500
    @ObservationIgnored private var pendingLog: [LogLine] = []
    @ObservationIgnored private var logFlushPending = false
    @ObservationIgnored private var nextLogID = 0

    private enum Keys {
        static let frequency = "radio.frequency"
        static let favorites = "radio.favorites"
        static let deemphasis = "radio.deemphasis"
        static let stereo = "radio.stereo"
    }

    init() {
        let defaults = UserDefaults.standard
        let saved = UInt32(clamping: defaults.integer(forKey: Keys.frequency))
        frequency = ReceiverModel.band.contains(saved) ? saved : 100_000_000
        favorites = (defaults.array(forKey: Keys.favorites) as? [Int] ?? [])
            .map { UInt32(clamping: $0) }
            .filter { ReceiverModel.band.contains($0) }
        deemphasis = defaults.string(forKey: Keys.deemphasis).flatMap(Deemphasis.init)
            ?? .forCurrentRegion
        stereoEnabled = defaults.object(forKey: Keys.stereo) as? Bool ?? true

        server.log = { [weak self] line in self?.appendServerLog(line) }
        server.event = { [weak self] event in self?.handle(event) }
        fm.event = { [weak self] event in self?.handle(event) }
        setUpNowPlaying()
        observeAudioSession()

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
        // The other features hold the user client; ask only when idle.
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
        if !isDevicePresent && activity == .radio {
            radioError = String(localized: "The receiver was disconnected.")
            pauseRadio()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshDevice()
        }
    }

    // MARK: - Radio

    var isFavorite: Bool { favorites.contains(frequency) }

    func playRadio() {
        guard activity == .idle, radioState == .stopped else { return }
        radioError = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            radioError = String(localized: "Audio is not available: \(error.localizedDescription)")
            return
        }
        activity = .radio
        radioState = .starting
        fm.start(frequency: frequency, deemphasis: deemphasis.tau, stereo: stereoEnabled)
        showsNowPlaying = true
        updateNowPlaying()
    }

    func pauseRadio() {
        guard activity == .radio else { return }
        fm.stop()
    }

    func toggleRadio() {
        radioState == .stopped ? playRadio() : pauseRadio()
    }

    /// Rounds to the channel raster and keeps the frequency in the band.
    func tune(to hz: UInt32) {
        let step = ReceiverModel.channelStep
        let rounded = (hz + step / 2) / step * step
        let f = min(max(rounded, ReceiverModel.band.lowerBound), ReceiverModel.band.upperBound)
        guard f != frequency else { return }
        frequency = f
        isStereo = false
        UserDefaults.standard.set(Int(f), forKey: Keys.frequency)
        if activity == .radio { fm.tune(f) }
        updateNowPlaying()
    }

    func step(by channels: Int) {
        let target = Int64(frequency) + Int64(channels) * Int64(ReceiverModel.channelStep)
        tune(to: UInt32(clamping: target))
    }

    func toggleFavorite() {
        if isFavorite {
            removeFavorite(frequency)
        } else {
            favorites.append(frequency)
            favorites.sort()
            saveFavorites()
        }
    }

    func removeFavorite(_ f: UInt32) {
        favorites.removeAll { $0 == f }
        saveFavorites()
    }

    /// The next (or previous) favorite after the current frequency, wrapping
    /// around; used by the Lock Screen's track buttons.
    func switchFavorite(forward: Bool) {
        guard !favorites.isEmpty else { return }
        let current = frequency
        let next = forward ? favorites.first(where: { $0 > current }) ?? favorites.first
                           : favorites.last(where: { $0 < current }) ?? favorites.last
        if let next { tune(to: next) }
    }

    private func saveFavorites() {
        UserDefaults.standard.set(favorites.map(Int.init), forKey: Keys.favorites)
        updateNowPlaying()
    }

    private func handle(_ event: FMReceiver.Event) {
        switch event {
        case .started:
            radioState = .playing
            updateNowPlaying()
        case .stopped, .failed:
            if case .failed(let message) = event { radioError = message }
            radioState = .stopped
            signalQuality = 0
            isStereo = false
                if activity == .radio { activity = .idle }
            updateNowPlaying()
            refreshDevice()
        case .reception(let reception):
            // Reports from before a retune describe the previous station.
            guard reception.frequency == frequency, radioState == .playing else { return }
            signalQuality = reception.quality
            isStereo = reception.isStereo
        }
    }

    private func setUpNowPlaying() {
        nowPlaying.setUp(.init(
            play: { [weak self] in self?.playRadio() },
            pause: { [weak self] in self?.pauseRadio() },
            next: { [weak self] in self?.switchFavorite(forward: true) },
            previous: { [weak self] in self?.switchFavorite(forward: false) }
        ))
    }

    private func updateNowPlaying() {
        guard showsNowPlaying else { return }
        nowPlaying.update(title: Format.station(frequency),
                          subtitle: String(localized: "FM Radio"),
                          playing: radioState == .playing,
                          hasFavorites: !favorites.isEmpty)
    }

    /// Pauses for phone calls, Siri or other apps' audio, and when the
    /// headphones are unplugged.
    private func observeAudioSession() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification,
                           object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated {
                self?.audioInterrupted(type: type, options: options)
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification,
                           object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    self?.pauseRadio()
                }
            }
        }
    }

    private func audioInterrupted(type: UInt?, options: UInt?) {
        switch type.flatMap(AVAudioSession.InterruptionType.init) {
        case .began:
            if activity == .radio {
                resumeAfterInterruption = true
                pauseRadio()
            }
        case .ended:
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options ?? 0)
                .contains(.shouldResume)
            if resumeAfterInterruption && shouldResume { playRadio() }
            resumeAfterInterruption = false
        default:
            break
        }
    }

    // MARK: - rtl_tcp server

    func startServer() {
        guard activity == .idle else { return }
        activity = .server
        serverState = .starting
        serverError = nil
        serverClient = nil
        // The Lock Screen's play button would only find the receiver busy.
        showsNowPlaying = false
        nowPlaying.clear()
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
