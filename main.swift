import Cocoa
import ServiceManagement

// MARK: - Constants

private let keychainService = "Claude Code-credentials"
private let usageAPIURL = "https://api.anthropic.com/api/oauth/usage"
private let apiBetaHeader = "oauth-2025-04-20"
let updateRepoOwner = "viktor-svirsky"
let updateRepoName = "ccusage"
private let allowedDownloadHosts: Set<String> = ["github.com", "objects.githubusercontent.com"]
private let maxRetryInterval = 86400  // 1 day
private let minRetryInterval = 60     // 1 minute
let defaultFetchInterval: TimeInterval = 300  // 5 minutes

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
          let d7 = sevenDay["utilization"] as? Double,
          h5 >= 0, h5 <= 100, d7 >= 0, d7 <= 100 else {
        return nil
    }
    return UsageData(
        fiveHour: UsageWindow(utilization: h5, remaining: fiveHour["remaining"] as? Double, resetsAt: parseResetDate(fiveHour["resets_at"])),
        sevenDay: UsageWindow(utilization: d7, remaining: sevenDay["remaining"] as? Double, resetsAt: parseResetDate(sevenDay["resets_at"]))
    )
}

func clampRetryAfter(_ value: Int) -> Int {
    min(max(value, minRetryInterval), maxRetryInterval)
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

struct UpdateInfo: Equatable {
    let tagName: String
    let downloadURL: String?
}

func parseReleaseInfo(from data: Data, currentVersion: String) -> UpdateInfo? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tagName = json["tag_name"] as? String else {
        return nil
    }
    guard isNewerVersion(tagName, than: currentVersion) else {
        return nil
    }
    if let assets = json["assets"] as? [[String: Any]],
       let zipAsset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
       let downloadURL = zipAsset["browser_download_url"] as? String,
       isValidDownloadURL(downloadURL) {
        return UpdateInfo(tagName: tagName, downloadURL: downloadURL)
    }
    return UpdateInfo(tagName: tagName, downloadURL: nil)
}

func isValidDownloadURL(_ urlString: String) -> Bool {
    guard let url = URL(string: urlString),
          url.scheme == "https",
          let host = url.host else {
        return false
    }
    return allowedDownloadHosts.contains(host)
}

// MARK: - Version Comparison

let currentVersion: String = {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0.0.0-dev"
}()

