import Cocoa
import CommonCrypto
import ServiceManagement
import SQLite3
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
let defaultFetchInterval: TimeInterval = 60  // 1 minute
private let maxBackoffInterval: TimeInterval = 300  // 5 minutes
let widgetWorkerURL = "https://ccusage-widget.g-spot.workers.dev"

let deviceId: String = {
    let name = Host.current().localizedName ?? "unknown"
    var result = ""
    for scalar in name.lowercased().unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) {
            result.append(Character(scalar))
        } else if !result.isEmpty && result.last != "-" {
            result.append("-")
        }
    }
    if result.last == "-" { result.removeLast() }
    return result.isEmpty ? "unknown" : result
}()

// MARK: - API Types

struct UsageWindow: Equatable {
    let utilization: Double
    let remaining: Double?
    let resetsAt: Date?
}

struct ModelBreakdown: Equatable {
    let opus: UsageWindow?
    let sonnet: UsageWindow?
    let oauthApps: UsageWindow?
    let cowork: UsageWindow?
}

struct ExtraUsage: Equatable {
    let isEnabled: Bool
    let utilization: Double?
}

struct UsageData: Equatable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
    let models: ModelBreakdown?
    let extraUsage: ExtraUsage?

    init(fiveHour: UsageWindow, sevenDay: UsageWindow, models: ModelBreakdown? = nil, extraUsage: ExtraUsage? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.models = models
        self.extraUsage = extraUsage
    }
}

struct DailyEntryData: Codable, Equatable {
    let date: String
    let usage: Double
}

struct SessionData: Codable, Equatable {
    let project: String
    let model: String?
    let tokens: Int?
    let durationSeconds: Int?
}

struct WidgetData: Codable {
    let fiveHourUtilization: Double
    let sevenDayUtilization: Double
    let fiveHourPace: Double?
    let sevenDayPace: Double?
    let fiveHourResetsAt: TimeInterval?
    let sevenDayResetsAt: TimeInterval?
    let updatedAt: TimeInterval
    // v2 fields — nil-safe for older workers
    let extraUsageEnabled: Bool?
    let depletionSeconds: Double?  // seconds until 7d depletion, nil if safe
    let activeSessionCount: Int?
    // v3 fields — analytics for iOS widget
    let opusUtilization: Double?
    let sonnetUtilization: Double?
    let haikuUtilization: Double?
    let dailyEntries: [DailyEntryData]?
    let sessions: [SessionData]?
    let extraUsageUtilization: Double?

    func hasSameValues(as other: WidgetData) -> Bool {
        fiveHourUtilization == other.fiveHourUtilization
            && sevenDayUtilization == other.sevenDayUtilization
            && fiveHourPace == other.fiveHourPace
            && sevenDayPace == other.sevenDayPace
            && fiveHourResetsAt == other.fiveHourResetsAt
            && sevenDayResetsAt == other.sevenDayResetsAt
            && extraUsageEnabled == other.extraUsageEnabled
            && depletionSeconds == other.depletionSeconds
            && activeSessionCount == other.activeSessionCount
            && opusUtilization == other.opusUtilization
            && sonnetUtilization == other.sonnetUtilization
            && haikuUtilization == other.haikuUtilization
            && dailyEntries == other.dailyEntries
            && sessions == other.sessions
            && extraUsageUtilization == other.extraUsageUtilization
    }
}

private struct WidgetPushBody: Encodable {
    let data: WidgetData
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
    /// Last observed window-end timestamp. A change (past → new future) means the window reset.
    var lastFiveHourResetsAt: Date?
    var lastSevenDayResetsAt: Date?
    /// Utilization recorded alongside the last `resetsAt`. Used to avoid firing a reset alert
    /// when the user hadn't actually consumed anything in the previous window.
    var lastFiveHourUtilization: Double = 0
    var lastSevenDayUtilization: Double = 0
}

enum UsageNotification: Equatable {
    case zoneTransition(window: String, zone: UsageZone, utilization: Double)
    case depleted(window: String)
    case paceOverBudget(window: String, pace: Double)
    /// A usage window boundary crossed — the previous window ended and quota refreshed.
    /// `previousUtilization` is what the user consumed in the window that just closed.
    case windowReset(window: String, previousUtilization: Double)

    var identifier: String {
        switch self {
        case .zoneTransition(let window, let zone, _):
            return "zone-\(window)-\(zone)"
        case .depleted(let window):
            return "depleted-\(window)"
        case .paceOverBudget(let window, _):
            return "pace-\(window)"
        case .windowReset(let window, _):
            return "reset-\(window)"
        }
    }
}

func determineNotifications(
    oldState: NotificationState,
    newUsage: UsageData,
    fiveHourPace: Double?,
    sevenDayPace: Double?,
    now: Date = Date()
) -> ([UsageNotification], NotificationState) {
    var notifications: [UsageNotification] = []
    var newState = oldState

    let h5Zone = zoneFor(utilization: newUsage.fiveHour.utilization)
    let d7Zone = zoneFor(utilization: newUsage.sevenDay.utilization)

    newState.fiveHourZone = h5Zone
    newState.sevenDayZone = d7Zone

    // Window-reset detection: a tracked `resetsAt` advanced to a later timestamp = window rolled
    // over. We require the previous window had non-trivial usage so fresh installs and idle
    // accounts don't get spammed. `> prior + 60` tolerates minor API jitter.
    func detectReset(
        windowName: String,
        oldReset: Date?,
        newReset: Date?,
        priorUtilization: Double
    ) -> UsageNotification? {
        guard let oldReset, let newReset,
              newReset.timeIntervalSince(oldReset) > 60,
              priorUtilization >= 1.0
        else { return nil }
        return .windowReset(window: windowName, previousUtilization: priorUtilization)
    }
    if let reset = detectReset(
        windowName: "5-hour",
        oldReset: oldState.lastFiveHourResetsAt,
        newReset: newUsage.fiveHour.resetsAt,
        priorUtilization: oldState.lastFiveHourUtilization
    ) { notifications.append(reset) }
    if let reset = detectReset(
        windowName: "7-day",
        oldReset: oldState.lastSevenDayResetsAt,
        newReset: newUsage.sevenDay.resetsAt,
        priorUtilization: oldState.lastSevenDayUtilization
    ) { notifications.append(reset) }
    newState.lastFiveHourResetsAt = newUsage.fiveHour.resetsAt
    newState.lastSevenDayResetsAt = newUsage.sevenDay.resetsAt
    newState.lastFiveHourUtilization = newUsage.fiveHour.utilization
    newState.lastSevenDayUtilization = newUsage.sevenDay.utilization
    _ = now // reserved for future time-based rules; avoids unused-param warning

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

func sha256hex(_ input: String) -> String {
    let data = Data(input.utf8)
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    _ = data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
    return hash.map { String(format: "%02x", $0) }.joined()
}

private func parseOAuthDict(from jsonData: Data) -> [String: Any]? {
    guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any] else {
        return nil
    }
    return oauth
}

private func parseOAuthStringField(_ field: String, from jsonData: Data) -> String? {
    guard let oauth = parseOAuthDict(from: jsonData),
          let value = oauth[field] as? String,
          !value.isEmpty else {
        return nil
    }
    return value
}

func parseToken(from jsonData: Data) -> String? {
    parseOAuthStringField("accessToken", from: jsonData)
}

func parseRefreshToken(from jsonData: Data) -> String? {
    parseOAuthStringField("refreshToken", from: jsonData)
}

func parseExpiresAt(from jsonData: Data) -> Date? {
    guard let oauth = parseOAuthDict(from: jsonData) else { return nil }
    let ms: Double
    if let intMs = oauth["expiresAt"] as? Int {
        ms = Double(intMs)
    } else if let doubleMs = oauth["expiresAt"] as? Double {
        ms = doubleMs
    } else {
        return nil
    }
    return Date(timeIntervalSince1970: ms / 1000.0)
}

func parseOAuthAccountEmail(from jsonData: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
          let oauthAccount = json["oauthAccount"] as? [String: Any],
          let email = oauthAccount["emailAddress"] as? String,
          !email.isEmpty else {
        return nil
    }
    return email
}

func _missingCredentialsDetails(from claudeConfigData: Data?) -> (String, String) {
    guard let claudeConfigData,
          let email = parseOAuthAccountEmail(from: claudeConfigData) else {
        return ("No credentials found", "Ensure Claude Code is signed in")
    }
    return ("Claude account found for \(email)", "OAuth token missing. Run `claude auth login`")
}

/// Parse the account name from `security find-generic-password` output.
func parseKeychainAccount(from output: String) -> String? {
    for line in output.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\"acct\"<blob>=\"") {
            return String(trimmed.dropFirst("\"acct\"<blob>=\"".count).dropLast(1))
        }
    }
    return nil
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

