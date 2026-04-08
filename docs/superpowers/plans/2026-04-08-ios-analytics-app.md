# iOS Analytics App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform the CCUsage iOS app from a setup screen into a full analytics dashboard with live usage, history charts, cost tracking, session details, and threshold notifications.

**Architecture:** Three layers modified in dependency order: (1) Mac `main.swift` — extend `WidgetData` with model breakdown, daily entries, daily costs, session details, extra usage; (2) Cloudflare Worker — update `PutBody` TypeScript interface; (3) iOS app — rewrite into 3-tab SwiftUI app (Dashboard, History, Settings) with glassmorphic dark theme, data service, and local notifications.

**Tech Stack:** Swift 5 / SwiftUI (iOS 17+), Cloudflare Workers (TypeScript), no external dependencies.

**Spec:** `docs/superpowers/specs/2026-04-08-ios-analytics-app-design.md`

---

## Task 1: Extend Mac-side WidgetData and buildWidgetData

**Files:**
- Modify: `main.swift:72-120` (WidgetData struct, hasSameValues, buildWidgetData)

- [ ] **Step 1: Add new fields to WidgetData struct**

In `main.swift`, replace the `WidgetData` struct (lines 72-97) with:

```swift
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
    let depletionSeconds: Double?
    let todayCost: Double?
    let activeSessionCount: Int?
    // v3 fields — analytics app
    let opusUtilization: Double?
    let sonnetUtilization: Double?
    let haikuUtilization: Double?
    let dailyEntries: [DailyEntryData]?
    let dailyCosts: [DailyCostData]?
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
            && todayCost == other.todayCost
            && activeSessionCount == other.activeSessionCount
            && opusUtilization == other.opusUtilization
            && sonnetUtilization == other.sonnetUtilization
            && haikuUtilization == other.haikuUtilization
            && dailyEntries == other.dailyEntries
            && dailyCosts == other.dailyCosts
            && sessions == other.sessions
            && extraUsageUtilization == other.extraUsageUtilization
    }
}

struct DailyEntryData: Codable, Equatable {
    let date: String
    let usage: Double
}

struct DailyCostData: Codable, Equatable {
    let date: String
    let cost: Double
}

struct SessionData: Codable, Equatable {
    let project: String
    let model: String?
    let tokens: Int?
    let durationSeconds: Int?
}
```

- [ ] **Step 2: Add daily cost tracking to DailyUsageData**

In `main.swift`, find the `DailyEntry` struct (line 638) and `DailyUsageData` struct (line 643). Add a `dailyCosts` field to `DailyUsageData`:

```swift
struct DailyUsageData: Codable, Equatable {
    var lastUtilization: Double?
    var days: [DailyEntry]
    var historyEntries: [UsageHistory.Entry]?
    var usageIncreases: [Date]?
    var dailyCosts: [DailyCostEntry]?

    init(lastUtilization: Double? = nil, days: [DailyEntry] = [], historyEntries: [UsageHistory.Entry]? = nil, usageIncreases: [Date]? = nil, dailyCosts: [DailyCostEntry]? = nil) {
        self.lastUtilization = lastUtilization
        self.days = days
        self.historyEntries = historyEntries
        self.usageIncreases = usageIncreases
        self.dailyCosts = dailyCosts
    }
}
```

Add the `DailyCostEntry` struct right after `DailyEntry`:

```swift
struct DailyCostEntry: Codable, Equatable {
    let date: String
    var cost: Double
}
```

- [ ] **Step 3: Add recordDailyCost function**

Add this function right after the existing `recordDailyUsage` function (after line 688):

```swift
func recordDailyCost(_ store: inout DailyUsageData, todayCost: Double, now: Date = Date()) {
    let today = dailyDateString(now)
    if var costs = store.dailyCosts {
        if let idx = costs.firstIndex(where: { $0.date == today }) {
            costs[idx] = DailyCostEntry(date: today, cost: todayCost)
        } else {
            costs.append(DailyCostEntry(date: today, cost: todayCost))
        }
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: now)!
        let cutoffStr = dailyDateString(cutoff)
        store.dailyCosts = costs.filter { $0.date > cutoffStr }
    } else {
        store.dailyCosts = [DailyCostEntry(date: today, cost: todayCost)]
    }
}
```

- [ ] **Step 4: Extend buildWidgetData to include new fields**

Replace `buildWidgetData` function (lines 2089-2120). The new version takes additional parameters:

```swift
func buildWidgetData(_ usage: UsageData, todayCost: Double = 0, activeSessionCount: Int = 0,
                     dailyEntries: [DailyEntry]? = nil, dailyCosts: [DailyCostEntry]? = nil,
                     activeSessions: [TrackedSession]? = nil) -> WidgetData {
    let h5Pace = calculatePace(utilization: usage.fiveHour.utilization, resetsAt: usage.fiveHour.resetsAt, windowDuration: 5 * 3600)
    let d7Pace = calculatePace(utilization: usage.sevenDay.utilization, resetsAt: usage.sevenDay.resetsAt, windowDuration: 7 * 86400)
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
    let sessionDataList: [SessionData]? = activeSessions.flatMap { sessions in
        let list = sessions.filter { $0.hasDisplayableData }.map { s in
            SessionData(
                project: s.projectName ?? "unknown",
                model: s.currentModel,
                tokens: s.sessionTokens.totalTokens > 0 ? s.sessionTokens.totalTokens : nil,
                durationSeconds: s.lastFileModification.flatMap { mod in
                    let secs = Int(Date().timeIntervalSince(mod))
                    return secs < 86400 ? secs : nil
                }
            )
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
        todayCost: todayCost > 0 ? todayCost : nil,
        activeSessionCount: activeSessionCount > 0 ? activeSessionCount : nil,
        opusUtilization: usage.models?.opus?.utilization,
        sonnetUtilization: usage.models?.sonnet?.utilization,
        haikuUtilization: usage.models?.haiku?.utilization,
        dailyEntries: dailyEntries?.map { DailyEntryData(date: $0.date, usage: $0.usage) },
        dailyCosts: dailyCosts?.map { DailyCostData(date: $0.date, cost: $0.cost) },
        sessions: sessionDataList,
        extraUsageUtilization: usage.extraUsage?.utilization
    )
}
```

