//
//  FMReceiver.swift
//  RTL-SDR Host
//
//  Plays an FM broadcast station from the RTL-SDR: configures the receiver,
//  pulls IQ from the shared ring buffer, demodulates it and feeds the stereo
//  audio to an AVAudioEngine. Reports reception quality, stereo and RDS a
//  few times per second.
//
//  The RTL-SDR's crystal and the audio hardware run on different clocks, so
//  the audio buffer between them slowly fills up or drains. The receiver
//  keeps it at about 150 ms by stretching the demodulated signal by up to
//  ±0.1 % (inaudible), see `ratio`.
//
//  Device control and demodulation share one serial queue, like the
//  rtl_tcp server. The audio buffer bridges the few milliseconds a tuning
//  command blocks it.
//

import AVFoundation
import Foundation
import Synchronization

nonisolated final class FMReceiver: @unchecked Sendable {

    struct Reception: Equatable, Sendable {
        var frequency: UInt32           // the station this describes
        var quality = 0.0               // 0 … 1
        var isStereo = false
        var stationName: String?        // RDS PS
        var radioText: String?          // RDS RT
    }

    enum Event: Sendable {
        case started
        case stopped
        case failed(String)             // could not start; not running
        case reception(Reception)       // a few times per second
    }

    /// Called on the main queue.
    var event: (@MainActor (Event) -> Void)?

    private let client: RTLSDRClient
    private let queue = DispatchQueue(label: "com.m0kds.fm", qos: .userInteractive)

    private let ring = AudioRing(frames: FMDemodulator.audioRate,
                                 target: FMDemodulator.audioRate * 15 / 100)
    private let demodulator = FMDemodulator()
    private let pendingFrequency = Mutex<UInt32?>(nil)

    // On `queue`.
    private var output: AudioOutput?        // created on first use
    private var running = false
    private var session = 0                 // tells stale pumps to stop
    private var frequency: UInt32 = 0       // the station being played
    private var audio: [Float] = []         // interleaved left / right
    private var fillAverage = 0.0
    private var muteRemaining = 0           // audio frames to silence
    private var untilReport = 0             // audio frames to the next report

    init(client: RTLSDRClient) {
        self.client = client
    }

    // MARK: - Control

    func start(frequency: UInt32, deemphasis: Double, stereo: Bool) {
        queue.async { self.doStart(frequency: frequency, deemphasis: deemphasis, stereo: stereo) }
    }

    func stop() {
        queue.async { self.doStop() }
    }

    /// Retunes while playing. Calls in quick succession, e.g. while the user
    /// drags the tuning scale, collapse into the latest frequency.
    func tune(_ frequency: UInt32) {
        pendingFrequency.withLock { $0 = frequency }
        queue.async { self.applyPendingFrequency() }
    }

    func setDeemphasis(_ tau: Double) {
        queue.async { self.demodulator.setDeemphasis(tau) }
    }

    func setStereo(_ enabled: Bool) {
        queue.async { self.demodulator.stereoEnabled = enabled }
    }

    private func notify(_ e: Event) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.event?(e) }
        }
    }

    private func fail(_ message: String) {
        notify(.failed(message))
    }

    // MARK: - On the queue

    private func doStart(frequency: UInt32, deemphasis: Double, stereo: Bool) {
        guard !running else { return }

        guard client.open() else {
            fail("The receiver is not available. Is the RTL-SDR plugged in?")
            return
        }
        guard client.mapRing() else {
            client.close()
            fail("Could not map the receiver's sample buffer.")
            return
        }
        pendingFrequency.withLock { $0 = nil }
        client.call(kRTLSDRMethodStopStream)
        let setup = [
            client.call(kRTLSDRMethodSetSampleRate, UInt64(FMDemodulator.inputRate)),
            client.call(kRTLSDRMethodSetCenterFreq, tunerFrequency(frequency)),
            client.call(kRTLSDRMethodSetTunerGainMode, 0),        // automatic
            client.call(kRTLSDRMethodResetBuffer),
        ]
        guard setup.allSatisfy({ $0 == 0 }) else {
            client.close()
            fail("The receiver did not accept the radio settings.")
            return
        }

        demodulator.reset()
        demodulator.setDeemphasis(deemphasis)
        demodulator.stereoEnabled = stereo
        ring.reset()
        client.resetRingCounters()
        client.beginConsuming()
        let start = client.callWithResult(kRTLSDRMethodStartStream)
        guard start.kr == 0, start.result == 0 else {
            client.call(kRTLSDRMethodStopStream)
            client.close()
            fail("The receiver did not start streaming.")
            return
        }
        let output = self.output ?? AudioOutput(ring: ring)
        self.output = output
        do {
            try output.start()
        } catch {
            client.call(kRTLSDRMethodStopStream)
            client.close()
            fail("The audio output could not start: \(error.localizedDescription)")
            return
        }

        running = true
        session += 1
        self.frequency = frequency
        fillAverage = Double(ring.target)
        muteRemaining = 0
        untilReport = 0
        notify(.started)
        pump(session)
    }

    private func doStop() {
        if running {
            running = false
            output?.stop()
            client.call(kRTLSDRMethodStopStream)
            client.close()
        }
        notify(.stopped)
    }

    private func applyPendingFrequency() {
        guard let frequency = pendingFrequency.withLock({ value -> UInt32? in
            defer { value = nil }
            return value
        }) else { return }
        guard running else { return }
        client.call(kRTLSDRMethodSetCenterFreq, tunerFrequency(frequency))
        self.frequency = frequency
        demodulator.stationChanged()
        // Skip the noise while the tuner settles.
        muteRemaining = FMDemodulator.audioRate / 10
        untilReport = 0
    }

    private func tunerFrequency(_ station: UInt32) -> UInt64 {
        UInt64(station) + UInt64(FMDemodulator.tuningOffset)
    }

    /// Ring buffer → demodulator → audio, then again. Bound to one session,
    /// so a retry scheduled before a restart cannot start a second pump.
    private func pump(_ id: Int) {
        guard running, id == session else { return }

        guard let iq = client.readIQ(), !iq.isEmpty else {
            queue.asyncAfter(deadline: .now() + 0.005) { self.pump(id) }
            return
        }

        audio.removeAll(keepingCapacity: true)
        iq.withUnsafeBytes { demodulator.process($0, ratio: ratio, into: &audio) }

        let frames = audio.count / 2
        if muteRemaining > 0 && frames > 0 {
            let n = min(muteRemaining, frames)
            audio.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: 2 * n) }
            muteRemaining -= n
        }
        audio.withUnsafeBufferPointer { ring.write($0) }
        fillAverage += 0.05 * (Double(ring.fill) - fillAverage)

        untilReport -= frames
        if untilReport <= 0 {
            untilReport = FMDemodulator.audioRate / 4
            notify(.reception(Reception(frequency: frequency,
                                        quality: demodulator.quality,
                                        isStereo: demodulator.isStereo,
                                        stationName: demodulator.rds.parser.stationName,
                                        radioText: demodulator.rds.parser.radioText)))
        }

        queue.async { self.pump(id) }
    }

    /// Output / input samples of the resampler. A buffer above its target
    /// means the RTL-SDR runs fast against the audio clock: produce a little
    /// less, and vice versa.
    private var ratio: Double {
        let target = Double(ring.target)
        let error = min(max((fillAverage - target) / target, -1), 1)
        return 1 - 0.001 * error
    }
}