func parseWindowIfPresent(_ dict: [String: Any]?) -> UsageWindow? {
    guard let dict, let util = dict["utilization"] as? Double, util >= 0, util <= 100 else { return nil }
    return UsageWindow(utilization: util, remaining: dict["remaining"] as? Double, resetsAt: parseResetDate(dict["resets_at"]))
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

    let models = ModelBreakdown(
        opus: parseWindowIfPresent(json["seven_day_opus"] as? [String: Any]),
        sonnet: parseWindowIfPresent(json["seven_day_sonnet"] as? [String: Any]),
        oauthApps: parseWindowIfPresent(json["seven_day_oauth_apps"] as? [String: Any]),
        cowork: parseWindowIfPresent(json["seven_day_cowork"] as? [String: Any])
    )
    let hasModels = models.opus != nil || models.sonnet != nil || models.oauthApps != nil || models.cowork != nil

    var extraUsage: ExtraUsage? = nil
    if let extra = json["extra_usage"] as? [String: Any], let enabled = extra["is_enabled"] as? Bool {
        extraUsage = ExtraUsage(isEnabled: enabled, utilization: extra["utilization"] as? Double)
    }

    return UsageData(
        fiveHour: UsageWindow(utilization: h5, remaining: fiveHour["remaining"] as? Double, resetsAt: parseResetDate(fiveHour["resets_at"])),
        sevenDay: UsageWindow(utilization: d7, remaining: sevenDay["remaining"] as? Double, resetsAt: parseResetDate(sevenDay["resets_at"])),
        models: hasModels ? models : nil,
        extraUsage: extraUsage
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

func compactResetTime(_ date: Date?, relativeTo now: Date = Date()) -> String? {
    guard let date else { return nil }
    let seconds = date.timeIntervalSince(now)
    if seconds <= 0 { return nil }
    let totalMinutes = Int(seconds) / 60
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 24 {
        let days = hours / 24
        let remainingHours = hours % 24
        if remainingHours == 0 { return "\(days)d" }
        return "\(days)d \(remainingHours)h"
    }
    if hours > 0 {
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
}

func formatCompactFiveHour(window: UsageWindow, sparkline: String?, extraUsage: ExtraUsage?, now: Date = Date()) -> String {
    let pct = formatValue(window.utilization)
    var parts: [String] = ["5h: \(pct)%"]
    if let pace = calculatePace(utilization: window.utilization, resetsAt: window.resetsAt, windowDuration: 5 * 3600, now: now) {
        parts.append(String(format: "%.1fx", pace))
    }
    if let resetStr = compactResetTime(window.resetsAt, relativeTo: now) {
        parts.append("resets \(resetStr)")
    }
    if let extra = extraUsage, extra.isEnabled {
        parts.append("Extra on")
    }
    var result = parts.joined(separator: " \u{00B7} ")
    if let spark = sparkline, !spark.isEmpty {
        result += " \(spark)"
    }
    return result
}

// MARK: - Usage History

struct UsageHistory {
    struct Entry: Codable, Equatable {
        let date: Date
        let fiveHour: Double
        let sevenDay: Double
    }

    private(set) var entries: [Entry] = []
    private let maxEntries = 60  // ~2 hours at 2-min intervals

    mutating func record(_ usage: UsageData) {
        entries.append(Entry(date: Date(), fiveHour: usage.fiveHour.utilization, sevenDay: usage.sevenDay.utilization))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    /// Restore entries from persisted data, pruning stale ones.
    mutating func restore(_ saved: [Entry], maxAge: TimeInterval = 7200) {
        let cutoff = Date().addingTimeInterval(-maxAge)
        entries = saved.filter { $0.date > cutoff }.suffix(maxEntries).map { $0 }
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
        guard entries.count >= 3 else { return "" }
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

func depletionEstimate(utilization: Double, resetsAt: Date?, windowDuration: TimeInterval, now: Date = Date()) -> String? {
    guard let resetsAt else { return nil }
    let remaining = resetsAt.timeIntervalSince(now)
    guard remaining > 0, remaining < windowDuration else { return nil }
    let elapsed = windowDuration - remaining
    guard elapsed > 60, utilization > 0.1 else { return nil }
    if utilization >= 100 { return "Depleted" }
    let ratePerSec = utilization / elapsed
    let secsToFull = (100.0 - utilization) / ratePerSec
    if secsToFull > remaining { return "Won't deplete this window" }
    let hours = Int(secsToFull) / 3600
    let minutes = (Int(secsToFull) % 3600) / 60
    if hours > 24 {
        let days = hours / 24
        let remHours = hours % 24
        return remHours == 0 ? "Depletes in ~\(days)d" : "Depletes in ~\(days)d \(remHours)h"
    }
    if hours > 0 { return "Depletes in ~\(hours)h \(minutes)m" }
    return "Depletes in ~\(minutes)m"
}

func dailyBreakdown(utilization: Double, resetsAt: Date?, windowDuration: TimeInterval, now: Date = Date()) -> String? {
    guard let resetsAt else { return nil }
    let remaining = resetsAt.timeIntervalSince(now)
    guard remaining > 0, remaining < windowDuration else { return nil }
    let elapsed = windowDuration - remaining
    let elapsedDays = elapsed / 86400.0
    guard elapsedDays > 0.01 else { return nil }
    let perDay = utilization / elapsedDays
    let daysLeft = remaining / 86400.0
    let pctLeft = 100.0 - utilization
    let sustainablePerDay = daysLeft > 0.01 ? pctLeft / daysLeft : 0
    return String(format: "Daily rate: %.1f%%/day  •  Safe: %.1f%%/day", perDay, sustainablePerDay)
}

func formatForecastLine(utilization: Double, resetsAt: Date?, windowDuration: TimeInterval, now: Date = Date()) -> String? {
    guard let resetsAt else { return nil }
    let remaining = resetsAt.timeIntervalSince(now)
    guard remaining > 0, remaining < windowDuration else { return nil }
    let elapsed = windowDuration - remaining
    guard elapsed > 60, utilization > 0.1 else { return nil }
    if utilization >= 100 { return "Depleted" }
    let elapsedDays = elapsed / 86400.0
    let ratePerDay = utilization / elapsedDays
    let daysLeft = remaining / 86400.0
    let pctLeft = 100.0 - utilization
    let budgetPerDay = daysLeft > 0 ? pctLeft / daysLeft : 0
    let rateStr = String(format: "%.1f%%/day of %.1f%%/day budget", ratePerDay, budgetPerDay)
    let ratePerSec = utilization / elapsed
    let secsToFull = (100.0 - utilization) / ratePerSec
    if secsToFull > remaining { return "Safe \u{00B7} \(rateStr)" }
    let hours = Int(secsToFull) / 3600
    let minutes = (Int(secsToFull) % 3600) / 60
    let timeStr: String
    if hours > 24 {
        let days = hours / 24
        let remHours = hours % 24
        timeStr = remHours == 0 ? "\(days)d" : "\(days)d \(remHours)h"
    } else if hours > 0 {
        timeStr = "\(hours)h \(minutes)m"
    } else {
        timeStr = "\(minutes)m"
    }
    return "Depletes in ~\(timeStr) \u{00B7} \(rateStr)"
}

func paceIndicator(pace: Double?) -> String {
    guard let pace else { return "" }
    if pace > 1.2 { return "▲" }
    if pace < 0.8 { return "▼" }
    return "●"
}

func paceLabel(_ pace: Double) -> String {
    if pace > 1.2 { return String(format: "▲ %.1fx pace (over budget)", pace) }
    if pace < 0.8 { return String(format: "▼ %.1fx pace (under budget)", pace) }
    return String(format: "● %.1fx pace (on track)", pace)
}

func hourlyHeatmap(_ increases: [Date], now: Date = Date()) -> String? {
    guard increases.count >= 3 else { return nil }
    let blocks: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
    let currentHour = Calendar.current.component(.hour, from: now)
    var hourCounts = [Int: Int]()
    for date in increases {
        let hour = Calendar.current.component(.hour, from: date)
        hourCounts[hour, default: 0] += 1
    }
    let maxCount = hourCounts.values.max() ?? 1
    let chars = (0...currentHour).map { hour -> String in
        let count = hourCounts[hour, default: 0]
        if count == 0 { return "\u{00B7}" }
        let index = Int((Double(count) / Double(maxCount)) * Double(blocks.count - 1))
        return String(blocks[min(max(index, 0), blocks.count - 1)])
    }
    return chars.joined()
}

func hourlyHeatmapLabel(now: Date = Date()) -> String {
    let currentHour = Calendar.current.component(.hour, from: now)
    let markers = [0, 6, 12, 18].filter { $0 <= currentHour }
    let lastMarkerEnd = markers.last.map { $0 + String($0).count } ?? 0
    let width = max(currentHour + 1, lastMarkerEnd)
    var label = Array(repeating: Character(" "), count: width)
    // Place markers at positions 0, 6, 12, 18 (each at charPos = hour)
    for hour in markers {
        let text = String(format: "%d", hour)
        for (i, ch) in text.enumerated() where hour + i < width {
            label[hour + i] = ch
        }
    }
    return String(label)
}

func formatStatusLine(_ usage: UsageData, history: UsageHistory = UsageHistory()) -> String {
    let h5 = usage.fiveHour.utilization
    let d7 = usage.sevenDay.utilization
    let h5Pace = calculatePace(utilization: h5, resetsAt: usage.fiveHour.resetsAt, windowDuration: 5 * 3600)
    let d7Pace = calculatePace(utilization: d7, resetsAt: usage.sevenDay.resetsAt, windowDuration: 7 * 86400)
    let h5Indicator = paceIndicator(pace: h5Pace)
    let d7Indicator = paceIndicator(pace: d7Pace)
    let sep = h5Indicator.isEmpty ? " " : ""
    return "\(formatValue(h5))\(h5Indicator)\(sep)\(formatValue(d7))\(d7Indicator)"
}

func formatDepletionTime(secsToFull: Double) -> String {
    let hours = Int(secsToFull) / 3600
    let minutes = (Int(secsToFull) % 3600) / 60
    if hours > 24 {
        let days = hours / 24
        let remHours = hours % 24
        return remHours == 0 ? "\(days)d" : "\(days)d \(remHours)h"
    }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
}

func formatAdaptiveStatusLine(usage: UsageData, history: UsageHistory = UsageHistory(), now: Date = Date()) -> String {
    let d7 = usage.sevenDay.utilization
    if d7 >= 100 {
        return "\u{2716} depleted"
    }
    let windowDuration: TimeInterval = 7 * 86400
    if let resetsAt = usage.sevenDay.resetsAt {
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining > 0, remaining < windowDuration {
            let elapsed = windowDuration - remaining
            if elapsed > 60, d7 > 0.1 {
                let ratePerSec = d7 / elapsed
                let secsToFull = (100.0 - d7) / ratePerSec
                if secsToFull < remaining {
                    return "\u{26A0} \(formatDepletionTime(secsToFull: secsToFull)) left"
                }
            }
        }
    }
    return formatStatusLine(usage, history: history)
}

// MARK: - Daily Usage Tracking

struct DailyEntry: Codable, Equatable {
    let date: String
    var usage: Double
}

struct DailyUsageData: Codable, Equatable {
    var lastUtilization: Double?
    var days: [DailyEntry]
    var historyEntries: [UsageHistory.Entry]?
    var usageIncreases: [Date]?
    var widgetKey: String?

    init(lastUtilization: Double? = nil, days: [DailyEntry] = [], historyEntries: [UsageHistory.Entry]? = nil, usageIncreases: [Date]? = nil, widgetKey: String? = nil) {
        self.lastUtilization = lastUtilization
        self.days = days
        self.historyEntries = historyEntries
        self.usageIncreases = usageIncreases
        self.widgetKey = widgetKey
    }
}

private let dailyDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

func dailyDateString(_ date: Date) -> String {
    dailyDateFormatter.string(from: date)
}

func recordDailyUsage(_ store: inout DailyUsageData, sevenDayUtilization: Double, now: Date = Date()) {
    let today = dailyDateString(now)
    let delta: Double
    if let last = store.lastUtilization, sevenDayUtilization >= last {
        delta = sevenDayUtilization - last
    } else {
        delta = 0
    }
    store.lastUtilization = sevenDayUtilization

    if let idx = store.days.firstIndex(where: { $0.date == today }) {
        if delta > 0 { store.days[idx].usage += delta }
    } else {
        store.days.append(DailyEntry(date: today, usage: delta))
    }

    // Prune entries older than 7 days
    let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: now)!
    let cutoffStr = dailyDateString(cutoff)
    store.days = store.days.filter { $0.date > cutoffStr }
}

func weeklyChart(_ days: [DailyEntry], now: Date = Date()) -> String? {
    guard days.contains(where: { $0.usage > 0 }) else { return nil }
    let blocks: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
    let cal = Calendar.current

    var values: [Double] = []
    for i in (0..<7).reversed() {
        let date = cal.date(byAdding: .day, value: -i, to: now)!
        let dateStr = dailyDateString(date)
        values.append(days.first(where: { $0.date == dateStr })?.usage ?? 0)
    }

    let maxVal = values.max() ?? 0
    guard maxVal > 0 else { return nil }

    let chars = values.map { val -> String in
        if val <= 0 { return String(blocks[0]) }
        let index = Int((val / maxVal) * Double(blocks.count - 1))
        return String(blocks[min(max(index, 0), blocks.count - 1)])
    }
    return chars.joined(separator: " ")
}

func weeklyChartValues(_ days: [DailyEntry], now: Date = Date()) -> [Double] {
    let cal = Calendar.current
    return (0..<7).reversed().map { i -> Double in
        let date = cal.date(byAdding: .day, value: -i, to: now)!
        return days.first(where: { $0.date == dailyDateString(date) })?.usage ?? 0
    }
}

func weeklyChartLabel(now: Date = Date()) -> String {
    let cal = Calendar.current
    let letters = ["S", "M", "T", "W", "T", "F", "S"]
    let dayLetters = (0..<7).reversed().map { i -> String in
        let date = cal.date(byAdding: .day, value: -i, to: now)!
        let weekday = cal.component(.weekday, from: date)
        return letters[weekday - 1]
    }
    return dayLetters.joined(separator: " ")
}

func alignedWeeklyColumns(chart: String, values: [Double], dayLabel: String) -> (chart: String, pcts: String, days: String) {
    let pctLabels = values.map { $0 < 1 ? "·" : String(format: "%.0f", $0) }
    let colWidth = pctLabels.map { $0.count }.max() ?? 1
    guard colWidth > 1 else {
        return (chart, pctLabels.joined(separator: " "), dayLabel)
    }
    let rjust = { (s: String) -> String in
        s.count >= colWidth ? s : String(repeating: " ", count: colWidth - s.count) + s
    }
    return (
        chart.components(separatedBy: " ").map(rjust).joined(separator: " "),
        pctLabels.map(rjust).joined(separator: " "),
        dayLabel.components(separatedBy: " ").map(rjust).joined(separator: " ")
    )
}

func mergeDailyEntries(_ deviceEntries: [[DailyEntry]]) -> [DailyEntry] {
    var merged: [String: Double] = [:]
    for entries in deviceEntries {
        for entry in entries {
            merged[entry.date, default: 0] += entry.usage
        }
    }
    return merged.map { DailyEntry(date: $0.key, usage: $0.value) }
        .sorted { $0.date < $1.date }
}

// MARK: - Agent Tracking

struct TrackedAgent: Equatable {
    let toolUseId: String
    let description: String
    let subagentType: String
    let launchedAt: Date
    var completedAt: Date?
    var totalTokens: Int?
    var durationMs: Int?

    var isRunning: Bool { completedAt == nil }
}

func parseAgentLaunches(from jsonLine: Data, fallbackTimestamp: Date = Date()) -> [TrackedAgent] {
    guard let json = try? JSONSerialization.jsonObject(with: jsonLine) as? [String: Any],
          let type = json["type"] as? String, type == "assistant",
          let message = json["message"] as? [String: Any],
          let content = message["content"] as? [[String: Any]] else {
        return []
    }

    let timestamp: Date
    if let ts = json["timestamp"] as? String {
        timestamp = iso8601Formatter.date(from: ts) ?? fallbackTimestamp
    } else {
        timestamp = fallbackTimestamp
    }

    var agents: [TrackedAgent] = []
    for block in content {
        guard let blockType = block["type"] as? String, blockType == "tool_use",
              let name = block["name"] as? String, name == "Agent",
              let id = block["id"] as? String,
              let input = block["input"] as? [String: Any] else {
            continue
        }
        let desc = input["description"] as? String ?? "Agent"
        let subType = input["subagent_type"] as? String ?? "general-purpose"
        agents.append(TrackedAgent(
            toolUseId: id,
            description: desc,
            subagentType: subType,
            launchedAt: timestamp
        ))
    }
    return agents
}

func parseAgentCompletions(from jsonLine: Data) -> [(toolUseId: String, totalTokens: Int?, durationMs: Int?)] {
    guard let json = try? JSONSerialization.jsonObject(with: jsonLine) as? [String: Any],
          let type = json["type"] as? String, type == "user",
          let message = json["message"] as? [String: Any],
          let content = message["content"] as? [[String: Any]] else {
        return []
    }

    var completions: [(String, Int?, Int?)] = []
    for block in content {
        guard let blockType = block["type"] as? String, blockType == "tool_result",
              let toolUseId = block["tool_use_id"] as? String else {
            continue
        }

        var totalTokens: Int?
        var durationMs: Int?

        if let resultContent = block["content"] as? [[String: Any]] {
            for item in resultContent {
                if let text = item["text"] as? String {
                    if let range = text.range(of: "total_tokens: ") {
                        let rest = text[range.upperBound...]
                        if let end = rest.firstIndex(where: { !$0.isNumber }) {
                            totalTokens = Int(rest[..<end])
                        } else {
                            totalTokens = Int(rest)
                        }
                    }
                    if let range = text.range(of: "duration_ms: ") {
                        let rest = text[range.upperBound...]
                        if let end = rest.firstIndex(where: { !$0.isNumber }) {
                            durationMs = Int(rest[..<end])
                        } else {
                            durationMs = Int(rest)
                        }
                    }
                }
            }
        }
        completions.append((toolUseId, totalTokens, durationMs))
    }
    return completions
}

func formatAgentDuration(_ agent: TrackedAgent, now: Date = Date()) -> String {
    if let ms = agent.durationMs {
        let secs = ms / 1000
        if secs >= 60 { return "\(secs / 60)m\(secs % 60)s" }
        return "\(secs)s"
    }
    if agent.isRunning {
        let secs = Int(now.timeIntervalSince(agent.launchedAt))
        if secs >= 60 { return "\(secs / 60)m\(secs % 60)s" }
        return "\(secs)s"
    }
    return ""
}

func formatTokenCount(_ tokens: Int) -> String {
    if tokens >= 1_000_000_000 { return String(format: "%.1fB", Double(tokens) / 1_000_000_000.0) }
    if tokens >= 100_000_000 { return "\(tokens / 1_000_000)M" }
    if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000.0) }
    if tokens >= 1000 { return "\(tokens / 1000)K" }
    return "\(tokens)"
}

func projectNameFromSessionPath(_ path: String, homeDir: String = NSHomeDirectory()) -> String? {
    let dir = (path as NSString).deletingLastPathComponent
    let dirName = (dir as NSString).lastPathComponent
    let homePrefix = homeDir.replacingOccurrences(of: "/", with: "-") + "-"
    guard dirName.hasPrefix(homePrefix) else { return nil }
    let afterHome = String(dirName.dropFirst(homePrefix.count))
    guard let firstDash = afterHome.firstIndex(of: "-") else {
        return afterHome.isEmpty ? nil : afterHome
    }
    let project = String(afterHome[afterHome.index(after: firstDash)...])
    return project.isEmpty ? nil : project
}

struct AgentStats: Equatable {
    var completedCount: Int = 0
    var totalTokens: Int = 0
    var totalDurationMs: Int = 0

    var avgDurationMs: Int {
        completedCount > 0 ? totalDurationMs / completedCount : 0
    }

    mutating func record(tokens: Int?, durationMs: Int?) {
        completedCount += 1
        totalTokens += tokens ?? 0
        totalDurationMs += durationMs ?? 0
    }
}

struct SessionTokens: Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var cacheReadTokens: Int = 0

    var totalTokens: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }
    var totalInputTokens: Int { inputTokens + cacheCreationTokens + cacheReadTokens }

    var cacheHitRate: Double? {
        let total = Double(totalInputTokens)
        guard total > 0, cacheReadTokens > 0 else { return nil }
        return Double(cacheReadTokens) / total
    }

    mutating func add(input: Int, output: Int, cacheCreation: Int, cacheRead: Int) {
        inputTokens += input
        outputTokens += output
        cacheCreationTokens += cacheCreation
        cacheReadTokens += cacheRead
    }
}

func parseTokenUsage(from jsonLine: Data) -> (input: Int, output: Int, cacheCreation: Int, cacheRead: Int)? {
    guard let json = try? JSONSerialization.jsonObject(with: jsonLine) as? [String: Any] else {
        return nil
    }
    // Usage lives under message.usage in Claude Code JSONL
    let message = json["message"] as? [String: Any]
    guard let usage = (message?["usage"] as? [String: Any]) ?? (json["usage"] as? [String: Any]) else {
        return nil
    }
    let input = usage["input_tokens"] as? Int ?? 0
    let output = usage["output_tokens"] as? Int ?? 0
    let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
    let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
    guard input > 0 || output > 0 || cacheCreation > 0 || cacheRead > 0 else { return nil }
    return (input, output, cacheCreation, cacheRead)
}

func parseModel(from jsonLine: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: jsonLine) as? [String: Any] else {
        return nil
    }
    // Model lives under message.model in Claude Code JSONL
    let message = json["message"] as? [String: Any]
    if let model = message?["model"] as? String, !model.isEmpty { return model }
    if let model = json["model"] as? String, !model.isEmpty { return model }
    return nil
}

