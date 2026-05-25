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
    private let queue  = DispatchQueue(label: "com.m0kds.rtltcp.server")

    private var listener:   NWListener?
    private var connection: NWConnection?
    private var streaming = false

    private(set) var port: UInt16 = 1234

    /// Log sink (always called on the main queue).
    var log: ((String) -> Void)?
    /// Running-state changes (always called on the main queue). true == running.
    var statusChanged: ((Bool) -> Void)?

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

    private func notifyStatus(_ running: Bool) {
        DispatchQueue.main.async { self.statusChanged?(running) }
    }

    private func doStart(port: UInt16) {
        guard listener == nil else { return }
        self.port = port

        guard client.open() else {
            emit("✗ RTL-SDR user client unreachable — is the dext active? Is the device plugged in?")
            return
        }
        guard client.mapRing() else {
            emit("✗ Could not map the IQ ring buffer.")
            client.close()
            return
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let l = try? NWListener(using: params, on: nwPort) else {
            emit("✗ Could not create listener on port \(port).")
            client.close()
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
                self.notifyStatus(true)
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
        if streaming {
            client.call(kRTLSDRMethodStopStream)
            streaming = false
        }
        client.close()
        emit("rtl_tcp server stopped.")
        notifyStatus(false)
    }

    // MARK: - Connection handling

    private func handleNewConnection(_ conn: NWConnection) {
        guard connection == nil else {
            emit("Additional client rejected — only one is served.")
            conn.cancel()
            return
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
                self.onClientReady()
            case .failed(let error):
                self.emit("Client connection error: \(error)")
                self.onClientGone()
            case .cancelled:
                self.onClientGone()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func onClientReady() {
        sendDongleHeader()

        client.beginConsuming()
        let kr = client.call(kRTLSDRMethodResetBuffer)
        _ = kr
        streaming = (client.call(kRTLSDRMethodStartStream) == 0)
        if !streaming {
            emit("⚠ StartStream failed.")
        }

        pumpIQ()
        receiveCommand()
    }

    private func onClientGone() {
        guard connection != nil else { return }
        connection = nil
        if streaming {
            client.call(kRTLSDRMethodStopStream)
            streaming = false
        }
        emit("Client disconnected — waiting for a new connection.")
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

    private func pumpIQ() {
        guard let conn = connection, streaming else { return }

        if let data = client.readIQ(), !data.isEmpty {
            conn.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self = self else { return }
                if error != nil {
                    self.onClientGone()
                } else {
                    self.pumpIQ()                       // back-pressured: next chunk
                }
            })
        } else {
            // nothing produced yet - retry shortly
            queue.asyncAfter(deadline: .now() + 0.004) { [weak self] in
                self?.pumpIQ()
            }
        }
    }

    // MARK: - Command channel (socket -> control methods)

    private func receiveCommand() {
        guard let conn = connection else { return }
        // rtl_tcp commands are exactly 5 bytes.
        conn.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, data.count == 5 {
                self.handleCommand([UInt8](data))
            }
            if isComplete || error != nil {
                self.onClientGone()
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
        case Cmd.setSampleRate:
            client.call(kRTLSDRMethodSetSampleRate, p64)
            emit("cmd: sample rate \(param) Hz")
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
