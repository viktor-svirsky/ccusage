# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

CCUsage is a macOS menu bar app (macOS 13+) that displays Claude Code usage limits. It shows 5-hour and 7-day utilization windows with pace-aware color coding, model breakdowns, depletion forecasts, live agent tracking, and a persistent weekly usage chart. Usage data is synced to an iOS widget via a Cloudflare Worker + KV store. Written entirely in Swift with no dependencies — just `main.swift` (app) and `CCUsageTests.swift` (tests).

## Build & Test

```bash
make build    # Compile .app bundle (includes icon generation)
make test     # Run all unit tests (~608 tests)
make install  # Build + copy to /Applications + launch
make clean    # Remove build artifacts
```

Tests compile with `-DTESTING` flag, which gates out AppKit/system-dependent code via `#if TESTING` / `#if !TESTING` conditionals. The test binary runs at `/tmp/CCUsageTests`.

## Architecture

**Single-file app** — everything is in `main.swift` (~2455 lines), organized by `// MARK: -` sections:

| Section | Lines | Purpose |
|---------|-------|---------|
| Constants | ~5-34 | API URLs, OAuth client ID, retry intervals, device ID |
| API Types | ~36-68 | `UsageData`, `UsageWindow`, `ModelBreakdown`, `ExtraUsage` structs |
| Usage Zones & Notifications | ~70-179 | Zone enum (green/yellow/red/depleted), notification logic |
| Pure Logic | ~181-302 | Token/usage JSON parsing, formatting functions (all testable) |
| Usage History | ~304-354 | Session-scoped ring buffer (60 entries, ~2h), sparkline/trend generation |
| Pacing | ~356-468 | Pace calculation, depletion estimates, budget advice, heatmaps |
| Daily Usage Tracking | ~469-575 | Persistent per-day usage deltas, weekly chart |
| Agent Tracking | ~576-835 | JSONL parsing for agents, session tokens, model, bash uses, context window; `SessionTokens`, `AgentStats`, `TrackedSession`, formatting |
| Agent Session Tracker | ~836-1375 | `AgentTracker` class — polls `~/.claude/projects/` for ALL live sessions, tracks tokens/model/context/shell per session |
| Version Comparison | ~1533-1561 | Semver comparison for auto-update |
| Sentry Error Reporting | ~1563-1600 | Lightweight HTTP-based error reporting to Sentry (no SDK), gated behind `#if !TESTING` |
| Fetch Schedule | ~1610-1634 | Rate limit handling with exponential backoff |
| Status Bar Controller | ~1636-2435 | `StatusBarController` — all AppKit UI, API calls, OAuth, auto-update, daily store persistence, iCloud sync |
| Main | ~2437-2453 | Entry point — `#if TESTING` runs tests, else starts the app |

**Data flow**: Keychain or `~/.claude/.credentials.json` (OAuth token) → Anthropic usage API → parse JSON → update `UsageData` → format menu items → push `WidgetData` to Cloudflare Worker. Agent tracking polls JSONL files independently on a 3-second timer, extracting agent events, per-turn token usage (`message.usage`), model identification, and cache hit rates. Daily usage deltas are persisted to `~/.ccusage-daily.json`.

## Testing

`CCUsageTests.swift` (~2150 lines) uses a custom minimal test framework (no XCTest). Key functions:
- `check()`, `assertEqual()`, `assertNil()`, `assertNotNil()` — assertion helpers
- `test()` / `suite()` — grouping (no setup/teardown)
- `runAllTests()` — calls all `run*Tests()` functions, exits with code 0/1

All pure logic functions are tested. `StatusBarController` methods that depend on AppKit are excluded via `#if !TESTING`.

## Key Patterns

- **`#if TESTING` gates**: Used throughout `main.swift` to swap AppKit-dependent code (attributed strings, notifications) for plain-text equivalents in tests. When adding new UI code, follow this pattern — the TESTING branch must be a functional equivalent (plain text) of production, not a behavioral subset.
- **OAuth flow**: Reads credentials from macOS Keychain (`Claude Code-credentials` service), refreshes tokens independently via `platform.claude.com/v1/oauth/token`.
- **Rate limiting**: `FetchSchedule` struct handles exponential backoff on 429s, respects `Retry-After` headers. Backoff caps at `maxBackoffInterval` (300s). The 429 fallback (when no `Retry-After` header) also uses `maxBackoffInterval`, not `defaultFetchInterval`.
- **Auto-update**: Checks GitHub Releases API, validates download URLs against allowlist, replaces app bundle with rollback on failure.
- **Agent tracking**: `AgentTracker` scans `~/.claude/projects/` for ALL `.jsonl` session files, tracking multiple sessions simultaneously via `TrackedSession` structs. Each session independently tracks tokens, model, context window usage, shell request count, and sub-agents. Sessions are read incrementally (file offset per session). The menu shows all active sessions with per-session stats.
- **Sentry error reporting**: Lightweight HTTP-based error reporting via Sentry's `/store/` API (no SDK). Reports API failures, OAuth errors, and update failures. Gated behind `#if !TESTING`. Fire-and-forget — never blocks UI.
- **Daily usage tracking**: `DailyUsageData` stores per-day utilization deltas in `~/.ccusage-daily.json`. Local file stores `lastUtilization` for delta tracking.
- **Widget sync**: On each API refresh, `pushWidgetData()` PUTs `WidgetData` JSON to a Cloudflare Worker (`ccusage-widget`). The Worker validates the OAuth access token against Anthropic's API (cached for 5 min) and stores data in KV keyed by `sha256(refreshToken)`. The iOS widget fetches via unauthenticated GET using the key URL shared via QR code. Worker source is in `worker/`.

## Version

The `VERSION` file is the source of truth. `make build` stamps it into `Info.plist` via `CFBundleVersion`. Releases are triggered with `gh workflow run Release -f version=X.Y.Z`.