- [ ] **Step 5: Update pushWidgetData call site**

Find `pushWidgetData` method (line 2362). Update the `buildWidgetData` call inside it to pass the new parameters:

```swift
let widgetData = buildWidgetData(
    usage,
    todayCost: tokenCostTracker.todayCost.totalCost,
    activeSessionCount: agentTracker.totalRunningCount,
    dailyEntries: dailyStore.days,
    dailyCosts: dailyStore.dailyCosts,
    activeSessions: Array(agentTracker.activeSessions)
)
```

- [ ] **Step 6: Record daily cost on each refresh**

Find the place in `StatusBarController` where `recordDailyUsage` is called (search for `recordDailyUsage(&dailyStore`). Add a `recordDailyCost` call right after it:

```swift
recordDailyCost(&dailyStore, todayCost: tokenCostTracker.todayCost.totalCost)
```

- [ ] **Step 7: Add tests for new functionality**

In `CCUsageTests.swift`, add tests for `recordDailyCost` and the extended `buildWidgetData`. Find the existing `runDailyUsageTests` function and add after it:

```swift
func runDailyCostTests() {
    suite("Daily Cost Tracking") {
        test("records cost for today") {
            var store = DailyUsageData()
            let now = Date()
            recordDailyCost(&store, todayCost: 3.42, now: now)
            assertEqual(store.dailyCosts?.count, 1)
            assertEqual(store.dailyCosts?.first?.cost, 3.42)
        }
        test("updates cost for same day") {
            var store = DailyUsageData()
            let now = Date()
            recordDailyCost(&store, todayCost: 1.0, now: now)
            recordDailyCost(&store, todayCost: 3.42, now: now)
            assertEqual(store.dailyCosts?.count, 1)
            assertEqual(store.dailyCosts?.first?.cost, 3.42)
        }
        test("prunes old entries") {
            var store = DailyUsageData()
            let cal = Calendar.current
            let old = cal.date(byAdding: .day, value: -8, to: Date())!
            recordDailyCost(&store, todayCost: 1.0, now: old)
            recordDailyCost(&store, todayCost: 2.0, now: Date())
            assertEqual(store.dailyCosts?.count, 1)
        }
    }
}
```

Add `runDailyCostTests()` to the `runAllTests()` function. Also add a test for the extended `buildWidgetData`:

```swift
func runExtendedWidgetDataTests() {
    suite("Extended WidgetData") {
        test("includes model breakdown") {
            let usage = UsageData(
                fiveHour: UsageWindow(utilization: 42, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 67, remaining: nil, resetsAt: nil),
                models: ModelBreakdown(
                    opus: UsageWindow(utilization: 55, remaining: nil, resetsAt: nil),
                    sonnet: UsageWindow(utilization: 35, remaining: nil, resetsAt: nil),
                    oauthApps: nil, cowork: nil
                )
            )
            let wd = buildWidgetData(usage)
            assertEqual(wd.opusUtilization, 55)
            assertEqual(wd.sonnetUtilization, 35)
            assertNil(wd.haikuUtilization)
        }
        test("includes daily entries") {
            let usage = UsageData(
                fiveHour: UsageWindow(utilization: 10, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 20, remaining: nil, resetsAt: nil)
            )
            let days = [DailyEntry(date: "2026-04-08", usage: 5.3)]
            let costs = [DailyCostEntry(date: "2026-04-08", cost: 3.42)]
            let wd = buildWidgetData(usage, dailyEntries: days, dailyCosts: costs)
            assertEqual(wd.dailyEntries?.count, 1)
            assertEqual(wd.dailyEntries?.first?.usage, 5.3)
            assertEqual(wd.dailyCosts?.count, 1)
            assertEqual(wd.dailyCosts?.first?.cost, 3.42)
        }
        test("hasSameValues compares new fields") {
            let usage = UsageData(
                fiveHour: UsageWindow(utilization: 10, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 20, remaining: nil, resetsAt: nil),
                models: ModelBreakdown(opus: UsageWindow(utilization: 55, remaining: nil, resetsAt: nil), sonnet: nil, oauthApps: nil, cowork: nil)
            )
            let a = buildWidgetData(usage)
            let b = buildWidgetData(usage)
            check(a.hasSameValues(as: b), "identical data should match")

            let usage2 = UsageData(
                fiveHour: UsageWindow(utilization: 10, remaining: nil, resetsAt: nil),
                sevenDay: UsageWindow(utilization: 20, remaining: nil, resetsAt: nil),
                models: ModelBreakdown(opus: UsageWindow(utilization: 60, remaining: nil, resetsAt: nil), sonnet: nil, oauthApps: nil, cowork: nil)
            )
            let c = buildWidgetData(usage2)
            check(!a.hasSameValues(as: c), "different opus should not match")
        }
    }
}
```

Add `runExtendedWidgetDataTests()` to `runAllTests()`.

- [ ] **Step 8: Run tests**

Run: `make test`
Expected: All tests pass including new daily cost and extended widget data tests.

- [ ] **Step 9: Build Mac app**

Run: `make build`
Expected: Compiles successfully.

---

## Task 2: Update Cloudflare Worker PutBody interface

**Files:**
- Modify: `worker/src/index.ts:5-15`

- [ ] **Step 1: Update PutBody interface**

Replace the `PutBody` interface (lines 5-15) with the extended version. The worker stores raw JSON so it doesn't validate individual fields — we just need the TypeScript type to be honest about what's coming in:

