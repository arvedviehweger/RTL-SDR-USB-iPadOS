//
//  RTLSDRClient.swift
//  RTL-SDR Host
//
//  Minimal client for the RTL_SDR DriverKit extension. Wraps the C/IOKit
//  bridge (RTLSDRBridge) and runs a one-shot connection self-test that
//  exercises the whole chain: user-client connection, scalar control methods,
//  the GetDeviceInfo struct method, the mapped IQ ring buffer and streaming.
//
//  This is the seed for the later rtl_tcp server - the same calls
//  (set frequency / sample rate / gain, start streaming, drain the ring
//  buffer) are what an rtl_tcp implementation needs.
//

import Foundation

final class RTLSDRClient {

    private var connection: UInt32 = 0
    private var ringBase: UnsafeMutableRawPointer?
    private var ringSize: UInt64 = 0

    /// RTLSDRRingBuffer header = 4 x UInt64 (writeCount, readCount,
    /// dropCount, dataSize) before the sample data starts.
    private let ringHeaderSize = 32

    var isOpen: Bool { connection != 0 }

    /// True while the dext's RTL_SDR service exists. It is missing both when
    /// no RTL-SDR is plugged in and when the driver is disabled in Settings;
    /// iPadOS offers no way to tell these apart.
    static var isServicePresent: Bool { rtlsdrhost_service_present() != 0 }

    // MARK: - Connection

    @discardableResult
    func open() -> Bool {
        connection = rtlsdrhost_open()
        return connection != 0
    }

    func close() {
        ringBase = nil
        ringSize = 0
        if connection != 0 {
            rtlsdrhost_close(connection)
            connection = 0
        }
    }

    // MARK: - Control commands

    /// Calls a scalar external method. `selector` is a kRTLSDRMethod* constant;
    /// the generic integer type keeps this working whether the C enum imports
    /// as Int32 or UInt32. Returns the IOKit kern_return_t (0 == success).
    @discardableResult
    func call<T: BinaryInteger>(_ selector: T, _ arg: UInt64 = 0) -> Int32 {
        return callWithResult(selector, arg).kr
    }

    func callWithResult<T: BinaryInteger>(_ selector: T, _ arg: UInt64 = 0) -> (kr: Int32, result: Int64) {
        guard connection != 0 else { return (-1, 0) }
        var out: UInt64 = 0
        let kr = rtlsdrhost_call(connection, UInt32(selector), arg, &out)
        return (kr, Int64(bitPattern: out))
    }

    func deviceInfo() -> RTLSDRDeviceInfo? {
        guard connection != 0 else { return nil }
        var info = RTLSDRDeviceInfo()
        var size = MemoryLayout<RTLSDRDeviceInfo>.size
        let kr = rtlsdrhost_get_struct(connection,
                                       UInt32(kRTLSDRMethodGetDeviceInfo),
                                       &info, &size)
        return kr == 0 ? info : nil
    }

