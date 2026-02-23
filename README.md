# StandupReminder

A lightweight macOS menu bar app that reminds you to stand up, stretch, and decompress your spine. Built for developers (and anyone) who sit too long.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Why?

Sitting for hours wrecks your back. This app lives in your menu bar, tracks how long you've been working, and forces you to take stretch breaks with guided exercises — specifically chosen for spinal disc health.

## Features

- **Menu bar timer** — shows cumulative active work time at a glance
- **Activity detection** — automatically pauses when you step away (uses IOKit idle time)
- **Blocking stretch overlay** — full-screen break with guided exercises (skip available after 10s)
- **Exercises for disc health** — standing back extensions, McKenzie press-ups, nerve glides, and more
- **Warning banner** — 30-second heads-up before a break starts
- **Snooze** — up to 2 snoozes per cycle (5 min, then 2 min)
- **Posture nudge** — gentle mid-cycle reminder to check your posture
- **Meeting detection** — defers breaks during Zoom, Teams, WebEx, FaceTime, screen sharing
- **Adaptive breaks** — break duration increases the longer you sit without moving
- **Daily streak tracking** — tracks consecutive days of completed breaks
- **Session summary** — stats on quit showing work time, breaks completed/skipped
- **Disable timer** — pause for 15m / 30m / 1h / 2h, or indefinitely
- **Launch at login** — optional auto-start via macOS Login Items
- **Dock-free** — runs as a background agent (no Dock icon)
- **Configurable** — reminder interval (15–60 min), idle threshold, stretch duration, blocking mode

## Quick Install (No Xcode Required)

Download and run the installer — it builds the app and copies it to your Applications folder:

```bash
git clone https://github.com/KarthikShiva97/Test.git
cd Test
./install.sh
```

That's it. The app will open automatically after install.

### What You Need

- A Mac running **macOS 14 (Sonoma)** or later
- **Xcode Command Line Tools** — the installer will prompt you to install them if missing

> Don't have the Command Line Tools? When prompted, click "Install" in the dialog that appears. It takes a few minutes. You do NOT need the full Xcode app.

## Manual Build

If you prefer to build yourself:

```bash
./build.sh
open StandupReminder.app
```

Or with Swift directly:

```bash
swift build -c release
.build/release/StandupReminder
```

## How It Works

1. The app polls system idle time every 5 seconds via `IOKit`
2. If idle time is below the threshold (default: 2 min), you're considered "active" and the work timer increments
3. At the halfway point, you get a gentle posture nudge
4. 30 seconds before the break, a warning banner appears (with snooze option)
5. When the timer hits the interval (default: 25 min), a full-screen stretch overlay blocks your screen
6. The overlay shows a guided stretch exercise, rotating every 20 seconds
7. After the stretch, the timer resets for the next cycle

## Menu Bar Controls

| Action | Shortcut | Description |
|---|---|---|
| **Break Now** | Cmd+B | Trigger a stretch break immediately |
| **Disable for...** | — | Pause tracking for 15m / 30m / 1h / 2h / indefinitely |
| **Resume Tracking** | Cmd+P | Re-enable after disabling |
| **Reset Session** | Cmd+R | Zero out all counters |
| **Preferences...** | Cmd+, | Open settings window |
| **Quit** | Cmd+Q | Exit the app |

## Preferences

| Setting | Options | Default |
|---|---|---|
| Reminder interval | 15, 20, 25, 30, 45, 60 min | 25 min |
| Idle threshold | 1, 2, 3, 5, 10 min | 2 min |
| Blocking mode | On / Off | On |
| Stretch duration | 30s, 1m, 2m, 3m, 5m | 1 min |
| Launch at login | On / Off | Off |

## Uninstall

```bash
# Remove the app
rm -rf /Applications/StandupReminder.app

# Remove saved preferences (optional)
defaults delete com.standupreminder.app
```

## Architecture

```
Sources/StandupReminder/
├── main.swift                # App entry point
├── AppDelegate.swift          # Menu bar UI, status item, actions
├── ActivityMonitor.swift      # IOKit idle time detection
├── ReminderManager.swift      # Work timer, break scheduling, meeting detection
├── PreferencesWindow.swift    # SwiftUI preferences UI
├── SessionStats.swift         # Break stats and daily streak tracking
├── StretchOverlayWindow.swift # Full-screen blocking stretch overlay
└── WarningBanner.swift        # Pre-break warning banner with snooze
```

## License

MIT
