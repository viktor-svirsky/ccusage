import Cocoa
import ServiceManagement
import UserNotifications

// MARK: - Constants

private let keychainService = "Claude Code-credentials"
private let usageAPIURL = "https://api.anthropic.com/api/oauth/usage"
private let apiBetaHeader = "oauth-2025-04-20"
private let oauthTokenURL = "https://platform.claude.com/v1/oauth/token"
private let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
private let oauthScopes = "user:profile user:inference"
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

// MARK: - Usage Zones & Notifications

enum UsageZone: Int, Comparable, Equatable {
    case green = 0
    case yellow = 1
    case red = 2
    case depleted = 3

    static func < (lhs: UsageZone, rhs: UsageZone) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

func zoneFor(utilization: Double) -> UsageZone {
    if utilization >= 100 { return .depleted }
    if utilization >= 80 { return .red }
    if utilization >= 50 { return .yellow }
    return .green
}

struct NotificationState: Equatable {
    var fiveHourZone: UsageZone = .green
    var sevenDayZone: UsageZone = .green
    var fiveHourPaceAlerted: Bool = false
    var sevenDayPaceAlerted: Bool = false
}

enum UsageNotification: Equatable {
    case zoneTransition(window: String, zone: UsageZone, utilization: Double)
    case depleted(window: String)
    case paceOverBudget(window: String, pace: Double)

