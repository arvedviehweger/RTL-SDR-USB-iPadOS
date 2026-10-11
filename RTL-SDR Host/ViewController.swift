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

    private let hintView       = UIView()
    private let hintLabel      = UILabel()
    private let settingsButton = UIButton(type: .system)
    private let logView        = UITextView()
    private let testButton     = UIButton(type: .system)
    private let serverButton   = UIButton(type: .system)

    private var serverRunning = false

    // The rtl_tcp server logs every client command, and clients with their
    // own AGC send several per second. Keep the log bounded and refresh the
    // view at most every 100 ms so it does not compete with the SDR client
    // for CPU.
    private let maxLogLines = 500
    private var logLines: [String] = []
    private var logFlushPending = false

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "RTL-SDR Host"
        view.backgroundColor = .systemBackground
        setupUI()
        wireServer()
        updateDriverHint()

        // Plugging in or unplugging the RTL-SDR updates the hint right away.
        rtlsdrhost_watch_service { [weak self] in
            MainActor.assumeIsolated { self?.driverServiceChanged() }
        }

        // Coming back from Settings, the driver may have been switched on.
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification,
                                               object: nil)

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
        setupHint()

        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logView.backgroundColor = .secondarySystemBackground
        logView.layer.cornerRadius = 10
        logView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        // The hint sits above the log and takes no space while hidden.
        let content = UIStackView(arrangedSubviews: [hintView, logView])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.axis = .vertical
        content.spacing = 12
        view.addSubview(content)

        styleButton(testButton,   title: "Test connection", color: .systemBlue)
        testButton.addTarget(self, action: #selector(runTest), for: .touchUpInside)
        view.addSubview(testButton)

        styleButton(serverButton, title: "Start rtl_tcp server", color: .systemGreen)
        serverButton.addTarget(self, action: #selector(toggleServer), for: .touchUpInside)
        view.addSubview(serverButton)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),

            serverButton.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 16),
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

    private func setupHint() {
        hintView.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.15)
        hintView.layer.cornerRadius = 10
        hintView.isHidden = true

        hintLabel.numberOfLines = 0
        hintLabel.font = .systemFont(ofSize: 15)
        hintLabel.text = "No RTL-SDR found. Plug it in and make sure its driver is enabled in Settings › Apps › RTL-SDR-Host."

        settingsButton.setTitle("Open Settings", for: .normal)
        settingsButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        settingsButton.setContentHuggingPriority(.required, for: .horizontal)
        settingsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        settingsButton.addTarget(self, action: #selector(openSettings), for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [hintLabel, settingsButton])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        hintView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: hintView.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: hintView.bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: hintView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: hintView.trailingAnchor, constant: -16),
        ])
    }

    /// Shows the hint while the dext's service is missing: no RTL-SDR plugged
    /// in, or its driver disabled in Settings.
    private func updateDriverHint() {
        hintView.isHidden = RTLSDRClient.isServicePresent
    }

    /// The RTL_SDR service appeared or went away. Checks once more a moment
    /// later, in case a service that is shutting down is still listed.
    private func driverServiceChanged() {
        updateDriverHint()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.updateDriverHint()
        }
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
                self.updateDriverHint()
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
            updateDriverHint()
        }
    }

    @objc private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    @objc private func appDidBecomeActive() {
        updateDriverHint()
    }

    // MARK: - Log

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
        guard !logFlushPending else { return }
        logFlushPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.flushLog()
        }
    }

    private func flushLog() {
        logFlushPending = false
        logView.text = logLines.joined(separator: "\n")
        let end = NSRange(location: (logView.text as NSString).length, length: 0)
        logView.scrollRangeToVisible(end)
    }
}
