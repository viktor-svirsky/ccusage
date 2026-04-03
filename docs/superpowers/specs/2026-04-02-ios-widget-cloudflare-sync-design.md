# iOS Widget: Cloudflare Sync

Replace iCloud-based sync between macOS app and iOS widget with a Cloudflare Worker + KV store. This eliminates the $99/year Apple Developer Program requirement for iCloud containers.

## Architecture

```
macOS app  --PUT /widget (Bearer token)--> Cloudflare Worker --> KV store
iOS widget --GET /widget/:key -----------> Cloudflare Worker --> KV store
```

Three components:

1. **Cloudflare Worker + KV** — stores and serves `WidgetData` JSON
2. **macOS app (main.swift)** — pushes `WidgetData` to Worker on each API refresh
3. **iOS widget (CCUsageExtension.swift)** — fetches `WidgetData` from Worker every 15 min

## Data

Same `WidgetData` struct as today (~150 bytes JSON):

```json
{
  "fiveHourUtilization": 45.2,
  "sevenDayUtilization": 32.1,
  "fiveHourPace": 1.1,
  "sevenDayPace": 0.9,
  "fiveHourResetsAt": 1743620000,
  "sevenDayResetsAt": 1744200000,
  "updatedAt": 1743610000
}
```

## Worker API

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| `PUT /widget` | Bearer access_token | Validates token against Anthropic API | Store WidgetData |
| `GET /widget/:key` | None (key is unguessable) | — | Read WidgetData |
| `GET /health` | None | — | Returns 200 |

### PUT /widget

1. Extract `Authorization: Bearer <access_token>` from header
2. Parse request body. Must include `refreshTokenHash` (SHA-256 hex of refresh token, computed client-side).
3. Check KV for `auth:<sha256(access_token)>`. If present, skip validation (cached).
4. If not cached: validate token by calling `https://api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20` header. If non-200, return 401. On success, cache `auth:<sha256(access_token)>` in KV with TTL 300s (5 min).
5. KV key: `widget:<refreshTokenHash>`
6. Store the `WidgetData` portion (without `refreshTokenHash`) in KV with TTL of 3600 seconds (1 hour).
7. Return `200 { "key": "<refreshTokenHash>" }`

Request body:

```json
{
  "refreshTokenHash": "a1b2c3...",
  "data": {
    "fiveHourUtilization": 45.2,
    "sevenDayUtilization": 32.1,
    "fiveHourPace": 1.1,
    "sevenDayPace": 0.9,
    "fiveHourResetsAt": 1743620000,
    "sevenDayResetsAt": 1744200000,
    "updatedAt": 1743610000
  }
}
```

### GET /widget/:key

1. Read KV at `widget:<key>`
2. If found: return `200` with `WidgetData` JSON
3. If not found or expired: return `404`

### GET /health

Returns `200 { "status": "ok" }`.

## Auth & Key Strategy

- **Write auth**: macOS app sends its Anthropic OAuth access token. Worker validates it by calling the Anthropic usage API. This proves the token is real without storing it.
- **Storage key**: SHA-256 hash of the refresh token, computed by the macOS app. The refresh token is long-lived, so the key is stable across access token refreshes.
- **Read auth**: None. The key is a SHA-256 hash (64 hex chars) — effectively unguessable. This means the iOS widget only needs the Worker URL + key, no OAuth tokens.
- **Token rotation**: If the refresh token rotates, the macOS app computes a new hash and starts writing to a new key. The iOS widget needs to re-scan the QR code. This is rare.

## iOS Widget Setup Flow

1. macOS app menu: "Share to iPhone" menu item
2. Clicking it shows a window with a QR code encoding: `https://<worker>.workers.dev/widget/<key>`
3. iOS companion app: single screen with "Scan QR Code" or "Paste URL" options
4. URL stored in `UserDefaults` via App Group (shared between companion app and widget extension)
5. Widget timeline provider fetches the URL every 15 minutes

No OAuth tokens are stored on iOS. No Keychain needed. No iCloud entitlements needed.

## macOS App Changes

### Add
- SHA-256 helper to hash refresh token (CommonCrypto / CryptoKit)
- `pushWidgetData()` function: PUT to Worker after each successful API refresh. Fire-and-forget async — never blocks the main refresh cycle. Silently ignore network errors.
- Worker URL constant (or configurable via menu)
- "Share to iPhone" menu item with QR code window (CoreImage CIQRCodeGenerator)
- Store Worker URL + key in local state for the QR code

### Remove
- iCloud daily sync: `saveDailyToICloud()`, `loadMergedDailyDays()` iCloud path
- iCloud widget sync: `saveWidgetData()` iCloud container writes
- iCloud subfolder constant, iCloud container identifier
- `deviceId` (only used for iCloud file naming)

### Keep
- Local `~/.ccusage-daily.json` for macOS-only daily usage tracking and weekly chart
- All existing daily usage recording logic (just remove the iCloud write)

## iOS Widget Changes

### CCUsageExtension.swift
- Replace iCloud file read with HTTP GET to stored URL
- Read URL from shared `UserDefaults` (App Group)
- Parse `WidgetData` JSON from HTTP response
- Show "No data" if URL not configured or fetch fails
- Timeline: refresh every 15 minutes (same as today)

### CCUsageWidgetApp.swift / ContentView.swift
- Replace setup instructions with QR scanner + paste URL input
- Store URL in App Group UserDefaults
- Show current status (connected / last update time)

### Remove
- iCloud container entitlements
- iCloud file reading logic
- `iCloud.com.viktorsvirsky.ccusage` container references

## Cloudflare Setup

- Worker name: `ccusage-widget`
- KV namespace: `CCUSAGE_WIDGET`
- Deploy via `wrangler` (config in `worker/wrangler.toml`)
- Free tier is sufficient (< 100K reads/day, < 1K writes/day)

## File Structure

```
ccusage/
  worker/
    wrangler.toml
    src/
      index.ts
  CCUsageWidget/          (existing, modified)
    CCUsageExtension/
    CCUsageWidgetApp/
    CCUsageWidget.xcodeproj/
  main.swift              (existing, modified)
```