    var identifier: String {
        switch self {
        case .zoneTransition(let window, let zone, _):
            return "zone-\(window)-\(zone)"
        case .depleted(let window):
            return "depleted-\(window)"
        case .paceOverBudget(let window, _):
            return "pace-\(window)"
        }
    }
}

func determineNotifications(
    oldState: NotificationState,
    newUsage: UsageData,
    fiveHourPace: Double?,
    sevenDayPace: Double?
) -> ([UsageNotification], NotificationState) {
    var notifications: [UsageNotification] = []
    var newState = oldState

    let h5Zone = zoneFor(utilization: newUsage.fiveHour.utilization)
    let d7Zone = zoneFor(utilization: newUsage.sevenDay.utilization)

    newState.fiveHourZone = h5Zone
    newState.sevenDayZone = d7Zone

    // Reset pace tracking when dropping to green or leaving depleted
    if h5Zone == .green || (oldState.fiveHourZone == .depleted && h5Zone != .depleted) {
        newState.fiveHourPaceAlerted = false
    }
    if d7Zone == .green || (oldState.sevenDayZone == .depleted && d7Zone != .depleted) {
        newState.sevenDayPaceAlerted = false
    }

    // 5-hour zone transitions (upward only)
    if h5Zone > oldState.fiveHourZone {
        if h5Zone == .depleted {
            notifications.append(.depleted(window: "5-hour"))
        } else {
            notifications.append(.zoneTransition(window: "5-hour", zone: h5Zone, utilization: newUsage.fiveHour.utilization))
        }
    }

    // 7-day zone transitions (upward only)
    if d7Zone > oldState.sevenDayZone {
        if d7Zone == .depleted {
            notifications.append(.depleted(window: "7-day"))
        } else {
            notifications.append(.zoneTransition(window: "7-day", zone: d7Zone, utilization: newUsage.sevenDay.utilization))
        }
    }

    // Pace alerts (suppressed when depleted)
    if h5Zone != .depleted {
        if let pace = fiveHourPace, pace > 1.2 {
            if !newState.fiveHourPaceAlerted {
                notifications.append(.paceOverBudget(window: "5-hour", pace: pace))
                newState.fiveHourPaceAlerted = true
            }
        } else {
            newState.fiveHourPaceAlerted = false
        }
    }

    if d7Zone != .depleted {
        if let pace = sevenDayPace, pace > 1.2 {
            if !newState.sevenDayPaceAlerted {
                notifications.append(.paceOverBudget(window: "7-day", pace: pace))
                newState.sevenDayPaceAlerted = true
            }
        } else {
            newState.sevenDayPaceAlerted = false
        }
    }

    return (notifications, newState)
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

func parseRefreshToken(from jsonData: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any],
          let token = oauth["refreshToken"] as? String,
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

// MARK: - Usage History

struct UsageHistory {
    struct Entry {
        let date: Date
        let fiveHour: Double
        let sevenDay: Double
    }

    private(set) var entries: [Entry] = []
    private let maxEntries = 24  // ~2 hours at 5-min intervals

    mutating func record(_ usage: UsageData) {
        entries.append(Entry(date: Date(), fiveHour: usage.fiveHour.utilization, sevenDay: usage.sevenDay.utilization))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func trend(for keyPath: KeyPath<Entry, Double>) -> Character {
        guard entries.count >= 6 else { return "→" }
        let recent = entries.suffix(3).map { $0[keyPath: keyPath] }
        let avg = recent.reduce(0, +) / Double(recent.count)
        let prev = entries[entries.count - 6][keyPath: keyPath]
        let diff = avg - prev
        if diff > 2 { return "↑" }
        if diff < -2 { return "↓" }
        return "→"
    }

    func sparkline(for keyPath: KeyPath<Entry, Double>, width: Int = 12) -> String {
        let blocks: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        guard !entries.isEmpty else { return "" }
        let values = entries.suffix(width).map { $0[keyPath: keyPath] }
        let minVal = values.min() ?? 0
        let maxVal = values.max() ?? 100
        let range = maxVal - minVal
        return String(values.map { val in
            if range < 0.001 { return blocks[0] }
            let normalized = (val - minVal) / range
            let index = Int(normalized * Double(blocks.count - 1))
            return blocks[min(max(index, 0), blocks.count - 1)]
        })
    }
}

// MARK: - Pacing

func calculatePace(utilization: Double, resetsAt: Date?, windowDuration: TimeInterval, now: Date = Date()) -> Double? {
    guard let resetsAt else { return nil }
    let remaining = resetsAt.timeIntervalSince(now)
    guard remaining > 0, remaining < windowDuration else { return nil }
    let elapsed = windowDuration - remaining
    let expectedUtilization = (elapsed / windowDuration) * 100.0
    guard expectedUtilization > 1 else { return nil }
    return utilization / expectedUtilization
}

func paceLabel(_ pace: Double) -> String {
    if pace > 1.2 { return String(format: "▲ %.1fx pace (over budget)", pace) }
    if pace < 0.8 { return String(format: "▼ %.1fx pace (under budget)", pace) }
    return String(format: "● %.1fx pace (on track)", pace)
}

func formatStatusLine(_ usage: UsageData, history: UsageHistory = UsageHistory()) -> String {
    let h5 = usage.fiveHour.utilization
    let d7 = usage.sevenDay.utilization
    let h5Trend = history.trend(for: \.fiveHour)
    let d7Trend = history.trend(for: \.sevenDay)
    return "\(usageIndicator(for: h5))\(h5Trend)5h:\(formatValue(h5))%  \(usageIndicator(for: d7))\(d7Trend)7d:\(formatValue(d7))%"
}

#if !TESTING
func requestNotificationPermission() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
}

func deliverNotification(_ notification: UsageNotification) {
    let content = UNMutableNotificationContent()

    switch notification {
    case .zoneTransition(let window, let zone, let utilization):
        let severity = zone == .red ? "Critical" : "Warning"
        content.title = "CCUsage: \(window) \(severity)"
        content.body = "\(window) window is at \(formatValue(utilization))% utilization"
    case .depleted(let window):
        content.title = "CCUsage: \(window) Depleted"
        content.body = "\(window) window has reached 100% — usage limit hit"
    case .paceOverBudget(let window, let pace):
        content.title = "CCUsage: \(window) Over Budget"
        content.body = "\(window) window is at \(String(format: "%.1f", pace))x pace — usage rate exceeds budget"
    }

    content.sound = .default

    let request = UNNotificationRequest(
        identifier: notification.identifier,
        content: content,
        trigger: nil
    )
    UNUserNotificationCenter.current().add(request)
}

func usageColor(for pct: Double) -> NSColor {
    if pct >= 80 { return NSColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1.0) }
    if pct >= 50 { return NSColor(red: 0.85, green: 0.65, blue: 0.0, alpha: 1.0) }
    return NSColor.labelColor
}

func formatAttributedStatusLine(_ usage: UsageData, history: UsageHistory = UsageHistory()) -> NSAttributedString {
    let h5 = usage.fiveHour.utilization
    let d7 = usage.sevenDay.utilization
    let h5Trend = String(history.trend(for: \.fiveHour))
    let d7Trend = String(history.trend(for: \.sevenDay))

    let baseFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    let boldFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
    let base: [NSAttributedString.Key: Any] = [.font: baseFont]
    let dimmed: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: NSColor.secondaryLabelColor]

    func boldColored(_ pct: Double) -> [NSAttributedString.Key: Any] {
        [.font: boldFont, .foregroundColor: usageColor(for: pct)]
    }

    let result = NSMutableAttributedString()
    result.append(NSAttributedString(string: "\(usageIndicator(for: h5))", attributes: base))
    result.append(NSAttributedString(string: h5Trend, attributes: dimmed))
    result.append(NSAttributedString(string: "5h:", attributes: base))
    result.append(NSAttributedString(string: "\(formatValue(h5))%", attributes: boldColored(h5)))
    result.append(NSAttributedString(string: "  \(usageIndicator(for: d7))", attributes: base))
    result.append(NSAttributedString(string: d7Trend, attributes: dimmed))
    result.append(NSAttributedString(string: "7d:", attributes: base))
    result.append(NSAttributedString(string: "\(formatValue(d7))%", attributes: boldColored(d7)))
    return result
}

