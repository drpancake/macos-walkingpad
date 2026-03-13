# WLT6200 BLE Protocol (KingSmith R2 Pro)

Reverse-engineered from live testing with Mitch's treadmill, March 2026.

## Device Identity

- **BLE Advertised Name**: `WLT6200` (NOT "walkingpad", "ks-", or "kingsmith")
- **Manufacturer**: Wi-linktech (read from 0x2A29)
- **Model**: WLT6200 (read from 0x2A24)
- **Hardware Rev**: 1.0
- **Software Rev**: 100.00.01

## BLE Services & Characteristics

| Service | Characteristic | Properties | Purpose |
|---------|---------------|------------|---------|
| `FE00` | `FE01` | notify, read | Status notifications (treadmill → app) |
| `FE00` | `FE02` | write-without-response | Commands (app → treadmill) |
| `FF00` | `FF01` | write | Unknown / unused in our testing |
| `180A` | various | read | Device info (manufacturer, model, etc.) |

- **FE02** is the only command channel that works. Always use `write-without-response`.
- **FE01** sends notifications after every command. Subscribe on connect.
- **FF01** accepts writes but produces no observable effect.

## Command Packet Format

```
[0xF7] [0xA2] [subcmd] [param] [checksum] [0xFD]
```

- **6 bytes total**, always
- **Checksum**: `(0xA2 + subcmd + param) & 0xFF` (modular sum, NOT XOR)
- **Min spacing**: ~0.7 seconds between commands (the ph4-walkingpad library uses 0.69s)

## Commands

| Action | subcmd | param | Notes |
|--------|--------|-------|-------|
| Query status | `0x00` | `0x00` | Returns current state via FE01 notification |
| Set speed | `0x01` | speed×10 | e.g., 25 = 2.5 km/h, 40 = 4.0 km/h |
| Set mode | `0x02` | mode | 0=auto, 1=manual, 2=standby |
| Start belt | `0x04` | `0x01` | Initiates 3-second countdown, then belt runs |

### Example Packets

```
Query:    f7 a2 00 00 a2 fd
Start:    f7 a2 04 01 a7 fd
Speed 2.5: f7 a2 01 19 bc fd
Speed 4.0: f7 a2 01 28 cb fd
Manual:   f7 a2 02 01 a5 fd
Standby:  f7 a2 02 02 a6 fd
Speed 0:  f7 a2 01 00 a3 fd
```

## Start Sequence (MUST follow this order)

1. **Set manual mode**: `subcmd=0x02, param=0x01`
2. **Wait 0.7s**
3. **Send start**: `subcmd=0x04, param=0x01`
4. **Wait ~5s** for countdown (state goes 9→8→7→6→1)
5. **Set speed**: `subcmd=0x01, param=speed*10`
6. **Poll status** every ~1s with query command to keep connection alive

**Critical**: Do NOT send start command while belt is already running — it restarts the countdown.

## Stop Sequence

1. **Set speed to 0**: `subcmd=0x01, param=0x00`
2. **Wait 2s** for belt to decelerate
3. **Set standby mode**: `subcmd=0x02, param=0x02`

## Status Notification Format (FE01)

Notifications are **20 bytes**, triggered by every command sent:

```
[0xF8] [0xA2] [state] [speed] [mode] [time_h] [time_m] [time_l] [dist_h] [dist_m] [dist_l] [step_h] [step_m] [step_l] [app_speed] [?] [ctrl_btn] [?] [checksum] [0xFD]
```

| Byte | Field | Values |
|------|-------|--------|
| 0 | Header | Always `0xF8` |
| 1 | Command byte | Always `0xA2` |
| 2 | Belt state | See state table below |
| 3 | Actual speed | Raw value, divide by 10 for km/h |
| 4 | Mode | 0=auto, 1=manual, 2=standby |
| 5-7 | Elapsed time | 3-byte big-endian, seconds |
| 8-10 | Distance | 3-byte big-endian (units TBD, likely decimeters) |
| 11-13 | Steps | 3-byte big-endian |
| 14 | App speed | Last speed set by app (raw, /10 for km/h) |
| 15 | Unknown | Always 0 in testing |
| 16 | Controller button | 0 in testing |
| 17 | Unknown | Always 0 in testing |
| 18 | Checksum | Sum of bytes[1..17] & 0xFF |
| 19 | Footer | Always `0xFD` |

### Belt State Values (byte[2])

| Value | Meaning |
|-------|---------|
| 0 | Stopped / idle |
| 1 | Running |
| 4 | Standby (after mode set to standby) |
| 6-9 | Countdown (9=start, counts down to 6, then jumps to 1=running) |

The countdown is approximately: 9 → 8 → 7 → 6 → 1 (running), taking ~4 seconds total.

## Important Behaviors

### Weight Sensor / Safety Auto-Stop
The treadmill has a **weight/presence sensor**. If no one is standing on the belt, it will auto-stop after ~5-6 seconds of running. This is a hardware safety feature, not a protocol issue. The belt starts, runs briefly, then state drops from 1→0 and speed ramps down.

**Symptom**: Belt starts (countdown completes, state=1, speed ramps up) but stops after 5-6 seconds even with active BLE connection and polling.

**Solution**: Someone must be standing on the treadmill.

### Connection Keepalive
The treadmill does NOT auto-stop when BLE connection is maintained and someone is on the belt. Simple query polling (every 1s) is sufficient — no need to resend speed commands.

If the BLE connection drops, the treadmill stops immediately (safety feature).

### Auto Mode vs Manual Mode
- **Auto mode (0)**: Start command is IGNORED. Belt does not start. Do not use.
- **Manual mode (1)**: Required for BLE control. All commands work.
- **Standby mode (2)**: Belt is idle. Default state on power-up.

### Speed Behavior
- Speed changes take effect immediately (within ~1 second)
- Actual speed (byte[3]) ramps to match target — not instant
- Speed range observed: 2.0-4.0 km/h tested, likely 0.5-6.0 km/h supported
- Setting speed to 0 while running causes the belt to decelerate and stop

### Repeated Start Commands
Sending `subcmd=0x04` while the belt is already running (state=1) **restarts the countdown**. Only send start once, then use speed commands to control.

## Scanning / Discovery

- Scan with `nil` services (device may not advertise FE00 in scan response)
- Match by name: `WLT6200` (case-insensitive)
- After connection, discover all services, then:
  - Subscribe to `FE01` notifications
  - Use `FE02` for write-without-response commands
