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
let defaultFetchInterval: TimeInterval = 120  // 2 minutes
private let maxBackoffInterval: TimeInterval = 300  // 5 minutes
private let iCloudSubfolder = ".ccusage"

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

func budgetAdvice(utilization: Double, resetsAt: Date?, windowDuration: TimeInterval, now: Date = Date()) -> String? {
    guard let resetsAt else { return nil }
    let remaining = resetsAt.timeIntervalSince(now)
    guard remaining > 60 else { return nil }
    let pctLeft = 100.0 - utilization
    guard pctLeft > 0 else { return "Budget exhausted" }
    let hoursLeft = remaining / 3600.0
    guard hoursLeft >= 0.5 else { return "Budget: use sparingly" }
    let perHour = pctLeft / hoursLeft
    return String(format: "Budget: %.1f%%/hour to last the window", perHour)
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
    let d7Pace = calculatePace(utilization: d7, resetsAt: usage.sevenDay.resetsAt, windowDuration: 7 * 86400)
    let indicator = paceIndicator(pace: d7Pace)
    return "\(formatValue(h5))/\(formatValue(d7))\(indicator)"
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

    init(lastUtilization: Double? = nil, days: [DailyEntry] = [], historyEntries: [UsageHistory.Entry]? = nil, usageIncreases: [Date]? = nil) {
        self.lastUtilization = lastUtilization
        self.days = days
        self.historyEntries = historyEntries
        self.usageIncreases = usageIncreases
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
    guard let firstDash = afterHome.firstIndex(of: "-") else { return nil }
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

// MARK: - Token Cost Tracking

struct ModelPricing {
    let inputPerMTok: Double
    let outputPerMTok: Double
    let cacheWritePerMTok: Double
    let cacheReadPerMTok: Double
}

let modelPricingTable: [String: ModelPricing] = [
    "opus": ModelPricing(inputPerMTok: 15.0, outputPerMTok: 75.0, cacheWritePerMTok: 18.75, cacheReadPerMTok: 1.50),
    "sonnet": ModelPricing(inputPerMTok: 3.0, outputPerMTok: 15.0, cacheWritePerMTok: 3.75, cacheReadPerMTok: 0.30),
    "haiku": ModelPricing(inputPerMTok: 0.80, outputPerMTok: 4.0, cacheWritePerMTok: 1.0, cacheReadPerMTok: 0.08),
]

func pricingForModel(_ model: String) -> ModelPricing {
    let lower = model.lowercased()
    for (family, pricing) in modelPricingTable {
        if lower.contains(family) { return pricing }
    }
    return modelPricingTable["opus"]!  // default to most expensive
}

struct TokenCostEntry {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var cacheReadTokens: Int = 0
    var requests: Int = 0
    var totalCost: Double = 0

    var totalInputTokens: Int { inputTokens + cacheWriteTokens + cacheReadTokens }

    var cacheHitRate: Double? {
        let total = Double(totalInputTokens)
        guard total > 0, cacheReadTokens > 0 else { return nil }
        return Double(cacheReadTokens) / total
    }

    mutating func add(model: String, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) {
        inputTokens += input
        outputTokens += output
        cacheWriteTokens += cacheWrite
        cacheReadTokens += cacheRead
        requests += 1
        let p = pricingForModel(model)
        totalCost += Double(input) / 1_000_000 * p.inputPerMTok
            + Double(output) / 1_000_000 * p.outputPerMTok
            + Double(cacheWrite) / 1_000_000 * p.cacheWritePerMTok
            + Double(cacheRead) / 1_000_000 * p.cacheReadPerMTok
    }
}

class TokenCostTracker {
    private var dailyCosts: [String: TokenCostEntry] = [:]  // "YYYY-MM-DD" -> entry
    private var fileOffsets: [String: UInt64] = [:]
    private let claudeDir: String
    private var lastFullScan: Date = .distantPast
    private let scanInterval: TimeInterval = 60

    init(claudeDir: String? = nil) {
        self.claudeDir = claudeDir ?? (NSHomeDirectory() + "/.claude/projects")
    }

    func costForDate(_ date: String) -> TokenCostEntry? {
        dailyCosts[date]
    }

    var todayCost: TokenCostEntry {
        let today = dateString(from: Date())
        return dailyCosts[today] ?? TokenCostEntry()
    }

    var weekCost: TokenCostEntry {
        aggregateCost(days: 7)
    }

    var monthCost: TokenCostEntry {
        aggregateCost(days: 30)
    }

    private func aggregateCost(days: Int) -> TokenCostEntry {
        var result = TokenCostEntry()
        let cal = Calendar.current
        for i in 0..<days {
            guard let date = cal.date(byAdding: .day, value: -i, to: Date()) else { continue }
            let key = dateString(from: date)
            if let entry = dailyCosts[key] {
                result.inputTokens += entry.inputTokens
                result.outputTokens += entry.outputTokens
                result.cacheWriteTokens += entry.cacheWriteTokens
                result.cacheReadTokens += entry.cacheReadTokens
                result.requests += entry.requests
                result.totalCost += entry.totalCost
            }
        }
        return result
    }

    private func dateString(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// Process raw JSONL data (for testing)
    func processData(_ data: Data) {
        let lines = data.split(separator: UInt8(ascii: "\n"))
        for line in lines {
            processLine(Data(line))
        }
    }

    private func processLine(_ lineData: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let type = json["type"] as? String, type == "assistant",
              let timestamp = json["timestamp"] as? String,
              timestamp.count >= 10 else { return }
        let message = json["message"] as? [String: Any]
        guard let usage = (message?["usage"] as? [String: Any]) ?? (json["usage"] as? [String: Any]) else { return }
        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        guard input > 0 || output > 0 || cacheWrite > 0 || cacheRead > 0 else { return }
        let model = (message?["model"] as? String) ?? (json["model"] as? String) ?? "unknown"
        let dateKey = String(timestamp.prefix(10))
        dailyCosts[dateKey, default: TokenCostEntry()].add(model: model, input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead)
    }

    /// Poll all JSONL files for new data. Throttled to full scan every 60s.
    @discardableResult
    func poll() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastFullScan) >= scanInterval else { return false }
        lastFullScan = now

        let fm = FileManager.default
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: claudeDir) else { return false }

        var changed = false
        for dir in projectDirs {
            let projectPath = (claudeDir as NSString).appendingPathComponent(dir)
            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = (projectPath as NSString).appendingPathComponent(file)
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let modified = attrs[.modificationDate] as? Date,
                      modified > cutoff,
                      let fileSize = attrs[.size] as? UInt64 else { continue }

                let currentOffset = fileOffsets[path] ?? 0
                guard fileSize > currentOffset else { continue }

                guard let handle = FileHandle(forReadingAtPath: path) else { continue }
                defer { handle.closeFile() }
                handle.seek(toFileOffset: currentOffset)
                let newData = handle.readDataToEndOfFile()
                fileOffsets[path] = currentOffset + UInt64(newData.count)

                let lines = newData.split(separator: UInt8(ascii: "\n"))
                for line in lines {
                    processLine(Data(line))
                }
                changed = true
            }
            // Also scan subagent directories
            let subagentsPath = (projectPath as NSString).appendingPathComponent("subagents")
            if let subFiles = try? fm.contentsOfDirectory(atPath: subagentsPath) {
                for file in subFiles where file.hasSuffix(".jsonl") {
                    let path = (subagentsPath as NSString).appendingPathComponent(file)
                    guard let attrs = try? fm.attributesOfItem(atPath: path),
                          let modified = attrs[.modificationDate] as? Date,
                          modified > cutoff,
                          let fileSize = attrs[.size] as? UInt64 else { continue }

                    let currentOffset = fileOffsets[path] ?? 0
                    guard fileSize > currentOffset else { continue }

                    guard let handle = FileHandle(forReadingAtPath: path) else { continue }
                    defer { handle.closeFile() }
                    handle.seek(toFileOffset: currentOffset)
                    let newData = handle.readDataToEndOfFile()
                    fileOffsets[path] = currentOffset + UInt64(newData.count)

                    let lines = newData.split(separator: UInt8(ascii: "\n"))
                    for line in lines {
                        processLine(Data(line))
                    }
                    changed = true
                }
            }
        }
        return changed
    }
}

