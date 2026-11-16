//
//  DABAudioDecoder.swift
//  RTL-SDR Host
//
//  DAB+ audio through Core Audio's own AAC decoder.
//
//  DAB+ uses AAC with 960-sample frames (frameLengthFlag = 1), which Core
//  Audio does not accept. It decodes them anyway when told they are 1024
//  frames: apart from the top scale factor band, which DAB+ broadcasts with
//  SBR never reach, a 960 frame parses exactly like a 1024 one, and the
//  inverse MDCT, SBR and PS all work in units of the frame. So the output
//  is the right audio, stretched by 1024/960 and 960/1024 quieter. Playing
//  it at 16/15 of the nominal rate and lifting it by 16/15 undoes both.
//
//    AU → AudioConverter (AudioSpecificConfig with frameLengthFlag 0)
//       → PCM at f × 16/15 → AVAudioConverter → 48 kHz stereo, × 16/15
//
//  All AAC, SBR and PS decoding stays in Apple's licensed codec.
//
//  Runs on one queue; not thread-safe.
//

import AVFoundation
import AudioToolbox

nonisolated final class DABAudioDecoder {

    static let outputRate = 48_000

    private var format: SuperframeDecoder.AudioFormat?
    private var converter: AudioConverterRef?
    private var resampler: AVAudioConverter?
    private var decodedFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: Double(DABAudioDecoder.outputRate),
                                             channels: 2, interleaved: true)!
    private let feeder = PacketFeeder()
    private var pcm: [Float] = []

    deinit {
        if let converter { AudioConverterDispose(converter) }
    }

    func reset() {
        if let converter { AudioConverterDispose(converter) }
        converter = nil
        resampler = nil
        format = nil
    }

    /// Decodes one AU, or a lost one (nil) as silence; appends interleaved
    /// stereo at 48 kHz to `out`.
    func decode(_ au: [UInt8]?, format: SuperframeDecoder.AudioFormat, into out: inout [Float]) {
        if format != self.format { configure(format) }
        guard let converter, let decodedFormat else { return }
        let channels = Int(decodedFormat.channelCount)
        let frames = format.sbr ? 2048 : 1024

        pcm.removeAll(keepingCapacity: true)
        if let au {
            feeder.packet = au
            var buffer = [Float](repeating: 0, count: 2 * frames * channels)
            var produced = UInt32(2 * frames)
            let status = buffer.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(converter, PacketFeeder.proc,
                                                       Unmanaged.passUnretained(feeder).toOpaque(),
                                                       &produced, &list, nil)
            }
            if status == noErr || status == PacketFeeder.noMoreData {
                pcm.append(contentsOf: buffer[0..<(Int(produced) * channels)])
            }
        }
        if pcm.isEmpty {
            pcm = [Float](repeating: 0, count: frames * channels)
        }
        resample(channels: channels, into: &out)
    }

    private func configure(_ format: SuperframeDecoder.AudioFormat) {
        reset()
        self.format = format
        let channels = format.stereo || format.ps ? 2 : 1
        var input = AudioStreamBasicDescription(
            mSampleRate: Double(format.sampleRate),
            mFormatID: format.ps ? kAudioFormatMPEG4AAC_HE_V2 : format.sbr ? kAudioFormatMPEG4AAC_HE : kAudioFormatMPEG4AAC,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: format.sbr ? 2048 : 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        var output = AudioStreamBasicDescription(
            mSampleRate: Double(format.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var c: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &c) == noErr, let c else { return }
        let cookie = DABAudioDecoder.esds(DABAudioDecoder.audioSpecificConfig(format))
        guard AudioConverterSetProperty(c, kAudioConverterDecompressionMagicCookie,
                                        UInt32(cookie.count), cookie) == noErr else {
            AudioConverterDispose(c)
            return
        }
        converter = c
        feeder.channels = UInt32(channels)
        // What the decoder outputs really runs 16/15 faster.
        let decoded = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: Double(format.sampleRate) * 16 / 15,
                                    channels: AVAudioChannelCount(channels), interleaved: true)!
        decodedFormat = decoded
        let r = AVAudioConverter(from: decoded, to: outputFormat)
        r?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        if channels == 1 { r?.channelMap = [0, 0] }
        resampler = r
    }

    private func resample(channels: Int, into out: inout [Float]) {
        guard let resampler, let decodedFormat else { return }
        let frames = pcm.count / channels
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: decodedFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        input.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        let capacity = AVAudioFrameCount(Double(frames) * outputFormat.sampleRate / decodedFormat.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        resampler.convert(to: output, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return input
        }
        let n = Int(output.frameLength) * 2
        let gain: Float = 16 / 15
        let samples = output.floatChannelData![0]
        out.reserveCapacity(out.count + n)
        for i in 0..<n { out.append(samples[i] * gain) }
    }

    // MARK: - Configuration

    /// AudioSpecificConfig as for 1024-sample frames, explicit SBR/PS
    /// signalling as DAB+ defines it.
    static func audioSpecificConfig(_ f: SuperframeDecoder.AudioFormat) -> [UInt8] {
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000]
        let core = f.sbr ? f.sampleRate / 2 : f.sampleRate
        var bits: [(Int, Int)] = [(f.ps ? 29 : f.sbr ? 5 : 2, 5), (rates.firstIndex(of: core)!, 4), (f.stereo ? 2 : 1, 4)]
        if f.sbr { bits += [(rates.firstIndex(of: f.sampleRate)!, 4), (2, 5)] }
        bits += [(0, 1), (0, 1), (0, 1)]        // frameLengthFlag 0 (!), dependsOnCoreCoder, extensionFlag
        var out: [UInt8] = []
        var n = 0
        for (value, width) in bits {
            for i in stride(from: width - 1, through: 0, by: -1) {
                if n % 8 == 0 { out.append(0) }
                if (value >> i) & 1 == 1 { out[out.count - 1] |= UInt8(0x80 >> (n % 8)) }
                n += 1
            }
        }
        return out
    }

    /// The ES_Descriptor Core Audio takes as the AAC magic cookie.
    static func esds(_ asc: [UInt8]) -> [UInt8] {
        var decoderConfig: [UInt8] = [0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        decoderConfig += [0x05, UInt8(asc.count)] + asc
        var stream: [UInt8] = [0, 0, 0]
        stream += [0x04, UInt8(decoderConfig.count)] + decoderConfig
        stream += [0x06, 0x01, 0x02]
        return [0x03, UInt8(stream.count)] + stream
    }
}

/// Hands one AU at a time to AudioConverterFillComplexBuffer.
nonisolated final class PacketFeeder {

    static let noMoreData: OSStatus = 0x6E6F_6D6F    // 'nomo'

    var packet: [UInt8]? {
        didSet { pending = packet != nil }
    }
    var channels: UInt32 = 2
    private var pending = false
    private let storage = UnsafeMutableRawPointer.allocate(byteCount: 8192, alignment: 16)
    private let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)

    deinit {
        storage.deallocate()
        description.deallocate()
    }

    static let proc: AudioConverterComplexInputDataProc = { _, count, data, outDescription, user in
        let feeder = Unmanaged<PacketFeeder>.fromOpaque(user!).takeUnretainedValue()
        guard feeder.pending, let packet = feeder.packet, packet.count <= 8192 else {
            count.pointee = 0
            return PacketFeeder.noMoreData
        }
        feeder.pending = false
        packet.withUnsafeBytes { feeder.storage.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers = AudioBuffer(mNumberChannels: feeder.channels, mDataByteSize: UInt32(packet.count),
                                            mData: feeder.storage)
        feeder.description.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                  mDataByteSize: UInt32(packet.count))
        outDescription?.pointee = feeder.description
        count.pointee = 1
        return noErr
    }
}