func parseBashUses(from jsonLine: Data) -> Int {
    guard let json = try? JSONSerialization.jsonObject(with: jsonLine) as? [String: Any],
          let type = json["type"] as? String, type == "assistant",
          let message = json["message"] as? [String: Any],
          let content = message["content"] as? [[String: Any]] else {
        return 0
    }
    return content.filter {
        ($0["type"] as? String) == "tool_use" && ($0["name"] as? String) == "Bash"
    }.count
}

func parseContextWindow(from jsonLine: Data) -> (contextTokens: Int, contextMax: Int)? {
    guard let json = try? JSONSerialization.jsonObject(with: jsonLine) as? [String: Any] else {
        return nil
    }
    let message = json["message"] as? [String: Any]
    guard let usage = (message?["usage"] as? [String: Any]) ?? (json["usage"] as? [String: Any]) else {
        return nil
    }
    let input = usage["input_tokens"] as? Int ?? 0
    let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
    let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
    let contextTokens = input + cacheCreation + cacheRead
    if let contextMax = usage["context_window"] as? Int, contextMax > 0 {
        return (contextTokens, contextMax)
    }
    guard contextTokens > 0 else { return nil }
    let model = message?["model"] as? String ?? (json["model"] as? String ?? "")
    return (contextTokens, modelMaxContextTokens(model, observedTokens: contextTokens))
}

func modelMaxContextTokens(_ model: String, observedTokens: Int = 0) -> Int {
    // If observed tokens exceed 200K, the model must have extended context (1M)
    if observedTokens > 200_000 { return 1_000_000 }
    return 200_000
}


func modelDisplayName(_ model: String) -> String {
    let parts = model.lowercased().split(separator: "-")
    let families = ["opus", "sonnet", "haiku"]
    guard let familyIndex = parts.firstIndex(where: { families.contains(String($0)) }) else {
        return model
    }
    let family = String(parts[familyIndex]).capitalized
    let versionParts = parts.dropFirst(familyIndex + 1).prefix(2)
    let version = versionParts.compactMap { part -> String? in
        let digits = part.prefix(while: { $0.isNumber })
        return digits.isEmpty ? nil : String(digits)
    }
    if version.isEmpty { return family }
    return "\(family) \(version.joined(separator: "."))"
}

func formatSessionStats(_ tokens: SessionTokens, model: String? = nil) -> String {
    guard tokens.totalTokens > 0 else { return "" }
    var parts: [String] = []
    if let model { parts.append(modelDisplayName(model)) }
    parts.append("\(formatTokenCount(tokens.totalInputTokens)) in")
    parts.append("\(formatTokenCount(tokens.outputTokens)) out")
    if let rate = tokens.cacheHitRate {
        parts.append(String(format: "%.0f%% cache", rate * 100))
    }
    return parts.joined(separator: " \u{00B7} ")
}

func formatAgentStatsLine(_ stats: AgentStats) -> String {
    guard stats.completedCount > 0 else { return "" }
    let avgSecs = stats.avgDurationMs / 1000
    return "Session: \(stats.completedCount) agents \u{00B7} \(formatTokenCount(stats.totalTokens)) tok \u{00B7} avg \(avgSecs)s"
}

// MARK: - Codex Tracking

struct CodexThread: Equatable {
    let id: String
    let title: String
    let model: String?
    let tokensUsed: Int
    let createdAt: Date
    let updatedAt: Date
    let cwd: String

    var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    func isActive(now: Date = Date(), threshold: TimeInterval = 300) -> Bool {
        now.timeIntervalSince(updatedAt) < threshold
    }
}

struct CodexSummary: Equatable {
    let todayTokens: Int
    let todaySessions: Int
    let activeSessions: [CodexThread]
}

func buildCodexSummary(from threads: [CodexThread], now: Date = Date()) -> CodexSummary? {
    guard !threads.isEmpty else { return nil }
    let todayStr = dailyDateString(now)

    var todayTokens = 0
    var todaySessions = 0
    var active: [CodexThread] = []

    for thread in threads {
        let createdDayStr = dailyDateString(thread.createdAt)
        if createdDayStr == todayStr {
            todayTokens += thread.tokensUsed
            todaySessions += 1
        }
        if thread.isActive(now: now) {
            active.append(thread)
        }
    }

    return CodexSummary(
        todayTokens: todayTokens,
        todaySessions: todaySessions,
        activeSessions: active
    )
}