func isNewerVersion(_ remote: String, than local: String) -> Bool {
    // Strip "v" prefix and any pre-release suffix (e.g., "1.0.0-dev" -> "1.0.0")
    func normalize(_ v: String) -> [Int] {
        let stripped = v.hasPrefix("v") ? String(v.dropFirst()) : v
        return stripped.split(separator: ".").map { segment in
            // Take only the numeric prefix of each segment ("0-dev" -> 0)
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

// MARK: - Fetch Schedule State

struct FetchSchedule {
    var interval: TimeInterval = defaultFetchInterval
    var isRateLimited: Bool = false
    var nextFetchAt: Date = .distantPast

    mutating func onSuccess() {
        isRateLimited = false
        interval = defaultFetchInterval
        nextFetchAt = Date().addingTimeInterval(interval)
    }

    mutating func onRateLimit(retryAfter: Int) {
        let clamped = clampRetryAfter(retryAfter)
        interval = Double(clamped)
        nextFetchAt = Date().addingTimeInterval(interval)
        isRateLimited = true
    }
}

// MARK: - Status Bar Controller

class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var uiTimer: Timer?
    private var isFetching = false
    private var lastRefreshDate: Date?
    private var lastUsage: UsageData?
    private var schedule = FetchSchedule()

    private let detailFiveHour = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let detailSevenDay = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lastRefreshItem = NSMenuItem(title: "Last refresh: never", action: nil, keyEquivalent: "")
    private let versionItem = NSMenuItem(title: "v\(currentVersion)", action: nil, keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "Check for Updates\u{2026}", action: nil, keyEquivalent: "u")
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

        // Single 60s timer: updates UI countdowns + triggers fetch when nextFetchAt arrives
        uiTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.current.add(uiTimer!, forMode: .common)

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
        updateTimer?.invalidate()
    }

    /// Called every 60s. Refreshes UI and triggers API fetch when due.
    private func tick() {
        refreshUI()
        if Date() >= schedule.nextFetchAt {
            refresh()
        }
    }

    // MARK: - Keychain

    /// Read credentials via the system `security` CLI to avoid per-binary Keychain ACL prompts.
    private func readToken() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", keychainService, "-w"]
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
        guard let url = URL(string: usageAPIURL) else { return }

        isFetching = true

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(apiBetaHeader, forHTTPHeaderField: "anthropic-beta")

        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isFetching = false

                if error != nil {
                    self.setError("Connection failed")
                    return
                }

                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    if http.statusCode == 401 {
                        self.setError("Token expired")
                        self.detailFiveHour.title = "Re-authenticate in Claude Code"
                        self.detailSevenDay.title = "Then click Refresh Now"
                    } else if http.statusCode == 429 {
                        let raw = http.value(forHTTPHeaderField: "retry-after").flatMap { Int($0) } ?? Int(defaultFetchInterval)
                        let retryAfter = clampRetryAfter(raw)
                        self.schedule.onRateLimit(retryAfter: raw)
                        let minutes = (retryAfter + 59) / 60
                        if self.lastUsage == nil {
                            self.setError("Rate limited")
                        }
                        self.lastRefreshItem.title = "Next API call in \(minutes)m (rate limited)"
                    } else {
                        self.setError("Server error")
                    }
                    return
                }

                guard let data, let usage = parseUsage(from: data) else {
                    self.setError("Unexpected response")
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
        schedule.onSuccess()
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

        detailFiveHour.title = "\(usageIndicator(for: h5))  5-hour window: \(formatValue(h5))%\(formatResetTime(usage.fiveHour.resetsAt))"
        detailSevenDay.title = "\(usageIndicator(for: d7))  7-day window:  \(formatValue(d7))%\(formatResetTime(usage.sevenDay.resetsAt))"

        updateLastRefreshLabel()
    }

    private func updateLastRefreshLabel() {
        if schedule.isRateLimited {
            let waitRemaining = schedule.nextFetchAt.timeIntervalSinceNow
            let remaining = max(Int(waitRemaining) / 60 + 1, 1)
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
        guard let url = URL(string: "https://api.github.com/repos/\(updateRepoOwner)/\(updateRepoName)/releases/latest") else {
            isCheckingForUpdates = false
            return
        }
        var request = URLRequest(url: url)
        request.setValue("CCUsage/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isCheckingForUpdates = false
                guard let self, let data,
                      let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    return
                }
                if let info = parseReleaseInfo(from: data, currentVersion: currentVersion) {
                    if let downloadURL = info.downloadURL {
                        self.updateItem.title = "Update available: \(info.tagName)"
                        self.updateItem.action = #selector(self.installUpdate)
                        self.updateItem.representedObject = downloadURL
                    } else {
                        self.updateItem.title = "Update \(info.tagName) available on GitHub"
                        self.updateItem.action = nil
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
              isValidDownloadURL(downloadURLString),
              let downloadURL = URL(string: downloadURLString) else {
            updateItem.title = "Invalid download URL"
            return
        }

        isUpdating = true
        updateItem.title = "Downloading update\u{2026}"
        updateItem.action = nil

        let task = URLSession.shared.downloadTask(with: downloadURL) { [weak self] tempURL, response, error in
            guard let tempURL, error == nil else {
                DispatchQueue.main.async {
                    self?.isUpdating = false
                    self?.updateItem.title = "Download failed"
                    self?.updateItem.action = #selector(self?.checkForUpdates)
                }
                return
            }

            let appBundle = Bundle.main.bundlePath
            let fm = FileManager.default
            let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)

            do {
                // Create temp directory with restricted permissions
                try fm.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

                // Unzip to temp directory with timeout
                let unzipProcess = Process()
                unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzipProcess.arguments = ["-x", "-k", tempURL.path, tempDir.path]
                try unzipProcess.run()
                let deadline = Date().addingTimeInterval(30)
                while unzipProcess.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if unzipProcess.isRunning {
                    unzipProcess.terminate()
                    throw NSError(domain: "CCUsage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unzip timed out"])
                }
                guard unzipProcess.terminationStatus == 0 else {
                    throw NSError(domain: "CCUsage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unzip failed"])
                }

                // Find .app in extracted contents
                let contents = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
                guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
                    throw NSError(domain: "CCUsage", code: 2, userInfo: [NSLocalizedDescriptionKey: "No app in archive"])
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
                    self?.updateItem.title = "Update failed"
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