```typescript
interface PutBody {
	data: {
		fiveHourUtilization: number;
		sevenDayUtilization: number;
		fiveHourPace: number | null;
		sevenDayPace: number | null;
		fiveHourResetsAt: number | null;
		sevenDayResetsAt: number | null;
		updatedAt: number;
		// v2 fields
		extraUsageEnabled?: boolean | null;
		depletionSeconds?: number | null;
		todayCost?: number | null;
		activeSessionCount?: number | null;
		// v3 fields — analytics app
		opusUtilization?: number | null;
		sonnetUtilization?: number | null;
		haikuUtilization?: number | null;
		dailyEntries?: { date: string; usage: number }[] | null;
		dailyCosts?: { date: string; cost: number }[] | null;
		sessions?: { project: string; model?: string | null; tokens?: number | null; durationSeconds?: number | null }[] | null;
		extraUsageUtilization?: number | null;
	};
}
```

- [ ] **Step 2: Verify worker builds**

Run: `cd worker && npm run build` (or `npx wrangler deploy --dry-run`)
Expected: TypeScript compiles without errors.

- [ ] **Step 3: Deploy worker**

Run: `cd worker && npx wrangler deploy`
Expected: Deployed successfully. No schema migration needed — data is stored as JSON string.

---

## Task 3: Create shared iOS models and theme

**Files:**
- Create: `CCUsageWidget/CCUsageWidgetApp/SharedModels.swift`
- Create: `CCUsageWidget/CCUsageWidgetApp/Theme.swift`

- [ ] **Step 1: Create SharedModels.swift**

```swift
import Foundation

struct WidgetData: Codable {
    let fiveHourUtilization: Double
    let sevenDayUtilization: Double
    let fiveHourPace: Double?
    let sevenDayPace: Double?
    let fiveHourResetsAt: TimeInterval?
    let sevenDayResetsAt: TimeInterval?
    let updatedAt: TimeInterval
    let extraUsageEnabled: Bool?
    let depletionSeconds: Double?
    let todayCost: Double?
    let activeSessionCount: Int?
    // v3 fields
    let opusUtilization: Double?
    let sonnetUtilization: Double?
    let haikuUtilization: Double?
    let dailyEntries: [DailyEntryData]?
    let dailyCosts: [DailyCostData]?
    let sessions: [SessionData]?
    let extraUsageUtilization: Double?

    static let placeholder = WidgetData(
        fiveHourUtilization: 45,
        sevenDayUtilization: 32,
        fiveHourPace: 1.0,
        sevenDayPace: 0.8,
        fiveHourResetsAt: Date().addingTimeInterval(14400).timeIntervalSince1970,
        sevenDayResetsAt: Date().addingTimeInterval(4 * 86400).timeIntervalSince1970,
        updatedAt: Date().timeIntervalSince1970,
        extraUsageEnabled: nil,
        depletionSeconds: nil,
        todayCost: nil,
        activeSessionCount: nil,
        opusUtilization: nil,
        sonnetUtilization: nil,
        haikuUtilization: nil,
        dailyEntries: nil,
        dailyCosts: nil,
        sessions: nil,
        extraUsageUtilization: nil
    )
}

struct DailyEntryData: Codable {
    let date: String
    let usage: Double
}

struct DailyCostData: Codable {
    let date: String
    let cost: Double
}

struct SessionData: Codable {
    let project: String
    let model: String?
    let tokens: Int?
    let durationSeconds: Int?
}
```

- [ ] **Step 2: Create Theme.swift**

```swift
import SwiftUI

enum Theme {
    // Background
    static let backgroundTop = Color(red: 15/255, green: 23/255, blue: 42/255)
    static let backgroundBottom = Color(red: 30/255, green: 41/255, blue: 59/255)
    static var backgroundGradient: LinearGradient {
        LinearGradient(colors: [backgroundTop, backgroundBottom], startPoint: .top, endPoint: .bottom)
    }

    // Cards
    static let cardBackground = Color.white.opacity(0.04)
    static let cardBorder = Color.white.opacity(0.06)
    static let accentCardBackground = Color.white.opacity(0.06)
    static let accentCardBorder = Color.white.opacity(0.08)

    // Status colors
    static let green = Color(red: 74/255, green: 222/255, blue: 128/255)
    static let orange = Color(red: 251/255, green: 146/255, blue: 60/255)
    static let red = Color(red: 244/255, green: 62/255, blue: 94/255)

    // Model colors
    static let opus = Color(red: 167/255, green: 139/255, blue: 250/255)
    static let sonnet = Color(red: 34/255, green: 211/255, blue: 238/255)
    static let haiku = Color(red: 148/255, green: 163/255, blue: 184/255)

    // Cost
    static let costPurple = Color(red: 168/255, green: 85/255, blue: 247/255)

    // Text
    static let textPrimary = Color(red: 226/255, green: 232/255, blue: 240/255)
    static let textSecondary = Color(red: 148/255, green: 163/255, blue: 184/255)
    static let textTertiary = Color(red: 100/255, green: 116/255, blue: 139/255)
    static let textQuaternary = Color(red: 71/255, green: 85/255, blue: 105/255)

    // Helpers
    static func usageColor(_ pct: Double, pace: Double?) -> Color {
        let effective = pace.map { max(pct, pct * $0) } ?? pct
        if effective >= 80 { return red }
        if effective >= 50 { return orange }
        return green
    }

    static func paceLabel(_ pace: Double?) -> String {
        guard let p = pace else { return "unknown" }
        if p > 1.2 { return "fast pace" }
        if p < 0.8 { return "slow pace" }
        return "steady pace"
    }

    static func paceSymbol(_ pace: Double?) -> String {
        guard let p = pace else { return "●" }
        if p > 1.2 { return "▲" }
        if p < 0.8 { return "▼" }
        return "●"
    }

    static func resetLabel(_ ts: TimeInterval?) -> String {
        guard let ts else { return "" }
        let secs = ts - Date().timeIntervalSince1970
        guard secs > 0 else { return "resetting" }
        let h = Int(secs) / 3600
        let m = (Int(secs) % 3600) / 60
        if h >= 48 { return "\(h / 24)d" }
        if h >= 1 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func depletionLabel(_ seconds: Double?) -> String? {
        guard let secs = seconds, secs > 0 else { return nil }
        let h = Int(secs) / 3600
        let m = (Int(secs) % 3600) / 60
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        if h >= 1 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

struct GlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Theme.cardBorder, lineWidth: 1)
            )
    }
}
```

