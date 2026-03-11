#!/usr/bin/env python3
"""WalkingPad/KingSmith treadmill controller using Bluetooth FTMS (Fitness Machine Service)."""

import asyncio
import struct
import sys
from bleak import BleakScanner, BleakClient

# FTMS UUIDs
TREADMILL_DATA     = "00002acd-0000-1000-8000-00805f9b34fb"
MACHINE_STATUS     = "00002ada-0000-1000-8000-00805f9b34fb"
CONTROL_POINT      = "00002ad9-0000-1000-8000-00805f9b34fb"
SPEED_RANGE        = "00002ad4-0000-1000-8000-00805f9b34fb"
TRAINING_STATUS    = "00002ad3-0000-1000-8000-00805f9b34fb"

# FTMS Control Point opcodes
OP_REQUEST_CONTROL = 0x00
OP_RESET           = 0x01
OP_SET_TARGET_SPEED = 0x02
OP_START_RESUME    = 0x07
OP_STOP_PAUSE      = 0x08

DEFAULT_ADDRESS = "YOUR_DEVICE_ADDRESS"  # Use 'scan' command to find this


def parse_treadmill_data(data):
    """Parse FTMS Treadmill Data characteristic."""
    if len(data) < 4:
        return {}
    flags = struct.unpack_from("<H", data, 0)[0]
    offset = 2
    result = {}

    # Instantaneous Speed is present if bit 0 of flags is 0
    if not (flags & 0x0001):
        speed = struct.unpack_from("<H", data, offset)[0]
        result["speed_kmh"] = speed / 100.0
        offset += 2

    # Average Speed present if bit 1 is set
    if flags & 0x0002:
        avg_speed = struct.unpack_from("<H", data, offset)[0]
        result["avg_speed_kmh"] = avg_speed / 100.0
        offset += 2

    # Total Distance present if bit 2 is set
    if flags & 0x0004:
        dist = struct.unpack_from("<I", data[offset:offset+4].ljust(4, b'\x00'), 0)[0] & 0xFFFFFF
        result["distance_m"] = dist
        offset += 3

    # Inclination + Ramp Angle if bit 3
    if flags & 0x0008:
        offset += 4

    # Elevation Gain if bit 4
    if flags & 0x0010:
        offset += 4

    # Instantaneous Pace if bit 5
    if flags & 0x0020:
        offset += 1

    # Average Pace if bit 6
    if flags & 0x0040:
        offset += 1

    # Expended Energy if bit 7
    if flags & 0x0080:
        if offset + 4 <= len(data):
            total_energy = struct.unpack_from("<H", data, offset)[0]
            result["calories"] = total_energy
        offset += 5

    # Heart Rate if bit 8
    if flags & 0x0100:
        offset += 1

    # Metabolic Equivalent if bit 9
    if flags & 0x0200:
        offset += 1

    # Elapsed Time if bit 10
    if flags & 0x0400:
        if offset + 2 <= len(data):
            elapsed = struct.unpack_from("<H", data, offset)[0]
            result["elapsed_s"] = elapsed
        offset += 2

    # Remaining Time if bit 11
    if flags & 0x0800:
        offset += 2

    return result


status_data = {}


def on_treadmill_data(sender, data):
    global status_data
    parsed = parse_treadmill_data(data)
    if parsed:
        status_data.update(parsed)


def on_machine_status(sender, data):
    opcodes = {0x02: "Stopped by safety", 0x03: "Stopped by user", 0x04: "Started/Resumed",
               0x05: "Target speed changed", 0x07: "Control permission lost"}
    if data:
        msg = opcodes.get(data[0], f"Status: 0x{data[0]:02x}")
        print(f"  [{msg}]")


async def scan():
    print("Scanning for BLE devices (10s)...")
    devices = await BleakScanner.discover(timeout=10)
    found = []
    for d in devices:
        name = d.name or ""
        if any(k in name.lower() for k in ["walkingpad", "kingsmith", "ks-"]):
            found.append(d)
            print(f"  FOUND: {d.name} [{d.address}]")
    if not found:
        print("\nNo WalkingPad found. All nearby named BLE devices:")
        for d in sorted(devices, key=lambda x: x.name or ""):
            if d.name:
                print(f"  {d.name} [{d.address}]")
    return found


async def write_control(client, opcode, params=b""):
    """Write to FTMS control point."""
    await client.write_gatt_char(CONTROL_POINT, bytes([opcode]) + params)


