# CCUsage Optimization & Refactor Plan

**Date:** 2026-04-15
**Status:** Approved for autonomous execution
**Branch context:** `feature/d1-migration` (WIP, 1569 insertions uncommitted across core files + iOS widget app in-progress)

## Motivation

`main.swift` has grown to ~3162 lines (single file). Widget shows stale data during quiet usage periods. Multiple uncoordinated timers, synchronous network calls on main thread, duplicated formatting logic, God-class `StatusBarController`. Security gaps in auto-update flow and credential storage. Goal: structured, phased cleanup that preserves all behavior and tests.

## Findings Summary

### Widget Staleness — ROOT CAUSE

**`main.swift:2464`** — `pushWidgetData()` skips the PUT entirely when `last.hasSameValues(as: widgetData)`. During idle periods (stable metrics) no push fires, the Worker's `updatedAt` is never refreshed, and the iOS widget displays a frozen "last updated" timestamp. Users perceive the whole widget as stale.

**Secondary:** `Array(agentTracker.activeSessions)` iterates a Set in undefined order, so `hasSameValues()` can report false-different on identical state, causing spurious pushes (opposite problem — churn).

**Worker inefficiency (not staleness):** `worker/src/index.ts:106-115` claims to skip the data write on unchanged payload, but the `else` branch still writes `newValue` (UPDATE with `data = ?`). Comment misleading; both branches write. Minor D1 write waste.

### Security — Ranked

| # | Location | Issue | Severity |
|---|----------|-------|----------|
| S1 | `main.swift:2074-2076` | Hardcoded Sentry DSN components (abusable for log spam) | Medium |
| S2 | `main.swift` credential file write path | `~/.claude/.credentials.json` created with default perms (0644); no chmod 0600 | High |
| S3 | `main.swift` auto-update flow | Only Bundle ID check before swapping `.app`; no codesign verify | High |
| S4 | `worker/src/index.ts:96` + `main.swift` | Widget key = `SHA256(org_id)`. org_id low-entropy — bruteforce possible. Should be HMAC with server secret | High |
| S5 | `worker/src/index.ts` | No rate limiting on GET; enumeration possible | Medium |
| S6 | `worker/src/index.ts:68-94` | Token hash cached 3600s without revocation signal | Low |
| S7 | File permissions — ccusage-daily.json, Sentry bodies | No audit of what goes in payloads | Low |

### Performance — Ranked

| # | Location | Issue | Impact |
|---|----------|-------|--------|
| P1 | `pushWidgetData` call site (refresh) | Sync URLSession PUT on main thread, blocks menu | High |
| P2 | Timers: 1s/3s/10s/60s/300s | Uncoordinated, collisions on main thread | High |
| P3 | `saveDailyStore()` | Writes JSON on every refresh, no hash dedup | Medium |
| P4 | `formatUnifiedSessions` | 150-200 NSAttributedString allocations / minute regardless of state | Medium |
| P5 | `AgentTracker.findAllSessions` | Re-enumerates `~/.claude/projects/` every 3s | Medium |
| P6 | `CodexTracker.poll()` | Opens/closes SQLite every 10s even when mtime unchanged | Low |
| P7 | `updateSessionsUI()` | No dirty-flag; re-renders unchanged sessions | Low |
| P8 | Date formatters / string builders | Allocations per render, no memoization | Low |

### Architecture — Decomposition

Single-file spaghetti (3162 lines). Proposed 9-file split:

| File | Lines (approx) | Responsibility |
|------|----------------|----------------|
| `Constants.swift` | ~40 | URLs, OAuth client ID, retry intervals |
| `Models.swift` | ~160 | API/UsageData, WidgetData, shared types |
| `TokenFormatting.swift` | ~100 | formatTokens / formatCost / time helpers (consolidate dupes) |
| `UsageMetrics.swift` | ~300 | History ring buffer, pacing, daily delta tracking (pure logic) |
| `SessionTracking.swift` | ~500 | Agent tracking (JSONL), token cost, Codex, unified session formatting |
| `APIClient.swift` | ~220 | OAuth, Keychain I/O, fetch schedule (DI-ready) |
| `WidgetSync.swift` | ~80 | buildWidgetData, push logic |
| `VersionManagement.swift` | ~120 | Semver, auto-update (+ codesign verify) |
| `StatusBarUI.swift` | ~400 | NSStatusBar + menu rendering |
| `RefreshCoordinator.swift` | ~300 | Timer unification, API call orchestration |
| `main.swift` (reduced) | ~150 | Entry point, DI wiring, test runner |

**StatusBarController decomposition:** currently 938 lines, 7 responsibilities → split into `StatusBarUI` (pure presentation), `RefreshCoordinator` (API + timers), `StatusBarController` (thin composition root).

**`#if TESTING` → DI:** Replace compile-time branches with protocol injection: `CredentialsProvider`, `ErrorReporter`, `FileStore`, `Clock`. Production impls inject real system; tests inject fakes. Eliminates gate duplication.

## Execution Phases

Each phase is independently mergeable. Tests must pass before advancing. No commit by assistant — user reviews manually per project rule.

### Phase 0 — Widget staleness hotfix (SHIP-READY)

**Change:** `main.swift:2464` — replace value-equality skip with heartbeat-aware check.

