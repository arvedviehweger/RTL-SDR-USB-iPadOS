//
//  BackgroundAudioKeeper.swift
//  RTL-SDR Host
//
//  Keeps the app (and therefore the rtl_tcp server) running while it is in the
//  background.
//
//  iOS/iPadOS suspends a normal app a few seconds after it leaves the
//  foreground. The only practical way for a long-running server to survive is
//  the "audio" background mode: while the app holds an active audio session
//  and renders audio continuously, the system keeps its process alive.
//
//  Here that audio is simply silence. It is mixed with other audio
//  (.mixWithOthers), so starting the server does not interrupt music the user
//  may be playing.
//
//  Requires UIBackgroundModes = [audio] in Info.plist.
//
//  If background suspension should ever still occur, removing .mixWithOthers
//  makes the keep-alive more robust (at the cost of pausing other audio).
//

import Foundation
import AVFoundation

final class BackgroundAudioKeeper {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100,
                                       channels: 2)

    private var configured = false
    private var running = false

    var isActive: Bool { running }

    /// Activates the audio session and starts rendering continuous silence.
    func start() {
        guard !running, let format = format else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)

            if !configured {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                configured = true
            }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: 4_096) else { return }
            buffer.frameLength = buffer.frameCapacity
            if let channels = buffer.floatChannelData {
                let bytes = Int(buffer.frameCapacity) * MemoryLayout<Float>.size
                for ch in 0..<Int(format.channelCount) {
                    memset(channels[ch], 0, bytes)          // pure silence
                }
            }

            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops,
                                  completionHandler: nil)
            player.play()
            running = true
        } catch {
            print("BackgroundAudioKeeper: start failed - \(error)")
        }
    }

    /// Stops the silent playback and releases the audio session.
    func stop() {
        guard running else { return }
        running = false
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
