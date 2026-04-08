# iOS Analytics App Design

**Date:** 2026-04-08
**Status:** Approved

## Overview

Transform the CCUsage iOS app from a setup-only screen into a full analytics dashboard with live usage data, weekly history, cost tracking, session monitoring, and threshold notifications. Glassmorphic dark visual style, tab-based navigation.

## Architecture

### Tab Structure

Three tabs via SwiftUI `TabView`:

1. **Dashboard** — live usage, model breakdown, sessions
2. **History** — weekly charts, cost history, model mix
3. **Settings** — connection setup (existing), notification preferences

### Data Flow

```
Mac (main.swift) → pushWidgetData() → Cloudflare Worker PUT /widget → D1 database
iOS app fetches GET /widget/{key} on 2-minute interval (same as widget extension)
```

The app and widget extension share data via App Group (`group.com.viktorsvirsky.ccusage`). Both read the same widget URL from shared `UserDefaults`.

## Extended WidgetData

Current `WidgetData` fields remain. New fields added (all optional for backward compatibility):

```swift
struct WidgetData: Codable {
    // Existing fields
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

    // NEW: Model breakdown (5-hour window utilization per model)
    let opusUtilization: Double?
    let sonnetUtilization: Double?
    let haikuUtilization: Double?

    // NEW: Daily usage entries (last 7 days)
    let dailyEntries: [DailyEntryData]?

    // NEW: Daily cost entries (last 7 days)
    let dailyCosts: [DailyCostData]?

    // NEW: Active session details
    let sessions: [SessionData]?

    // NEW: Extra usage utilization
    let extraUsageUtilization: Double?
}

struct DailyEntryData: Codable {
    let date: String        // "yyyy-MM-dd"
    let usage: Double       // utilization delta for that day
}

struct DailyCostData: Codable {
    let date: String        // "yyyy-MM-dd"
    let cost: Double        // estimated cost in USD
}

struct SessionData: Codable {
    let project: String     // project directory name
    let model: String?      // e.g. "Opus 4", "Sonnet 4"
    let tokens: Int?        // total tokens in session
    let durationSeconds: Int? // session duration
}
```

## Mac-side Changes (main.swift)

### buildWidgetData()

Extend to include the new fields:

