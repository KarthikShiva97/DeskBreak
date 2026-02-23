# StandupReminder

A lightweight macOS menu bar app that tracks how long you've been working and sends periodic standup/stretch reminders.

## Features

- **Menu bar timer** — shows cumulative active work time at a glance
- **Activity detection** — uses IOKit HIDIdleTime to detect mouse/keyboard idle; automatically pauses tracking when you step away
- **macOS notifications** — sends native notification reminders at a configurable interval
- **Configurable** — set reminder interval (10–120 min) and idle threshold (1–10 min) via Preferences
- **Dock-free** — runs as a background agent (no Dock icon)

## Requirements

- macOS 13 (Ventura) or later
- Xcode 15+ or Swift 5.9+ toolchain

## Build & Run

```bash
cd StandupReminder
./build.sh
open StandupReminder.app
```

Or build manually:

```bash
swift build -c release
.build/release/StandupReminder
```

## Install

```bash
cp -R StandupReminder.app /Applications/
```

## How It Works

1. The app polls system idle time every 5 seconds via `IOKit` (`HIDIdleTime`)
2. If idle time is below the threshold (default: 2 min), the user is considered "active" and the work timer increments
3. When cumulative active time since the last reminder reaches the configured interval (default: 30 min), a macOS notification fires
4. The timer resets for the next cycle; total session time keeps accumulating

## Menu Bar Controls

| Action | Description |
|---|---|
| **Pause/Resume Tracking** | Manually stop/start the timer |
| **Reset Session** | Zero out all counters |
| **Preferences…** | Open settings window |
| **Quit** | Exit the app |

## Architecture

```
Sources/StandupReminder/
├── main.swift               # App entry point
├── AppDelegate.swift         # Menu bar UI, status item, actions
├── ActivityMonitor.swift     # IOKit idle time detection
├── ReminderManager.swift     # Work timer + notification scheduling
└── PreferencesWindow.swift   # SwiftUI preferences UI
```
