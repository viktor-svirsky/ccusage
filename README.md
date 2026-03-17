# CCUsage

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Tests](https://img.shields.io/badge/tests-271%20passing-brightgreen)](https://github.com/viktor-svirsky/ccusage)
[![GitHub release](https://img.shields.io/github/v/release/viktor-svirsky/ccusage)](https://github.com/viktor-svirsky/ccusage/releases/latest)
[![Homebrew](https://img.shields.io/badge/Homebrew-tap-FBB040?logo=homebrew&logoColor=white)](https://github.com/viktor-svirsky/homebrew-ccusage)

macOS menu bar app that shows Claude Code usage limits (5-hour and 7-day windows) at a glance — with trend direction, sparklines, and budget pacing.

<p align="center">
  <img src=".github/screenshots/menubar.png" alt="Menu bar" width="600">
  <br>
  <img src=".github/screenshots/dropdown.png" alt="Dropdown detail" width="400">
</p>

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
- Independent OAuth token refresh — works even when Claude Code isn't running
- Proactive token renewal before expiry + automatic retry on 401 with graceful degradation
- Adaptive rate-limit handling with exponential backoff (respects Retry-After, auto-refreshes OAuth token on 429)
- Session-scoped usage history (last 24 data points, ~2 hours)
- Auto-update from GitHub Releases with one-click install
- Registers as login item automatically

## Requirements

- macOS 13+
- Claude Code signed in at least once (OAuth token in Keychain)

## Install

### Homebrew

```bash
brew install viktor-svirsky/ccusage/ccusage
```

### From GitHub Releases

Download the latest `CCUsage.zip` from [Releases](https://github.com/viktor-svirsky/ccusage/releases), unzip, and move `CCUsage.app` to `/Applications`.

### From source

```bash
make install
```

## Build & Test

```bash
make test    # run 271 unit tests
make build   # compile .app bundle
```

## Uninstall

```bash
brew uninstall ccusage        # if installed via Homebrew
make uninstall                # if installed from source
```

## Creating a Release

Trigger the release workflow manually:

```bash
gh workflow run Release -f version=1.2.0
```

This runs tests, builds the app with the specified version, creates a git tag, publishes a GitHub Release with the `.zip` artifact, and updates the [Homebrew tap](https://github.com/viktor-svirsky/homebrew-ccusage) automatically.