- **Model breakdown**: Read from `usage.models` — extract `opus.utilization`, `sonnet.utilization`, `haiku.utilization` (all from 5-hour window, since that's what the API provides per-model).
- **Daily entries**: Read from `dailyStore.days` (already tracked in `DailyUsageData`).
- **Daily costs**: Derive from `tokenCostTracker` — needs a new `dailyCosts` property that accumulates per-day costs similar to how `DailyUsageData` tracks per-day utilization. Store in the same `~/.ccusage-daily.json` file.
- **Sessions**: Read from `agentTracker.sessions` — map each `TrackedSession` to `SessionData` with project name (derived from session path), model, token count, and duration.
- **Extra usage utilization**: Read from `usage.extraUsage?.utilization`.

### pushWidgetData()

No structural changes — already sends the full `WidgetData` JSON. The new fields are included automatically since `WidgetData` is `Codable`.

### hasSameValues()

Add the new fields to the equality check to avoid unnecessary pushes.

### Daily Cost Tracking

Add a `dailyCosts` array to `DailyUsageData`. On each API refresh, snapshot the current `tokenCostTracker.todayCost.totalCost` as today's cost entry (replacing any existing entry for today, since `todayCost` is already a running total for the day). Prune entries older than 7 days, same as `dailyEntries`.

## Worker Changes (worker/src/index.ts)

### PutBody interface

Update to accept the full extended `WidgetData`. The worker stores the raw JSON blob, so it doesn't need to parse or validate the new fields — it just passes them through. The `sameExceptUpdatedAt` comparison function should continue to work since it compares stringified JSON minus `updatedAt`.

No schema migration needed — data is stored as a JSON string in the `data` column.

## iOS App Changes

### New Files

| File | Purpose |
|------|---------|
| `ContentView.swift` | Rewrite: TabView container with Dashboard/History/Settings tabs |
| `DashboardView.swift` | New: Live usage dashboard |
| `HistoryView.swift` | New: Weekly charts and cost history |
| `SettingsView.swift` | New: Connection setup + notification preferences |
| `SharedModels.swift` | New: `WidgetData` definition shared between app and extension |
| `DataService.swift` | New: Fetches data from worker, caches, provides to views |
| `NotificationService.swift` | New: Local notification scheduling |
| `Theme.swift` | New: Glassmorphic dark color/style constants |

### ContentView.swift (rewrite)

Replace current setup-only screen with a `TabView`:

```
TabView {
    DashboardView()  // tab 1
    HistoryView()    // tab 2
    SettingsView()   // tab 3 (absorbs existing setup flow)
}
```

If not connected (no saved URL), show a full-screen onboarding/setup flow instead of the tab view.

### DashboardView

Sections (scrollable):
1. **Utilization cards** — two side-by-side glassmorphic cards showing 5h and 7d percentage, pace indicator (steady/fast/slow), progress bar with gradient, reset countdown
2. **Depletion warning** — orange banner, only visible when `depletionSeconds != nil`. Shows "Depletes in X" with pace context
3. **Model breakdown** — stacked horizontal bar (Opus purple, Sonnet cyan, Haiku gray) with legend
4. **Quick stats row** — three compact cards: today's cost, active session count, extra usage on/off
5. **Active sessions** — list of `SessionData` entries with project name, model, tokens, duration. Each in a glassmorphic card. Hidden when no sessions

### HistoryView

Sections (scrollable):
1. **Weekly usage chart** — vertical bar chart of 7 `dailyEntries`. Bar color follows the existing zone system (green < 50%, orange 50-80%, red > 80% of max day). Summary row below: week total, daily average, peak day
2. **Cost history** — smaller bar chart of 7 `dailyCosts`. Purple bars. Weekly total in header
3. **Model mix** — horizontal progress bars for Opus/Sonnet/Haiku with percentages

When `dailyEntries` or `dailyCosts` are nil (older Mac version not syncing them), show a placeholder: "Update CCUsage on your Mac for history data."

### SettingsView

Absorbs existing `ContentView` setup flow, restyled for dark theme:
1. **Connection status** — green dot + "Connected" when URL saved, with truncated URL
2. **QR scan button** — existing `QRScannerView` integration
3. **URL paste field** — existing text field + save button
4. **Notification toggles** — 3 switches stored in UserDefaults:
   - High usage alert (80% threshold)
   - Critical alert (95% threshold)
   - Depletion warning (when `depletionSeconds` present)
5. **About** — widget refresh interval, app version
6. **Disconnect** — destructive button

### DataService

Observable class that:
- Reads widget URL from App Group UserDefaults
- Fetches `WidgetData` from worker on a timer (every 2 minutes when app is foreground)
- Caches last response in App Group UserDefaults (shared with widget extension)
- Publishes `@Published var data: WidgetData?` for SwiftUI views
- On each fetch, evaluates notification conditions and fires local notifications

### NotificationService

Handles local notifications (no push infrastructure needed):
- Requests notification permission on first toggle-on in settings
- On each data fetch, checks:
  - If 5h or 7d utilization crosses 80% → "High Usage" notification (if enabled)
  - If 5h or 7d utilization crosses 95% → "Critical" notification (if enabled)
  - If `depletionSeconds` appears (was nil, now has value) → "Depletion Warning" (if enabled)
- Deduplicates: stores last notification state in UserDefaults to avoid repeat alerts for same threshold crossing

### Theme

Constants for the glassmorphic dark style:
- Background gradient: `#0f172a` → `#1e293b`
- Card background: `white.opacity(0.04)` with `white.opacity(0.06)` border
- Accent card: `white.opacity(0.06)` with `white.opacity(0.08)` border
- Green: `#4ade80`, Orange: `#fb923c`, Red: `#f43e5e`
- Opus purple: `#a78bfa`, Sonnet cyan: `#22d3ee`, Haiku gray: `#94a3b8`
- Cost purple: `#a855f7`
- Text primary: `#e2e8f0`, secondary: `#94a3b8`, tertiary: `#64748b`, quaternary: `#475569`
- Progress bar gradients: green→cyan (healthy), orange→red (warning)

### Shared WidgetData

The `WidgetData` struct is currently duplicated between the extension and the app. Extract to a shared file or Swift package that both targets import. The extended struct (with new optional fields) must be backward-compatible — the widget extension ignores fields it doesn't render.

## Widget Extension Changes

Minimal. The extension continues using the existing fields it already renders. New fields in `WidgetData` are optional and decoded but ignored by widget views. No visual changes to widgets.

## Xcode Project Changes

- Add new Swift files to the app target
- Ensure `SharedModels.swift` is in both app and extension targets (or create a shared framework)
- Add `UserNotifications` framework to app target
- No new third-party dependencies

## Notifications Implementation

Local notifications only — no APNS, no server-side push:

1. App requests `UNUserNotificationCenter` authorization on first toggle
2. On each data fetch (every 2 min in foreground), `NotificationService` evaluates thresholds
3. State tracking in `UserDefaults`:
   - `lastNotified80`: timestamp of last 80% alert
   - `lastNotified95`: timestamp of last 95% alert
   - `lastNotifiedDepletion`: timestamp of last depletion alert
   - Cooldown: don't re-notify same threshold within 30 minutes
4. Background App Refresh: register for `BGAppRefreshTask` to fetch data periodically when app is backgrounded. This allows notifications even when app isn't open. iOS limits background refresh to ~15-30 min intervals.

## Testing

- Mac-side: extend existing `CCUsageTests.swift` to test new `buildWidgetData` fields, daily cost tracking
- iOS: manual testing on device (already connected)
- Worker: no logic changes, just pass-through of larger JSON blob

## Migration / Backward Compatibility

- New `WidgetData` fields are all optional — older Mac versions push nil, iOS app shows placeholders
- Worker stores raw JSON, no schema change needed
- Widget extension decodes new fields but doesn't use them — no visual changes
- `hasSameValues()` includes new fields so pushes happen when model/session data changes