class CodexTracker {
    private let dbPath: String
    private(set) var lastSummary: CodexSummary?
    /// Skip the SQLite round-trip when neither the DB file nor its WAL sidecar has been modified
    /// since the last poll. SQLite in WAL mode writes to `state_5.sqlite-wal` while the main DB
    /// mtime stays frozen until checkpoint, so we must watch both files to avoid stale summaries.
    private var lastDBModification: Date?

    /// Return the most recent modification timestamp across the main DB and its WAL sidecar
    /// (if present). nil means the file is missing or attrs couldn't be read.
    private func currentDBModification() -> Date? {
        let paths = [dbPath, dbPath + "-wal"]
        var latest: Date?
        for path in paths {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date else { continue }
            if let cur = latest {
                latest = modified > cur ? modified : cur
            } else {
                latest = modified
            }
        }
        return latest
    }

    init(dbPath: String? = nil) {
        self.dbPath = dbPath ?? (NSHomeDirectory() + "/.codex/state_5.sqlite")
    }

    @discardableResult
    func poll() -> CodexSummary? {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            lastSummary = nil
            lastDBModification = nil
            return nil
        }

        // Cheap mtime check: avoid opening + querying SQLite when nothing has changed.
        if let modified = currentDBModification(),
           let last = lastDBModification, modified == last {
            return lastSummary
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            lastSummary = nil
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT id, title, model, tokens_used, created_at, updated_at, cwd
            FROM threads
            WHERE archived = 0
            ORDER BY updated_at DESC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            lastSummary = nil
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var threads: [CodexThread] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(stmt, 0),
                  let titlePtr = sqlite3_column_text(stmt, 1),
                  let cwdPtr = sqlite3_column_text(stmt, 6) else { continue }
            let id = String(cString: idPtr)
            let title = String(cString: titlePtr)
            let model: String? = {
                guard sqlite3_column_type(stmt, 2) != SQLITE_NULL,
                      let ptr = sqlite3_column_text(stmt, 2) else { return nil }
                return String(cString: ptr)
            }()
            let tokensUsed = Int(sqlite3_column_int64(stmt, 3))
            let rawCreated = sqlite3_column_int64(stmt, 4)
            let rawUpdated = sqlite3_column_int64(stmt, 5)
            let createdAt = Date(timeIntervalSince1970: rawCreated > 32_503_680_000 ? Double(rawCreated) / 1000.0 : Double(rawCreated))
            let updatedAt = Date(timeIntervalSince1970: rawUpdated > 32_503_680_000 ? Double(rawUpdated) / 1000.0 : Double(rawUpdated))
            let cwd = String(cString: cwdPtr)

            threads.append(CodexThread(
                id: id, title: title, model: model,
                tokensUsed: tokensUsed, createdAt: createdAt,
                updatedAt: updatedAt, cwd: cwd
            ))
        }

        let summary = buildCodexSummary(from: threads)
        lastSummary = summary
        // Record mtime AFTER successful read so the next poll can short-circuit.
        // On read failure we leave `lastDBModification` untouched so the next poll retries.
        lastDBModification = currentDBModification()
        return summary
    }
}


// MARK: - Unified Sessions

func formatUnifiedSessions(claudeSessions: [TrackedSession], codex: CodexSummary?, now: Date = Date()) -> String {
    let codexHasContent = codex.map { !$0.activeSessions.isEmpty } ?? false
    guard !claudeSessions.isEmpty || codexHasContent else { return "" }

    var lines: [String] = []

    // Claude sessions — each as a direct line
    for session in claudeSessions {
        var parts: [String] = []
        parts.append(session.projectName ?? "unknown")
        if let model = session.currentModel { parts.append(modelDisplayName(model)) }
        if session.sessionTokens.totalTokens > 0 {
            parts.append("\(formatTokenCount(session.sessionTokens.totalTokens)) tok")
        }
        if session.contextWindowMax > 0 {
            parts.append("\(formatTokenCount(session.lastContextTokens))/\(formatTokenCount(session.contextWindowMax)) ctx")
        }
        if session.isStale { parts.append("idle") }
        lines.append(parts.joined(separator: " \u{00B7} "))

        // Show most recent running agent with pencil prefix
        if let runningAgent = session.agents.last(where: { $0.isRunning }) {
            let duration = formatAgentDuration(runningAgent, now: now)
            lines.append("  \u{270E} \(runningAgent.description)  \(duration)")
        }
    }

    // Codex sessions — each as a direct line
    if let codex = codex {
        for thread in codex.activeSessions {
            var parts: [String] = ["Codex"]
            if let model = thread.model { parts.append(model) }
            parts.append("\(formatTokenCount(thread.tokensUsed)) tok")
            parts.append(thread.projectName)
            lines.append(parts.joined(separator: " \u{00B7} "))
        }
    }

    return lines.joined(separator: "\n")
}

#if !TESTING
func formatAttributedUnifiedSessions(claudeSessions: [TrackedSession], codex: CodexSummary?, now: Date = Date()) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let smallFont = NSFont.systemFont(ofSize: 11)
    let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    let blue = NSColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 1.0)      // #38bdf8
    let dim = NSColor.secondaryLabelColor
    let darkDim = NSColor.tertiaryLabelColor

    var isFirst = true

    // Claude sessions — each as a direct line
    for session in claudeSessions {
        let name = session.projectName ?? "unknown"
        if !isFirst { result.append(NSAttributedString(string: "\n", attributes: [.font: smallFont])) }
        isFirst = false
        result.append(NSAttributedString(string: name, attributes: [.font: smallFont]))
        if let model = session.currentModel {
            result.append(NSAttributedString(string: " \u{00B7} \(modelDisplayName(model))", attributes: [.font: smallFont, .foregroundColor: dim]))
        }
        if session.sessionTokens.totalTokens > 0 {
            result.append(NSAttributedString(string: " \u{00B7} \(formatTokenCount(session.sessionTokens.totalTokens)) tok", attributes: [.font: monoFont, .foregroundColor: dim]))
        }
        if session.contextWindowMax > 0 {
            result.append(NSAttributedString(string: " \u{00B7} \(formatTokenCount(session.lastContextTokens))/\(formatTokenCount(session.contextWindowMax)) ctx", attributes: [.font: monoFont, .foregroundColor: darkDim]))
        }
        if session.isStale {
            result.append(NSAttributedString(string: " \u{00B7} idle", attributes: [.font: smallFont, .foregroundColor: darkDim]))
        }

        // Show most recent running agent
        if let runningAgent = session.agents.last(where: { $0.isRunning }) {
            let duration = formatAgentDuration(runningAgent, now: now)
            result.append(NSAttributedString(string: "\n  ", attributes: [.font: smallFont]))
            result.append(NSAttributedString(string: "\u{270E} \(runningAgent.description)", attributes: [.font: smallFont, .foregroundColor: NSColor.systemOrange]))
            result.append(NSAttributedString(string: "  \(duration)", attributes: [.font: monoFont, .foregroundColor: dim]))
        }
    }

    // Codex sessions — each as a direct line
    if let codex = codex {
        for thread in codex.activeSessions {
            if !isFirst { result.append(NSAttributedString(string: "\n", attributes: [.font: smallFont])) }
            isFirst = false
            result.append(NSAttributedString(string: "Codex", attributes: [.font: smallFont, .foregroundColor: blue]))
            if let model = thread.model {
                result.append(NSAttributedString(string: " \u{00B7} \(model)", attributes: [.font: smallFont, .foregroundColor: dim]))
            }
            result.append(NSAttributedString(string: " \u{00B7} \(formatTokenCount(thread.tokensUsed)) tok", attributes: [.font: monoFont, .foregroundColor: dim]))
            result.append(NSAttributedString(string: " \u{00B7} \(thread.projectName)", attributes: [.font: smallFont, .foregroundColor: dim]))
        }
    }

    return result
}
#endif

// MARK: - Agent Session Tracker

struct TrackedSession {
    let path: String
    let projectName: String?
    var agents: [TrackedAgent] = []
    var stats = AgentStats()
    var sessionTokens = SessionTokens()
    var currentModel: String?
    var lastFileOffset: UInt64 = 0
    var lastFileModification: Date?
    var shellRequestCount: Int = 0
    var lastContextTokens: Int = 0
    var contextWindowMax: Int = 0
    private let staleThreshold: TimeInterval = 300

    init(path: String) {
        self.path = path
        self.projectName = projectNameFromSessionPath(path)
    }

    var isStale: Bool {
        guard let lastMod = lastFileModification else { return false }
        let hasData = !agents.isEmpty || sessionTokens.totalTokens > 0
        return hasData && !hasActiveAgents && Date().timeIntervalSince(lastMod) > staleThreshold
    }

    var hasActiveAgents: Bool { agents.contains { $0.isRunning } }
    var runningCount: Int { agents.filter { $0.isRunning }.count }
    var hasDisplayableData: Bool { !agents.isEmpty || sessionTokens.totalTokens > 0 }

    /// Process new JSONL lines. Returns true if state changed.
    mutating func processNewData(_ newData: Data) -> Bool {
        guard !newData.isEmpty else { return false }
        var changed = false
        let lines = newData.split(separator: UInt8(ascii: "\n"))
        for line in lines {
            let lineData = Data(line)

            let launches = parseAgentLaunches(from: lineData)
            if !launches.isEmpty {
                agents.append(contentsOf: launches)
                changed = true
            }

            let completions = parseAgentCompletions(from: lineData)
            for (toolUseId, tokens, duration) in completions {
                if let index = agents.firstIndex(where: { $0.toolUseId == toolUseId }) {
                    agents[index].completedAt = Date()
                    agents[index].totalTokens = tokens
                    agents[index].durationMs = duration
                    stats.record(tokens: tokens, durationMs: duration)
                    changed = true
                }
            }

            if let usage = parseTokenUsage(from: lineData) {
                sessionTokens.add(input: usage.input, output: usage.output, cacheCreation: usage.cacheCreation, cacheRead: usage.cacheRead)
                changed = true
            }
            if let model = parseModel(from: lineData), model != currentModel {
                currentModel = model
                changed = true
            }
            if let ctx = parseContextWindow(from: lineData) {
                lastContextTokens = ctx.contextTokens
                contextWindowMax = max(contextWindowMax, ctx.contextMax)
                changed = true
            }
            let bashCount = parseBashUses(from: lineData)
            if bashCount > 0 {
                shellRequestCount += bashCount
                changed = true
            }
        }
        return changed
    }

    mutating func pruneCompleted(olderThan interval: TimeInterval = 300) {
        let cutoff = Date().addingTimeInterval(-interval)
        agents.removeAll { !$0.isRunning && ($0.completedAt ?? .distantFuture) < cutoff }
    }
}

class AgentTracker {
    private(set) var sessions: [String: TrackedSession] = [:]
    private let claudeDir: String
    private let staleThreshold: TimeInterval = 300

    init(claudeDir: String? = nil) {
        self.claudeDir = claudeDir ?? (NSHomeDirectory() + "/.claude/projects")
    }

    var activeSessions: [TrackedSession] {
        sessions.values
            .filter { $0.hasDisplayableData || $0.isStale }
            .sorted { ($0.lastFileModification ?? .distantPast) > ($1.lastFileModification ?? .distantPast) }
    }

    var totalRunningCount: Int {
        sessions.values.reduce(0) { $0 + $1.runningCount }
    }