```swift
// Push if values changed OR >= 5 minutes since last push (heartbeat)
let heartbeatInterval: TimeInterval = 300
let shouldPush: Bool = {
    guard let last = lastPushedWidgetData,
          let lastPushAt = lastWidgetPushAt else { return true }
    if !last.hasSameValues(as: widgetData) { return true }
    return Date().timeIntervalSince(lastPushAt) >= heartbeatInterval
}()
if !shouldPush { return }
```

**Also:** fix `hasSameValues` session comparison — sort `activeSessions` before comparison, or switch `sessions` field to deterministic order (sorted by project id) at `buildWidgetData` time.

**Tests:** extend widget push tests with cases (unchanged-under-heartbeat, unchanged-over-heartbeat, changed-immediate, session-reorder-same).

**Risk:** None. Additive client behavior. Worker unchanged.

### Phase 1 — Security critical

- **S2**: after any credentials file write, `chmod(path, 0o600)`. Verify on read; warn if looser.
- **S3**: before swapping `.app` bundle during auto-update, shell out to `codesign -v --strict --deep` on the downloaded bundle; abort if signature invalid. Keep existing rollback.
- **S1**: move Sentry DSN to compile-time constant sourced from `Info.plist` (built-time substitution) — not a code-level change but closes "grep for keys" surface. Acceptable interim: leave DSN, rotate it, document limitations.
- **S5**: worker — add simple IP bucket rate limiter (token bucket in D1; 60 req/min/IP) for GET. Upgrade later to Cloudflare Rate Limiting rules.

**Tests:** unit test for permission-check helper (S2), signature-verify pass/fail (S3), rate-limit worker handler (S5).

**Risk:** low. Additive.

### Phase 2 — Extract pure modules (low risk)

Order: `Constants.swift` → `Models.swift` → `TokenFormatting.swift` → `UsageMetrics.swift`. Each extraction: cut section from `main.swift`, paste into file, run tests. Pure logic — zero behavioral delta expected.

**Quality gates:** `make test` passes after each extraction.

**Risk:** low. Mechanical moves. Merge conflicts likely with WIP since main.swift already has 1212 uncommitted lines — this phase should run AFTER current WIP merges, or coordinated against it.

### Phase 3 — Extract I/O modules

`APIClient.swift`, `SessionTracking.swift`, `WidgetSync.swift`, `VersionManagement.swift`. Introduces protocol boundaries where `#if TESTING` gates currently live.

**Introduce protocols:**
- `CredentialsProvider { read() -> Data?; write(Data) throws }`
- `ErrorReporter { report(Error, ctx: [String: Any]) }`
- `FileStore { read(path) -> Data?; write(path, Data); mtime(path) -> Date? }`
- `Clock { now() -> Date }`

**Tests:** swap `#if TESTING` branches for fakes. Grow coverage.

**Risk:** medium. Touches broad surface.

### Phase 4 — StatusBarController decomposition

Split into `StatusBarUI` (pure rendering, testable) + `RefreshCoordinator` (timers/API) + thin `StatusBarController` composition root. Unify timers into single 3s heartbeat with subcycle counters (60s UI, 10s Codex, 300s updates).

**Performance wins enabled here:** P1 (async widget push), P2 (timer unification), P4 (dirty-flag rendering), P7 (cached session hash).

**Tests:** RefreshCoordinator tests with injected Clock + APIClient fake. UI renderer tests compare AttributedString output.

**Risk:** high. God-class break-up.

### Phase 5 — Worker hardening + simplification

- Fix `handlePut` "dedup" branch: either actually skip the write, or collapse both branches (single INSERT OR REPLACE) and drop the dead code path.
- HMAC widget key: server generates key = `hmac_sha256(org_id, worker_secret)`. Requires worker `WORKER_SECRET` env binding + client key refresh flow.
- Rate limiting on GET (if not already in Phase 1).
- Drop `sameExceptUpdatedAt` JSON parse if D1 write cost is acceptable (simpler handler).

**Tests:** worker has existing tests (per repo); extend.

**Risk:** medium. HMAC migration requires coordinated client rollout — old keys invalid. Plan migration: dual-read (HMAC-new + SHA-old) for 2 weeks, then drop SHA path.

### Phase 6 — Performance polish

Remaining perf items: P3 (daily-store dedup), P5 (AgentTracker dir-list cache), P6 (Codex mtime check), P8 (memoize formatters).

**Risk:** low.

## Success Criteria

- `make test` green after each phase
- Widget timestamp advances at least every 5 min while Mac awake
- `main.swift` reduced to ≤ 200 lines (composition root only)
- No `#if TESTING` gates remaining outside entry-point
- Zero new warnings under `-Wall`
- Codesign verification gates auto-update

## Execution Mode

Autonomous ("Ralph") loop over phases in order. No assistant-initiated commits (per repo CLAUDE.md rule). After each phase: run tests, report diff summary, await next iteration. Final step: code-reviewer agent sweep over diff.

## Deferred / Out-of-Scope

- iOS widget app redesign (covered by `2026-04-08-ios-analytics-app-design.md`)
- Switching off custom test framework to XCTest — not requested, large disruption
- Bundle signing/notarization pipeline change (infra concern)