async def connect_and_run(address, command, speed_kmh=None):
    global status_data
    status_data = {}

    async with BleakClient(address) as client:
        print(f"Connected to {address}")

        if command == "status":
            await client.start_notify(TREADMILL_DATA, on_treadmill_data)
            await asyncio.sleep(2)
            await client.stop_notify(TREADMILL_DATA)
            if status_data:
                print(f"Speed:    {status_data.get('speed_kmh', 0):.1f} km/h")
                print(f"Distance: {status_data.get('distance_m', 0)} m")
                print(f"Time:     {status_data.get('elapsed_s', 0)}s")
                print(f"Calories: {status_data.get('calories', 0)} kcal")
            else:
                print("No treadmill data received. Belt may be in standby.")

            # Also read speed range
            try:
                sr = await client.read_gatt_char(SPEED_RANGE)
                if len(sr) >= 6:
                    min_spd, max_spd, inc = struct.unpack_from("<HHH", sr, 0)
                    print(f"Speed range: {min_spd/100:.1f} - {max_spd/100:.1f} km/h (increment: {inc/100:.1f})")
            except Exception:
                pass

        elif command == "start":
            await client.start_notify(MACHINE_STATUS, on_machine_status)
            print("Requesting control...")
            await write_control(client, OP_REQUEST_CONTROL)
            await asyncio.sleep(0.3)

            if speed_kmh is not None:
                speed_raw = int(speed_kmh * 100)
                print(f"Setting target speed to {speed_kmh:.1f} km/h...")
                await write_control(client, OP_SET_TARGET_SPEED, struct.pack("<H", speed_raw))
                await asyncio.sleep(0.3)

            print("Starting belt...")
            await write_control(client, OP_START_RESUME)
            await asyncio.sleep(1)
            print("Done!")

        elif command == "speed":
            if speed_kmh is None:
                print("Error: provide speed in km/h (e.g. 3.0)")
                return
            await client.start_notify(MACHINE_STATUS, on_machine_status)
            print("Requesting control...")
            await write_control(client, OP_REQUEST_CONTROL)
            await asyncio.sleep(0.3)
            speed_raw = int(speed_kmh * 100)
            print(f"Setting speed to {speed_kmh:.1f} km/h...")
            await write_control(client, OP_SET_TARGET_SPEED, struct.pack("<H", speed_raw))
            await asyncio.sleep(1)
            print("Done!")

        elif command == "stop":
            await client.start_notify(MACHINE_STATUS, on_machine_status)
            print("Requesting control...")
            await write_control(client, OP_REQUEST_CONTROL)
            await asyncio.sleep(0.3)
            print("Stopping belt...")
            await write_control(client, OP_STOP_PAUSE, bytes([0x01]))
            await asyncio.sleep(1)
            print("Done!")

        elif command == "pause":
            await client.start_notify(MACHINE_STATUS, on_machine_status)
            print("Requesting control...")
            await write_control(client, OP_REQUEST_CONTROL)
            await asyncio.sleep(0.3)
            print("Pausing belt...")
            await write_control(client, OP_STOP_PAUSE, bytes([0x02]))
            await asyncio.sleep(1)
            print("Done!")


def usage():
    print("WalkingPad Controller")
    print()
    print("Usage: python walkingpad.py <command> [address] [args]")
    print()
    print("Commands:")
    print(f"  scan                       Scan for WalkingPad devices")
    print(f"  status  [address]          Get current speed/distance/time")
    print(f"  start   [address] [speed]  Start belt (speed in km/h, e.g. 3.0)")
    print(f"  speed   [address] <speed>  Change speed (km/h)")
    print(f"  stop    [address]          Stop belt")
    print(f"  pause   [address]          Pause belt")
    print()
    print(f"Default address: {DEFAULT_ADDRESS}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        usage()
        sys.exit(1)

    command = sys.argv[1]

    if command == "scan":
        asyncio.run(scan())
    elif command in ("status", "start", "stop", "pause", "speed"):
        # Check if second arg looks like an address or a speed
        address = DEFAULT_ADDRESS
        speed = None
        args = sys.argv[2:]

        if args and (len(args[0]) > 10 or "-" in args[0]):
            address = args.pop(0)
        if args:
            try:
                speed = float(args[0])
            except ValueError:
                pass
        asyncio.run(connect_and_run(address, command, speed))
    else:
        usage()
