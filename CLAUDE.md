# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

CCUsage is a macOS menu bar app (macOS 13+) that displays Claude Code usage limits. It shows 5-hour and 7-day utilization windows with pace-aware color coding, model breakdowns, depletion forecasts, live agent tracking, and a persistent weekly usage chart synced across devices via iCloud. Written entirely in Swift with no dependencies — just `main.swift` (app) and `CCUsageTests.swift` (tests).

## Build & Test

```bash
make build    # Compile .app bundle (includes icon generation)
make test     # Run all unit tests (~440 tests)
make install  # Build + copy to /Applications + launch
make clean    # Remove build artifacts
```

Tests compile with `-DTESTING` flag, which gates out AppKit/system-dependent code via `#if TESTING` / `#if !TESTING` conditionals. The test binary runs at `/tmp/CCUsageTests`.

## Architecture

**Single-file app** — everything is in `main.swift` (~2215 lines), organized by `// MARK: -` sections:

| Section | Lines | Purpose |
|---------|-------|---------|
| Constants | ~5-34 | API URLs, OAuth client ID, retry intervals, device ID |
| API Types | ~36-68 | `UsageData`, `UsageWindow`, `ModelBreakdown`, `ExtraUsage` structs |
| Usage Zones & Notifications | ~70-179 | Zone enum (green/yellow/red/depleted), notification logic |
| Pure Logic | ~181-302 | Token/usage JSON parsing, formatting functions (all testable) |
| Usage History | ~304-354 | Session-scoped ring buffer (60 entries, ~2h), sparkline/trend generation |
| Pacing | ~356-468 | Pace calculation, depletion estimates, budget advice, heatmaps |
| Daily Usage Tracking | ~469-575 | Persistent per-day usage deltas, weekly chart, iCloud merge logic |
| Agent Tracking | ~576-835 | JSONL parsing for agents, session tokens, model; `SessionTokens`, `AgentStats`, formatting |
| Agent Session Tracker | ~836-1375 | `AgentTracker` class — polls `~/.claude/projects/` for live sessions, tracks tokens/model |
| Version Comparison | ~1377-1405 | Semver comparison for auto-update |
| Fetch Schedule | ~1415-1439 | Rate limit handling with exponential backoff |
| Status Bar Controller | ~1441-2198 | `StatusBarController` — all AppKit UI, API calls, OAuth, auto-update, daily store persistence, iCloud sync |
| Main | ~2200-2215 | Entry point — `#if TESTING` runs tests, else starts the app |

**Data flow**: Keychain (OAuth token) → Anthropic usage API → parse JSON → update `UsageData` → format menu items. Agent tracking polls JSONL files independently on a 3-second timer, extracting agent events, per-turn token usage (`message.usage`), model identification, and cache hit rates. Daily usage deltas are persisted to `~/.ccusage-daily.json` and synced via iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs/.ccusage/<device-id>.json`).

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
- **Agent tracking**: `AgentTracker` scans `~/.claude/projects/` for the most recently modified `.jsonl` session file, reads new lines incrementally (tracks file offset), parses agent launch/completion events.
- **Daily usage tracking**: `DailyUsageData` stores per-day utilization deltas. Each device writes its own file to iCloud Drive; `loadMergedDailyDays()` reads all device files and merges them via `mergeDailyEntries()`. Local file stores `lastUtilization` for delta tracking; iCloud files store only the `days` array.

## Version

The `VERSION` file is the source of truth. `make build` stamps it into `Info.plist` via `CFBundleVersion`. Releases are triggered with `gh workflow run Release -f version=X.Y.Z`.
