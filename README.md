# CCUsage

macOS menu bar app that shows Claude Code usage limits (5-hour and 7-day windows) with reset countdowns.

## Features

- Live utilization percentages in menu bar (e.g. `🟢 5h:14%  7d:18%`)
- Color-coded indicator: green (<50%), yellow (50-79%), red (80%+)
- Reset time countdowns for each usage window
- Relative "last refresh" timestamp
- Auto-refresh every 60 seconds + on wake from sleep
- Registers as login item automatically

## Requirements

- macOS 13+
- Claude Code signed in (OAuth token in Keychain)

## Install

```bash
make install
```

## Build & Test

```bash
make test    # run 76 unit tests
make build   # compile .app bundle
```

## Uninstall

```bash
make uninstall
```