    func findAllSessions() -> [(path: String, modified: Date, size: UInt64)] {
        let fm = FileManager.default
        // Use 2x staleThreshold so sessions can be displayed as "stale/idle"
        // before being evicted from the dictionary
        let cutoff = Date().addingTimeInterval(-staleThreshold * 2)
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: claudeDir) else { return [] }
        var found: [(String, Date, UInt64)] = []
        for dir in projectDirs {
            let projectPath = (claudeDir as NSString).appendingPathComponent(dir)
            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = (projectPath as NSString).appendingPathComponent(file)
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let modified = attrs[.modificationDate] as? Date,
                      modified > cutoff,
                      let size = attrs[.size] as? UInt64 else { continue }
                found.append((path, modified, size))
            }
        }
        return found
    }

    /// Poll all sessions for changes. Returns true if any session state changed.
    @discardableResult
    func poll() -> Bool {
        let foundSessions = findAllSessions()
        let foundPathSet = Set(foundSessions.map { $0.path })

        let removed = sessions.keys.filter { !foundPathSet.contains($0) }
        var changed = !removed.isEmpty
        removed.forEach { sessions.removeValue(forKey: $0) }

        for (path, modified, fileSize) in foundSessions {
            let isNew = sessions[path] == nil
            if isNew {
                sessions[path] = TrackedSession(path: path)
                // For newly discovered sessions, skip to near end to avoid parsing
                // megabytes of history. Read only the last 64KB for recent state.
                let tailSize: UInt64 = 65536
                if fileSize > tailSize {
                    sessions[path]!.lastFileOffset = fileSize - tailSize
                }
            }

            sessions[path]!.lastFileModification = modified

            guard fileSize > sessions[path]!.lastFileOffset else { continue }

            guard let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { handle.closeFile() }

            handle.seek(toFileOffset: sessions[path]!.lastFileOffset)
            let newData = handle.readDataToEndOfFile()
            sessions[path]!.lastFileOffset += UInt64(newData.count)

            if sessions[path]!.processNewData(newData) {
                changed = true
            }
        }
        return changed
    }

    func pruneCompleted(olderThan interval: TimeInterval = 300) {
        for key in sessions.keys {
            sessions[key]?.pruneCompleted(olderThan: interval)
        }
    }
}

#if !TESTING
private let colorRed = NSColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1.0)
private let colorOrange = NSColor(red: 0.9, green: 0.55, blue: 0.1, alpha: 1.0)
private let colorYellow = NSColor(red: 0.85, green: 0.65, blue: 0.0, alpha: 1.0)
private let colorGreen = NSColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1.0)
private let colorBlue = NSColor(red: 0.25, green: 0.55, blue: 0.95, alpha: 1.0)

func paceColor(_ pace: Double?) -> NSColor {
    guard let pace else { return NSColor.secondaryLabelColor }
    if pace > 1.2 { return colorRed }
    if pace < 0.8 { return colorGreen }
    return NSColor.secondaryLabelColor
}

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
    case .windowReset(let window, let previousUtilization):
        content.title = "CCUsage: \(window) Reset"
        content.body = "\(window) window reset — previous cycle ended at \(formatValue(previousUtilization))% utilization"
    }

    content.sound = .default

    let request = UNNotificationRequest(
        identifier: notification.identifier,
        content: content,
        trigger: nil
    )
    UNUserNotificationCenter.current().add(request)
}

func usageColor(for pct: Double, pace: Double? = nil) -> NSColor {
    let effective = pace.map { max(pct, pct * $0) } ?? pct
    if effective >= 80 { return colorRed }
    if effective >= 50 { return colorYellow }
    return colorGreen
}

func formatAttributedStatusLine(_ usage: UsageData, history: UsageHistory = UsageHistory()) -> NSAttributedString {
    let h5 = usage.fiveHour.utilization
    let d7 = usage.sevenDay.utilization
    let h5Pace = calculatePace(utilization: h5, resetsAt: usage.fiveHour.resetsAt, windowDuration: 5 * 3600)
    let d7Pace = calculatePace(utilization: d7, resetsAt: usage.sevenDay.resetsAt, windowDuration: 7 * 86400)

    let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    let result = NSMutableAttributedString()
    let h5Color = usageColor(for: h5, pace: h5Pace)
    result.append(NSAttributedString(string: "\(formatValue(h5))", attributes: [.font: font, .foregroundColor: h5Color]))
    let h5Indicator = paceIndicator(pace: h5Pace)
    if !h5Indicator.isEmpty {
        result.append(NSAttributedString(string: h5Indicator, attributes: [.font: font, .foregroundColor: paceColor(h5Pace)]))
    } else {
        result.append(NSAttributedString(string: " ", attributes: [.font: font]))
    }
    let d7Color = usageColor(for: d7, pace: d7Pace)
    result.append(NSAttributedString(string: "\(formatValue(d7))", attributes: [.font: font, .foregroundColor: d7Color]))
    let d7Indicator = paceIndicator(pace: d7Pace)
    if !d7Indicator.isEmpty {
        result.append(NSAttributedString(string: d7Indicator, attributes: [.font: font, .foregroundColor: paceColor(d7Pace)]))
    }
    return result
}

func formatAttributedAdaptiveStatusLine(_ usage: UsageData, history: UsageHistory = UsageHistory(), now: Date = Date()) -> NSAttributedString {
    let d7 = usage.sevenDay.utilization
    let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    if d7 >= 100 {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colorRed]
        return NSAttributedString(string: "\u{2716} depleted", attributes: attrs)
    }

    let windowDuration: TimeInterval = 7 * 86400
    if let resetsAt = usage.sevenDay.resetsAt {
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining > 0, remaining < windowDuration {
            let elapsed = windowDuration - remaining
            if elapsed > 60, d7 > 0.1 {
                let ratePerSec = d7 / elapsed
                let secsToFull = (100.0 - d7) / ratePerSec
                if secsToFull < remaining {
                    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.systemOrange]
                    return NSAttributedString(string: "\u{26A0} \(formatDepletionTime(secsToFull: secsToFull)) left", attributes: attrs)
                }
            }
        }
    }

    return formatAttributedStatusLine(usage, history: history)
}

func formatAttributedCompactFiveHour(window: UsageWindow, sparkline: String?, extraUsage: ExtraUsage?, now: Date = Date()) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let font = NSFont.systemFont(ofSize: 13)
    let boldFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
    let dim = NSColor.secondaryLabelColor
    let color = usageColor(for: window.utilization)

    // "5h: " in dim
    result.append(NSAttributedString(string: "5h: ", attributes: [.font: font, .foregroundColor: dim]))
    // percentage bold + color-coded
    result.append(NSAttributedString(string: "\(formatValue(window.utilization))%", attributes: [.font: boldFont, .foregroundColor: color]))

    // pace
    if let pace = calculatePace(utilization: window.utilization, resetsAt: window.resetsAt, windowDuration: 5 * 3600, now: now) {
        result.append(NSAttributedString(string: String(format: " \u{00B7} %.1fx", pace), attributes: [.font: font, .foregroundColor: paceColor(pace)]))
    }

    // reset time
    if let resetStr = compactResetTime(window.resetsAt, relativeTo: now) {
        result.append(NSAttributedString(string: " \u{00B7} resets \(resetStr)", attributes: [.font: font, .foregroundColor: dim]))
    }

    // extra usage
    if let extra = extraUsage, extra.isEnabled {
        result.append(NSAttributedString(string: " \u{00B7} Extra on", attributes: [.font: font, .foregroundColor: colorBlue]))
    }

    // sparkline
    if let spark = sparkline, !spark.isEmpty {
        let sparkFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        result.append(NSAttributedString(string: " \(spark)", attributes: [.font: sparkFont, .foregroundColor: NSColor.tertiaryLabelColor]))
    }

    return result
}

func formatAttributedSevenDay(usage: UsageData, forecast: String?, dailyDays: [DailyEntry], hourlyIncreases: [Date], now: Date = Date()) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let font = NSFont.systemFont(ofSize: 13)
    let boldFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
    let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    let dimFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    let dim = NSColor.secondaryLabelColor
    let pct = usage.sevenDay.utilization
    let color = usageColor(for: pct)

    // "7d: " in dim
    result.append(NSAttributedString(string: "7d: ", attributes: [.font: font, .foregroundColor: dim]))
    // percentage bold + color-coded
    result.append(NSAttributedString(string: "\(formatValue(pct))%", attributes: [.font: boldFont, .foregroundColor: color]))

    if let pace = calculatePace(utilization: pct, resetsAt: usage.sevenDay.resetsAt, windowDuration: 7 * 86400, now: now) {
        result.append(NSAttributedString(string: String(format: " \u{00B7} %.1fx", pace), attributes: [.font: font, .foregroundColor: paceColor(pace)]))
    }

    if let resetStr = compactResetTime(usage.sevenDay.resetsAt, relativeTo: now) {
        result.append(NSAttributedString(string: " \u{00B7} resets \(resetStr)", attributes: [.font: font, .foregroundColor: dim]))
    }

    // Inline forecast indicator
    if let forecast {
        let forecastColor: NSColor
        let compactForecast: String
        if forecast.hasPrefix("Safe") {
            forecastColor = dim  // don't shout "safe" — only shout danger
            compactForecast = "Safe"
        } else if forecast.hasPrefix("Depletes") {
            forecastColor = colorOrange
            compactForecast = forecast.replacingOccurrences(of: " \u{00B7}.*$", with: "", options: .regularExpression)
        } else {
            forecastColor = colorRed
            compactForecast = forecast
        }
        result.append(NSAttributedString(string: " \u{00B7} \(compactForecast)", attributes: [.font: font, .foregroundColor: forecastColor]))
    }

    // Weekly chart
    if let chart = weeklyChart(dailyDays, now: now) {
        let values = weeklyChartValues(dailyDays, now: now)
        let total = values.reduce(0, +)
        let totalStr = String(format: " %.0f%%", total)
        let aligned = alignedWeeklyColumns(chart: chart, values: values, dayLabel: weeklyChartLabel(now: now))
        result.append(NSAttributedString(string: "\n  Week  \(aligned.chart)", attributes: [.font: monoFont, .foregroundColor: NSColor.labelColor]))
        result.append(NSAttributedString(string: totalStr, attributes: [.font: dimFont, .foregroundColor: dim]))
        result.append(NSAttributedString(string: "\n        \(aligned.pcts)", attributes: [.font: dimFont, .foregroundColor: dim]))
        result.append(NSAttributedString(string: "\n        \(aligned.days)", attributes: [.font: dimFont, .foregroundColor: NSColor.tertiaryLabelColor]))
    }

    // Heatmap
    if let heatmap = hourlyHeatmap(hourlyIncreases, now: now) {
        result.append(NSAttributedString(string: "\n  Today \(heatmap)", attributes: [.font: monoFont, .foregroundColor: NSColor.labelColor]))
        result.append(NSAttributedString(string: "\n        \(hourlyHeatmapLabel(now: now))", attributes: [.font: dimFont, .foregroundColor: dim]))
    }

    return result
}
#endif


func peakHoursSummary(_ increases: [Date]) -> String? {
    guard increases.count >= 3 else { return nil }
    var hourCounts = [Int: Int]()
    for date in increases {
        let hour = Calendar.current.component(.hour, from: date)
        hourCounts[hour, default: 0] += 1
    }
    guard let peakHour = hourCounts.max(by: { $0.value < $1.value })?.key else { return nil }
    let endHour = (peakHour + 1) % 24
    return String(format: "Peak usage: %02d:00–%02d:00", peakHour, endHour)
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

// MARK: - Codesign Verification (auto-update)

/// Parse the `TeamIdentifier=XXXX` line from `codesign -dvvv` stderr output.
/// Returned nil for unsigned bundles or if the field is absent.
func teamIdentifier(fromCodesignOutput output: String) -> String? {
    for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
        let s = String(line)
        guard let eq = s.range(of: "=") else { continue }
        let key = s[..<eq.lowerBound]
        if key == "TeamIdentifier" {
            let value = s[eq.upperBound...].trimmingCharacters(in: .whitespaces)
            return value.isEmpty || value == "not set" ? nil : value
        }
    }
    return nil
}