---

## Task 4: Create DataService

**Files:**
- Create: `CCUsageWidget/CCUsageWidgetApp/DataService.swift`

- [ ] **Step 1: Create DataService.swift**

```swift
import Foundation
import Combine

private let appGroupID = "group.com.viktorsvirsky.ccusage"
private let widgetURLKey = "widgetURL"
private let cachedDataKey = "cachedWidgetData"
private let cachedDataTimestampKey = "cachedWidgetDataTimestamp"

@MainActor
class DataService: ObservableObject {
    @Published var data: WidgetData?
    @Published var isConnected: Bool = false
    @Published var lastError: String?

    private var timer: Timer?
    private let refreshInterval: TimeInterval = 120 // 2 minutes

    var widgetURL: String? {
        UserDefaults(suiteName: appGroupID)?.string(forKey: widgetURLKey)
    }

    init() {
        isConnected = widgetURL != nil
        loadCached()
    }

    func start() {
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetch()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func saveURL(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme == "https",
              url.host?.hasSuffix(".workers.dev") == true,
              let key = url.path.split(separator: "/").last,
              key.count == 64,
              key.allSatisfy({ $0.isHexDigit }) else {
            return false
        }
        UserDefaults(suiteName: appGroupID)?.set(trimmed, forKey: widgetURLKey)
        isConnected = true
        fetch()
        return true
    }

    func disconnect() {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.removeObject(forKey: widgetURLKey)
        defaults.removeObject(forKey: cachedDataKey)
        defaults.removeObject(forKey: cachedDataTimestampKey)
        isConnected = false
        data = nil
    }

    private func loadCached() {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let cachedData = defaults.data(forKey: cachedDataKey),
              let cached = try? JSONDecoder().decode(WidgetData.self, from: cachedData) else { return }
        data = cached
    }

    private func fetch() {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let urlString = defaults.string(forKey: widgetURLKey),
              let url = URL(string: urlString) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] responseData, response, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.lastError = error.localizedDescription
                    return
                }
                guard let responseData,
                      let http = response as? HTTPURLResponse,
                      http.statusCode == 200,
                      let decoded = try? JSONDecoder().decode(WidgetData.self, from: responseData) else {
                    self.lastError = "Failed to fetch data"
                    return
                }
                self.data = decoded
                self.lastError = nil
                defaults.set(responseData, forKey: cachedDataKey)
                defaults.set(Date().timeIntervalSince1970, forKey: cachedDataTimestampKey)
                NotificationService.shared.evaluate(decoded)
            }
        }.resume()
    }
}
```

---

## Task 5: Create NotificationService

**Files:**
- Create: `CCUsageWidget/CCUsageWidgetApp/NotificationService.swift`

- [ ] **Step 1: Create NotificationService.swift**

```swift
import Foundation
import UserNotifications

class NotificationService {
    static let shared = NotificationService()

    private let defaults = UserDefaults.standard
    private let cooldown: TimeInterval = 1800 // 30 minutes

    // Settings keys
    static let highUsageKey = "notifyHighUsage"
    static let criticalKey = "notifyCritical"
    static let depletionKey = "notifyDepletion"

    // State keys
    private let lastNotified80Key = "lastNotified80"
    private let lastNotified95Key = "lastNotified95"
    private let lastNotifiedDepletionKey = "lastNotifiedDepletion"

    var highUsageEnabled: Bool {
        get { defaults.bool(forKey: Self.highUsageKey) }
        set { defaults.set(newValue, forKey: Self.highUsageKey) }
    }

    var criticalEnabled: Bool {
        get { defaults.bool(forKey: Self.criticalKey) }
        set { defaults.set(newValue, forKey: Self.criticalKey) }
    }

    var depletionEnabled: Bool {
        get { defaults.bool(forKey: Self.depletionKey) }
        set { defaults.set(newValue, forKey: Self.depletionKey) }
    }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            completion(granted)
        }
    }

    func evaluate(_ data: WidgetData) {
        let now = Date().timeIntervalSince1970
        let maxUtil = max(data.fiveHourUtilization, data.sevenDayUtilization)

        if highUsageEnabled && maxUtil >= 80 && maxUtil < 95 {
            let last = defaults.double(forKey: lastNotified80Key)
            if now - last > cooldown {
                send(title: "High Usage", body: "Usage at \(Int(maxUtil))% — approaching limit")
                defaults.set(now, forKey: lastNotified80Key)
            }
        }

        if criticalEnabled && maxUtil >= 95 {
            let last = defaults.double(forKey: lastNotified95Key)
            if now - last > cooldown {
                send(title: "Critical Usage", body: "Usage at \(Int(maxUtil))% — near limit")
                defaults.set(now, forKey: lastNotified95Key)
            }
        }

        if depletionEnabled, let secs = data.depletionSeconds, secs > 0 {
            let last = defaults.double(forKey: lastNotifiedDepletionKey)
            if now - last > cooldown {
                let label = Theme.depletionLabel(secs) ?? "soon"
                send(title: "Depletion Warning", body: "At current pace, limit reached in \(label)")
                defaults.set(now, forKey: lastNotifiedDepletionKey)
            }
        }
    }

    private func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
```

---

## Task 6: Create DashboardView

**Files:**
- Create: `CCUsageWidget/CCUsageWidgetApp/DashboardView.swift`

- [ ] **Step 1: Create DashboardView.swift**

