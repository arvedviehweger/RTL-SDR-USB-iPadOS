//
//  RTLTCPServer.swift
//  RTL-SDR Host
//
//  An rtl_tcp-compatible TCP server. Existing rtl_tcp clients (SDR++, GQRX via
//  gr-osmosdr, SDRangel, CubicSDR, SDR# …) can connect to <iPad-IP>:1234 and
//  receive the IQ stream / send control commands, exactly as they would to a
//  PC running rtl_tcp.
//
//  Protocol (see the original rtl_tcp.c):
//    * On connect the server sends a 12-byte dongle-info header:
//        char     magic[4]          = "RTL0"
//        uint32_t tuner_type        (big-endian)
//        uint32_t tuner_gain_count  (big-endian)
//    * Then it streams raw 8-bit unsigned interleaved IQ samples.
//    * The client sends 5-byte commands: 1 byte command id + 4 byte
//      big-endian parameter.
//
//  This implementation handles the universal command set 0x01–0x0e that every
//  existing client uses. The fork-specific extended commands (0x40+) are
//  accepted and ignored - ignoring a command never breaks a client, since
//  rtl_tcp commands are fire-and-forget (no reply).
//

import Foundation
import Network

final class RTLTCPServer {

    // rtl_tcp command ids (universal set, identical across all rtl_tcp builds)
    private enum Cmd {
        static let setFrequency       : UInt8 = 0x01
        static let setSampleRate      : UInt8 = 0x02
        static let setGainMode        : UInt8 = 0x03
        static let setGain            : UInt8 = 0x04
        static let setFreqCorrection  : UInt8 = 0x05
        static let setIfStage         : UInt8 = 0x06
        static let setTestMode        : UInt8 = 0x07
        static let setAgcMode         : UInt8 = 0x08
        static let setDirectSampling  : UInt8 = 0x09
        static let setOffsetTuning    : UInt8 = 0x0a
        static let setRtlCrystal      : UInt8 = 0x0b
        static let setTunerCrystal    : UInt8 = 0x0c
        static let setGainByIndex     : UInt8 = 0x0d
        static let setBiasTee         : UInt8 = 0x0e
    }

    private let client: RTLSDRClient
    // .userInitiated: the IQ stream feeds a live SDR client, often running
    // in the foreground while this app is in the background.
    private let queue  = DispatchQueue(label: "com.m0kds.rtltcp.server",
                                       qos: .userInitiated)
    /// Control commands block on USB I/O in the dext (I2C to the tuner).
    /// Running them here keeps the IQ pump on `queue` going meanwhile; the
    /// serial queue preserves the order in which the client sent them.
    private let commandQueue = DispatchQueue(label: "com.m0kds.rtltcp.commands",
                                             qos: .userInitiated)

    private var listener:   NWListener?
    private var connection: NWConnection?
    private var streaming = false

    // Stream statistics, logged every `statsInterval` seconds while a client
    // is streaming (all accessed on `queue`).
    private let statsInterval = 5
    private var statsTimer: DispatchSourceTimer?
    private var statsSince:     UInt64 = 0      // uptime ns of the last report
    private var statsRingWrite: UInt64 = 0      // ring writeCount at statsSince
    private var statsRingDrop:  UInt64 = 0      // ring dropCount at statsSince
    private var statsSent:      UInt64 = 0      // bytes handed to the socket
    private var statsLastData:  UInt64 = 0      // uptime ns of the last IQ chunk
    private var statsMaxGap:    UInt64 = 0      // longest pause between chunks

    private(set) var port: UInt16 = 1234

    /// What happened to the server and its client, for the UI.
    enum Event {
        case started
        case stopped
        case failed(String)                 // could not start; not running
        case clientConnected(String)        // the client's address
        case clientDisconnected
        case frequency(UInt32)              // set by the client, in Hz
        case sampleRate(UInt32)             // set by the client, in Hz
    }

    /// Log sink (always called on the main queue).
    var log: ((String) -> Void)?
    /// Server and client events (always called on the main queue).
    var event: ((Event) -> Void)?

    init(client: RTLSDRClient) {
        self.client = client
    }

    var isRunning: Bool { listener != nil }

    // MARK: - Start / stop

    func start(port: UInt16 = 1234) {
        queue.async { self.doStart(port: port) }
    }

