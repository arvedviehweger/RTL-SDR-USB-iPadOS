//
//  ViewController.swift
//  RTL-SDR Host
//
//  Created by Arved Viehweger on 20.05.26.
//
//  Two actions:
//   • "Test connection" - one-shot self-test of the dext user client.
//   • "rtl_tcp server"  - starts an rtl_tcp-compatible TCP server so that
//                         existing SDR clients can use the iPad's RTL-SDR
//                         over the network.
//

import UIKit

class ViewController: UIViewController {

    private let driverExtensionIdentifier = "com.m0kds.RTL-SDR-Host.driver"

    private let client = RTLSDRClient()
    private lazy var server = RTLTCPServer(client: client)
    private let keeper = BackgroundAudioKeeper()

    private let logView      = UITextView()
    private let testButton   = UIButton(type: .system)
    private let serverButton = UIButton(type: .system)

    private var serverRunning = false

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "RTL-SDR Host"
        view.backgroundColor = .systemBackground
        setupUI()
        wireServer()

        print("RTL-SDR Host started")
        print("Bundled driver extension identifier: \(driverExtensionIdentifier)")

        appendLog("RTL-SDR Host ready.")
        appendLog("Driver Extension: \(driverExtensionIdentifier)")
        appendLog("")
        appendLog("• Test connection  – check the USB connection to the RTL-SDR")
        appendLog("• rtl_tcp server   – exposes the RTL-SDR on the network.")
    }

    // MARK: - UI

    private func setupUI() {
        logView.translatesAutoresizingMaskIntoConstraints = false
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logView.backgroundColor = .secondarySystemBackground
        logView.layer.cornerRadius = 10
        logView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.addSubview(logView)

        styleButton(testButton,   title: "Test connection", color: .systemBlue)
        testButton.addTarget(self, action: #selector(runTest), for: .touchUpInside)
        view.addSubview(testButton)

        styleButton(serverButton, title: "Start rtl_tcp server", color: .systemGreen)
        serverButton.addTarget(self, action: #selector(toggleServer), for: .touchUpInside)
        view.addSubview(serverButton)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            logView.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            logView.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            logView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),

            serverButton.topAnchor.constraint(equalTo: logView.bottomAnchor, constant: 16),
            serverButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            serverButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            serverButton.heightAnchor.constraint(equalToConstant: 54),

            testButton.topAnchor.constraint(equalTo: serverButton.bottomAnchor, constant: 10),
            testButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            testButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            testButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
            testButton.heightAnchor.constraint(equalToConstant: 54),
        ])
    }

    private func styleButton(_ button: UIButton, title: String, color: UIColor) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        button.backgroundColor = color
        button.setTitleColor(.white, for: .normal)
        button.setTitleColor(UIColor.white.withAlphaComponent(0.5), for: .disabled)
        button.layer.cornerRadius = 12
    }

    private func wireServer() {
        server.log = { [weak self] line in self?.appendLog(line) }
        server.statusChanged = { [weak self] running in
            guard let self = self else { return }
            self.serverRunning = running
            self.serverButton.setTitle(running ? "Stop rtl_tcp server"
                                               : "Start rtl_tcp server", for: .normal)
            self.serverButton.backgroundColor = running ? .systemRed : .systemGreen
            self.testButton.isEnabled = !running
            self.testButton.alpha = running ? 0.5 : 1.0

            // Keep the app - and therefore the rtl_tcp server - alive:
            //  • audio background mode survives switching to another app,
            //  • disabling the idle timer keeps the screen from locking.
            if running {
                self.keeper.start()
                UIApplication.shared.isIdleTimerDisabled = true
            } else {
                self.keeper.stop()
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    // MARK: - Actions

    @objc private func runTest() {
        testButton.isEnabled = false
        serverButton.isEnabled = false
        testButton.alpha = 0.5
        serverButton.alpha = 0.5
        appendLog("")
        appendLog("──────── Test started ────────")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.client.runConnectionTest { line in
                DispatchQueue.main.async { self.appendLog(line) }
            }
            DispatchQueue.main.async {
                self.testButton.isEnabled = true
                self.serverButton.isEnabled = true
                self.testButton.alpha = 1.0
                self.serverButton.alpha = 1.0
            }
        }
    }

    @objc private func toggleServer() {
        if serverRunning {
            server.stop()
        } else {
            appendLog("")
            appendLog("──────── rtl_tcp server ────────")
            server.start(port: 1234)
        }
    }

    // MARK: - Log

    private func appendLog(_ line: String) {
        let current = logView.text ?? ""
        logView.text = current.isEmpty ? line : current + "\n" + line
        let end = NSRange(location: (logView.text as NSString).length, length: 0)
        logView.scrollRangeToVisible(end)
    }
}