```swift
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var dataService: DataService

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                if let d = dataService.data {
                    utilizationCards(d)
                    if let label = Theme.depletionLabel(d.depletionSeconds) {
                        depletionWarning(label)
                    }
                    if d.opusUtilization != nil || d.sonnetUtilization != nil || d.haikuUtilization != nil {
                        modelBreakdown(d)
                    }
                    quickStats(d)
                    if let sessions = d.sessions, !sessions.isEmpty {
                        activeSessions(sessions)
                    }
                } else {
                    noData
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .onAppear { dataService.start() }
        .onDisappear { dataService.stop() }
    }

    private var header: some View {
        HStack {
            Text("Dashboard")
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let d = dataService.data {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.green)
                        .frame(width: 6, height: 6)
                        .shadow(color: Theme.green, radius: 3)
                    Text(updatedLabel(d.updatedAt))
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.top, 8)
    }

    private func utilizationCards(_ d: WidgetData) -> some View {
        HStack(spacing: 12) {
            utilizationCard(label: "5-HOUR", pct: d.fiveHourUtilization, pace: d.fiveHourPace, reset: d.fiveHourResetsAt)
            utilizationCard(label: "7-DAY", pct: d.sevenDayUtilization, pace: d.sevenDayPace, reset: d.sevenDayResetsAt)
        }
    }

    private func utilizationCard(label: String, pct: Double, pace: Double?, reset: TimeInterval?) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .tracking(0.5)
                Text("\(Int(pct.rounded()))%")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Theme.usageColor(pct, pace: pace))
                Text("\(Theme.paceSymbol(pace)) \(Theme.paceLabel(pace))")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                ProgressView(value: min(pct / 100, 1))
                    .tint(Theme.usageColor(pct, pace: pace))
                    .scaleEffect(x: 1, y: 0.6, anchor: .center)
                    .padding(.top, 4)
                if let reset {
                    Text("Resets in \(Theme.resetLabel(reset))")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textQuaternary)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func depletionWarning(_ label: String) -> some View {
        HStack(spacing: 10) {
            Text("\u{26A0}\u{FE0F}")
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Depletes in \(label)")
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(Theme.orange)
                Text("At current 7-day pace")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Theme.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.orange.opacity(0.2), lineWidth: 1)
        )
    }

    private func modelBreakdown(_ d: WidgetData) -> some View {
        let opus = d.opusUtilization ?? 0
        let sonnet = d.sonnetUtilization ?? 0
        let haiku = d.haikuUtilization ?? 0
        let total = opus + sonnet + haiku
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("MODEL BREAKDOWN")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .tracking(0.5)
                if total > 0 {
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            if opus > 0 {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Theme.opus)
                                    .frame(width: geo.size.width * opus / total)
                            }
                            if sonnet > 0 {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Theme.sonnet)
                                    .frame(width: geo.size.width * sonnet / total)
                            }
                            if haiku > 0 {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Theme.haiku)
                                    .frame(width: geo.size.width * haiku / total)
                            }
                        }
                    }
                    .frame(height: 6)
                }
                HStack(spacing: 16) {
                    modelLegend(color: Theme.opus, name: "Opus", value: opus)
                    modelLegend(color: Theme.sonnet, name: "Sonnet", value: sonnet)
                    modelLegend(color: Theme.haiku, name: "Haiku", value: haiku)
                }
            }
        }
    }

    private func modelLegend(color: Color, name: String, value: Double) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(name) \(Int(value.rounded()))%")
                .font(.caption)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func quickStats(_ d: WidgetData) -> some View {
        HStack(spacing: 10) {
            statCard(label: "TODAY'S COST", value: d.todayCost.map { String(format: "$%.2f", $0) } ?? "--")
            statCard(label: "SESSIONS", value: d.activeSessionCount.map { "\($0)" } ?? "0")
            statCard(label: "EXTRA USE", value: d.extraUsageEnabled == true ? "ON" : "OFF",
                     color: d.extraUsageEnabled == true ? Theme.green : Theme.textTertiary)
        }
    }

    private func statCard(label: String, value: String, color: Color = Theme.textPrimary) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
                .tracking(0.5)
            Text(value)
                .font(.title3).fontWeight(.bold)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.cardBorder, lineWidth: 1)
        )
    }

    private func activeSessions(_ sessions: [SessionData]) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("ACTIVE SESSIONS")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .tracking(0.5)
                ForEach(Array(sessions.enumerated()), id: \.offset) { _, session in
                    sessionRow(session)
                }
            }
        }
    }

    private func sessionRow(_ s: SessionData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(s.project)
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("● live")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.green.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 12) {
                if let model = s.model {
                    Text(model).font(.caption2).foregroundStyle(Theme.textTertiary)
                }
                if let tokens = s.tokens {
                    Text(formatTokens(tokens)).font(.caption2).foregroundStyle(Theme.textTertiary)
                }
                if let dur = s.durationSeconds {
                    Text(formatDuration(dur)).font(.caption2).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var noData: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.largeTitle)
                .foregroundStyle(Theme.textTertiary)
            Text("No data yet")
                .font(.headline)
                .foregroundStyle(Theme.textSecondary)
            Text("Waiting for data from your Mac")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // Helpers
    private func updatedLabel(_ ts: TimeInterval) -> String {
        let ago = Int(Date().timeIntervalSince1970 - ts)
        if ago < 60 { return "just now" }
        if ago < 3600 { return "\(ago / 60)m ago" }
        if ago < 86400 { return "\(ago / 3600)h ago" }
        return "\(ago / 86400)d ago"
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1000 { return String(format: "%.1fk tokens", Double(tokens) / 1000) }
        return "\(tokens) tokens"
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds >= 3600 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        return "\(seconds / 60)m"
    }
}
```

---

## Task 7: Create HistoryView

**Files:**
- Create: `CCUsageWidget/CCUsageWidgetApp/HistoryView.swift`

