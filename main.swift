import Cocoa
import Security
import ServiceManagement

// MARK: - API Types

struct UsageWindow: Equatable {
    let utilization: Double
    let remaining: Double?
    let resetsAt: Date?
}

struct UsageData: Equatable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
}

// MARK: - Pure Logic (testable)

func parseToken(from jsonData: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String,
          !token.isEmpty else {
        return nil
    }
    return token
}

private let iso8601Formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func parseResetDate(_ value: Any?) -> Date? {
    guard let str = value as? String else { return nil }
    return iso8601Formatter.date(from: str)
}

func parseUsage(from data: Data) -> UsageData? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let fiveHour = json["five_hour"] as? [String: Any],
          let sevenDay = json["seven_day"] as? [String: Any],
          let h5 = fiveHour["utilization"] as? Double,
          let d7 = sevenDay["utilization"] as? Double else {
        return nil
    }
    return UsageData(
        fiveHour: UsageWindow(utilization: h5, remaining: fiveHour["remaining"] as? Double, resetsAt: parseResetDate(fiveHour["resets_at"])),
        sevenDay: UsageWindow(utilization: d7, remaining: sevenDay["remaining"] as? Double, resetsAt: parseResetDate(sevenDay["resets_at"]))
    )
}

func formatValue(_ val: Double) -> String {
    String(format: val.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", val)
}

func usageIndicator(for pct: Double) -> String {
    if pct >= 80 { return "\u{1F534}" }  // red circle
    if pct >= 50 { return "\u{1F7E1}" }  // yellow circle
    return "\u{1F7E2}"                     // green circle
}

func formatResetTime(_ date: Date?, relativeTo now: Date = Date()) -> String {
    guard let date else { return "" }
    let seconds = date.timeIntervalSince(now)
    if seconds <= 0 { return " (resetting...)" }
    let totalMinutes = Int(seconds) / 60
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 24 {
        let days = hours / 24
        let remainingHours = hours % 24
        if remainingHours == 0 {
            return " (resets in \(days)d)"
        }
        return " (resets in \(days)d \(remainingHours)h)"
    }
    if hours > 0 {
        if minutes == 0 { return " (resets in \(hours)h)" }
        return " (resets in \(hours)h \(minutes)m)"
    }
    return " (resets in \(minutes)m)"
}

func formatStatusLine(_ usage: UsageData) -> String {
    let h5 = usage.fiveHour.utilization
    let d7 = usage.sevenDay.utilization
    let worst = max(h5, d7)
    return "\(usageIndicator(for: worst)) 5h:\(formatValue(h5))%  7d:\(formatValue(d7))%"
}

// MARK: - URLSession (no caching)

private let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 10
    return URLSession(configuration: config)
}()

// MARK: - Status Bar Controller

class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private var isFetching = false
    private var lastRefreshDate: Date?

    private let detailFiveHour = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let detailSevenDay = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lastRefreshItem = NSMenuItem(title: "Last refresh: never", action: nil, keyEquivalent: "")

    override init() {
        super.init()

        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem.button?.title = "CC ..."

        let menu = NSMenu()
        detailFiveHour.isEnabled = false
        detailSevenDay.isEnabled = false
        lastRefreshItem.isEnabled = false

        menu.addItem(detailFiveHour)
        menu.addItem(detailSevenDay)
        menu.addItem(.separator())
        menu.addItem(lastRefreshItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateLastRefreshLabel()
            self?.refresh()
        }
        RunLoop.current.add(timer!, forMode: .common)

        // Refresh immediately after waking from sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Keychain

    private func readToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return parseToken(from: data)
    }

    // MARK: - API

    private func fetchUsage(token: String) {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return }

        isFetching = true

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isFetching = false

                if let error {
                    self.setError(error.localizedDescription)
                    return
                }

                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    if http.statusCode == 401 {
                        self.setError("Token expired")
                        self.detailFiveHour.title = "Re-authenticate in Claude Code"
                        self.detailSevenDay.title = "Then click Refresh Now"
                    } else {
                        self.setError("HTTP \(http.statusCode)")
                    }
                    return
                }

                guard let data, let usage = parseUsage(from: data) else {
                    self.setError("Bad response")
                    return
                }
                self.updateDisplay(usage)
            }
        }.resume()
    }

    // MARK: - Display

    private func updateDisplay(_ usage: UsageData) {
        let h5 = usage.fiveHour.utilization
        let d7 = usage.sevenDay.utilization

        statusItem.button?.title = formatStatusLine(usage)

        detailFiveHour.title = "\(usageIndicator(for: h5))  5-hour window: \(String(format: "%.1f", h5))%\(formatResetTime(usage.fiveHour.resetsAt))"
        detailSevenDay.title = "\(usageIndicator(for: d7))  7-day window:  \(String(format: "%.1f", d7))%\(formatResetTime(usage.sevenDay.resetsAt))"

        lastRefreshDate = Date()
        updateLastRefreshLabel()
    }

    private func updateLastRefreshLabel() {
        guard let date = lastRefreshDate else { return }
        let minutes = Int(Date().timeIntervalSince(date)) / 60
        if minutes < 1 {
            lastRefreshItem.title = "Last refresh: just now"
        } else if minutes == 1 {
            lastRefreshItem.title = "Last refresh: 1 minute ago"
        } else {
            lastRefreshItem.title = "Last refresh: \(minutes) minutes ago"
        }
    }

    private func setError(_ msg: String) {
        statusItem.button?.title = "\u{1F534} CC: [\(msg)]"
        detailFiveHour.title = "Error: \(msg)"
        detailSevenDay.isHidden = true
        lastRefreshItem.title = "Last attempt: failed"
    }

    // MARK: - Actions

    @objc func refresh() {
        guard !isFetching else { return }

        detailSevenDay.isHidden = false

        guard let token = readToken() else {
            setError("No creds")
            detailFiveHour.title = "Cannot read credentials from Keychain"
            detailSevenDay.title = "Ensure Claude Code is signed in"
            detailSevenDay.isHidden = false
            return
        }
        fetchUsage(token: token)
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Main

#if TESTING
runAllTests()
#else
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if SMAppService.mainApp.status != .enabled {
    try? SMAppService.mainApp.register()
}

let controller = StatusBarController()
_ = controller  // prevent premature deallocation
app.run()
#endif