#if !TESTING
/// Run a process and capture combined stdout + stderr. Returns (exitCode, combinedOutput).
private func runAndCapture(executable: String, arguments: [String], timeout: TimeInterval = 30) throws -> (Int32, String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = arguments
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    try proc.run()
    let deadline = Date().addingTimeInterval(timeout)
    while proc.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
    if proc.isRunning {
        proc.terminate()
        throw NSError(domain: "CCUsage", code: 10, userInfo: [NSLocalizedDescriptionKey: "\(executable) timed out"])
    }
    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (proc.terminationStatus, out + err)
}

/// Verify a downloaded .app bundle before installing it. The check is *symmetric*: we only
/// enforce signature integrity + Team-ID pinning if the currently running bundle itself passes
/// `codesign --verify --deep --strict`. When the running bundle is ad-hoc signed (as our CI
/// release builds are — no Developer ID cert) its own `--verify` fails with errors like
/// "code has no resources but signature indicates they must be present". Demanding that the
/// downloaded bundle pass a check the current bundle can't pass bricks auto-update for every
/// user. Falling open in that case matches the existing Team-ID dev-build policy.
///
/// Properly Developer-ID-signed + notarized releases get the full check. Ad-hoc releases get
/// no signature check — same trust model as before PR #87, but with the Team-ID pin layered
/// on top whenever it's available.
func verifyDownloadedBundleSignature(at bundleURL: URL) throws {
    // 1. Check the currently running bundle first. If it itself can't pass --verify, we're
    //    running an ad-hoc / dev / unsigned build — enforcing integrity on the downloaded
    //    bundle would lock the user out of any update. Fall open to match Team-ID policy.
    let currentVerify = try runAndCapture(
        executable: "/usr/bin/codesign",
        arguments: ["--verify", "--deep", "--strict", Bundle.main.bundlePath]
    )
    let enforceIntegrity = currentVerify.0 == 0

    if enforceIntegrity {
        let verify = try runAndCapture(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", bundleURL.path]
        )
        guard verify.0 == 0 else {
            throw NSError(domain: "CCUsage", code: 11, userInfo: [NSLocalizedDescriptionKey: "codesign --verify failed: \(verify.1)"])
        }
    }

    // 2. Team Identifier pinning: downloaded bundle must share the running app's team.
    //    We still probe here whether or not integrity was enforced, so an ad-hoc → Team-ID
    //    downgrade attack still fails at the Team-ID step below.
    let currentInfo = try runAndCapture(
        executable: "/usr/bin/codesign",
        arguments: ["-dvvv", Bundle.main.bundlePath]
    )
    let newInfo = try runAndCapture(
        executable: "/usr/bin/codesign",
        arguments: ["-dvvv", bundleURL.path]
    )
    // Probe failure is only fatal when we're also enforcing integrity — otherwise we've
    // already decided the trust floor is "whatever the current bundle is".
    if enforceIntegrity {
        guard currentInfo.0 == 0 else {
            throw NSError(domain: "CCUsage", code: 13, userInfo: [NSLocalizedDescriptionKey: "codesign probe of current bundle failed: \(currentInfo.1)"])
        }
        guard newInfo.0 == 0 else {
            throw NSError(domain: "CCUsage", code: 14, userInfo: [NSLocalizedDescriptionKey: "codesign probe of new bundle failed: \(newInfo.1)"])
        }
    }
    let currentTeam = teamIdentifier(fromCodesignOutput: currentInfo.1)
    let newTeam = teamIdentifier(fromCodesignOutput: newInfo.1)
    // If the running app has no Team ID (e.g. local dev build / ad-hoc CI build) skip the
    // pinning check — otherwise we'd lock users out of their own builds.
    if let currentTeam {
        guard currentTeam == newTeam else {
            throw NSError(
                domain: "CCUsage",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Team Identifier mismatch: current=\(currentTeam) new=\(newTeam ?? "<none>")"]
            )
        }
    }
}
#else
// Tests cannot spawn codesign; this is a no-op stub. Pure parsing of codesign output
// is tested directly via `teamIdentifier(fromCodesignOutput:)`.
func verifyDownloadedBundleSignature(at bundleURL: URL) throws {}
#endif

// MARK: - Sentry Error Reporting

#if !TESTING
private let sentryKey = "e775413587228219897ba908e29d5901"
private let sentryProjectId = "4511105650720769"
private let sentryHost = "o4510977201995776.ingest.us.sentry.io"

// PRODUCTION flag is set by the release workflow via `make build PRODUCTION=1`.
// Dev-machine `make install` builds report as `development`, keeping prod signal clean.
#if PRODUCTION
private let sentryEnvironment = "production"
#else
private let sentryEnvironment = "development"
#endif

private func sentryCapture(type: String, message: String, context: [String: String] = [:]) {
    guard let url = URL(string: "https://\(sentryHost)/api/\(sentryProjectId)/store/?sentry_version=7&sentry_key=\(sentryKey)") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("ccusage-swift/\(currentVersion)", forHTTPHeaderField: "User-Agent")

    let eventId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let timestamp = iso8601Formatter.string(from: Date())
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

    var event: [String: Any] = [
        "event_id": eventId,
        "timestamp": timestamp,
        "level": "error",
        "platform": "cocoa",
        "logger": "ccusage",
        "release": "ccusage@\(currentVersion)",
        "environment": sentryEnvironment,
        "tags": ["os.version": osVersion, "app.version": currentVersion],
        "exception": ["values": [["type": type, "value": message]]]
    ]
    if !context.isEmpty {
        event["extra"] = context
    }

    request.httpBody = try? JSONSerialization.data(withJSONObject: event)
    session.dataTask(with: request) { _, _, _ in }.resume()
}
#endif

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
        // Exponential backoff: 60s, 120s, 240s, capped at maxBackoffInterval (300s)
        let backoff = min(clamped * pow(2.0, Double(consecutiveRateLimits - 1)), maxBackoffInterval)
        interval = backoff
        nextFetchAt = Date().addingTimeInterval(interval)
        isRateLimited = true
    }
}

// MARK: - Widget Data

/// Heartbeat push threshold: force a widget push this often even when values are unchanged.
/// Without heartbeats the iOS widget's `updatedAt` timestamp freezes during idle periods
/// and users perceive the widget as stale.
let widgetHeartbeatInterval: TimeInterval = 300

/// Decide whether to push widget data now. Returns true if metrics changed OR enough time
/// has passed since the last successful push to warrant a heartbeat. Pure logic for testability.
func shouldPushWidget(
    now: Date,
    current: WidgetData,
    lastPushed: WidgetData?,
    lastPushedAt: Date?,
    heartbeatInterval: TimeInterval = widgetHeartbeatInterval
) -> Bool {
    guard let lastPushed, let lastPushedAt else { return true }
    if !lastPushed.hasSameValues(as: current) { return true }
    return now.timeIntervalSince(lastPushedAt) >= heartbeatInterval
}

func buildWidgetData(_ usage: UsageData, activeSessionCount: Int = 0, dailyEntries: [DailyEntry]? = nil, activeSessions: [TrackedSession]? = nil) -> WidgetData {
    let h5Pace = calculatePace(utilization: usage.fiveHour.utilization, resetsAt: usage.fiveHour.resetsAt, windowDuration: 5 * 3600)
    let d7Pace = calculatePace(utilization: usage.sevenDay.utilization, resetsAt: usage.sevenDay.resetsAt, windowDuration: 7 * 86400)
    // Calculate depletion for 7d
    var depletionSecs: Double? = nil
    let d7 = usage.sevenDay.utilization
    let windowDuration: TimeInterval = 7 * 86400
    if let resetsAt = usage.sevenDay.resetsAt, d7 > 0.1, d7 < 100 {
        let remaining = resetsAt.timeIntervalSinceNow
        if remaining > 0, remaining < windowDuration {
            let elapsed = windowDuration - remaining
            if elapsed > 60 {
                let ratePerSec = d7 / elapsed
                let secsToFull = (100.0 - d7) / ratePerSec
                if secsToFull < remaining { depletionSecs = secsToFull }
            }
        }
    }
    // Model breakdown utilization
    let opusUtil = usage.models?.opus?.utilization
    let sonnetUtil = usage.models?.sonnet?.utilization
    // No haiku in ModelBreakdown yet — nil for forward compat
    let haikuUtil: Double? = nil
    // Daily entries
    let entryData = dailyEntries?.map { DailyEntryData(date: $0.date, usage: $0.usage) }
    // Sessions (sorted by project for deterministic comparison; underlying storage may be a Set)
    let sessionData: [SessionData]? = activeSessions.flatMap { sessions in
        let list = sessions.filter { $0.hasDisplayableData }.map { s -> SessionData in
            let project = s.projectName ?? "unknown"
            let model = s.currentModel
            let tokens = s.sessionTokens.totalTokens > 0 ? s.sessionTokens.totalTokens : nil
            let duration: Int? = s.lastFileModification.flatMap { mod in
                let secs = Int(Date().timeIntervalSince(mod))
                return secs > 0 && secs < 86400 ? secs : nil
            }
            return SessionData(project: project, model: model, tokens: tokens, durationSeconds: duration)
        }.sorted { lhs, rhs in
            if lhs.project != rhs.project { return lhs.project < rhs.project }
            if (lhs.model ?? "") != (rhs.model ?? "") { return (lhs.model ?? "") < (rhs.model ?? "") }
            // Tiebreakers keep the sort total — otherwise two sessions with identical
            // (project, model) can flip ordering between pushes and re-trigger `hasSameValues`.
            if (lhs.tokens ?? -1) != (rhs.tokens ?? -1) { return (lhs.tokens ?? -1) < (rhs.tokens ?? -1) }
            return (lhs.durationSeconds ?? -1) < (rhs.durationSeconds ?? -1)
        }
        return list.isEmpty ? nil : list
    }
    return WidgetData(
        fiveHourUtilization: usage.fiveHour.utilization,
        sevenDayUtilization: usage.sevenDay.utilization,
        fiveHourPace: h5Pace,
        sevenDayPace: d7Pace,
        fiveHourResetsAt: usage.fiveHour.resetsAt?.timeIntervalSince1970,
        sevenDayResetsAt: usage.sevenDay.resetsAt?.timeIntervalSince1970,
        updatedAt: Date().timeIntervalSince1970,
        extraUsageEnabled: usage.extraUsage?.isEnabled,
        depletionSeconds: depletionSecs,
        activeSessionCount: activeSessionCount > 0 ? activeSessionCount : nil,
        opusUtilization: opusUtil,
        sonnetUtilization: sonnetUtil,
        haikuUtilization: haikuUtil,
        dailyEntries: entryData,
        sessions: sessionData,
        extraUsageUtilization: usage.extraUsage?.utilization
    )
}

// MARK: - Status Bar Controller

