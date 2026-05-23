//
//  ViewController.swift
//  RTL-SDR Host
//
//  Created by Arved Viehweger on 20.05.26.
//
//  Minimal test UI: one button runs RTLSDRClient.runConnectionTest(), which
//  opens the dext's user client, configures the device, streams for one
//  second and reports whether IQ data arrived in the shared ring buffer.
//

import UIKit

class ViewController: UIViewController {

    private let driverExtensionIdentifier = "com.m0kds.RTL-SDR-Host.driver"

    private let client = RTLSDRClient()
    private let logView = UITextView()
    private let testButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "RTL-SDR Host"
        view.backgroundColor = .systemBackground
        setupUI()

        print("RTL-SDR Host started")
        print("Bundled driver extension identifier: \(driverExtensionIdentifier)")

        appendLog("RTL-SDR Host bereit.")
        appendLog("Driver Extension: \(driverExtensionIdentifier)")
        appendLog("")
        appendLog("RTL-SDR anstecken, dann Verbindung testen tippen.")
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

        testButton.translatesAutoresizingMaskIntoConstraints = false
        testButton.setTitle("Verbindung testen", for: .normal)
        testButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        testButton.backgroundColor = .systemBlue
        testButton.setTitleColor(.white, for: .normal)
        testButton.setTitleColor(UIColor.white.withAlphaComponent(0.5), for: .disabled)
        testButton.layer.cornerRadius = 12
        testButton.addTarget(self, action: #selector(runTest), for: .touchUpInside)
        view.addSubview(testButton)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            logView.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            logView.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            logView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),

            testButton.topAnchor.constraint(equalTo: logView.bottomAnchor, constant: 16),
            testButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            testButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            testButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
            testButton.heightAnchor.constraint(equalToConstant: 54),
        ])
    }

    // MARK: - Test run

    @objc private func runTest() {
        setButton(enabled: false)
        appendLog("")
        appendLog("──────── Test gestartet ────────")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.client.runConnectionTest { line in
                DispatchQueue.main.async { self.appendLog(line) }
            }
            DispatchQueue.main.async { self.setButton(enabled: true) }
        }
    }

    private func setButton(enabled: Bool) {
        testButton.isEnabled = enabled
        testButton.alpha = enabled ? 1.0 : 0.5
    }

    private func appendLog(_ line: String) {
        let current = logView.text ?? ""
        logView.text = current.isEmpty ? line : current + "\n" + line
        let end = NSRange(location: (logView.text as NSString).length, length: 0)
        logView.scrollRangeToVisible(end)
    }
}