// MARK: - Audio output

/// Plays the frames from `ring` as 48 kHz stereo.
nonisolated final class AudioOutput: @unchecked Sendable {

    private let engine = AVAudioEngine()
    private var configurationObserver: NSObjectProtocol?
    private let shouldRun = Atomic<Bool>(false)

    init(ring: AudioRing) {
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(FMDemodulator.audioRate),
                                   channels: 2)!
        let source = AVAudioSourceNode(format: format, renderBlock: AudioOutput.render(from: ring))
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)

        // The engine stops when the output route changes its format, e.g.
        // when AirPlay or Bluetooth takes over. Start it again on the new one.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self, self.shouldRun.load(ordering: .relaxed),
                  !self.engine.isRunning else { return }
            try? self.engine.start()
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func start() throws {
        shouldRun.store(true, ordering: .relaxed)
        engine.prepare()
        try engine.start()
    }

    func stop() {
        shouldRun.store(false, ordering: .relaxed)
        engine.stop()
    }

    /// Runs on the real-time audio thread: no locks, no allocations.
    private static func render(from ring: AudioRing) -> AVAudioSourceNodeRenderBlock {
        return { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            if buffers.count == 2, let left = buffers[0].mData, let right = buffers[1].mData {
                ring.read(left: left.assumingMemoryBound(to: Float.self),
                          right: right.assumingMemoryBound(to: Float.self),
                          frames: Int(frameCount))
            }
            return noErr
        }
    }
}

/// Single-producer, single-consumer buffer of interleaved stereo frames
/// between the demodulator and the audio thread. Plays silence until
/// `target` frames are buffered, at the start and after running dry.
nonisolated final class AudioRing: @unchecked Sendable {

    let capacity: Int                       // frames
    let target: Int                         // frames

    private let samples: UnsafeMutablePointer<Float>
    private let writeCount = Atomic<Int>(0) // frames
    private let readCount = Atomic<Int>(0)  // frames
    private var priming = true              // reader side only

    init(frames: Int, target: Int) {
        capacity = frames
        self.target = target
        samples = .allocate(capacity: 2 * frames)
        samples.initialize(repeating: 0, count: 2 * frames)
    }

    deinit {
        samples.deallocate()
    }

    /// Buffered frames.
    var fill: Int {
        writeCount.load(ordering: .acquiring) - readCount.load(ordering: .acquiring)
    }

    /// Only while the audio output is stopped.
    func reset() {
        writeCount.store(0, ordering: .sequentiallyConsistent)
        readCount.store(0, ordering: .sequentiallyConsistent)
        priming = true
    }

    /// Producer side: interleaved left / right samples. Drops what does not
    /// fit.
    func write(_ input: UnsafeBufferPointer<Float>) {
        let w = writeCount.load(ordering: .relaxed)
        let r = readCount.load(ordering: .acquiring)
        let n = min(input.count / 2, capacity - (w - r))
        guard n > 0, let src = input.baseAddress else { return }
        let offset = w % capacity
        let first = min(n, capacity - offset)
        (samples + 2 * offset).update(from: src, count: 2 * first)
        if n > first {
            samples.update(from: src + 2 * first, count: 2 * (n - first))
        }
        writeCount.store(w + n, ordering: .releasing)
    }

    /// Consumer side, on the audio thread.
    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let r = readCount.load(ordering: .relaxed)
        let available = writeCount.load(ordering: .acquiring) - r
        if priming {
            guard available >= target else {
                left.update(repeating: 0, count: frames)
                right.update(repeating: 0, count: frames)
                return
            }
            priming = false
        }
        let n = min(frames, available)
        for k in 0..<n {
            let i = 2 * ((r + k) % capacity)
            left[k] = samples[i]
            right[k] = samples[i + 1]
        }
        if n < frames {
            (left + n).update(repeating: 0, count: frames - n)
            (right + n).update(repeating: 0, count: frames - n)
            priming = true
        }
        readCount.store(r + n, ordering: .releasing)
    }
}
