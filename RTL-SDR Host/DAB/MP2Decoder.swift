//
//  MP2Decoder.swift
//  RTL-SDR Host
//
//  Classic DAB audio: MPEG-1/2 Audio Layer II frames in a stream
//  subchannel, decoded by kjmp2 (zlib licence, vendored unchanged as
//  kjmp2.c). At 48 kHz one frame fills one CIF; at 24 kHz a frame spans two,
//  so the bytes are framed by their sync word, not by CIF.
//
//  kjmp2 trusts the frame it is given. Every frame is copied into a buffer
//  with zeroed slack behind it, so a corrupted bit allocation cannot make
//  it read past the end.
//
//  Runs on one queue; not thread-safe (nor is kjmp2: one decoder at a time).
//

import AVFoundation

nonisolated final class MP2Decoder {

    /// The frame's audio data ends before the scale factor CRCs, X-PAD and
    /// F-PAD of DAB (EN 300 401 clause 7.4); this gets the whole frame.
    var onFrame: (([UInt8]) -> Void)?
    private(set) var sampleRate = 0
    private(set) var framesGood = 0

    private var context = kjmp2_context_t()
    private var pending: [UInt8] = []
    private var frame = [UInt8](repeating: 0, count: Int(KJMP2_MAX_FRAME_SIZE) + 8192)
    private var pcm = [Int16](repeating: 0, count: 2 * Int(KJMP2_SAMPLES_PER_FRAME))
    private var resampler: AVAudioConverter?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: Double(DABAudioDecoder.outputRate),
                                             channels: 2, interleaved: true)!

    init() {
        kjmp2_init(&context)
    }

    func reset() {
        kjmp2_init(&context)
        pending.removeAll()
        sampleRate = 0
        resampler = nil
    }

    /// One CIF of subchannel bytes; appends 48 kHz stereo to `out`.
    func process(_ bytes: [UInt8], into out: inout [Float]) {
        pending.append(contentsOf: bytes)
        var i = 0
        while i + 4 <= pending.count {
            guard pending[i] == 0xFF, pending[i + 1] & 0xF6 == 0xF4 else {
                i += 1
                continue
            }
            let rate = Int(pending.withUnsafeBufferPointer { kjmp2_get_sample_rate($0.baseAddress! + i) })
            guard rate == 48000 || rate == 24000 else {
                i += 1
                continue
            }
            // Frame size from the header alone.
            let size = Int(pending.withUnsafeBufferPointer { kjmp2_decode_frame(&context, $0.baseAddress! + i, nil) })
            guard size > 4, size <= Int(KJMP2_MAX_FRAME_SIZE) else {
                i += 1
                continue
            }
            guard i + size <= pending.count else { break }

            frame.withUnsafeMutableBufferPointer { f in
                f.update(repeating: 0)
                pending.withUnsafeBufferPointer { p in
                    f.baseAddress!.update(from: p.baseAddress! + i, count: size)
                }
            }
            let used = frame.withUnsafeBufferPointer { f in
                pcm.withUnsafeMutableBufferPointer { kjmp2_decode_frame(&context, f.baseAddress!, $0.baseAddress!) }
            }
            if used > 0 {
                framesGood += 1
                onFrame?(Array(frame[0..<size]))
                emit(rate: rate, into: &out)
            }
            i += size
        }
        pending.removeFirst(i)
        if pending.count > 4 * Int(KJMP2_MAX_FRAME_SIZE) { pending.removeAll() }
    }

    private func emit(rate: Int, into out: inout [Float]) {
        let n = 2 * Int(KJMP2_SAMPLES_PER_FRAME)
        if rate == DABAudioDecoder.outputRate {
            out.reserveCapacity(out.count + n)
            for s in pcm { out.append(Float(s) / 32768) }
            return
        }
        if rate != sampleRate || resampler == nil {
            sampleRate = rate
            let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate),
                                      channels: 2, interleaved: true)!
            resampler = AVAudioConverter(from: input, to: outputFormat)
        }
        guard let resampler,
              let buffer = AVAudioPCMBuffer(pcmFormat: resampler.inputFormat,
                                            frameCapacity: AVAudioFrameCount(KJMP2_SAMPLES_PER_FRAME)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                            frameCapacity: AVAudioFrameCount(2 * KJMP2_SAMPLES_PER_FRAME + 64)) else { return }
        buffer.frameLength = AVAudioFrameCount(KJMP2_SAMPLES_PER_FRAME)
        let data = buffer.floatChannelData![0]
        for k in 0..<n { data[k] = Float(pcm[k]) / 32768 }
        var given = false
        var error: NSError?
        resampler.convert(to: output, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        let samples = output.floatChannelData![0]
        for k in 0..<(Int(output.frameLength) * 2) { out.append(samples[k]) }
    }
}
