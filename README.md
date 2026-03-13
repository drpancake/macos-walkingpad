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

## Supported Treadmills

| Model | Protocol | Status |
|-------|----------|--------|
| KingSmith R2 Pro (WLT6200) | Proprietary (FE00/FE01/FE02) | Tested |
| WalkingPad / KingSmith (FTMS) | BLE FTMS (0x1826) | Untested (original code) |

The app auto-detects which protocol to use based on the device name and available BLE services.

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

The app appears as a walking icon in your menu bar. Click it to open the control panel. On first run you'll be asked to set up your profile (weight, height, age, gender, daily goal, start speed).

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

## Architecture

The app uses a protocol-based architecture for multi-model treadmill support:

```
BLEManager (coordinator)
  ├── TreadmillProtocol (Swift protocol)
  │     ├── WLT6200Protocol.swift  — KingSmith R2 Pro proprietary
  │     └── FTMSProtocol.swift     — BLE FTMS standard (generic)
  └── Shared: persistence, calories, goals, streaks, UI state
```

**BLEManager** handles BLE scanning, connection lifecycle, and shared state (persistence, calorie calculation, daily tracking, goal/streak). It delegates all protocol-specific work to the active `TreadmillProtocol` implementation.

**Auto-detection**: After connecting to a device and discovering all BLE services, BLEManager tries each registered protocol. Name-matched protocols are tried first, then remaining ones. The first `configure()` returning `true` wins.

## Adding a New Model

Adding support for a new treadmill is a 3-step process:

### 1. Create `YourModelProtocol.swift`

Use [`WLT6200Protocol.swift`](WalkingPad/Sources/WalkingPad/WLT6200Protocol.swift) as the reference implementation. Add your protocol documentation as top-of-file comments.

```swift
class YourModelProtocol: TreadmillProtocol {
    static let namePatterns = ["your-device-name"]  // lowercase BLE name substrings
    var modelName: String { "Your Model" }
    var speedRange: SpeedRange { SpeedRange(min: 0.5, max: 8.0, increment: 0.1) }

    func configure(peripheral: CBPeripheral, services: [CBService]) -> Bool {
        // Find your service UUID, grab write/notify characteristics
        // Subscribe to notifications, return true if this device is yours
    }

    func start(speed: Double) { /* send start commands */ }
    func stop()               { /* send stop commands */ }
    func pause()              { /* send pause commands */ }
    func setSpeed(_ kmh: Double) { /* send speed command */ }

    func handleNotification(characteristic: CBCharacteristic, data: Data) -> TreadmillStatus? {
        // Parse incoming data, return TreadmillStatus with belt state, speed, distance, time, steps
    }

    func handleReadValue(characteristic: CBCharacteristic, data: Data) -> ReadResult? {
        // Parse read responses (speed range, features, etc.) or return nil
    }

    func tick() { /* called every 1s — send keepalive/query if needed */ }
    func reset() { /* clean up on disconnect */ }
}
```

### 2. Register in `BLEManager.swift`

Add your protocol to the `protocolTypes` array. FTMS should stay last as the generic fallback:

```swift
private let protocolTypes: [ProtocolEntry] = [
    ProtocolEntry(namePatterns: WLT6200Protocol.namePatterns, factory: { WLT6200Protocol() }),
    ProtocolEntry(namePatterns: YourModelProtocol.namePatterns, factory: { YourModelProtocol() }),
    ProtocolEntry(namePatterns: FTMSProtocol.namePatterns, factory: { FTMSProtocol() }),  // last
]
```

### 3. Build and test

```bash
cd WalkingPad && ./build.sh && open build/WalkingPad.app
```

The build uses a glob (`Sources/WalkingPad/*.swift`) so new files are picked up automatically.

## License

MIT — see [LICENSE](LICENSE).
