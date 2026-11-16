//
//  DABReceiver.swift
//  RTL-SDR Host
//
//  Plays a DAB / DAB+ service from the RTL-SDR, and scans Band III for
//  ensembles. Same shape as FMReceiver: device control and decoding share
//  one serial queue, the audio goes through an AudioRing to AudioOutput.
//
//    IQ 2.048 MS/s → OFDMDemodulator → FIC → ensemble
//                                    → MSC subchannel → superframes → AAC
//                                                     → MP2
//                                    → PAD → DLS, slideshow
//
//  DAB+ delivers audio in bursts (a superframe every 120 ms), so the ring
//  holds 400 ms. The RTL-SDR's crystal and the audio clock drift apart;
//  the receiver drops or repeats a single sample now and then to keep the
//  ring near its target, far below anything audible.
//

import Foundation
import Synchronization

nonisolated final class DABReceiver: @unchecked Sendable {

    struct Reception: Equatable, Sendable {
        var channel: String
        var isSynced = false
        var mer = 0.0                   // dB
        var quality = 0.0               // 0 … 1
        var ficErrors = 0.0             // share of FIBs failing their CRC
        var audioErrors = 0.0           // share of AUs / frames lost
        var format: String?
        var bitrate: Int?
        var protection: String?
        var frequencyOffset = 0.0       // Hz
    }

    enum Event: Sendable {
        case started
        case stopped
        case failed(String)
        case ensemble(channel: String, DABEnsemble)
        case reception(Reception)
        case label(String?)
        case slide(PADDecoder.Slide?)
        case scanProgress(channel: Int, of: Int)
        case scanFinished
    }

    /// Called on the main queue.
    var event: (@MainActor (Event) -> Void)?

    private let client: RTLSDRClient
    private let queue = DispatchQueue(label: "com.m0kds.dab", qos: .userInteractive)

    private let ring = AudioRing(frames: 2 * DABAudioDecoder.outputRate,
                                 target: DABAudioDecoder.outputRate * 40 / 100)
    private let pendingGain = Mutex<Int??>(nil)

    // On `queue`.
    private var output: AudioOutput?
    private var running = false
    private var scanning = false
    private var session = 0
    private var channel = 0                     // index into DAB.channels
    private var service: UInt32?
    private var samplesOnChannel = 0
    private var settle = 0                      // IQ samples to skip after tuning

    private let ofdm = OFDMDemodulator()
    private let fic = FICDecoder()
    private var notifiedEnsemble: DABEnsemble?
    private var msc: MSCDecoder?
    private var superframes: SuperframeDecoder?
    private let aac = DABAudioDecoder()
    private let mp2 = MP2Decoder()
    private let pad = PADDecoder()
    private var labelVersion = 0
    private var slideVersion = 0
    private var padShown = false                // a label or slide went out
    private var audio: [Float] = []
    private var fillAverage = 0.0
    private var samplesSinceReport = 0
    private var ficCount = (fibs: 0, errors: 0)
    private var audioCount = (good: 0, bad: 0)

    init(client: RTLSDRClient) {
        self.client = client
        mp2.onFrame = { [unowned self] frame in
            pad.processMP2(frame)
            audioCount.good += 1
        }
    }

    // MARK: - Control

    /// `gain` in tenths of a dB, nil for automatic. `service` may be nil to
    /// just receive the ensemble.
    func start(channel: Int, service: UInt32?, gain: Int?) {
        queue.async { self.doStart(channel: channel, service: service, gain: gain, scan: false) }
    }

    /// Runs through Band III, reporting each ensemble, then stops.
    func scan(gain: Int?) {
        queue.async { self.doStart(channel: 0, service: nil, gain: gain, scan: true) }
    }

    func stop() {
        queue.async { self.doStop() }
    }

    /// Plays another service; retunes if it is on another channel.
    func select(channel: Int, service: UInt32) {
        queue.async {
            guard self.running, !self.scanning else { return }
            if channel != self.channel {
                self.retune(channel)
            }
            self.service = service
            self.closeService()
        }
    }

    func setGain(_ gain: Int?) {
        pendingGain.withLock { $0 = .some(gain) }
        queue.async {
            guard self.running, let gain = self.pendingGain.withLock({ v -> Int?? in
                defer { v = nil }
                return v
            }) else { return }
            self.applyGain(gain)
        }
    }

    private func notify(_ e: Event) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.event?(e) }
        }
    }

    // MARK: - On the queue

    private func doStart(channel: Int, service: UInt32?, gain: Int?, scan: Bool) {
        guard !running, DAB.channels.indices.contains(channel) else { return }
        guard client.open() else {
            notify(.failed("The receiver is not available. Is the RTL-SDR plugged in?"))
            return
        }
        guard client.mapRing() else {
            client.close()
            notify(.failed("Could not map the receiver's sample buffer."))
            return
        }
        pendingGain.withLock { $0 = nil }
        client.call(kRTLSDRMethodStopStream)
        let setup = [
            client.call(kRTLSDRMethodSetSampleRate, UInt64(DAB.sampleRate)),
            client.call(kRTLSDRMethodSetCenterFreq, UInt64(DAB.channels[channel].frequency)),
            applyGain(gain),
            client.call(kRTLSDRMethodResetBuffer),
        ]
        guard setup.allSatisfy({ $0 == 0 }) else {
            client.close()
            notify(.failed("The receiver did not accept the radio settings."))
            return
        }
        client.resetRingCounters()
        client.beginConsuming()
        let start = client.callWithResult(kRTLSDRMethodStartStream)
        guard start.kr == 0, start.result == 0 else {
            client.call(kRTLSDRMethodStopStream)
            client.close()
            notify(.failed("The receiver did not start streaming."))
            return
        }
        if !scan {
            ring.reset()
            let output = self.output ?? AudioOutput(ring: ring)
            self.output = output
            do {
                try output.start()
            } catch {
                client.call(kRTLSDRMethodStopStream)
                client.close()
                notify(.failed("The audio output could not start: \(error.localizedDescription)"))
                return
            }
        }

        running = true
        scanning = scan
        session += 1
        self.channel = channel
        self.service = service
        resetSignal()
        fillAverage = Double(ring.target)
        notify(.started)
        if scan { notify(.scanProgress(channel: 0, of: DAB.channels.count)) }
        pump(session)
    }

    private func doStop() {
        if running {
            running = false
            output?.stop()
            client.call(kRTLSDRMethodStopStream)
            client.close()
            if scanning { notify(.scanFinished) }
            scanning = false
        }
        closeService()
        notify(.stopped)
    }

    private func retune(_ channel: Int) {
        self.channel = channel
        client.call(kRTLSDRMethodSetCenterFreq, UInt64(DAB.channels[channel].frequency))
        client.drainPendingIQ()
        resetSignal()
    }

    /// Everything that belongs to the signal on one channel.
    private func resetSignal() {
        ofdm.reset()
        fic.reset()
        notifiedEnsemble = nil
        samplesOnChannel = 0
        settle = DAB.sampleRate / 20                // 50 ms for the tuner
        ficCount = (0, 0)
        closeService()
    }

    /// Drops the service's decoders; the pump sets them up again once the
    /// FIC says where the service is.
    private func closeService() {
        msc = nil
        superframes = nil
        aac.reset()
        mp2.reset()
        pad.reset()
        audioCount = (0, 0)
        if padShown {
            notify(.label(nil))
            notify(.slide(nil))
            padShown = false
        }
        labelVersion = pad.labelVersion
        slideVersion = pad.slideVersion
    }

    @discardableResult
    private func applyGain(_ gain: Int?) -> Int32 {
        guard let gain else { return client.call(kRTLSDRMethodSetTunerGainMode, 0) }
        return client.call(kRTLSDRMethodSetTunerGain, UInt64(UInt32(bitPattern: Int32(gain))))
    }

    private func pump(_ id: Int) {
        guard running, id == session else { return }
        guard let iq = client.readIQ(), !iq.isEmpty else {
            queue.asyncAfter(deadline: .now() + 0.005) { self.pump(id) }
            return
        }
        var bytes = iq
        if settle > 0 {
            let skip = min(settle, bytes.count / 2)
            settle -= skip
            bytes = bytes.dropFirst(2 * skip)
        }
        samplesOnChannel += bytes.count / 2
        let frames = bytes.withUnsafeBytes { ofdm.process($0) }
        for frame in frames {
            handle(frame)
        }
        if scanning {
            advanceScan()
        } else {
            samplesSinceReport += bytes.count / 2
            if samplesSinceReport >= DAB.sampleRate / 3 {
                samplesSinceReport = 0
                report()
            }
        }
        queue.async { self.pump(id) }
    }

    private func handle(_ frame: OFDMDemodulator.Frame) {
        let before = (fic.fibs, fic.fibErrors)
        fic.process(frame.fic)
        ficCount.fibs += fic.fibs - before.0
        ficCount.errors += fic.fibErrors - before.1

        let ensemble = fic.ensemble
        if ensemble != notifiedEnsemble, ensemble.label != nil {
            notifiedEnsemble = ensemble
            notify(.ensemble(channel: DAB.channels[channel].name, ensemble))
        }
        guard !scanning else { return }
        openServiceIfReady(ensemble)
        guard let msc else { return }

        audio.removeAll(keepingCapacity: true)
        for cif in msc.process(frame.msc) {
            if let superframes {
                for au in superframes.process(cif) {
                    if let au {
                        pad.processAU(au)
                        audioCount.good += 1
                    } else {
                        audioCount.bad += 1
                    }
                    if let format = superframes.format { aac.decode(au, format: format, into: &audio) }
                }
            } else {
                mp2.process(cif, into: &audio)
            }
        }
        if pad.labelVersion != labelVersion {
            labelVersion = pad.labelVersion
            padShown = true
            notify(.label(pad.label))
        }
        if pad.slideVersion != slideVersion {
            slideVersion = pad.slideVersion
            padShown = true
            notify(.slide(pad.slide))
        }
        write(audio)
    }

    private func openServiceIfReady(_ ensemble: DABEnsemble) {
        guard let service, let component = ensemble.services[service]?.audio,
              let subchannel = ensemble.subchannels[component.subchannel] else { return }
        if let msc, msc.subchannel == subchannel { return }
        closeService()
        msc = MSCDecoder(subchannel: subchannel)
        superframes = component.isDABPlus ? SuperframeDecoder(bitrate: subchannel.bitrate) : nil
    }

    /// Into the ring, a sample dropped or repeated when it drifts away from
    /// its target.
    private func write(_ samples: [Float]) {
        guard samples.count >= 4 else { return }
        var samples = samples
        let target = Double(ring.target)
        if fillAverage > target * 1.25 {
            samples.removeLast(2)
        } else if fillAverage < target * 0.75, ring.fill > 0 {
            samples.append(contentsOf: samples.suffix(2))
        }
        samples.withUnsafeBufferPointer { ring.write($0) }
        fillAverage += 0.05 * (Double(ring.fill) - fillAverage)
    }

    private func report() {
        var r = Reception(channel: DAB.channels[channel].name)
        r.isSynced = ofdm.isSynced
        r.mer = ofdm.isSynced ? ofdm.mer : 0
        // Audio needs about 5 dB MER; 15 dB and more is perfect.
        r.quality = ofdm.isSynced ? min(max((ofdm.mer - 4) / 12, 0), 1) : 0
        r.ficErrors = ficCount.fibs > 0 ? Double(ficCount.errors) / Double(ficCount.fibs) : 0
        let au = audioCount.good + audioCount.bad
        r.audioErrors = au > 0 ? Double(audioCount.bad) / Double(au) : 0
        r.frequencyOffset = ofdm.frequencyOffset
        if let msc {
            r.bitrate = msc.subchannel.bitrate
            r.protection = msc.subchannel.protectionName
            if let superframes {
                r.format = superframes.format?.description
            } else if mp2.sampleRate > 0 || audioCount.good > 0 {
                r.format = "MPEG Layer II"
            }
        }
        ficCount = (0, 0)
        audioCount = (0, 0)
        notify(.reception(r))
    }

    // MARK: - Scan

    /// 1 s on a channel without a DAB signal, up to 4 s to read an
    /// ensemble's services.
    private func advanceScan() {
        let synced = ofdm.isSynced
        let complete = fic.ensemble.isComplete
        let limit = synced ? 4 * DAB.sampleRate : DAB.sampleRate
        guard complete || samplesOnChannel >= limit else { return }
        let next = channel + 1
        guard next < DAB.channels.count else {
            doStop()
            return
        }
        notify(.scanProgress(channel: next, of: DAB.channels.count))
        retune(next)
    }
}
