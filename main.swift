import Cocoa
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

// MARK: - Version Comparison

let currentVersion: String = {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0.0.0-dev"
}()

let updateRepoOwner = "viktor-svirsky"
let updateRepoName = "ccusage"

func isNewerVersion(_ remote: String, than local: String) -> Bool {
    // Strip "v" prefix and any pre-release suffix (e.g., "1.0.0-dev" → "1.0.0")
    func normalize(_ v: String) -> [Int] {
        let stripped = v.hasPrefix("v") ? String(v.dropFirst()) : v
        return stripped.split(separator: ".").map { segment in
            // Take only the numeric prefix of each segment ("0-dev" → 0)
            let digits = segment.prefix(while: { $0.isNumber })
            return Int(digits) ?? 0
        }
    }
    let rParts = normalize(remote)
    let lParts = normalize(local)
    for i in 0..<max(rParts.count, lParts.count) {
        let rv = i < rParts.count ? rParts[i] : 0
        let lv = i < lParts.count ? lParts[i] : 0
        if rv != lv { return rv > lv }
    }
    // Numeric parts equal — pre-release (contains "-") is older than release
    let rHasPre = remote.contains("-")
    let lHasPre = local.contains("-")
    if rHasPre != lHasPre { return lHasPre }
    return false
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
    private var uiTimer: Timer?
    private var fetchTimer: Timer?
    private var isFetching = false
    private var lastRefreshDate: Date?
    private var rateLimitedUntil: Date?
    private var lastUsage: UsageData?
    private static let fetchInterval: TimeInterval = 3600  // 1 hour (API rate limit is ~1 req/hour)

    private let detailFiveHour = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let detailSevenDay = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lastRefreshItem = NSMenuItem(title: "Last refresh: never", action: nil, keyEquivalent: "")
    private let versionItem = NSMenuItem(title: "v\(currentVersion)", action: nil, keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "u")
    private var isUpdating = false
    private var updateTimer: Timer?

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
        versionItem.isEnabled = false
        updateItem.action = #selector(checkForUpdates)
        menu.addItem(versionItem)
        menu.addItem(updateItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu

        refresh()

        // UI timer: update countdowns every 60s (no API call)
        uiTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshUI()
        }
        RunLoop.current.add(uiTimer!, forMode: .common)

        // Fetch timer: poll API every 5 minutes
        fetchTimer = Timer.scheduledTimer(withTimeInterval: Self.fetchInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.current.add(fetchTimer!, forMode: .common)

        // Check for updates every 5 minutes
        checkForUpdates()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.checkForUpdates()
        }
        RunLoop.current.add(updateTimer!, forMode: .common)

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
        uiTimer?.invalidate()
        fetchTimer?.invalidate()
        updateTimer?.invalidate()
    }

    // MARK: - Keychain

    /// Read credentials via the system `security` CLI to avoid per-binary Keychain ACL prompts.
    private func readToken() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            return parseToken(from: data)
        } catch {
            return nil
        }
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
                    } else if http.statusCode == 429 {
                        let retryAfter = (http.value(forHTTPHeaderField: "retry-after").flatMap { Int($0) }) ?? 3600
                        let retryDate = Date().addingTimeInterval(Double(retryAfter))
                        self.rateLimitedUntil = retryDate
                        // Reschedule fetch timer to fire right after rate limit expires
                        self.fetchTimer?.invalidate()
                        self.fetchTimer = Timer.scheduledTimer(withTimeInterval: Double(retryAfter + 5), repeats: false) { [weak self] _ in
                            self?.rateLimitedUntil = nil
                            self?.refresh()
                            // Restore regular interval
                            self?.fetchTimer = Timer.scheduledTimer(withTimeInterval: Self.fetchInterval, repeats: true) { [weak self] _ in
                                self?.refresh()
                            }
                            if let t = self?.fetchTimer { RunLoop.main.add(t, forMode: .common) }
                        }
                        RunLoop.main.add(self.fetchTimer!, forMode: .common)
                        let minutes = (retryAfter + 59) / 60
                        if self.lastUsage == nil {
                            self.setError("Rate limited")
                        }
                        self.detailFiveHour.title = self.lastUsage != nil
                            ? "\(usageIndicator(for: self.lastUsage!.fiveHour.utilization))  5-hour window: \(String(format: "%.1f", self.lastUsage!.fiveHour.utilization))%\(formatResetTime(self.lastUsage!.fiveHour.resetsAt))"
                            : "API rate limited — retrying in \(minutes)m"
                        self.lastRefreshItem.title = "Next API call in \(minutes)m (rate limited)"
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
        lastUsage = usage
        lastRefreshDate = Date()
        refreshUI()
    }

    /// Re-render UI from cached data (no API call). Called every 60s.
    private func refreshUI() {
        guard let usage = lastUsage else {
            updateLastRefreshLabel()
            return
        }
        let h5 = usage.fiveHour.utilization
        let d7 = usage.sevenDay.utilization

        statusItem.button?.title = formatStatusLine(usage)

        detailFiveHour.title = "\(usageIndicator(for: h5))  5-hour window: \(String(format: "%.1f", h5))%\(formatResetTime(usage.fiveHour.resetsAt))"
        detailSevenDay.title = "\(usageIndicator(for: d7))  7-day window:  \(String(format: "%.1f", d7))%\(formatResetTime(usage.sevenDay.resetsAt))"

        updateLastRefreshLabel()
    }

    private func updateLastRefreshLabel() {
        if let rateLimitedUntil, Date() < rateLimitedUntil {
            let remaining = Int(rateLimitedUntil.timeIntervalSinceNow) / 60 + 1
            lastRefreshItem.title = "Next API call in \(remaining)m (rate limited)"
            return
        }
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
        guard rateLimitedUntil == nil || Date() >= rateLimitedUntil! else { return }

        rateLimitedUntil = nil
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

    // MARK: - Auto-Update

    private var isCheckingForUpdates = false

    @objc func checkForUpdates() {
        guard !isUpdating, !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        let url = URL(string: "https://api.github.com/repos/\(updateRepoOwner)/\(updateRepoName)/releases/latest")!
        session.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isCheckingForUpdates = false
                guard let self, let data,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String else {
                    return
                }
                if isNewerVersion(tagName, than: currentVersion) {
                    self.updateItem.title = "Update available: \(tagName)"
                    self.updateItem.action = #selector(self.installUpdate)
                    // Find the zip asset URL
                    if let assets = json["assets"] as? [[String: Any]],
                       let zipAsset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                       let downloadURL = zipAsset["browser_download_url"] as? String {
                        self.updateItem.representedObject = downloadURL
                    }
                } else {
                    self.updateItem.title = "Up to date"
                    self.updateItem.action = #selector(self.checkForUpdates)
                }
            }
        }.resume()
    }

    @objc func installUpdate() {
        guard let downloadURLString = updateItem.representedObject as? String,
              let downloadURL = URL(string: downloadURLString) else { return }

        isUpdating = true
        updateItem.title = "Downloading update…"
        updateItem.action = nil

        let task = URLSession.shared.downloadTask(with: downloadURL) { [weak self] tempURL, response, error in
            // Do file I/O on background queue to avoid blocking main thread
            guard let tempURL, error == nil else {
                DispatchQueue.main.async {
                    self?.isUpdating = false
                    self?.updateItem.title = "Update failed"
                    self?.updateItem.action = #selector(self?.checkForUpdates)
                }
                return
            }

            let appBundle = Bundle.main.bundlePath
            let fm = FileManager.default
            let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)

            do {
                // Unzip to temp directory
                try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let unzipProcess = Process()
                unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzipProcess.arguments = ["-x", "-k", tempURL.path, tempDir.path]
                try unzipProcess.run()
                unzipProcess.waitUntilExit()
                guard unzipProcess.terminationStatus == 0 else { throw NSError(domain: "CCUsage", code: 1) }

                // Find .app in extracted contents
                let contents = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
                guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
                    throw NSError(domain: "CCUsage", code: 2)
                }

                // Verify the downloaded app has the expected bundle ID
                guard let newBundle = Bundle(url: newApp),
                      newBundle.bundleIdentifier == "com.local.CCUsage" else {
                    throw NSError(domain: "CCUsage", code: 3, userInfo: [NSLocalizedDescriptionKey: "Bundle ID mismatch"])
                }

                // Replace current app (with rollback on failure)
                let backup = URL(fileURLWithPath: appBundle + ".backup")
                try? fm.removeItem(at: backup)
                try fm.moveItem(atPath: appBundle, toPath: backup.path)
                do {
                    try fm.moveItem(at: newApp, to: URL(fileURLWithPath: appBundle))
                } catch {
                    // Restore backup if replacing fails
                    try? fm.moveItem(at: backup, to: URL(fileURLWithPath: appBundle))
                    throw error
                }
                try? fm.removeItem(at: backup)
                try? fm.removeItem(at: tempDir)

                // Relaunch
                DispatchQueue.main.async {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    proc.arguments = ["-n", appBundle]
                    try? proc.run()
                    NSApplication.shared.terminate(nil)
                }
            } catch {
                try? fm.removeItem(at: tempDir)
                DispatchQueue.main.async {
                    self?.isUpdating = false
                    self?.updateItem.title = "Update failed: \(error.localizedDescription)"
                    self?.updateItem.action = #selector(self?.checkForUpdates)
                }
            }
        }
        task.resume()
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