func progressBar(percent: Double, width: Int = 20) -> String {
    let filled = Int((percent / 100.0) * Double(width))
    let empty = width - filled
    return String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: empty)
}

func paceColor(_ pace: Double) -> NSColor {
    if pace > 1.2 { return NSColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1.0) }
    if pace < 0.8 { return NSColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1.0) }
    return NSColor.secondaryLabelColor
}

func formatAttributedMenuItem(label: String, window: UsageWindow, subtitle: String = "", subtitleColor: NSColor? = nil) -> NSAttributedString {
    let pct = window.utilization
    let remaining = window.remaining.map { formatValue($0) } ?? formatValue(100.0 - pct)
    let resetStr = formatResetTime(window.resetsAt)

    let regular = NSFont.menuFont(ofSize: 13)
    let mono = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    let base: [NSAttributedString.Key: Any] = [.font: regular]
    let barAttrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: usageColor(for: pct)]

    let result = NSMutableAttributedString()
    result.append(NSAttributedString(string: "\(label): \(formatValue(pct))%", attributes: base))
    result.append(NSAttributedString(string: "  \u{2022} \(remaining)% free", attributes: [.font: regular, .foregroundColor: NSColor.secondaryLabelColor]))
    result.append(NSAttributedString(string: resetStr, attributes: [.font: regular, .foregroundColor: NSColor.tertiaryLabelColor]))
    result.append(NSAttributedString(string: "\n    \(progressBar(percent: pct))", attributes: barAttrs))
    if !subtitle.isEmpty {
        let color = subtitleColor ?? usageColor(for: pct)
        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: color
        ]
        result.append(NSAttributedString(string: "\n    \(subtitle)", attributes: subtitleAttrs))
    }
    return result
}
#endif

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
    private(set) var consecutiveRateLimits: Int = 0

    mutating func onSuccess() {
        isRateLimited = false
        consecutiveRateLimits = 0
        interval = defaultFetchInterval
        nextFetchAt = Date().addingTimeInterval(interval)
    }

    mutating func onRateLimit(retryAfter: Int) {
        consecutiveRateLimits += 1
        let clamped = Double(clampRetryAfter(retryAfter))
        // Exponential backoff: 60s, 120s, 240s, capped at defaultFetchInterval (300s)
        let backoff = min(clamped * pow(2.0, Double(consecutiveRateLimits - 1)), defaultFetchInterval)
        interval = backoff
        nextFetchAt = Date().addingTimeInterval(interval)
        isRateLimited = true
    }
}

// MARK: - Status Bar Controller

