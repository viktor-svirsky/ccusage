# CCUsage

macOS menu bar app that shows Claude Code usage limits (5-hour and 7-day windows) with reset countdowns.

## Features

- Live utilization percentages in menu bar (e.g. `🟢 5h:14%  7d:18%`)
- Color-coded indicator: green (<50%), yellow (50-79%), red (80%+)
- Reset time countdowns for each usage window
- Relative "last refresh" timestamp
- Auto-refresh every 60 seconds + on wake from sleep
- Adaptive rate-limit handling (backs off on 429, respects Retry-After)
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
make test    # run 139 unit tests
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
