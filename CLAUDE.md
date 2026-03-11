# CLAUDE.md

## Project Overview

macOS menu bar app for controlling WalkingPad/KingSmith treadmills over Bluetooth Low Energy (BLE) using the FTMS (Fitness Machine Service) standard.

## Architecture

Three Swift source files, compiled directly with `swiftc` (no Xcode project, no SPM):

- **App.swift** — Entry point, `NSStatusItem` menu bar setup, `NSPopover` with SwiftUI content, 1-second timer for menu bar updates
- **BLEManager.swift** — Core BLE communication (`CBCentralManager`/`CBPeripheralDelegate`), FTMS protocol parsing, calorie calculation (ACSM equations), file persistence (`~/.walkingpad/data.json`), daily goal tracking, streak/history
- **Views.swift** — All SwiftUI views: popover layout, metrics grid, daily goal progress, controls, speed presets, 7-day history chart, goal celebration overlay, onboarding, settings

## Build

```bash
cd WalkingPad
./build.sh        # compiles with swiftc, ad-hoc codesigns
open build/WalkingPad.app
```

Targets `arm64-apple-macosx13.0`. Links SwiftUI, AppKit, CoreBluetooth frameworks.

## BLE Protocol

- Scans for FTMS service UUID `0x1826` (not filtered by device name)
- FTMS characteristics: Treadmill Data (`2ACD`), Machine Status (`2ADA`), Control Point (`2AD9`), Speed Range (`2AD4`)
- Control opcodes: `0x00` request control, `0x02` set speed, `0x07` start/resume, `0x08` stop/pause
- KingSmith vendor services (`FFC0`, `FFF0`) used optionally for step count

## Key Design Decisions

- **Delta-based distance tracking**: Accumulates distance deltas from BLE rather than using raw values, survives reconnects
- **First-connection catch-up**: When app reconnects, if treadmill distance > stored daily distance, it catches up and estimates missed calories
- **ACSM calorie calculation**: Uses personalised Mifflin-St Jeor BMR for resting VO2 instead of standard 3.5 ml/kg/min constant
- **30-minute inactivity reset**: Session data resets after 30 min idle, daily totals are preserved
- **Backward-compatible Codable**: `WalkPadStore.init(from:)` uses `try?` for each field so new fields don't break existing data files
- **No Xcode project**: Single `build.sh` script compiles all files — keeps repo minimal

## Data Persistence

JSON file at `~/.walkingpad/data.json` stores daily records (distance, calories, celebrated flag), session state, user profile, and onboarding flag. Saves every 5 seconds during activity. Prunes entries older than 60 days.

## Common Tasks

- **Add a new setting**: Add field to `UserProfile` struct, add row in `SettingsView` and `OnboardingView`, handle in `WalkPadStore.init(from:)` for backward compat
- **Change speed presets**: Edit `SpeedPresetsView` in Views.swift
- **Modify calorie formula**: Edit `caloriesPerMinute(atSpeedKmh:)` in BLEManager.swift
- **Change menu bar display**: Edit `updateMenuBar()` / `menuBarDailyProgress()` in App.swift