class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var uiTimer: Timer?
    private var isFetching = false
    private var didRetryWithRefresh = false
    private var lastRefreshDate: Date?
    private var lastUsage: UsageData?
    private var schedule = FetchSchedule()
    private var history = UsageHistory()
    private var notificationState = NotificationState()

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

        #if !TESTING
        requestNotificationPermission()
        #endif

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

    /// Read raw credential data via the system `security` CLI to avoid per-binary Keychain ACL prompts.
    private func readKeychainData() -> Data? {
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
            return data
        } catch {
            return nil
        }
    }

    private func readToken() -> String? {
        guard let data = readKeychainData() else { return nil }
        return parseToken(from: data)
    }

    private func readRefreshToken() -> String? {
        guard let data = readKeychainData() else { return nil }
        return parseRefreshToken(from: data)
    }

    /// Write updated credentials back to the keychain.
    private func writeKeychainData(_ data: Data) -> Bool {
        guard let jsonStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        // Delete existing entry, then add new one
        let del = Process()
        del.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        del.arguments = ["delete-generic-password", "-s", keychainService]
        del.standardOutput = FileHandle.nullDevice
        del.standardError = FileHandle.nullDevice
        try? del.run()
        del.waitUntilExit()

        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        add.arguments = ["add-generic-password", "-s", keychainService, "-w", jsonStr]
        add.standardOutput = FileHandle.nullDevice
        add.standardError = FileHandle.nullDevice
        do {
            try add.run()
            add.waitUntilExit()
            return add.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Refresh the OAuth token and update the keychain. Returns the new access token on success.
    private func refreshOAuthToken(completion: @escaping (String?) -> Void) {
        guard let refreshToken = readRefreshToken(),
              let url = URL(string: oauthTokenURL) else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauthClientID,
            "scope": oauthScopes
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: request) { [weak self] data, response, _ in
            guard let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccessToken = json["access_token"] as? String,
                  !newAccessToken.isEmpty else {
                completion(nil)
                return
            }

            // Update keychain with new tokens
            DispatchQueue.main.async {
                guard let self, let keychainData = self.readKeychainData(),
                      var creds = try? JSONSerialization.jsonObject(with: keychainData) as? [String: Any],
                      var oauth = creds["claudeAiOauth"] as? [String: Any] else {
                    completion(newAccessToken)  // Still return token even if keychain update fails
                    return
                }
                oauth["accessToken"] = newAccessToken
                if let newRefresh = json["refresh_token"] as? String, !newRefresh.isEmpty {
                    oauth["refreshToken"] = newRefresh
                }
                if let expiresIn = json["expires_in"] as? Int {
                    oauth["expiresAt"] = Int(Date().timeIntervalSince1970 * 1000) + expiresIn * 1000
                }
                creds["claudeAiOauth"] = oauth
                if let updatedData = try? JSONSerialization.data(withJSONObject: creds) {
                    _ = self.writeKeychainData(updatedData)
                }
                completion(newAccessToken)
            }
        }.resume()
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
                        // Rate limit is per-access-token; refresh to get a new one
                        if !self.didRetryWithRefresh {
                            self.didRetryWithRefresh = true
                            self.lastRefreshItem.title = "Refreshing token..."
                            self.refreshOAuthToken { [weak self] newToken in
                                guard let self, let newToken else {
                                    self?.handleRateLimit(raw: http.value(forHTTPHeaderField: "retry-after").flatMap { Int($0) } ?? Int(defaultFetchInterval))
                                    self?.didRetryWithRefresh = false
                                    return
                                }
                                self.fetchUsage(token: newToken)
                            }
                            return
                        }
                        self.didRetryWithRefresh = false
                        let raw = http.value(forHTTPHeaderField: "retry-after").flatMap { Int($0) } ?? Int(defaultFetchInterval)
                        self.handleRateLimit(raw: raw)
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

    private func handleRateLimit(raw: Int) {
        let retryAfter = clampRetryAfter(raw)
        schedule.onRateLimit(retryAfter: raw)
        let minutes = (retryAfter + 59) / 60
        if lastUsage == nil {
            setError("Rate limited")
        }
        lastRefreshItem.title = "Next API call in \(minutes)m (rate limited)"
    }

    // MARK: - Display

    private func updateDisplay(_ usage: UsageData) {
        lastUsage = usage
        history.record(usage)
        lastRefreshDate = Date()
        didRetryWithRefresh = false
        schedule.onSuccess()

        let h5Pace = calculatePace(utilization: usage.fiveHour.utilization, resetsAt: usage.fiveHour.resetsAt, windowDuration: 5 * 3600)
        let d7Pace = calculatePace(utilization: usage.sevenDay.utilization, resetsAt: usage.sevenDay.resetsAt, windowDuration: 7 * 86400)
        let (notifications, newState) = determineNotifications(oldState: notificationState, newUsage: usage, fiveHourPace: h5Pace, sevenDayPace: d7Pace)
        notificationState = newState
        #if !TESTING
        for notification in notifications {
            deliverNotification(notification)
        }
        #endif

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

        #if TESTING
        statusItem.button?.title = formatStatusLine(usage, history: history)
        #else
        statusItem.button?.attributedTitle = formatAttributedStatusLine(usage, history: history)
        #endif

        #if TESTING
        detailFiveHour.title = "\(usageIndicator(for: h5))  5-hour window: \(formatValue(h5))%\(formatResetTime(usage.fiveHour.resetsAt))"
        detailSevenDay.title = "\(usageIndicator(for: d7))  7-day window:  \(formatValue(d7))%\(formatResetTime(usage.sevenDay.resetsAt))"
        #else
        // 5-hour: sparkline + pace
        let h5Spark = history.sparkline(for: \.fiveHour)
        var h5Parts: [String] = []
        if !h5Spark.isEmpty { h5Parts.append("\(h5Spark)  (2h trend)") }
        var h5Color: NSColor? = nil
        if let h5Pace = calculatePace(utilization: usage.fiveHour.utilization, resetsAt: usage.fiveHour.resetsAt, windowDuration: 5 * 3600) {
            h5Parts.append(paceLabel(h5Pace))
            h5Color = paceColor(h5Pace)
        }
        detailFiveHour.attributedTitle = formatAttributedMenuItem(label: "5-hour window", window: usage.fiveHour, subtitle: h5Parts.joined(separator: "\n    "), subtitleColor: h5Color)

        // 7-day: pace only
        var d7Subtitle = ""
        var d7Color: NSColor? = nil
        if let d7Pace = calculatePace(utilization: usage.sevenDay.utilization, resetsAt: usage.sevenDay.resetsAt, windowDuration: 7 * 86400) {
            d7Subtitle = paceLabel(d7Pace)
            d7Color = paceColor(d7Pace)
        }
        detailSevenDay.attributedTitle = formatAttributedMenuItem(label: "7-day window ", window: usage.sevenDay, subtitle: d7Subtitle, subtitleColor: d7Color)
        #endif

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