    /// "Manufacturer Product" from the dongle's USB string descriptors,
    /// empty if the device reports none.
    static func deviceName(_ info: RTLSDRDeviceInfo) -> String {
        return [cString(info.manufacturer), cString(info.product)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// "1.0 (7)" - same format as RTLSDRDeviceInfo.dextVersion.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// Decodes a fixed-size C char array (imported as a tuple) up to its NUL.
    private static func cString<T>(_ chars: T) -> String {
        return withUnsafeBytes(of: chars) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: - Shared IQ ring buffer

    @discardableResult
    func mapRing() -> Bool {
        guard connection != 0 else { return false }
        var size: UInt64 = 0
        guard let p = rtlsdrhost_map_memory(connection,
                                            UInt32(kRTLSDRMemoryTypeIQRing),
                                            &size) else {
            return false
        }
        ringBase = p
        ringSize = size
        return true
    }

    private func ringField(_ offset: Int) -> UInt64 {
        guard let b = ringBase else { return 0 }
        return b.load(fromByteOffset: offset, as: UInt64.self)
    }

    var ringWriteCount: UInt64 { ringField(0) }
    var ringReadCount:  UInt64 { ringField(8) }
    var ringDropCount:  UInt64 { ringField(16) }
    var ringDataSize:   UInt64 { ringField(24) }

    /// Clears the shared-ring counters while streaming is stopped.
    func resetRingCounters() {
        guard let base = ringBase else { return }
        consumeCursor = 0
        base.storeBytes(of: UInt64(0), toByteOffset: 0, as: UInt64.self)
        base.storeBytes(of: UInt64(0), toByteOffset: 8, as: UInt64.self)
        base.storeBytes(of: UInt64(0), toByteOffset: 16, as: UInt64.self)
    }

    /// Hex dump of `count` bytes from the sample-data region.
    func peekData(_ count: Int, at dataOffset: Int = 0) -> String {
        guard let b = ringBase else { return "-" }
        let start = b.advanced(by: ringHeaderSize)
        var parts: [String] = []
        for i in 0..<count {
            parts.append(String(format: "%02X",
                                start.load(fromByteOffset: dataOffset + i,
                                           as: UInt8.self)))
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Streaming consumer (used by the rtl_tcp server)

    private var consumeCursor: UInt64 = 0

    /// Starts consuming at the current write position (discards any backlog).
    func beginConsuming() {
        drainPendingIQ()
    }

    /// Marks all currently buffered IQ as consumed without copying it.
    func drainPendingIQ() {
        guard let base = ringBase else { return }
        let w = ringWriteCount
        consumeCursor = w
        base.storeBytes(of: w, toByteOffset: 8, as: UInt64.self)
    }

    /// Returns every IQ byte produced since the last call, or nil if none.
    /// Advances the ring's readCount so the producer sees the consumption.
    /// If the consumer was lapped, it skips ahead to the newest data.
    func readIQ() -> Data? {
        guard let base = ringBase else { return nil }
        let dataSize = ringDataSize
        guard dataSize > 0 else { return nil }

        let w = ringWriteCount
        var r = consumeCursor
        var avail = w &- r
        if avail == 0 { return nil }
        if avail > dataSize {                 // lapped - jump to the newest window
            r = w &- dataSize
            avail = dataSize
        }

        let count = Int(avail)
        let dataStart = base.advanced(by: ringHeaderSize)
        var out = Data(count: count)
        out.withUnsafeMutableBytes { raw in
            guard let dst = raw.baseAddress else { return }
            let off = Int(r % dataSize)
            let first = min(count, Int(dataSize) - off)
            memcpy(dst, dataStart.advanced(by: off), first)
            if count > first {
                memcpy(dst.advanced(by: first), dataStart, count - first)
            }
        }

        r = r &+ avail
        consumeCursor = r
        base.storeBytes(of: r, toByteOffset: 8, as: UInt64.self)   // publish readCount
        return out
    }

    // MARK: - One-shot self-test

    func runConnectionTest(log: @escaping (String) -> Void) {
        log("Searching for RTL_SDR service …")
        guard open() else {
            log("✗ Could not connect to the RTL_SDR user client.")
            log("  → Is the RTL-SDR plugged in?")
            log("  → Is the driver enabled in Settings › Apps › RTL-SDR-Host?")
            return
        }
        log("✓ User client connection open.")

        if let info = deviceInfo() {
            log("✓ GetDeviceInfo:")
            let name = RTLSDRClient.deviceName(info)
            log("    device=\(name.isEmpty ? "unknown" : name)")
            log("    valid=\(info.valid)   tuner=\(tunerName(info.tunerType))")
            log("    sampleRate=\(info.sampleRate) Hz   streaming=\(info.streaming)")
            let dext = RTLSDRClient.cString(info.dextVersion)
            let app = RTLSDRClient.appVersion
            log("    dext=\(dext.isEmpty ? "unknown (older build)" : dext)   app=\(app)")
            if dext != app {
                log("⚠ The running dext is not the one in this app.")
                log("  → Replug the RTL-SDR; bump the build number after dext changes.")
            }
        } else {
            log("⚠ GetDeviceInfo failed (struct method).")
        }

        report("SetSampleRate 2.048 MS/s",
               call(kRTLSDRMethodSetSampleRate, 2_048_000), log)
        report("SetCenterFreq 100 MHz",
               call(kRTLSDRMethodSetCenterFreq, 100_000_000), log)
        report("SetTunerGainMode auto",
               call(kRTLSDRMethodSetTunerGainMode, 0), log)
        report("ResetBuffer",
               call(kRTLSDRMethodResetBuffer), log)

        guard mapRing() else {
            log("✗ Could not map the IQ ring buffer.")
            close()
            return
        }
        log("✓ IQ ring buffer mapped: \(ringSize) bytes (payload \(ringDataSize)).")
        resetRingCounters()

        let writeBefore = ringWriteCount
        report("StartStream", call(kRTLSDRMethodStartStream), log)

        log("… streaming for 1 second …")
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            drainPendingIQ()
            Thread.sleep(forTimeInterval: 0.01)
        }
        drainPendingIQ()

        let writeAfter = ringWriteCount
        let drops = ringDropCount
        report("StopStream", call(kRTLSDRMethodStopStream), log)

        let produced = writeAfter &- writeBefore
        if produced > 0 {
            let kib = Double(produced) / 1024.0
            log("")
            log("✓✓ IQ streaming active:")
            log("    \(produced) bytes in 1 s  (~\(Int(kib)) KiB/s)")
            log("    dropCount=\(drops)")
            log("    data sample: \(peekData(16))")
            log("")
            log("CONNECTION TEST SUCCESSFUL.")
        } else {
            log("")
            log("⚠ No IQ data received (writeCount unchanged).")
            log("  → Check the streaming path (AsyncIO/ReadComplete),")
            log("    look for [rtlsdr] messages in the console.")
        }

        close()
        log("Connection closed.")
    }

    // MARK: - Helpers

    private func report(_ name: String, _ kr: Int32, _ log: (String) -> Void) {
        if kr == 0 {
            log("  ✓ \(name)")
        } else {
            log("  ✗ \(name)  (kr=0x\(String(format: "%08X", UInt32(bitPattern: kr))))")
        }
    }

    private func tunerName(_ t: UInt32) -> String {
        switch t {
        case 1:  return "Elonics E4000"
        case 2:  return "Fitipower FC0012"
        case 3:  return "Fitipower FC0013"
        case 4:  return "FCI FC2580"
        case 5:  return "Rafael Micro R820T/2"
        case 6:  return "Rafael Micro R828D"
        default: return "unknown (\(t))"
        }
    }
}
