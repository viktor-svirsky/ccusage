import SwiftUI
import AVFoundation
import WidgetKit

private let appGroupID = "group.com.viktorsvirsky.ccusage"
private let widgetURLKey = "widgetURL"

struct ContentView: View {
    @State private var savedURL: String = ""
    @State private var pasteText: String = ""
    @State private var showScanner = false
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.blue)
                        .padding(.top, 32)

                    VStack(spacing: 8) {
                        Text("CCUsage Widget")
                            .font(.title).fontWeight(.bold)
                        Text("Shows Claude Code usage limits synced from your Mac.")
                            .font(.body).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    // Connection status
                    if !savedURL.isEmpty {
                        VStack(spacing: 8) {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.headline)
                            Text(savedURL)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    // Setup section
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Setup").font(.headline)

                        Button(action: { showScanner = true }) {
                            Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Text("Or paste the URL from your Mac:")
                            .font(.subheadline).foregroundStyle(.secondary)

                        HStack {
                            TextField("https://...", text: $pasteText)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                            Button("Save") {
                                saveURL(pasteText)
                            }
                            .buttonStyle(.bordered)
                            .disabled(pasteText.isEmpty)
                        }

                        if let msg = statusMessage {
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(msg.contains("Error") ? .red : .green)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    // Instructions
                    VStack(alignment: .leading, spacing: 16) {
                        Text("How it works").font(.headline)
                        StepRow(n: 1, text: "Run CCUsage on your Mac")
                        StepRow(n: 2, text: "Click \"Share to iPhone\" in the menu bar")
                        StepRow(n: 3, text: "Scan the QR code or paste the URL")
                        StepRow(n: 4, text: "Add the widget to your Home Screen")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    if !savedURL.isEmpty {
                        Button(role: .destructive) {
                            disconnect()
                        } label: {
                            Text("Disconnect")
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 20)
            }
            .navigationTitle("CCUsage")
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .sheet(isPresented: $showScanner) {
                QRScannerView { code in
                    showScanner = false
                    saveURL(code)
                }
            }
        }
        .onAppear {
            if let defaults = UserDefaults(suiteName: appGroupID) {
                savedURL = defaults.string(forKey: widgetURLKey) ?? ""
            }
        }
    }

    private func saveURL(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme == "https",
              url.host?.hasSuffix(".workers.dev") == true,
              let key = url.path.split(separator: "/").last,
              key.count == 64,
              key.allSatisfy({ $0.isHexDigit }) else {
            statusMessage = "Error: Invalid widget URL"
            return
        }
        if let defaults = UserDefaults(suiteName: appGroupID) {
            defaults.set(trimmed, forKey: widgetURLKey)
            savedURL = trimmed
            pasteText = ""
            statusMessage = "Saved! Widget will update shortly."
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func disconnect() {
        if let defaults = UserDefaults(suiteName: appGroupID) {
            defaults.removeObject(forKey: widgetURLKey)
            savedURL = ""
            statusMessage = nil
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

// MARK: - QR Scanner

struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let vc = QRScannerController()
        vc.onScan = onScan
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {}
}

class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var didScan = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            dismiss(animated: true)
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !didScan,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = obj.stringValue else { return }
        didScan = true
        session.stopRunning()
        onScan?(value)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }
}

// MARK: - Step Row

private struct StepRow: View {
    let n: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.caption).fontWeight(.bold)
                .frame(width: 24, height: 24)
                .background(Color.blue)
                .foregroundStyle(.white)
                .clipShape(Circle())
            Text(text)
                .font(.subheadline)
            Spacer()
        }
    }
}
