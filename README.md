# WalkingPad

A lightweight macOS menu bar app for controlling WalkingPad and KingSmith treadmills over Bluetooth (BLE). No app store, no account, no cloud. Just a simple native app that talks directly to your treadmill.

Made by [James Potter](https://x.com/jamespotter).

<img src="screenshot.png" alt="Screenshot" width="360">

## Features

- **Menu bar app** — lives in your menu bar with live progress, doesn't clutter your dock
- **BLE/FTMS control** — start, stop, pause, and set speed directly from your Mac
- **Daily goal tracking** — configurable distance goal with progress bar and time-remaining estimate
- **Accurate calorie calculation** — uses ACSM metabolic equations personalised to your body stats, not the treadmill's built-in number
- **7-day history** — bar chart with streak tracking
- **Persistent data** — stats survive app restarts (stored in `~/.walkingpad/data.json`)
- **First-run setup** — prompts for your profile on first launch
- **Configurable** — daily goal, default start speed, and body metrics via the gear icon

## Compatible Treadmills

The app uses the **Bluetooth FTMS standard** (Fitness Machine Service, UUID `0x1826`), so it should work with any treadmill that advertises this service. Tested with:

- **KingSmith / WalkingPad** Z1D

Likely compatible (same FTMS protocol): WalkingPad P1, C1, C2, A1 Pro, R1 Pro, R2, X21, and other KingSmith models. Non-KingSmith treadmills that support FTMS should also work — the app discovers by service UUID, not device name.

KingSmith vendor-specific features (step count via proprietary `FFC0`/`FFF0` BLE services) are supported as a bonus but not required.

**Tested with a different treadmill?** Please open an issue or PR to update the list.

## Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon Mac (arm64)
- Xcode Command Line Tools (for `swiftc`)

## Install

```bash
# Install Xcode Command Line Tools if you haven't already
xcode-select --install

# Clone and build
git clone <repo-url>
cd macos-walkingpad/WalkingPad
./build.sh
open build/WalkingPad.app
```

On first launch, macOS will prompt for Bluetooth permission — grant it.

The app appears as a 🚶 icon in your menu bar. Click it to open the control panel. On first run you'll be asked to set up your profile (weight, height, age, gender, daily goal, start speed).

### Auto-start on login

1. Open **System Settings > General > Login Items**
2. Click **+** and navigate to the built `WalkingPad.app`

Or copy it to `/Applications` first.

## Configuration

All settings are accessible via the gear icon in the top-right corner:

| Setting | Default | Description |
|---------|---------|-------------|
| Weight | 70 kg | Body weight for calorie calculation |
| Height | 170 cm | Height for calorie calculation |
| Age | 30 | Age for calorie calculation |
| Gender | Male | Gender for calorie calculation |
| Daily goal | 5.0 km | Target walking distance per day |
| Start speed | 2.5 km/h | Belt speed when you press Start |

Data is persisted to `~/.walkingpad/data.json` and survives app restarts. Sessions reset after 30 minutes of inactivity.

## How Calories Are Calculated

The app ignores the treadmill's calorie readout and uses **ACSM metabolic equations** personalised with Mifflin-St Jeor BMR:

1. **BMR** = 10 x weight + 6.25 x height - 5 x age (+5 male / -161 female)
2. **Resting VO2** derived from personal BMR (not the standard 3.5 ml/kg/min)
3. **Exercise VO2**: `0.1 x speed(m/min)` for walking (<=6 km/h), `0.2 x speed(m/min)` for running
4. **kcal/min** = (exerciseVO2 + restingVO2) x weight / 1000 x 5.0, accumulated in real-time

## CLI Tool

A standalone Python script is included for command-line control (requires [bleak](https://github.com/hbldh/bleak)):

```bash
pip install bleak

# Find your treadmill
python walkingpad.py scan

# Get current status
python walkingpad.py status <address>

# Start at 2.5 km/h
python walkingpad.py start <address> 2.5

# Change speed / stop / pause
python walkingpad.py speed <address> 3.0
python walkingpad.py stop <address>
python walkingpad.py pause <address>
```

## License

MIT — see [LICENSE](LICENSE).
