import SwiftUI
import AVFoundation
import WidgetKit

struct SettingsView: View {
    @EnvironmentObject var dataService: DataService

    @State private var showScanner = false
    @State private var pasteText = ""
    @State private var statusMessage: String?
    @State private var highUsage: Bool = NotificationService.shared.highUsageEnabled
    @State private var critical: Bool = NotificationService.shared.criticalEnabled
    @State private var depletion: Bool = NotificationService.shared.depletionEnabled
    @State private var pace: Bool = NotificationService.shared.paceEnabled
    @State private var windowReset: Bool = NotificationService.shared.windowResetEnabled

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                connectionSection
                notificationsSection
                aboutSection
                if dataService.isConnected {
                    disconnectButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in
                showScanner = false
                handleURL(code)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Connection

    private var connectionSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text("CONNECTION")
                        .font(.caption2).fontWeight(.semibold)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    if dataService.isConnected {
                        HStack(spacing: 4) {
                            Circle().fill(Theme.green).frame(width: 8, height: 8)
                            Text("Connected")
                                .font(.caption2)
                                .foregroundStyle(Theme.green)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Circle().fill(Theme.textTertiary).frame(width: 8, height: 8)
                            Text("Not connected")
                                .font(.caption2)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }

                if let url = dataService.widgetURL, !url.isEmpty {
                    Text(url)
                        .font(.caption2)
                        .foregroundStyle(Theme.textQuaternary)
                        .lineLimit(2)
                }

                Button(action: { showScanner = true }) {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        .font(.subheadline).fontWeight(.medium)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Text("Or paste the URL from your Mac:")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                HStack(spacing: 8) {
                    TextField("https://...", text: $pasteText)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(10)
                        .background(Theme.accentCardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.accentCardBorder, lineWidth: 1)
                        )
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)

                    Button("Save") {
                        handleURL(pasteText)
                    }
                    .font(.subheadline).fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(pasteText.isEmpty ? Color.blue.opacity(0.4) : Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .disabled(pasteText.isEmpty)
                }

                if let msg = statusMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(msg.contains("Error") ? Theme.red : Theme.green)
                }
            }
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("NOTIFICATIONS")
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundStyle(Theme.textTertiary)

                notificationToggle(
                    label: "High Usage (80%)",
                    icon: "exclamationmark.circle",
                    isOn: $highUsage
                ) { newVal in
                    if newVal {
                        NotificationService.shared.requestPermission { granted in
                            if granted {
                                NotificationService.shared.highUsageEnabled = true
                            } else {
                                highUsage = false
                            }
                        }
                    } else {
                        NotificationService.shared.highUsageEnabled = false
                    }
                }

                Divider().overlay(Theme.cardBorder)

                notificationToggle(
                    label: "Critical (95%)",
                    icon: "exclamationmark.triangle",
                    isOn: $critical
                ) { newVal in
                    if newVal {
                        NotificationService.shared.requestPermission { granted in
                            if granted {
                                NotificationService.shared.criticalEnabled = true
                            } else {
                                critical = false
                            }
                        }
                    } else {
                        NotificationService.shared.criticalEnabled = false
                    }
                }

                Divider().overlay(Theme.cardBorder)

                notificationToggle(
                    label: "Depletion",
                    icon: "battery.0percent",
                    isOn: $depletion
                ) { newVal in
                    if newVal {
                        NotificationService.shared.requestPermission { granted in
                            if granted {
                                NotificationService.shared.depletionEnabled = true
                            } else {
                                depletion = false
                            }
                        }
                    } else {
                        NotificationService.shared.depletionEnabled = false
                    }
                }

                Divider().overlay(Theme.cardBorder)

                notificationToggle(
                    label: "Over Pace (>1.2x)",
                    icon: "speedometer",
                    isOn: $pace
                ) { newVal in
                    if newVal {
                        NotificationService.shared.requestPermission { granted in
                            if granted {
                                NotificationService.shared.paceEnabled = true
                            } else {
                                pace = false
                            }
                        }
                    } else {
                        NotificationService.shared.paceEnabled = false
                    }
                }

                Divider().overlay(Theme.cardBorder)

                notificationToggle(
                    label: "Window Reset",
                    icon: "arrow.clockwise.circle",
                    isOn: $windowReset
                ) { newVal in
                    if newVal {
                        NotificationService.shared.requestPermission { granted in
                            if granted {
                                NotificationService.shared.windowResetEnabled = true
                            } else {
                                windowReset = false
                            }
                        }
                    } else {
                        NotificationService.shared.windowResetEnabled = false
                    }
                }
            }
        }
    }

    private func notificationToggle(label: String, icon: String, isOn: Binding<Bool>, onChange: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 20)
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .tint(Theme.green)
        .onChange(of: isOn.wrappedValue) { _, newValue in
            onChange(newValue)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("ABOUT")
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundStyle(Theme.textTertiary)

                aboutRow(label: "Widget Refresh", value: "2 minutes")
                Divider().overlay(Theme.cardBorder)
                aboutRow(label: "App Refresh", value: "2 minutes")
                Divider().overlay(Theme.cardBorder)
                aboutRow(label: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            }
        }
    }

    private func aboutRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Disconnect

    private var disconnectButton: some View {
        Button(action: { dataService.disconnect() }) {
            Text("Disconnect")
                .font(.subheadline).fontWeight(.medium)
                .foregroundStyle(Theme.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.red.opacity(0.2), lineWidth: 1)
                )
        }
    }

    // MARK: - Helpers

    private func handleURL(_ urlString: String) {
        if let error = dataService.saveURL(urlString) {
            statusMessage = "Error: \(error)"
        } else {
            pasteText = ""
            statusMessage = "Saved! Widget will update shortly."
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
