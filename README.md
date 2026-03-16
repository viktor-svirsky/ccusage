# CCUsage

macOS menu bar app that shows Claude Code usage limits (5-hour and 7-day windows) at a glance — with trend direction, sparklines, and budget pacing.

## Features

### Menu Bar
- Live utilization percentages (e.g. `🟢↑5h:14%  🟢→7d:18%`)
- Per-window color indicators: green (<50%), yellow (50-79%), red (80%+)
- Trend arrows (↑↓→) show whether usage is rising, falling, or flat based on session history

### Dropdown Detail
- Progress bars for each usage window
- Remaining percentage and reset time countdowns
- Sparkline charts (▁▂▃▄▅▆▇█) for the 5-hour window showing recent usage pattern
- Budget pacing for both windows — compares actual usage against expected linear spend rate (e.g. `▲ 1.4x pace (over budget)`)

### Infrastructure
- Auto-refresh every 5 minutes + on wake from sleep
- Adaptive rate-limit handling with exponential backoff (respects Retry-After, auto-refreshes OAuth token on 429)
- Session-scoped usage history (last 24 data points, ~2 hours)
- Auto-update from GitHub Releases with one-click install
- Registers as login item automatically

## Requirements

- macOS 13+
- Claude Code signed in (OAuth token in Keychain)

## Install

### From GitHub Releases

Download the latest `CCUsage.zip` from [Releases](https://github.com/viktor-svirsky/ccusage/releases), unzip, and move `CCUsage.app` to `/Applications`.

### From source

```bash
make install
```

## Build & Test

```bash
make test    # run 215 unit tests
make build   # compile .app bundle
```

## Uninstall

```bash
make uninstall
```

## Creating a Release

Trigger the release workflow manually:

```bash
gh workflow run Release -f version=1.0.0
```

This runs tests, builds the app with the specified version, creates a git tag, and publishes a GitHub Release with the `.zip` artifact.