    func stop() {
        queue.async { self.doStop() }
    }

    private func emit(_ s: String) {
        DispatchQueue.main.async { self.log?(s) }
    }

    private func notify(_ e: Event) {
        DispatchQueue.main.async { self.event?(e) }
    }

    /// Logs why the server could not start; it is not running afterwards.
    private func fail(_ message: String) {
        emit("✗ \(message)")
        notify(.failed(message))
    }

    private func doStart(port: UInt16) {
        guard listener == nil else { return }
        self.port = port

        guard client.open() else {
            fail("RTL-SDR user client unreachable — is the device plugged in? Is the driver enabled in Settings › Apps › RTL-SDR-Host?")
            return
        }
        guard client.mapRing() else {
            client.close()
            fail("Could not map the IQ ring buffer.")
            return
        }
        if let info = client.deviceInfo() {
            let name = RTLSDRClient.deviceName(info)
            if !name.isEmpty { emit("RTL-SDR: \(name)") }
        }

        // Detect clients that vanish without closing their socket (suspended
        // app, Wi-Fi change, sleeping host): keepalive covers an idle link,
        // persistTimeout a zero receive window, connectionDropTime
        // unacknowledged retransmissions.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive    = true
        tcp.keepaliveIdle      = 10
        tcp.keepaliveInterval  = 5
        tcp.keepaliveCount     = 3
        tcp.persistTimeout     = 10
        tcp.connectionDropTime = 10
        tcp.noDelay            = true   // send each IQ chunk right away

        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let l = try? NWListener(using: params, on: nwPort) else {
            client.close()
            fail("Could not create listener on port \(port).")
            return
        }

        l.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn)
        }
        l.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.emit("✓ rtl_tcp server running on port \(self.port).")
                let ips = RTLTCPServer.localIPAddresses()
                if ips.isEmpty {
                    self.emit("  Connect a client to:  <iPad-WiFi-IP>:\(self.port)")
                } else {
                    self.emit("  Enter as the rtl_tcp source in your SDR client:")
                    for ip in ips { self.emit("    • \(ip):\(self.port)") }
                }
                self.notify(.started)
            case .failed(let error):
                self.emit("✗ Listener error: \(error)")
                self.doStop()
            default:
                break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    private func doStop() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        commandQueue.sync {}                // let queued commands finish before close()
        stopStats()
        if streaming {
            client.call(kRTLSDRMethodStopStream)
            streaming = false
        }
        client.close()
        emit("rtl_tcp server stopped.")
        notify(.stopped)
    }

    // MARK: - Connection handling

    private func handleNewConnection(_ conn: NWConnection) {
        // Only one client is served and the newest one wins. Rejecting the
        // new client instead would lock out every reconnect for as long as
        // a previous client lingers without having closed its socket.
        if let old = connection {
            emit("New client — dropping the previous one.")
            dropClient(old)
        }
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            // Ignore late callbacks from a connection we have already dropped
            // (e.g. a .cancelled/.failed arriving after stop or a reset).
            guard self.connection === conn else { return }
            switch state {
            case .ready:
                self.emit("Client connected: \(conn.endpoint)")
                self.notify(.clientConnected(RTLTCPServer.host(of: conn.endpoint)))
                self.onClientReady(conn)
            case .failed(let error):
                self.emit("Client connection error: \(error)")
                self.onClientGone(conn)
            case .cancelled:
                self.onClientGone(conn)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func onClientReady(_ conn: NWConnection) {
        sendDongleHeader()

        client.call(kRTLSDRMethodStopStream)
        let kr = client.call(kRTLSDRMethodResetBuffer)
        _ = kr
        client.resetRingCounters()
        client.beginConsuming()
        let start = client.callWithResult(kRTLSDRMethodStartStream)
        let startKR = start.kr
        streaming = (startKR == 0 && start.result == 0)
        if !streaming {
            client.call(kRTLSDRMethodStopStream)
            emit("⚠ StartStream failed (kr=0x\(String(format: "%08X", UInt32(bitPattern: startKR))), rtl=\(start.result)).")
        }
        // Logs an "IQ:" statistics line every few seconds; uncomment to enable.
        // if streaming { startStats() }

        pumpIQ(conn)
        receiveCommand()
    }

    private func onClientGone(_ conn: NWConnection) {
        guard connection === conn else { return }
        dropClient(conn)
        emit("Client disconnected — waiting for a new connection.")
        notify(.clientDisconnected)
    }

    /// Closes the current client's socket and stops the IQ stream.
    private func dropClient(_ conn: NWConnection) {
        connection = nil
        conn.cancel()
        stopStats()
        if streaming {
            client.call(kRTLSDRMethodStopStream)
            streaming = false
        }
    }

    // MARK: - Dongle-info header

    private func sendDongleHeader() {
        var tunerType: UInt32 = 0
        if let info = client.deviceInfo() {
            tunerType = info.tunerType
        }
        let gainCount = RTLTCPServer.gainCount(forTuner: tunerType)

        var header = Data()
        header.append(contentsOf: Array("RTL0".utf8))
        header.append(bigEndian(tunerType))
        header.append(bigEndian(gainCount))

        connection?.send(content: header, completion: .contentProcessed { _ in })
        emit("Dongle header sent (tuner_type=\(tunerType), gain_count=\(gainCount)).")
    }

    // MARK: - IQ pump (ring buffer -> socket)

    /// Bound to one connection, so a pending retry of a previous client
    /// cannot start a second pump on its successor.
    private func pumpIQ(_ conn: NWConnection) {
        guard connection === conn, streaming else { return }

        if let data = client.readIQ(), !data.isEmpty {
            noteIQChunk(data.count)
            conn.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self = self else { return }
                guard self.connection === conn else { return }
                if error != nil {
                    self.onClientGone(conn)
                } else {
                    self.pumpIQ(conn)                   // back-pressured: next chunk
                }
            })
        } else {
            // nothing produced yet - retry shortly
            queue.asyncAfter(deadline: .now() + 0.004) { [weak self] in
                self?.pumpIQ(conn)
            }
        }
    }

    // MARK: - Stream statistics

    /// Reports, per interval: what arrived from USB versus 2 x sample rate,
    /// what went to the socket, the longest pause between IQ chunks (what a
    /// client's audio buffer has to bridge) and bytes lost in the ring.
    private func startStats() {
        stopStats()
        statsLastData = 0
        resetStats(at: DispatchTime.now().uptimeNanoseconds)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(statsInterval),
                       repeating: .seconds(statsInterval))
        timer.setEventHandler { [weak self] in self?.logStats() }
        timer.resume()
        statsTimer = timer
    }

    private func stopStats() {
        statsTimer?.cancel()
        statsTimer = nil
    }

    private func resetStats(at now: UInt64) {
        statsSince     = now
        statsRingWrite = client.ringWriteCount
        statsRingDrop  = client.ringDropCount
        statsSent      = 0
        statsMaxGap    = 0
    }

    private func noteIQChunk(_ count: Int) {
        let now = DispatchTime.now().uptimeNanoseconds
        if statsLastData != 0 {
            statsMaxGap = max(statsMaxGap, now - statsLastData)
        }
        statsLastData = now
        statsSent += UInt64(count)
    }

    private func logStats() {
        let now  = DispatchTime.now().uptimeNanoseconds
        let secs = Double(now - statsSince) / 1e9
        guard secs > 0 else { return }

        let usb      = Double(client.ringWriteCount &- statsRingWrite) / secs
        let sent     = Double(statsSent) / secs
        let drops    = client.ringDropCount &- statsRingDrop
        let expected = 2 * Double(client.deviceInfo()?.sampleRate ?? 0)
        emit(String(format: "IQ: USB %.2f MB/s (expected %.2f), sent %.2f MB/s, max gap %.0f ms, ring drops %llu B",
                    usb / 1e6, expected / 1e6, sent / 1e6,
                    Double(statsMaxGap) / 1e6, drops))
        resetStats(at: now)
    }

    // MARK: - Command channel (socket -> control methods)

    private func receiveCommand() {
        guard let conn = connection else { return }
        // rtl_tcp commands are exactly 5 bytes.
        conn.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            guard self.connection === conn else { return }
            if let data = data, data.count == 5 {
                let bytes = [UInt8](data)
                self.commandQueue.async { [weak self] in
                    self?.handleCommand(bytes)
                }
            }
            if isComplete || error != nil {
                self.onClientGone(conn)
                return
            }
            self.receiveCommand()
        }
    }

    private func handleCommand(_ b: [UInt8]) {
        guard b.count == 5 else { return }
        let cmd = b[0]
        let param = (UInt32(b[1]) << 24) | (UInt32(b[2]) << 16)
                  | (UInt32(b[3]) << 8)  |  UInt32(b[4])
        let p64 = UInt64(param)

        switch cmd {
        case Cmd.setFrequency:
            client.call(kRTLSDRMethodSetCenterFreq, p64)
            emit("cmd: frequency \(param) Hz")
            notify(.frequency(param))
        case Cmd.setSampleRate:
            client.call(kRTLSDRMethodSetSampleRate, p64)
            emit("cmd: sample rate \(param) Hz")
            notify(.sampleRate(param))
        case Cmd.setGainMode:
            client.call(kRTLSDRMethodSetTunerGainMode, p64)
            emit("cmd: gain mode \(param == 0 ? "auto" : "manual")")
        case Cmd.setGain:
            client.call(kRTLSDRMethodSetTunerGain, p64)
            emit("cmd: tuner gain \(Int32(bitPattern: param)) (tenths of a dB)")
        case Cmd.setFreqCorrection:
            client.call(kRTLSDRMethodSetFreqCorrection, p64)
            emit("cmd: frequency correction \(Int32(bitPattern: param)) ppm")
        case Cmd.setTestMode:
            client.call(kRTLSDRMethodSetTestmode, p64)
            emit("cmd: test mode \(param)")
        case Cmd.setAgcMode:
            client.call(kRTLSDRMethodSetAgcMode, p64)
            emit("cmd: RTL2832 AGC \(param)")
        case Cmd.setDirectSampling:
            client.call(kRTLSDRMethodSetDirectSampling, p64)
            emit("cmd: direct sampling \(param)")
        case Cmd.setGainByIndex:
            client.call(kRTLSDRMethodSetGainByIndex, p64)
            emit("cmd: gain by index \(param)")
        case Cmd.setBiasTee:
            client.call(kRTLSDRMethodSetBiasTee, p64)
            emit("cmd: bias-T \(param == 0 ? "off" : "on")")
        case Cmd.setOffsetTuning:
            client.call(kRTLSDRMethodSetOffsetTuning, p64)
            emit("cmd: offset tuning \(param == 0 ? "off" : "on")")
        case Cmd.setIfStage, Cmd.setRtlCrystal, Cmd.setTunerCrystal:
            emit("cmd: 0x\(hex(cmd)) (not yet mapped) — ignored")
        default:
            emit("cmd: unknown 0x\(hex(cmd)) — ignored")
        }
    }

    // MARK: - Helpers

    private func bigEndian(_ v: UInt32) -> Data {
        return Data([UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                     UInt8((v >> 8) & 0xff),  UInt8(v & 0xff)])
    }

    private func hex(_ v: UInt8) -> String {
        return String(format: "%02X", v)
    }

    /// Gain-table sizes from librtlsdr, keyed by enum rtlsdr_tuner.
    static func gainCount(forTuner type: UInt32) -> UInt32 {
        switch type {
        case 1:    return 14      // E4000
        case 2:    return 5       // FC0012
        case 3:    return 23      // FC0013
        case 4:    return 1       // FC2580
        case 5, 6: return 29      // R820T / R828D
        default:   return 0
        }
    }

    /// The client's address without its port, for display.
    private static func host(of endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4(let a): return "\(a)"
            case .ipv6(let a): return "\(a)"
            default:           return "\(host)"
            }
        }
        return "\(endpoint)"
    }

    /// IPv4 addresses of the Wi-Fi / Ethernet interfaces, for display.
    static func localIPAddresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return result }
        defer { freeifaddrs(ifaddr) }

        var cursor = ifaddr
        while let ptr = cursor {
            let iface = ptr.pointee
            cursor = iface.ifa_next

            guard let addr = iface.ifa_addr else { continue }
            guard addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            let name = String(cString: iface.ifa_name)
            guard name.hasPrefix("en") else { continue }   // Wi-Fi / Ethernet

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let r = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                &host, socklen_t(host.count),
                                nil, 0, NI_NUMERICHOST)
            if r == 0 {
                let ip = String(cString: host)
                if !ip.isEmpty && ip != "127.0.0.1" {
                    result.append(ip)
                }
            }
        }
        return result
    }
}