func formatCost(_ cost: Double) -> String {
    if cost >= 1000 {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return "$" + (formatter.string(from: NSNumber(value: cost)) ?? String(format: "%.2f", cost))
    }
    return String(format: "$%.2f", cost)
}

func formatTokenCosts(today: TokenCostEntry, week: TokenCostEntry, month: TokenCostEntry) -> String {
    var lines = ["Token Costs (est.)"]
    guard week.requests > 0 else {
        lines.append("  No usage data yet")
        return lines.joined(separator: "\n")
    }

    func row(_ label: String, _ entry: TokenCostEntry, showCache: Bool = false) -> String {
        var parts = ["\(formatCost(entry.totalCost))  \(formatTokenCount(entry.requests)) req"]
        if showCache, let rate = entry.cacheHitRate {
            parts.append(String(format: "%.0f%% cache", rate * 100))
        }
        return "  \(label)  \(parts.joined(separator: " \u{00B7} "))"
    }

    if today.requests > 0 {
        lines.append(row("Today", today, showCache: true))
    }
    lines.append(row("7-day", week))
    lines.append(row("30-day", month))
    return lines.joined(separator: "\n")
}

#if !TESTING
func formatAttributedTokenCosts(today: TokenCostEntry, week: TokenCostEntry, month: TokenCostEntry) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let font = NSFont.systemFont(ofSize: 13)
    let smallFont = NSFont.systemFont(ofSize: 11)
    let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    let boldFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)

    result.append(NSAttributedString(string: "Token Costs (est.)", attributes: [.font: font]))

    guard week.requests > 0 else {
        result.append(NSAttributedString(string: "\n  No usage data yet", attributes: [.font: smallFont, .foregroundColor: NSColor.tertiaryLabelColor]))
        return result
    }

    func row(_ label: String, _ entry: TokenCostEntry, showCache: Bool = false) {
        result.append(NSAttributedString(string: "\n  \(label)  ", attributes: [.font: smallFont, .foregroundColor: NSColor.secondaryLabelColor]))
        result.append(NSAttributedString(string: formatCost(entry.totalCost), attributes: [.font: boldFont, .foregroundColor: NSColor.labelColor]))
        result.append(NSAttributedString(string: "  \(formatTokenCount(entry.requests)) req", attributes: [.font: monoFont, .foregroundColor: NSColor.tertiaryLabelColor]))
        if showCache, let rate = entry.cacheHitRate {
            result.append(NSAttributedString(string: String(format: " \u{00B7} %.0f%% cache", rate * 100), attributes: [.font: monoFont, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
    }

    if today.requests > 0 {
        row("Today ", today, showCache: true)
    }
    row("7-day ", week)
    row("30-day", month)

    return result
}
#endif

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

func formatAgentSection(_ agents: [TrackedAgent], projectName: String? = nil, stats: AgentStats = AgentStats(), isStale: Bool = false, sessionTokens: SessionTokens = SessionTokens(), currentModel: String? = nil, shellRequestCount: Int = 0, contextTokens: Int = 0, contextWindowMax: Int = 0, now: Date = Date()) -> String {
    let sessionStatsLine = formatSessionStats(sessionTokens, model: currentModel)
    if isStale {
        var lines = ["Session \u{00B7} session idle"]
        if !sessionStatsLine.isEmpty { lines.append("  \(sessionStatsLine)") }
        let agentStatsLine = formatAgentStatsLine(stats)
        if !agentStatsLine.isEmpty { lines.append("  \(agentStatsLine)") }
        return lines.joined(separator: "\n")
    }
    guard !agents.isEmpty || sessionTokens.totalTokens > 0 else { return "" }
    let running = agents.filter { $0.isRunning }.count
    let done = agents.count - running

    var header = "Session"
    if let name = projectName { header += " \u{00B7} \(name)" }
    var parts: [String] = []
    if running > 0 { parts.append("\(running) running") }
    if done > 0 { parts.append("\(done) done") }
    if !parts.isEmpty { header += " (\(parts.joined(separator: " \u{00B7} ")))" }

    var lines = [header]
    if !sessionStatsLine.isEmpty { lines.append("  \(sessionStatsLine)") }
    var detailParts: [String] = []
    if sessionTokens.totalTokens > 0 { detailParts.append("\(formatTokenCount(sessionTokens.totalTokens)) tokens") }
    if contextWindowMax > 0 { detailParts.append("\(formatTokenCount(contextTokens))/\(formatTokenCount(contextWindowMax)) ctx") }
    if shellRequestCount > 0 { detailParts.append("\(shellRequestCount) shell") }
    if !detailParts.isEmpty { lines.append("  \(detailParts.joined(separator: " \u{00B7} "))") }
    for agent in agents {
        let status = agent.isRunning ? "\u{25CF}" : "\u{2713}"
        let duration = formatAgentDuration(agent, now: now)
        let tokens = agent.totalTokens.map { " \(formatTokenCount($0)) tok" } ?? ""
        let state = agent.isRunning ? " running" : ""
        lines.append("  \(status) \(agent.description)  \(duration)\(tokens)\(state)")
    }
    let agentStatsLine = formatAgentStatsLine(stats)
    if !agentStatsLine.isEmpty { lines.append("  \(agentStatsLine)") }
    return lines.joined(separator: "\n")
}

func formatMultiSessionSection(_ sessions: [TrackedSession], now: Date = Date()) -> String {
    guard !sessions.isEmpty else { return "" }
    let nonStale = sessions.filter { !$0.isStale }
    let headerCount = nonStale.isEmpty ? sessions.count : nonStale.count
    let headerLabel = nonStale.isEmpty ? "idle" : "active"
    var lines = ["Sessions (\(headerCount) \(headerLabel))"]
    for session in sessions {
        var header = "  "
        if let name = session.projectName { header += name } else { header += "unknown" }
        if let model = session.currentModel { header += " \u{00B7} \(modelDisplayName(model))" }
        if session.isStale { header += " \u{00B7} idle" }
        lines.append(header)
        var detailParts: [String] = []
        if session.sessionTokens.totalTokens > 0 { detailParts.append("\(formatTokenCount(session.sessionTokens.totalTokens)) tokens") }
        if session.contextWindowMax > 0 { detailParts.append("\(formatTokenCount(session.lastContextTokens))/\(formatTokenCount(session.contextWindowMax)) ctx") }
        if session.shellRequestCount > 0 { detailParts.append("\(session.shellRequestCount) shell") }
        if !detailParts.isEmpty { lines.append("    \(detailParts.joined(separator: " \u{00B7} "))") }
        for agent in session.agents {
            let status = agent.isRunning ? "\u{25CF}" : "\u{2713}"
            let duration = formatAgentDuration(agent, now: now)
            let tokens = agent.totalTokens.map { " \(formatTokenCount($0)) tok" } ?? ""
            let state = agent.isRunning ? " running" : ""
            lines.append("    \(status) \(agent.description)  \(duration)\(tokens)\(state)")
        }
    }
    return lines.joined(separator: "\n")
}

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
private let colorYellow = NSColor(red: 0.85, green: 0.65, blue: 0.0, alpha: 1.0)
private let colorGreen = NSColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1.0)

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

func usageColor(for pct: Double, pace: Double? = nil) -> NSColor {
    let effective = pace.map { max(pct, pct * $0) } ?? pct
    if effective >= 80 { return colorRed }
    if effective >= 50 { return colorYellow }
    return colorGreen
}

func formatAttributedStatusLine(_ usage: UsageData, history: UsageHistory = UsageHistory()) -> NSAttributedString {
    let d7 = usage.sevenDay.utilization
    let d7Pace = calculatePace(utilization: d7, resetsAt: usage.sevenDay.resetsAt, windowDuration: 7 * 86400)

    let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    let attrs: [NSAttributedString.Key: Any] = [.font: font]

    let result = NSMutableAttributedString()
    result.append(NSAttributedString(string: "\(formatValue(usage.fiveHour.utilization))/\(formatValue(d7))", attributes: attrs))
    let indicator = paceIndicator(pace: d7Pace)
    if !indicator.isEmpty {
        result.append(NSAttributedString(string: indicator, attributes: attrs))
    }
    return result
}

func progressBar(percent: Double, width: Int = 20) -> (filled: String, empty: String) {
    let filledCount = Int((percent / 100.0) * Double(width))
    let emptyCount = width - filledCount
    return (String(repeating: "●", count: filledCount), String(repeating: "○", count: emptyCount))
}

func paceColor(_ pace: Double) -> NSColor {
    if pace > 1.2 { return colorRed }
    if pace < 0.8 { return colorGreen }
    return NSColor.secondaryLabelColor
}

func formatAttributedMenuItem(label: String, window: UsageWindow, pace: Double? = nil, sparkline: String = "") -> NSAttributedString {
    let pct = window.utilization
    let remaining = window.remaining.map { formatValue($0) } ?? formatValue(100.0 - pct)
    let resetStr = formatResetTime(window.resetsAt)
    let color = usageColor(for: pct)

    let font = NSFont.systemFont(ofSize: 13)
    let boldFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
    let barFont = NSFont.systemFont(ofSize: 9)

    let result = NSMutableAttributedString()

    // Line 1: label + bold colored percentage + free + reset
    result.append(NSAttributedString(string: "\(label):  ", attributes: [.font: font]))
    result.append(NSAttributedString(string: "\(formatValue(pct))%", attributes: [.font: boldFont, .foregroundColor: color]))
    result.append(NSAttributedString(string: "  \u{2022} \(remaining)% free", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
    result.append(NSAttributedString(string: resetStr, attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))

    // Line 2: dot progress bar + pace
    let bar = progressBar(percent: pct)
    result.append(NSAttributedString(string: "\n  ", attributes: [.font: barFont]))
    result.append(NSAttributedString(string: bar.filled, attributes: [.font: barFont, .foregroundColor: color]))
    result.append(NSAttributedString(string: bar.empty, attributes: [.font: barFont, .foregroundColor: NSColor.separatorColor]))
    if let pace {
        result.append(NSAttributedString(string: String(format: "  %.1fx", pace), attributes: [.font: font, .foregroundColor: paceColor(pace)]))
    }

    // Line 3: sparkline if available
    if !sparkline.isEmpty {
        let sparkFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        result.append(NSAttributedString(string: "\n  \(sparkline)", attributes: [.font: sparkFont, .foregroundColor: NSColor.tertiaryLabelColor]))
    }

    return result
}
#endif

func formatModelBreakdown(_ models: ModelBreakdown, extraUsage: ExtraUsage? = nil) -> String {
    var lines: [String] = ["Model Usage (7-day)"]
    if let opus = models.opus {
        lines.append("  Opus:   \(formatValue(opus.utilization))%\(formatResetTime(opus.resetsAt))")
    }
    if let sonnet = models.sonnet {
        lines.append("  Sonnet: \(formatValue(sonnet.utilization))%\(formatResetTime(sonnet.resetsAt))")
    }
    if let oauth = models.oauthApps {
        lines.append("  OAuth:  \(formatValue(oauth.utilization))%\(formatResetTime(oauth.resetsAt))")
    }
    if let cowork = models.cowork {
        lines.append("  Cowork: \(formatValue(cowork.utilization))%\(formatResetTime(cowork.resetsAt))")
    }
    if let extra = extraUsage, extra.isEnabled {
        let val = extra.utilization.map { formatValue($0) + "%" } ?? "enabled"
        lines.append("  Extra:  \(val)")
    }
    return lines.joined(separator: "\n")
}

#if !TESTING
func formatAttributedModelBreakdown(_ models: ModelBreakdown, extraUsage: ExtraUsage? = nil) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let font = NSFont.systemFont(ofSize: 13)
    let barFont = NSFont.systemFont(ofSize: 9)
    let boldFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)

    func modelRow(_ name: String, _ window: UsageWindow) {
        let color = usageColor(for: window.utilization)
        let bar = progressBar(percent: window.utilization, width: 8)
        result.append(NSAttributedString(string: "\n  \(name) ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        result.append(NSAttributedString(string: bar.filled, attributes: [.font: barFont, .foregroundColor: color]))
        result.append(NSAttributedString(string: bar.empty, attributes: [.font: barFont, .foregroundColor: NSColor.separatorColor]))
        result.append(NSAttributedString(string: " \(formatValue(window.utilization))%", attributes: [.font: boldFont, .foregroundColor: color]))
        result.append(NSAttributedString(string: formatResetTime(window.resetsAt), attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
    }

    result.append(NSAttributedString(string: "Models (7-day)", attributes: [.font: font]))

    if let opus = models.opus { modelRow("Opus  ", opus) }
    if let sonnet = models.sonnet { modelRow("Sonnet", sonnet) }
    if let oauth = models.oauthApps { modelRow("OAuth ", oauth) }
    if let cowork = models.cowork { modelRow("Cowork", cowork) }
    if let extra = extraUsage, extra.isEnabled {
        let val = extra.utilization.map { formatValue($0) + "%" } ?? "on"
        result.append(NSAttributedString(string: "\n  Extra  \(val)", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
    }

    return result
}


func formatAttributedActivity(dailyDays: [DailyEntry], hourlyIncreases: [Date], now: Date = Date()) -> NSAttributedString? {
    let hasWeekly = weeklyChart(dailyDays, now: now) != nil
    let hasHourly = hourlyHeatmap(hourlyIncreases) != nil
    guard hasWeekly || hasHourly else { return nil }

    let result = NSMutableAttributedString()
    let font = NSFont.systemFont(ofSize: 13)
    let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    let dimFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    result.append(NSAttributedString(string: "Activity", attributes: [.font: font]))

    if let chart = weeklyChart(dailyDays, now: now) {
        let values = weeklyChartValues(dailyDays, now: now)
        let total = values.reduce(0, +)
        let totalStr = String(format: " %.0f%%", total)
        let aligned = alignedWeeklyColumns(chart: chart, values: values, dayLabel: weeklyChartLabel(now: now))
        result.append(NSAttributedString(string: "\n  Week  \(aligned.chart)", attributes: [.font: monoFont, .foregroundColor: NSColor.labelColor]))
        result.append(NSAttributedString(string: totalStr, attributes: [.font: dimFont, .foregroundColor: NSColor.secondaryLabelColor]))
        result.append(NSAttributedString(string: "\n        \(aligned.pcts)", attributes: [.font: dimFont, .foregroundColor: NSColor.secondaryLabelColor]))
        result.append(NSAttributedString(string: "\n        \(aligned.days)", attributes: [.font: dimFont, .foregroundColor: NSColor.tertiaryLabelColor]))
    }

    if let heatmap = hourlyHeatmap(hourlyIncreases, now: now) {
        result.append(NSAttributedString(string: "\n  Today \(heatmap)", attributes: [.font: monoFont, .foregroundColor: NSColor.labelColor]))
        result.append(NSAttributedString(string: "\n        \(hourlyHeatmapLabel(now: now))", attributes: [.font: dimFont, .foregroundColor: NSColor.secondaryLabelColor]))
    }

    return result
}

func formatAttributedAgentSection(_ agents: [TrackedAgent], projectName: String? = nil, stats: AgentStats = AgentStats(), isStale: Bool = false, sessionTokens: SessionTokens = SessionTokens(), currentModel: String? = nil, shellRequestCount: Int = 0, contextTokens: Int = 0, contextWindowMax: Int = 0, now: Date = Date()) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let font = NSFont.systemFont(ofSize: 13)
    let smallFont = NSFont.systemFont(ofSize: 11)
    let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    let sessionStatsLine = formatSessionStats(sessionTokens, model: currentModel)

    if isStale {
        result.append(NSAttributedString(string: "Session", attributes: [.font: font]))
        if let name = projectName {
            result.append(NSAttributedString(string: " \u{00B7} \(name)", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        result.append(NSAttributedString(string: "\n  Session idle", attributes: [.font: smallFont, .foregroundColor: NSColor.tertiaryLabelColor]))
        if !sessionStatsLine.isEmpty {
            result.append(NSAttributedString(string: "\n  \(sessionStatsLine)", attributes: [.font: monoFont, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let agentStatsLine = formatAgentStatsLine(stats)
        if !agentStatsLine.isEmpty {
            result.append(NSAttributedString(string: "\n  \(agentStatsLine)", attributes: [.font: monoFont, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        return result
    }

    let running = agents.filter { $0.isRunning }.count
    let done = agents.count - running

    result.append(NSAttributedString(string: "Session", attributes: [.font: font]))
    if let name = projectName {
        result.append(NSAttributedString(string: " \u{00B7} \(name)", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
    }

    var headerParts: [String] = []
    if running > 0 { headerParts.append("\(running) running") }
    if done > 0 { headerParts.append("\(done) done") }
    if !headerParts.isEmpty {
        result.append(NSAttributedString(string: " (\(headerParts.joined(separator: " \u{00B7} ")))", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
    }

    if !sessionStatsLine.isEmpty {
        result.append(NSAttributedString(string: "\n  \(sessionStatsLine)", attributes: [.font: monoFont, .foregroundColor: NSColor.secondaryLabelColor]))
    }

    var detailParts: [String] = []
    if sessionTokens.totalTokens > 0 { detailParts.append("\(formatTokenCount(sessionTokens.totalTokens)) tokens") }
    if contextWindowMax > 0 { detailParts.append("\(formatTokenCount(contextTokens))/\(formatTokenCount(contextWindowMax)) ctx") }
    if shellRequestCount > 0 { detailParts.append("\(shellRequestCount) shell") }
    if !detailParts.isEmpty {
        result.append(NSAttributedString(string: "\n  \(detailParts.joined(separator: " \u{00B7} "))", attributes: [.font: monoFont, .foregroundColor: NSColor.tertiaryLabelColor]))
    }

    for agent in agents {
        let isRunning = agent.isRunning
        let statusIcon = isRunning ? "\u{25CF}" : "\u{2713}"
        let statusColor = isRunning ? NSColor.systemOrange : colorGreen

        result.append(NSAttributedString(string: "\n  ", attributes: [.font: smallFont]))
        result.append(NSAttributedString(string: statusIcon, attributes: [.font: smallFont, .foregroundColor: statusColor]))
        result.append(NSAttributedString(string: " \(agent.description)", attributes: [.font: smallFont]))

        let duration = formatAgentDuration(agent, now: now)
        if !duration.isEmpty {
            result.append(NSAttributedString(string: "  \(duration)", attributes: [.font: monoFont, .foregroundColor: NSColor.secondaryLabelColor]))
        }

        if let tokens = agent.totalTokens {
            result.append(NSAttributedString(string: "  \(formatTokenCount(tokens)) tok", attributes: [.font: monoFont, .foregroundColor: NSColor.tertiaryLabelColor]))
        }

        if isRunning {
            result.append(NSAttributedString(string: "  running", attributes: [.font: monoFont, .foregroundColor: NSColor.systemOrange]))
        }
    }

    let agentStatsLine = formatAgentStatsLine(stats)
    if !agentStatsLine.isEmpty {
        result.append(NSAttributedString(string: "\n  \(agentStatsLine)", attributes: [.font: monoFont, .foregroundColor: NSColor.tertiaryLabelColor]))
    }

    return result
}

func formatAttributedMultiSessionSection(_ sessions: [TrackedSession], now: Date = Date()) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let font = NSFont.systemFont(ofSize: 13)
    let smallFont = NSFont.systemFont(ofSize: 11)
    let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    let nonStale = sessions.filter { !$0.isStale }
    let headerCount = nonStale.isEmpty ? sessions.count : nonStale.count
    let headerLabel = nonStale.isEmpty ? "idle" : "active"
    result.append(NSAttributedString(string: "Sessions (\(headerCount) \(headerLabel))", attributes: [.font: font]))

    for session in sessions {
        let name = session.projectName ?? "unknown"
        result.append(NSAttributedString(string: "\n  \(name)", attributes: [.font: smallFont]))
        if let model = session.currentModel {
            result.append(NSAttributedString(string: " \u{00B7} \(modelDisplayName(model))", attributes: [.font: smallFont, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        if session.isStale {
            result.append(NSAttributedString(string: " \u{00B7} idle", attributes: [.font: smallFont, .foregroundColor: NSColor.tertiaryLabelColor]))
        }

        var detailParts: [String] = []
        if session.sessionTokens.totalTokens > 0 { detailParts.append("\(formatTokenCount(session.sessionTokens.totalTokens)) tokens") }
        if session.contextWindowMax > 0 { detailParts.append("\(formatTokenCount(session.lastContextTokens))/\(formatTokenCount(session.contextWindowMax)) ctx") }
        if session.shellRequestCount > 0 { detailParts.append("\(session.shellRequestCount) shell") }
        if !detailParts.isEmpty {
            result.append(NSAttributedString(string: "\n    \(detailParts.joined(separator: " \u{00B7} "))", attributes: [.font: monoFont, .foregroundColor: NSColor.tertiaryLabelColor]))
        }

        for agent in session.agents {
            let isRunning = agent.isRunning
            let statusIcon = isRunning ? "\u{25CF}" : "\u{2713}"
            let statusColor = isRunning ? NSColor.systemOrange : colorGreen
            result.append(NSAttributedString(string: "\n    ", attributes: [.font: smallFont]))
            result.append(NSAttributedString(string: statusIcon, attributes: [.font: smallFont, .foregroundColor: statusColor]))
            result.append(NSAttributedString(string: " \(agent.description)", attributes: [.font: smallFont]))
            let duration = formatAgentDuration(agent, now: now)
            if !duration.isEmpty {
                result.append(NSAttributedString(string: "  \(duration)", attributes: [.font: monoFont, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            if isRunning {
                result.append(NSAttributedString(string: "  running", attributes: [.font: monoFont, .foregroundColor: NSColor.systemOrange]))
            }
        }
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

func formatInsights(_ usage: UsageData) -> String {
    var lines: [String] = []
    if let daily = dailyBreakdown(utilization: usage.sevenDay.utilization, resetsAt: usage.sevenDay.resetsAt, windowDuration: 7 * 86400) {
        lines.append(daily)
    }
    if let depl5 = depletionEstimate(utilization: usage.fiveHour.utilization, resetsAt: usage.fiveHour.resetsAt, windowDuration: 5 * 3600) {
        lines.append("5h: \(depl5)")
    }
    if let depl7 = depletionEstimate(utilization: usage.sevenDay.utilization, resetsAt: usage.sevenDay.resetsAt, windowDuration: 7 * 86400) {
        lines.append("7d: \(depl7)")
    }
    if let advice = budgetAdvice(utilization: usage.sevenDay.utilization, resetsAt: usage.sevenDay.resetsAt, windowDuration: 7 * 86400) {
        lines.append(advice)
    }
    return lines.joined(separator: "\n")
}

#if !TESTING
func formatAttributedInsights(_ usage: UsageData) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let font = NSFont.systemFont(ofSize: 13)
    let smallFont = NSFont.systemFont(ofSize: 11)
    let green = colorGreen
    let warn = colorYellow
    let dim = NSColor.secondaryLabelColor

    result.append(NSAttributedString(string: "Forecast", attributes: [.font: font]))

    // Depletion estimates — combine if both are the same
    let depl5 = depletionEstimate(utilization: usage.fiveHour.utilization, resetsAt: usage.fiveHour.resetsAt, windowDuration: 5 * 3600)
    let depl7 = depletionEstimate(utilization: usage.sevenDay.utilization, resetsAt: usage.sevenDay.resetsAt, windowDuration: 7 * 86400)

    if let d5 = depl5, let d7 = depl7, d5 == d7 {
        let color = d5.contains("Won't") ? green : warn
        result.append(NSAttributedString(string: "\n  \(d5)", attributes: [.font: smallFont, .foregroundColor: color]))
    } else {
        if let d5 = depl5 {
            let color = d5.contains("Won't") ? green : warn
            result.append(NSAttributedString(string: "\n  5h: \(d5)", attributes: [.font: smallFont, .foregroundColor: color]))
        }
        if let d7 = depl7 {
            let color = d7.contains("Won't") ? green : warn
            result.append(NSAttributedString(string: "\n  7d: \(d7)", attributes: [.font: smallFont, .foregroundColor: color]))
        }
    }

    // Daily rate
    if let daily = dailyBreakdown(utilization: usage.sevenDay.utilization, resetsAt: usage.sevenDay.resetsAt, windowDuration: 7 * 86400) {
        result.append(NSAttributedString(string: "\n  \(daily)", attributes: [.font: smallFont, .foregroundColor: dim]))
    }

    // Budget advice
    if let advice = budgetAdvice(utilization: usage.sevenDay.utilization, resetsAt: usage.sevenDay.resetsAt, windowDuration: 7 * 86400) {
        result.append(NSAttributedString(string: "\n  \(advice)", attributes: [.font: smallFont, .foregroundColor: green]))
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

// MARK: - Sentry Error Reporting

#if !TESTING
private let sentryKey = "e775413587228219897ba908e29d5901"
private let sentryProjectId = "4511105650720769"
private let sentryHost = "o4510977201995776.ingest.us.sentry.io"

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
        "environment": currentVersion.contains("dev") ? "development" : "production",
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

// MARK: - Status Bar Controller

class StatusBarController: NSObject {
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
    private let modelBreakdownItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let activityItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let insightsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var dailyStore = DailyUsageData()
    private let dailyStorePath = NSHomeDirectory() + "/.ccusage-daily.json"
    private let iCloudFolder: String? = {
        let iCloudDrive = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"
        guard FileManager.default.fileExists(atPath: iCloudDrive) else { return nil }
        let folder = (iCloudDrive as NSString).appendingPathComponent(iCloudSubfolder)
        if !FileManager.default.fileExists(atPath: folder) {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        return folder
    }()
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

        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem.button?.title = "CC ..."

        let menu = NSMenu()
        detailFiveHour.isEnabled = false
        detailSevenDay.isEnabled = false
        lastRefreshItem.isEnabled = false

        menu.addItem(detailFiveHour)
        menu.addItem(detailSevenDay)
        menu.addItem(.separator())
        modelBreakdownItem.isEnabled = false
        modelBreakdownItem.isHidden = true
        menu.addItem(modelBreakdownItem)
        sessionsItem.isEnabled = false
        sessionsItem.isHidden = true
        menu.addItem(sessionsItem)
        activityItem.isEnabled = false
        activityItem.isHidden = true
        menu.addItem(activityItem)
        insightsItem.isEnabled = false
        menu.addItem(insightsItem)
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

        // Poll for active Claude Code agents every 3 seconds
        agentTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshAgents()
        }
        RunLoop.current.add(agentTimer!, forMode: .common)

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
        updateAgentsUI()
        updateStatusBarAgentIndicator()
    }

    private func updateAgentsUI() {
        let active = agentTracker.activeSessions

        guard !active.isEmpty else {
            sessionsItem.isHidden = true
            return
        }
        sessionsItem.isHidden = false
        #if TESTING
        sessionsItem.title = formatMultiSessionSection(active)
        #else
        sessionsItem.attributedTitle = formatAttributedMultiSessionSection(active)
        #endif
    }

    private func updateStatusBarAgentIndicator() {
        guard let usage = lastUsage else { return }
        let runningCount = agentTracker.totalRunningCount
        #if TESTING
        var title = formatStatusLine(usage, history: history)
        if runningCount > 0 { title += " \u{26A1}\(runningCount)" }
        statusItem.button?.title = title
        #else
        let base = formatAttributedStatusLine(usage, history: history)
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
        // Save full data locally (includes lastUtilization for delta tracking)
        if let data = try? JSONEncoder().encode(dailyStore) {
            FileManager.default.createFile(atPath: dailyStorePath, contents: data)
        }
        // Save days to iCloud (device-specific file for cross-device merging)
        guard let folder = iCloudFolder else { return }
        let cloudPath = (folder as NSString).appendingPathComponent("\(deviceId).json")
        if let data = try? JSONEncoder().encode(dailyStore.days) {
            FileManager.default.createFile(atPath: cloudPath, contents: data)
        }
    }

    private func loadMergedDailyDays() -> [DailyEntry] {
        guard let folder = iCloudFolder else { return dailyStore.days }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: folder) else { return dailyStore.days }
        var deviceEntries: [[DailyEntry]] = []
        for file in files where file.hasSuffix(".json") {
            let path = (folder as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path),
                  let days = try? JSONDecoder().decode([DailyEntry].self, from: data) else { continue }
            deviceEntries.append(days)
        }
        guard !deviceEntries.isEmpty else { return dailyStore.days }
        return mergeDailyEntries(deviceEntries)
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
        guard let data = readKeychainData() else { return nil }
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
                        let raw = http.value(forHTTPHeaderField: "retry-after").flatMap { Int($0) } ?? Int(defaultFetchInterval)
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
        schedule.onRateLimit(retryAfter: raw)
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
        let h5 = usage.fiveHour.utilization
        let d7 = usage.sevenDay.utilization

        // Status bar title is updated via updateStatusBarAgentIndicator which includes usage + agent count
        updateStatusBarAgentIndicator()

        #if TESTING
        detailFiveHour.title = "\(usageIndicator(for: h5))  5-hour window: \(formatValue(h5))%\(formatResetTime(usage.fiveHour.resetsAt))"
        detailSevenDay.title = "\(usageIndicator(for: d7))  7-day window:  \(formatValue(d7))%\(formatResetTime(usage.sevenDay.resetsAt))"
        let mergedDays = loadMergedDailyDays()
        insightsItem.title = formatInsights(usage)
        if let models = usage.models {
            modelBreakdownItem.isHidden = false
            modelBreakdownItem.title = formatModelBreakdown(models, extraUsage: usage.extraUsage)
        } else {
            modelBreakdownItem.isHidden = true
        }
        let hasWeeklyTest = weeklyChart(mergedDays) != nil
        let hasHourlyTest = hourlyHeatmap(usageIncreases) != nil
        if hasWeeklyTest || hasHourlyTest {
            activityItem.isHidden = false
            var activityLines: [String] = []
            if let chart = weeklyChart(mergedDays) {
                let values = weeklyChartValues(mergedDays)
                let total = values.reduce(0, +)
                let aligned = alignedWeeklyColumns(chart: chart, values: values, dayLabel: weeklyChartLabel())
                activityLines.append(String(format: "Week: \(aligned.chart) %.0f%%", total))
                activityLines.append("      \(aligned.pcts)")
                activityLines.append("      \(aligned.days)")
            }
            if let heatmap = hourlyHeatmap(usageIncreases) {
                activityLines.append("Today: \(heatmap)")
                activityLines.append("       \(hourlyHeatmapLabel())")
            }
            activityItem.title = activityLines.joined(separator: "\n")
        } else {
            activityItem.isHidden = true
        }
        #else
        // 5-hour window
        let h5Pace = calculatePace(utilization: usage.fiveHour.utilization, resetsAt: usage.fiveHour.resetsAt, windowDuration: 5 * 3600)
        detailFiveHour.attributedTitle = formatAttributedMenuItem(label: "5-hour window", window: usage.fiveHour, pace: h5Pace)

        // 7-day window
        let d7Pace = calculatePace(utilization: usage.sevenDay.utilization, resetsAt: usage.sevenDay.resetsAt, windowDuration: 7 * 86400)
        detailSevenDay.attributedTitle = formatAttributedMenuItem(label: "7-day window", window: usage.sevenDay, pace: d7Pace)

        // Model breakdown
        if let models = usage.models {
            modelBreakdownItem.isHidden = false
            modelBreakdownItem.attributedTitle = formatAttributedModelBreakdown(models, extraUsage: usage.extraUsage)
        } else {
            modelBreakdownItem.isHidden = true
        }

        // Activity (weekly chart + hourly heatmap)
        let mergedDays = loadMergedDailyDays()
        if let activityAttr = formatAttributedActivity(dailyDays: mergedDays, hourlyIncreases: usageIncreases) {
            activityItem.isHidden = false
            activityItem.attributedTitle = activityAttr
        } else {
            activityItem.isHidden = true
        }

        insightsItem.attributedTitle = formatAttributedInsights(usage)
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

    // MARK: - Actions

    @objc func refresh() {
        guard !isFetching else { return }
        detailSevenDay.isHidden = false

        guard let keychainData = readKeychainData() else {
            setError("No creds")
            detailFiveHour.title = "Cannot read credentials from Keychain"
            detailSevenDay.title = "Ensure Claude Code is signed in"
            detailSevenDay.isHidden = false
            return
        }

        guard let token = parseToken(from: keychainData) else {
            setError("No creds")
            detailFiveHour.title = "Cannot read credentials from Keychain"
            detailSevenDay.title = "Ensure Claude Code is signed in"
            detailSevenDay.isHidden = false
            return
        }

        // Proactive refresh: if token expires within 5 minutes, refresh first
        let expiresAt = parseExpiresAt(from: keychainData)
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
                        } else {
                            self.updateItem.action = nil
                            self.installUpdate()
                        }
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
                #if !TESTING
                sentryCapture(type: "UpdateInstallError", message: error.localizedDescription)
                #endif
                try? fm.removeItem(at: tempDir)
                DispatchQueue.main.async {
                    self?.isUpdating = false
                    self?.autoInstallFailedVersion = self?.pendingUpdateVersion
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
