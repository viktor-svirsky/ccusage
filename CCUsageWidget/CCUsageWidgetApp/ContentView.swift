import SwiftUI
import WidgetKit

struct ContentView: View {
    @StateObject private var dataService = DataService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if dataService.isConnected {
                TabView {
                    DashboardView()
                        .tabItem {
                            Label("Dashboard", systemImage: "gauge.with.dots.needle.33percent")
                        }
                    HistoryView()
                        .tabItem {
                            Label("History", systemImage: "chart.bar.fill")
                        }
                    SettingsView()
                        .tabItem {
                            Label("Settings", systemImage: "gearshape.fill")
                        }
                }
                .tint(.blue)
            } else {
                OnboardingView()
            }
        }
        .environmentObject(dataService)
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                dataService.start()
            case .background, .inactive:
                dataService.stop()
            @unknown default:
                break
            }
        }
    }
}

// MARK: - Onboarding

private struct OnboardingView: View {
    @EnvironmentObject var dataService: DataService

    @State private var showScanner = false
    @State private var pasteText = ""
    @State private var statusMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 40)

                // Icon
                ZStack {
                    Circle()
                        .fill(Theme.accentCardBackground)
                        .frame(width: 100, height: 100)
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)
                }

                VStack(spacing: 8) {
                    Text("CCUsage")
                        .font(.largeTitle).fontWeight(.bold)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Monitor your Claude Code usage\nlimits from your iPhone.")
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }

                // Setup card
                GlassCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("GET STARTED")
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundStyle(Theme.textTertiary)

                        Button(action: { showScanner = true }) {
                            Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                                .font(.subheadline).fontWeight(.medium)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
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

                // How it works
                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("HOW IT WORKS")
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundStyle(Theme.textTertiary)

                        OnboardingStep(number: 1, text: "Run CCUsage on your Mac")
                        OnboardingStep(number: 2, text: "Click \"Share to iPhone\" in the menu bar")
                        OnboardingStep(number: 3, text: "Scan the QR code or paste the URL")
                        OnboardingStep(number: 4, text: "Add the widget to your Home Screen")
                    }
                }

                Spacer().frame(height: 20)
            }
            .padding(.horizontal, 20)
        }
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in
                showScanner = false
                handleURL(code)
            }
        }
    }

    private func handleURL(_ urlString: String) {
        if let error = dataService.saveURL(urlString) {
            statusMessage = "Error: \(error)"
        } else {
            pasteText = ""
            statusMessage = "Connected!"
        }
    }
}

// MARK: - Onboarding Step

private struct OnboardingStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption).fontWeight(.bold)
                .frame(width: 24, height: 24)
                .background(Color.blue)
                .foregroundStyle(.white)
                .clipShape(Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
    }
}