- [ ] **Step 1: Create HistoryView.swift**

```swift
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var dataService: DataService

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Text("History")
                        .font(.title2).fontWeight(.bold)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
                .padding(.top, 8)

                if let d = dataService.data {
                    if let entries = d.dailyEntries, !entries.isEmpty {
                        weeklyUsageChart(entries)
                    } else {
                        placeholder("Update CCUsage on your Mac for usage history")
                    }
                    if let costs = d.dailyCosts, !costs.isEmpty {
                        costHistoryChart(costs)
                    } else {
                        placeholder("Update CCUsage on your Mac for cost history")
                    }
                    if d.opusUtilization != nil || d.sonnetUtilization != nil || d.haikuUtilization != nil {
                        modelMix(d)
                    }
                } else {
                    placeholder("No data yet")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .background(Theme.backgroundGradient.ignoresSafeArea())
    }

    private func weeklyUsageChart(_ entries: [DailyEntryData]) -> some View {
        let maxVal = entries.map(\.usage).max() ?? 1
        let total = entries.reduce(0) { $0 + $1.usage }
        let avg = entries.isEmpty ? 0 : total / Double(entries.count)
        let peak = entries.max(by: { $0.usage < $1.usage })

        return GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("WEEKLY USAGE")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .tracking(0.5)
                    Spacer()
                    Text(dateRange(entries))
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }

                // Bars
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { i, entry in
                        VStack(spacing: 4) {
                            Text(String(format: "%.1f", entry.usage))
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.textTertiary)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(barGradient(entry.usage, max: maxVal))
                                .frame(height: max(4, CGFloat(entry.usage / maxVal) * 100))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 120)

                // Day labels
                HStack(spacing: 8) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { i, entry in
                        Text(dayLabel(entry.date, isLast: i == entries.count - 1))
                            .font(.system(size: 9))
                            .foregroundStyle(i == entries.count - 1 ? Theme.textPrimary : Theme.textQuaternary)
                            .fontWeight(i == entries.count - 1 ? .semibold : .regular)
                            .frame(maxWidth: .infinity)
                    }
                }

                Divider().background(Color.white.opacity(0.06))

                // Summary
                HStack {
                    summaryItem(label: "WEEK TOTAL", value: String(format: "%.1f%%", total))
                    Spacer()
                    summaryItem(label: "DAILY AVG", value: String(format: "%.1f%%", avg))
                    Spacer()
                    if let peak {
                        summaryItem(label: "PEAK DAY",
                                    value: "\(shortDay(peak.date)) \(String(format: "%.1f", peak.usage))",
                                    color: Theme.red)
                    }
                }
            }
        }
    }

    private func costHistoryChart(_ costs: [DailyCostData]) -> some View {
        let maxVal = costs.map(\.cost).max() ?? 1
        let total = costs.reduce(0) { $0 + $1.cost }

        return GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("COST HISTORY")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .tracking(0.5)
                    Spacer()
                    Text(String(format: "$%.2f", total))
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundStyle(Theme.textPrimary)
                    Text("this week")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }

                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(costs.enumerated()), id: \.offset) { _, cost in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.costPurple.opacity(0.6 + 0.4 * (cost.cost / maxVal)))
                                .frame(height: max(3, CGFloat(cost.cost / maxVal) * 50))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 50)

                HStack(spacing: 6) {
                    ForEach(Array(costs.enumerated()), id: \.offset) { i, cost in
                        Text(String(format: "$%.0f", cost.cost))
                            .font(.system(size: 8))
                            .foregroundStyle(i == costs.count - 1 ? Theme.textPrimary : Theme.textQuaternary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func modelMix(_ d: WidgetData) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("MODEL MIX THIS WEEK")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .tracking(0.5)
                modelRow(color: Theme.opus, name: "Opus", value: d.opusUtilization ?? 0)
                modelRow(color: Theme.sonnet, name: "Sonnet", value: d.sonnetUtilization ?? 0)
                modelRow(color: Theme.haiku, name: "Haiku", value: d.haikuUtilization ?? 0)
            }
        }
    }

    private func modelRow(color: Color, name: String, value: Double) -> some View {
        VStack(spacing: 4) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(name).font(.subheadline).foregroundStyle(Theme.textPrimary)
                }
                Spacer()
                Text("\(Int(value.rounded()))%")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            ProgressView(value: min(value / 100, 1))
                .tint(color)
                .scaleEffect(x: 1, y: 0.6, anchor: .center)
        }
    }

    private func placeholder(_ message: String) -> some View {
        GlassCard {
            HStack {
                Spacer()
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding(.vertical, 20)
        }
    }

    private func summaryItem(label: String, value: String, color: Color = Theme.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.subheadline).fontWeight(.bold)
                .foregroundStyle(color)
        }
    }

    // Helpers
    private func barGradient(_ value: Double, max: Double) -> LinearGradient {
        let ratio = max > 0 ? value / max : 0
        let color: Color = ratio > 0.8 ? Theme.red : ratio > 0.5 ? Theme.orange : Theme.green
        return LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .top, endPoint: .bottom)
    }

    private func dateRange(_ entries: [DailyEntryData]) -> String {
        guard let first = entries.first, let last = entries.last else { return "" }
        return "\(shortDate(first.date)) – \(shortDate(last.date))"
    }

    private func shortDate(_ dateStr: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        guard let date = f.date(from: dateStr) else { return dateStr }
        let out = DateFormatter()
        out.dateFormat = "MMM d"
        return out.string(from: date)
    }

    private func shortDay(_ dateStr: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        guard let date = f.date(from: dateStr) else { return dateStr }
        let out = DateFormatter()
        out.dateFormat = "EEE"
        return out.string(from: date)
    }

    private func dayLabel(_ dateStr: String, isLast: Bool) -> String {
        if isLast { return "Today" }
        return shortDay(dateStr)
    }
}
```