class StatusBarController: NSObject, UNUserNotificationCenterDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var uiTimer: Timer?
    private var secondsTimer: Timer?
    private var isFetching = false
    private var didRetryWithRefresh = false
    private var consecutiveRefreshFailures = 0
    private var lastRefreshDate: Date?
    private var lastUsage: UsageData?
    private var schedule = FetchSchedule()
    private var history = UsageHistory()
    private var notificationState = NotificationState()

    private let detailFiveHour = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let detailSevenDay = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var dailyStore = DailyUsageData()
    private let dailyStorePath = NSHomeDirectory() + "/.ccusage-daily.json"
    private var widgetKey: String?  // Canonical key from Worker (SHA-256 of org ID)
    private var widgetKeyVerified = false  // True after first successful push confirms the key
    private var lastPushedWidgetData: WidgetData?
    private var lastWidgetPushAt: Date?
    /// Byte-identical comparison of the last saved payload. `Data.hashValue` was intentionally
    /// avoided here — it uses a per-process randomized seed, which is correct for Dictionary
    /// hashing but fragile as a "did the value change" check if this were ever persisted across
    /// launches. Holding the full bytes is cheap (tens of KB) and unambiguous.
    private var lastDailyStoreBytes: Data?
    private var qrWindow: NSWindow?
    private let lastRefreshItem = NSMenuItem(title: "Last refresh: never", action: nil, keyEquivalent: "")
    private var sessionStartDate = Date()
    private var sessionFetchCount = 0
    private var usageIncreases: [Date] = []
    private let versionItem = NSMenuItem(title: "v\(currentVersion)", action: nil, keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "Check for Updates\u{2026}", action: nil, keyEquivalent: "u")
    private var isUpdating = false
    private var updateTimer: Timer?
    private let sessionsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var agentTracker = AgentTracker()
    private var agentTimer: Timer?
    private var codexTracker = CodexTracker()
    private var codexTimer: Timer?

    override init() {
        super.init()
        dailyStore = loadDailyStore()
        // Restore session state from persisted store
        if let saved = dailyStore.historyEntries {
            history.restore(saved)
        }
        if let saved = dailyStore.usageIncreases {
            usageIncreases = saved.filter { Date().timeIntervalSince($0) < 86400 }
        }
        widgetKey = dailyStore.widgetKey

        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem.button?.title = "CC ..."

        let menu = NSMenu()
        menu.autoenablesItems = false
        detailFiveHour.isEnabled = false
        detailSevenDay.isEnabled = false
        lastRefreshItem.isEnabled = false

        menu.addItem(detailFiveHour)
        menu.addItem(detailSevenDay)
        menu.addItem(.separator())
        sessionsItem.isEnabled = false
        sessionsItem.isHidden = true
        menu.addItem(sessionsItem)
        menu.addItem(.separator())
        menu.addItem(lastRefreshItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Share to iPhone\u{2026}", action: #selector(showWidgetQRCode), keyEquivalent: "i"))
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
        UNUserNotificationCenter.current().delegate = self
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

        // Poll for active Claude Code agents every 3 seconds
        agentTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshAgents()
        }
        RunLoop.current.add(agentTimer!, forMode: .common)

        // Poll Codex SQLite every 10 seconds
        codexTracker.poll()
        codexTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.codexTracker.poll()
            self?.updateSessionsUI()
        }
        RunLoop.current.add(codexTimer!, forMode: .common)

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
        secondsTimer?.invalidate()
        updateTimer?.invalidate()
        agentTimer?.invalidate()
        codexTimer?.invalidate()
    }

    /// Called every 60s. Refreshes UI and triggers API fetch when due.
    private func tick() {
        refreshUI()
        if Date() >= schedule.nextFetchAt {
            refresh()
        }
    }

    /// Called every 3s. Polls JSONL files for agent events.
    private func refreshAgents() {
        agentTracker.pruneCompleted()
        _ = agentTracker.poll()
        updateSessionsUI()
        updateStatusBarAgentIndicator()
    }

    private func updateSessionsUI() {
        let claudeSessions = agentTracker.activeSessions
        let codexSummary = codexTracker.lastSummary

        let codexHasContent = codexSummary.map { !$0.activeSessions.isEmpty } ?? false
        guard !claudeSessions.isEmpty || codexHasContent else {
            sessionsItem.isHidden = true
            return
        }
        sessionsItem.isHidden = false
        #if TESTING
        sessionsItem.title = formatUnifiedSessions(claudeSessions: claudeSessions, codex: codexSummary)
        #else
        sessionsItem.attributedTitle = formatAttributedUnifiedSessions(claudeSessions: claudeSessions, codex: codexSummary)
        #endif
    }

    private func updateStatusBarAgentIndicator() {
        guard let usage = lastUsage else { return }
        let runningCount = agentTracker.totalRunningCount
        #if TESTING
        var title = formatAdaptiveStatusLine(usage: usage, history: history)
        if runningCount > 0 { title += " \u{26A1}\(runningCount)" }
        statusItem.button?.title = title
        #else
        let base = formatAttributedAdaptiveStatusLine(usage, history: history)
        if runningCount > 0 {
            let result = NSMutableAttributedString(attributedString: base)
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
            result.append(NSAttributedString(string: " \u{26A1}\(runningCount)", attributes: [.font: font, .foregroundColor: NSColor.systemOrange]))
            statusItem.button?.attributedTitle = result
        } else {
            statusItem.button?.attributedTitle = base
        }
        #endif
    }

    /// 1-second timer for the first 60s after a refresh, then auto-stops.
    private func startSecondsTimer() {
        secondsTimer?.invalidate()
        secondsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, let date = self.lastRefreshDate else { timer.invalidate(); return }
            if Date().timeIntervalSince(date) >= 60 {
                timer.invalidate()
                self.secondsTimer = nil
            }
            self.updateLastRefreshLabel()
        }
        RunLoop.current.add(secondsTimer!, forMode: .common)
    }

    // MARK: - Daily Store Persistence

    private func loadDailyStore() -> DailyUsageData {
        guard let data = FileManager.default.contents(atPath: dailyStorePath),
              let store = try? JSONDecoder().decode(DailyUsageData.self, from: data) else {
            return DailyUsageData()
        }
        return store
    }

    private func saveDailyStore() {
        // Snapshot session state into the store before saving
        dailyStore.historyEntries = history.entries
        dailyStore.usageIncreases = usageIncreases
        guard let data = try? JSONEncoder().encode(dailyStore) else { return }
        // Dedup: this is called on every refresh (60s) — most of the time nothing changed.
        // Writing JSON + fsync unconditionally churns the disk for no gain. Compare the encoded
        // bytes and skip the write when identical to the previous save.
        if let last = lastDailyStoreBytes, last == data { return }
        lastDailyStoreBytes = data
        FileManager.default.createFile(atPath: dailyStorePath, contents: data)
    }

    // MARK: - Widget Sync

    private func pushWidgetData(_ usage: UsageData) {
        guard let credData = readCredentialData(),
              let token = parseToken(from: credData),
              let url = URL(string: "\(widgetWorkerURL)/widget") else { return }
        let widgetData = buildWidgetData(
            usage,
            activeSessionCount: agentTracker.totalRunningCount,
            dailyEntries: dailyStore.days,
            activeSessions: Array(agentTracker.activeSessions)
        )
        // Heartbeat: push unchanged data periodically so iOS widget's updatedAt keeps advancing.
        guard shouldPushWidget(
            now: Date(),
            current: widgetData,
            lastPushed: lastPushedWidgetData,
            lastPushedAt: lastWidgetPushAt
        ) else { return }
        let body = WidgetPushBody(data: widgetData)
        guard let bodyData = try? JSONEncoder().encode(body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        session.dataTask(with: request) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let key = json["key"] as? String, !key.isEmpty else { return }
            DispatchQueue.main.async {
                self?.widgetKey = key
                self?.widgetKeyVerified = true
                self?.lastPushedWidgetData = widgetData
                self?.lastWidgetPushAt = Date()
                if self?.dailyStore.widgetKey != key {
                    self?.dailyStore.widgetKey = key
                    self?.saveDailyStore()
                }
            }
        }.resume()
    }

    private func widgetURL() -> String? {
        guard let key = widgetKey, widgetKeyVerified else { return nil }
        return "\(widgetWorkerURL)/widget/\(key)"
    }

    @objc func showWidgetQRCode() {
        guard let urlString = widgetURL() else {
            let alert = NSAlert()
            alert.messageText = "Not ready yet"
            alert.informativeText = "Waiting for the first successful data refresh. Try again in a moment."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return }
        filter.setValue(Data(urlString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return }
        let scale = CGAffineTransform(scaleX: 8, y: 8)
        let scaledImage = ciImage.transformed(by: scale)
        let rep = NSCIImageRep(ciImage: scaledImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Share to iPhone"
        window.level = .floating
        window.center()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 400))
        let imageView = NSImageView(frame: NSRect(x: 50, y: 80, width: 240, height: 240))
        imageView.image = nsImage
        imageView.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(imageView)
        let label = NSTextField(labelWithString: "Scan with CCUsage on iPhone")
        label.frame = NSRect(x: 20, y: 340, width: 300, height: 30)
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        view.addSubview(label)
        let urlLabel = NSTextField(labelWithString: urlString)
        urlLabel.frame = NSRect(x: 20, y: 30, width: 300, height: 40)
        urlLabel.alignment = .center
        urlLabel.font = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
        urlLabel.lineBreakMode = .byCharWrapping
        urlLabel.maximumNumberOfLines = 3
        view.addSubview(urlLabel)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        qrWindow = window
    }

    // MARK: - Keychain

    /// Read OAuth credentials from the Keychain (`security` CLI) or `~/.claude/.credentials.json`.
    private func readCredentialData() -> Data? {
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
            if proc.terminationStatus == 0 { return data }
        } catch {}
        // Fallback: read from Claude Code credentials file
        let credPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/.credentials.json")
        return FileManager.default.contents(atPath: credPath)
    }

    private func readClaudeConfigData() -> Data? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
        return FileManager.default.contents(atPath: path)
    }

    private func missingCredentialsDetails() -> (String, String) {
        let data = readClaudeConfigData()
        return _missingCredentialsDetails(from: data)
    }

    /// Discover the account name associated with the keychain entry (needed for delete/add).
    private func readKeychainAccount() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", keychainService]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else { return nil }
            return parseKeychainAccount(from: output)
        } catch {
            return nil
        }
    }

    private func readRefreshToken() -> String? {
        guard let data = readCredentialData() else { return nil }
        return parseRefreshToken(from: data)
    }

    /// Write updated credentials back to the keychain.
    private func writeKeychainData(_ data: Data) -> Bool {
        guard let jsonStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        let account = readKeychainAccount()
        // Delete existing entry, then add new one
        let del = Process()
        del.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var delArgs = ["delete-generic-password", "-s", keychainService]
        if let account { delArgs += ["-a", account] }
        del.arguments = delArgs
        del.standardOutput = FileHandle.nullDevice
        del.standardError = FileHandle.nullDevice
        try? del.run()
        del.waitUntilExit()

        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var addArgs = ["add-generic-password", "-s", keychainService]
        if let account { addArgs += ["-a", account] }
        addArgs += ["-w", jsonStr]
        add.arguments = addArgs
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

    /// Write updated credentials back to `~/.claude/.credentials.json`.
    @discardableResult
    /// Write updated credentials back to `~/.claude/.credentials.json` with owner-only (0600) permissions.
    private func writeCredentialsFile(_ data: Data) -> Bool {
        let credPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/.credentials.json")
        // Create with 0600 up front; any process must be unable to read the OAuth refresh token.
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: Int16(0o600))]
        let created = FileManager.default.createFile(atPath: credPath, contents: data, attributes: attrs)
        guard created else { return false }
        // `createFile` replaces existing files but behavior around re-applying permissions on
        // overwrite is historically filesystem-dependent. Force-apply 0600 so a file that was
        // previously stored with looser perms gets tightened here. If this fails we must NOT
        // tell the caller the write succeeded — a refresh token sitting at 0644 is worse than
        // one not written at all (we can retry, Keychain is still authoritative).
        do {
            try FileManager.default.setAttributes(attrs, ofItemAtPath: credPath)
            return true
        } catch {
            try? FileManager.default.removeItem(atPath: credPath)
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
                #if !TESTING
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                sentryCapture(type: "OAuthRefreshError", message: "Token refresh failed (HTTP \(statusCode))")
                #endif
                completion(nil)
                return
            }

            // Update keychain (or credentials file) with new tokens
            DispatchQueue.main.async {
                guard let self, let credentialData = self.readCredentialData(),
                      var creds = try? JSONSerialization.jsonObject(with: credentialData) as? [String: Any],
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
                    if !self.writeKeychainData(updatedData) {
                        self.writeCredentialsFile(updatedData)
                    }
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

                if let error {
                    self.setError("Connection failed")
                    #if !TESTING
                    sentryCapture(type: "APIConnectionError", message: error.localizedDescription)
                    #endif
                    return
                }

                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    if http.statusCode == 401 {
                        if !self.didRetryWithRefresh {
                            self.didRetryWithRefresh = true
                            self.lastRefreshItem.title = "Refreshing token..."
                            self.refreshOAuthToken { [weak self] newToken in
                                guard let self else { return }
                                if let newToken {
                                    self.consecutiveRefreshFailures = 0
                                    self.fetchUsage(token: newToken)
                                } else {
                                    self.didRetryWithRefresh = false
                                    self.handleRefreshFailure()
                                }
                            }
                            return
                        }
                        self.didRetryWithRefresh = false
                        self.handleRefreshFailure()
                    } else if http.statusCode == 429 {
                        // Rate limit is per-access-token; refresh to get a new one
                        if !self.didRetryWithRefresh {
                            self.didRetryWithRefresh = true
                            self.lastRefreshItem.title = "Refreshing token..."
                            self.refreshOAuthToken { [weak self] newToken in
                                guard let self, let newToken else {
                                    self?.handleRateLimit(raw: http.value(forHTTPHeaderField: "retry-after").flatMap { Int($0) } ?? Int(maxBackoffInterval))
                                    self?.didRetryWithRefresh = false
                                    return
                                }
                                self.consecutiveRefreshFailures = 0
                                self.fetchUsage(token: newToken)
                            }
                            return
                        }
                        self.didRetryWithRefresh = false
                        let raw = http.value(forHTTPHeaderField: "retry-after").flatMap { Int($0) } ?? Int(maxBackoffInterval)
                        self.handleRateLimit(raw: raw)
                    } else {
                        self.setError("Server error")
                        #if !TESTING
                        sentryCapture(type: "APIServerError", message: "HTTP \(http.statusCode)", context: ["url": usageAPIURL])
                        #endif
                    }
                    return
                }

                guard let data, let usage = parseUsage(from: data) else {
                    self.setError("Unexpected response")
                    #if !TESTING
                    sentryCapture(type: "APIParseError", message: "Failed to parse usage response")
                    #endif
                    return
                }
                self.updateDisplay(usage)
            }
        }.resume()
    }

    private func handleRateLimit(raw: Int) {
        let retryAfter = clampRetryAfter(raw)
        schedule.onRateLimit(retryAfter: retryAfter)
        let minutes = (retryAfter + 59) / 60
        if lastUsage == nil {
            setError("Rate limited")
        }
        lastRefreshItem.title = "Next API call in \(minutes)m (rate limited)"
    }

    private func handleRefreshFailure() {
        consecutiveRefreshFailures += 1
        if consecutiveRefreshFailures >= 3 {
            setError("Token expired")
            detailFiveHour.title = "Re-authenticate in Claude Code"
            detailSevenDay.title = "Then click Refresh Now"
            detailSevenDay.isHidden = false
        } else {
            schedule.nextFetchAt = Date().addingTimeInterval(schedule.interval)
            let minutes = Int(schedule.interval) / 60
            if lastUsage == nil {
                setError("Token refresh failed")
            }
            lastRefreshItem.title = "Token refresh failed \u{2014} retrying in \(max(minutes, 1))m"
        }
    }

    // MARK: - Display

    private func updateDisplay(_ usage: UsageData) {
        // Track usage increases BEFORE recording to history (compare against previous entry)
        if let prev = history.entries.last {
            if usage.fiveHour.utilization > prev.fiveHour || usage.sevenDay.utilization > prev.sevenDay {
                usageIncreases.append(Date())
            }
        }
        sessionFetchCount += 1

        lastUsage = usage
        history.record(usage)
        recordDailyUsage(&dailyStore, sevenDayUtilization: usage.sevenDay.utilization)
        saveDailyStore()
        #if !TESTING
        pushWidgetData(usage)
        #endif
        lastRefreshDate = Date()
        startSecondsTimer()
        didRetryWithRefresh = false
        consecutiveRefreshFailures = 0
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
        let d7 = usage.sevenDay.utilization

        // Status bar title is updated via updateStatusBarAgentIndicator which includes usage + agent count
        updateStatusBarAgentIndicator()

        #if TESTING
        // Compact 5-hour line
        detailFiveHour.title = formatCompactFiveHour(window: usage.fiveHour, sparkline: nil, extraUsage: usage.extraUsage)

        // 7-day section
        let mergedDays = dailyStore.days
        let d7Forecast = formatForecastLine(utilization: d7, resetsAt: usage.sevenDay.resetsAt, windowDuration: 7 * 86400)
        let d7Pace = calculatePace(utilization: d7, resetsAt: usage.sevenDay.resetsAt, windowDuration: 7 * 86400)
        var pctLine = "7d: \(formatValue(d7))%"
        if let pace = d7Pace {
            pctLine += String(format: " \u{00B7} %.1fx", pace)
        }
        if let resetStr = compactResetTime(usage.sevenDay.resetsAt) {
            pctLine += " \u{00B7} resets \(resetStr)"
        }
        if let forecast = d7Forecast {
            if forecast.hasPrefix("Safe") {
                pctLine += " \u{00B7} Safe"
            } else if forecast.hasPrefix("Depletes") {
                pctLine += " \u{00B7} \(forecast.replacingOccurrences(of: " \u{00B7}.*$", with: "", options: .regularExpression))"
            } else {
                pctLine += " \u{00B7} \(forecast)"
            }
        }
        var sevenDayLines: [String] = [pctLine]
        if let chart = weeklyChart(mergedDays) {
            let values = weeklyChartValues(mergedDays)
            let total = values.reduce(0, +)
            let aligned = alignedWeeklyColumns(chart: chart, values: values, dayLabel: weeklyChartLabel())
            sevenDayLines.append(String(format: "  Week  \(aligned.chart) %.0f%%", total))
            sevenDayLines.append("        \(aligned.pcts)")
            sevenDayLines.append("        \(aligned.days)")
        }
        if let heatmap = hourlyHeatmap(usageIncreases) {
            sevenDayLines.append("  Today \(heatmap)")
            sevenDayLines.append("        \(hourlyHeatmapLabel())")
        }
        detailSevenDay.title = sevenDayLines.joined(separator: "\n")
        #else
        // Compact 5-hour window
        detailFiveHour.attributedTitle = formatAttributedCompactFiveHour(window: usage.fiveHour, sparkline: nil, extraUsage: usage.extraUsage)

        // 7-day section with forecast + activity inline
        let mergedDays = dailyStore.days
        let d7Forecast = formatForecastLine(utilization: d7, resetsAt: usage.sevenDay.resetsAt, windowDuration: 7 * 86400)
        detailSevenDay.attributedTitle = formatAttributedSevenDay(usage: usage, forecast: d7Forecast, dailyDays: mergedDays, hourlyIncreases: usageIncreases)
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
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 {
            lastRefreshItem.title = "Last refresh: \(seconds)s ago"
        } else {
            let minutes = seconds / 60
            lastRefreshItem.title = "Last refresh: \(minutes)m ago"
        }
    }

    private func setError(_ msg: String) {
        statusItem.button?.title = "\u{1F534} CC: [\(msg)]"
        detailFiveHour.title = "Error: \(msg)"
        detailSevenDay.isHidden = true
        lastRefreshItem.title = "Last attempt: failed"
    }

    // MARK: - Notification Delegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Actions

    @objc func refresh() {
        guard !isFetching else { return }
        detailSevenDay.isHidden = false

        guard let credentialData = readCredentialData() else {
            setError("No creds")
            let details = missingCredentialsDetails()
            detailFiveHour.title = details.0
            detailSevenDay.title = details.1
            detailSevenDay.isHidden = false
            return
        }

        guard let token = parseToken(from: credentialData) else {
            setError("No creds")
            let details = missingCredentialsDetails()
            detailFiveHour.title = details.0
            detailSevenDay.title = details.1
            detailSevenDay.isHidden = false
            return
        }

        // Proactive refresh: if token expires within 5 minutes, refresh first
        let expiresAt = parseExpiresAt(from: credentialData)
        if let expiresAt, expiresAt.timeIntervalSinceNow < 300 {
            isFetching = true
            lastRefreshItem.title = "Refreshing token..."
            refreshOAuthToken { [weak self] newToken in
                guard let self else { return }
                if let newToken {
                    self.consecutiveRefreshFailures = 0
                    self.fetchUsage(token: newToken)
                } else {
                    self.isFetching = false
                    self.handleRefreshFailure()
                }
            }
            return
        }

        fetchUsage(token: token)
    }

    // MARK: - Auto-Update

    private var isCheckingForUpdates = false
    private var autoInstallFailedVersion: String?
    private var pendingUpdateVersion: String?

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
                        self.pendingUpdateVersion = info.tagName
                        self.updateItem.representedObject = downloadURL
                        self.updateItem.title = "Update available: \(info.tagName)"
                        if self.autoInstallFailedVersion == info.tagName {
                            self.updateItem.action = #selector(self.installUpdateManually)
                            self.updateItem.isEnabled = true
                        } else {
                            self.updateItem.action = nil
                            self.updateItem.isEnabled = false
                            self.installUpdate()
                        }
                    } else {
                        self.updateItem.title = "Update \(info.tagName) available on GitHub"
                        self.updateItem.action = nil
                        self.updateItem.isEnabled = false
                    }
                } else {
                    self.updateItem.title = "Up to date"
                    self.updateItem.action = #selector(self.checkForUpdates)
                    self.updateItem.isEnabled = true
                }
            }
        }.resume()
    }

    @objc func installUpdateManually() {
        autoInstallFailedVersion = nil
        installUpdate()
    }

    func installUpdate() {
        guard let downloadURLString = updateItem.representedObject as? String,
              isValidDownloadURL(downloadURLString),
              let downloadURL = URL(string: downloadURLString) else {
            updateItem.title = "Invalid download URL"
            return
        }

        isUpdating = true
        updateItem.title = "Downloading update\u{2026}"
        updateItem.action = nil
        updateItem.isEnabled = false

        let task = URLSession.shared.downloadTask(with: downloadURL) { [weak self] tempURL, response, error in
            guard let tempURL, error == nil else {
                #if !TESTING
                sentryCapture(type: "UpdateDownloadError", message: error?.localizedDescription ?? "Download failed")
                #endif
                DispatchQueue.main.async {
                    self?.isUpdating = false
                    self?.autoInstallFailedVersion = self?.pendingUpdateVersion
                    self?.updateItem.title = "Download failed"
                    self?.updateItem.action = #selector(self?.checkForUpdates)
                    self?.updateItem.isEnabled = true
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

                // Verify code signature is intact + Team ID matches currently running bundle.
                // This blocks tampered/MITM'd archives from being installed.
                try verifyDownloadedBundleSignature(at: newApp)

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
                #if !TESTING
                sentryCapture(type: "UpdateInstallError", message: error.localizedDescription)
                #endif
                try? fm.removeItem(at: tempDir)
                DispatchQueue.main.async {
                    self?.isUpdating = false
                    self?.autoInstallFailedVersion = self?.pendingUpdateVersion
                    self?.updateItem.title = "Update failed"
                    self?.updateItem.action = #selector(self?.checkForUpdates)
                    self?.updateItem.isEnabled = true
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