---

## Task 8: Create SettingsView

**Files:**
- Create: `CCUsageWidget/CCUsageWidgetApp/SettingsView.swift`

- [ ] **Step 1: Create SettingsView.swift**

```swift
import SwiftUI
import AVFoundation
import WidgetKit

struct SettingsView: View {
    @EnvironmentObject var dataService: DataService
    @State private var pasteText = ""
    @State private var showScanner = false
    @State private var statusMessage: String?
    @State private var highUsage: Bool = NotificationService.shared.highUsageEnabled
    @State private var critical: Bool = NotificationService.shared.criticalEnabled
    @State private var depletion: Bool = NotificationService.shared.depletionEnabled

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Text("Settings")
                        .font(.title2).fontWeight(.bold)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
                .padding(.top, 8)

                // Connection status
                if dataService.isConnected {
                    connectionStatus
                }

                // Setup
                setupSection

                // Notifications
                notificationsSection

                // About
                aboutSection

                // Disconnect
                if dataService.isConnected {
                    Button(role: .destructive) {
                        dataService.disconnect()
                        WidgetCenter.shared.reloadAllTimelines()
                    } label: {
                        Text("Disconnect")
                            .font(.subheadline)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in
                showScanner = false
                save(code)
            }
        }
    }

    private var connectionStatus: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Theme.green)
                .frame(width: 8, height: 8)
                .shadow(color: Theme.green, radius: 4)
            Text("Connected")
                .font(.subheadline).fontWeight(.semibold)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(16)
        .background(Theme.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.green.opacity(0.15), lineWidth: 1)
        )
    }

    private var setupSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("CONNECTION")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .tracking(0.5)

                Button(action: { showScanner = true }) {
                    HStack {
                        Image(systemName: "qrcode.viewfinder")
                        Text("Scan QR Code")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                HStack(spacing: 8) {
                    TextField("https://...", text: $pasteText)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .tint(.blue)
                    Button("Save") { save(pasteText) }
                        .buttonStyle(.bordered)
                        .disabled(pasteText.isEmpty)
                }

                if let msg = statusMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(msg.contains("Error") ? .red : Theme.green)
                }
            }
        }
    }

    private var notificationsSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("NOTIFICATIONS")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .tracking(0.5)
                    .padding(.bottom, 14)

                notificationToggle(
                    title: "High Usage Alert",
                    subtitle: "Notify at 80% utilization",
                    isOn: $highUsage
                ) { NotificationService.shared.highUsageEnabled = $0 }

                Divider().background(Color.white.opacity(0.04)).padding(.vertical, 4)

                notificationToggle(
                    title: "Critical Alert",
                    subtitle: "Notify at 95% utilization",
                    isOn: $critical
                ) { NotificationService.shared.criticalEnabled = $0 }

                Divider().background(Color.white.opacity(0.04)).padding(.vertical, 4)

                notificationToggle(
                    title: "Depletion Warning",
                    subtitle: "When projected to hit limit",
                    isOn: $depletion
                ) { NotificationService.shared.depletionEnabled = $0 }
            }
        }
    }

    private func notificationToggle(title: String, subtitle: String, isOn: Binding<Bool>, onChange: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn.wrappedValue }, set: { newValue in
            if newValue {
                NotificationService.shared.requestPermission { granted in
                    DispatchQueue.main.async {
                        isOn.wrappedValue = granted
                        onChange(granted)
                    }
                }
            } else {
                isOn.wrappedValue = false
                onChange(false)
            }
        })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .tint(Theme.green)
        .padding(.vertical, 6)
    }

    private var aboutSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("ABOUT")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .tracking(0.5)
                    .padding(.bottom, 14)

                aboutRow(label: "Widget Refresh", value: "Every 2 min")
                Divider().background(Color.white.opacity(0.04)).padding(.vertical, 6)
                aboutRow(label: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            }
        }
    }

    private func aboutRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func save(_ urlString: String) {
        if dataService.saveURL(urlString) {
            pasteText = ""
            statusMessage = "Saved! Widget will update shortly."
            WidgetCenter.shared.reloadAllTimelines()
        } else {
            statusMessage = "Error: Invalid widget URL"
        }
    }
}

// MARK: - QR Scanner (reused from existing code)

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
```

---

## Task 9: Rewrite ContentView as TabView container

**Files:**
- Modify: `CCUsageWidget/CCUsageWidgetApp/ContentView.swift` (full rewrite)

- [ ] **Step 1: Rewrite ContentView.swift**

Replace the entire file:

```swift
import SwiftUI
import WidgetKit

struct ContentView: View {
    @StateObject private var dataService = DataService()

    var body: some View {
        Group {
            if dataService.isConnected {
                TabView {
                    DashboardView()
                        .tabItem {
                            Image(systemName: "chart.bar.fill")
                            Text("Dashboard")
                        }
                    HistoryView()
                        .tabItem {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                            Text("History")
                        }
                    SettingsView()
                        .tabItem {
                            Image(systemName: "gearshape.fill")
                            Text("Settings")
                        }
                }
                .tint(Color(red: 96/255, green: 165/255, blue: 250/255))
            } else {
                OnboardingView()
            }
        }
        .environmentObject(dataService)
        .preferredColorScheme(.dark)
    }
}

struct OnboardingView: View {
    @EnvironmentObject var dataService: DataService
    @State private var pasteText = ""
    @State private var showScanner = false
    @State private var statusMessage: String?

    var body: some View {
        ZStack {
            Theme.backgroundGradient.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.blue)
                        .padding(.top, 60)

                    VStack(spacing: 8) {
                        Text("CCUsage")
                            .font(.title).fontWeight(.bold)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Claude Code usage analytics synced from your Mac.")
                            .font(.body)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Connect your Mac").font(.headline).foregroundStyle(Theme.textPrimary)

                            Button(action: { showScanner = true }) {
                                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)

                            Text("Or paste the URL from your Mac:")
                                .font(.subheadline).foregroundStyle(Theme.textSecondary)

                            HStack {
                                TextField("https://...", text: $pasteText)
                                    .textFieldStyle(.roundedBorder)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.URL)
                                Button("Save") { save(pasteText) }
                                    .buttonStyle(.bordered)
                                    .disabled(pasteText.isEmpty)
                            }

                            if let msg = statusMessage {
                                Text(msg)
                                    .font(.caption)
                                    .foregroundStyle(msg.contains("Error") ? .red : Theme.green)
                            }
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("How it works").font(.headline).foregroundStyle(Theme.textPrimary)
                            stepRow(n: 1, text: "Run CCUsage on your Mac")
                            stepRow(n: 2, text: "Click \"Share to iPhone\" in the menu bar")
                            stepRow(n: 3, text: "Scan the QR code or paste the URL")
                            stepRow(n: 4, text: "Your analytics appear here instantly")
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in
                showScanner = false
                save(code)
            }
        }
    }

    private func stepRow(n: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.caption).fontWeight(.bold)
                .frame(width: 24, height: 24)
                .background(Color.blue)
                .foregroundStyle(.white)
                .clipShape(Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
    }

    private func save(_ urlString: String) {
        if dataService.saveURL(urlString) {
            pasteText = ""
            statusMessage = "Connected!"
            WidgetCenter.shared.reloadAllTimelines()
        } else {
            statusMessage = "Error: Invalid widget URL"
        }
    }
}
```

---

## Task 10: Update widget extension WidgetData and Xcode project

**Files:**
- Modify: `CCUsageWidget/CCUsageExtension/CCUsageExtension.swift:6-32`
- Modify: `CCUsageWidget/CCUsageWidget.xcodeproj/project.pbxproj`

- [ ] **Step 1: Update widget extension WidgetData**

In `CCUsageExtension.swift`, replace the `WidgetData` struct (lines 6-33) with the extended version. The extension doesn't render new fields but must decode them:

```swift
struct WidgetData: Codable {
    let fiveHourUtilization: Double
    let sevenDayUtilization: Double
    let fiveHourPace: Double?
    let sevenDayPace: Double?
    let fiveHourResetsAt: TimeInterval?
    let sevenDayResetsAt: TimeInterval?
    let updatedAt: TimeInterval
    let extraUsageEnabled: Bool?
    let depletionSeconds: Double?
    let todayCost: Double?
    let activeSessionCount: Int?
    // v3 fields — decoded but not rendered by widget
    let opusUtilization: Double?
    let sonnetUtilization: Double?
    let haikuUtilization: Double?
    let dailyEntries: [DailyEntryData]?
    let dailyCosts: [DailyCostData]?
    let sessions: [SessionData]?
    let extraUsageUtilization: Double?

    static let placeholder = WidgetData(
        fiveHourUtilization: 45,
        sevenDayUtilization: 32,
        fiveHourPace: 1.0,
        sevenDayPace: 0.8,
        fiveHourResetsAt: Date().addingTimeInterval(14400).timeIntervalSince1970,
        sevenDayResetsAt: Date().addingTimeInterval(4 * 86400).timeIntervalSince1970,
        updatedAt: Date().timeIntervalSince1970,
        extraUsageEnabled: nil,
        depletionSeconds: nil,
        todayCost: nil,
        activeSessionCount: nil,
        opusUtilization: nil,
        sonnetUtilization: nil,
        haikuUtilization: nil,
        dailyEntries: nil,
        dailyCosts: nil,
        sessions: nil,
        extraUsageUtilization: nil
    )
}

struct DailyEntryData: Codable {
    let date: String
    let usage: Double
}

struct DailyCostData: Codable {
    let date: String
    let cost: Double
}

struct SessionData: Codable {
    let project: String
    let model: String?
    let tokens: Int?
    let durationSeconds: Int?
}
```

- [ ] **Step 2: Update Xcode project to include new files**

Add PBXFileReference entries for the 6 new app files, PBXBuildFile entries for the Sources phase, and add them to the CCUsageWidgetApp group and Sources build phase. The new files are:
- `SharedModels.swift`
- `Theme.swift`
- `DataService.swift`
- `NotificationService.swift`
- `DashboardView.swift`
- `HistoryView.swift`
- `SettingsView.swift`

Use unique IDs following the existing pattern (AA/EE prefix). Add to the `CCUsageWidgetApp` group (BB0000000000000000000007) and the Sources build phase (CC0000000000000000000005).

---

## Task 11: Build, deploy to iPhone, and verify

- [ ] **Step 1: Run Mac tests**

Run: `make test`
Expected: All tests pass including new daily cost and extended widget data tests.

- [ ] **Step 2: Build Mac app**

Run: `make build`
Expected: Clean compile.

- [ ] **Step 3: Build iOS app via xcodebuild**

Run:
```bash
cd CCUsageWidget && xcodebuild -project CCUsageWidget.xcodeproj -scheme CCUsageWidgetApp -destination 'platform=iOS,name=iPhone' -configuration Debug build 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Deploy to iPhone**

Run:
```bash
cd CCUsageWidget && xcodebuild -project CCUsageWidget.xcodeproj -scheme CCUsageWidgetApp -destination 'platform=iOS,name=iPhone' -configuration Debug install 2>&1 | tail -20
```

Or if Xcode is preferred: open the project in Xcode, select the iPhone target, and hit Run.

- [ ] **Step 5: Deploy worker**

Run: `cd worker && npx wrangler deploy`

- [ ] **Step 6: Install updated Mac app**

Run: `make install`

- [ ] **Step 7: Verify end-to-end**

1. Mac app should push extended data (check menu bar still works)
2. iOS app should show Dashboard tab with live data
3. History tab should show weekly chart (may take a day to accumulate)
4. Settings tab should show connection status and notification toggles
5. Widget should continue working unchanged
