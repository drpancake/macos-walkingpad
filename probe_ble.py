#!/usr/bin/env python3
"""Probe all BLE characteristics on a WalkingPad/KingSmith treadmill."""
import asyncio, struct
from bleak import BleakClient

ADDRESS = "YOUR_DEVICE_ADDRESS"  # Use walkingpad.py scan to find this

def hexdump(data):
    return " ".join(f"{b:02x}" for b in data)

async def main():
    async with BleakClient(ADDRESS) as client:
        print("Connected!\n")

        # Read all readable characteristics
        print("=== READABLE CHARACTERISTICS ===")
        for service in client.services:
            for char in service.characteristics:
                if "read" in char.properties:
                    try:
                        val = await client.read_gatt_char(char.uuid)
                        text = val.decode("utf-8", errors="replace")
                        print(f"  {char.description or char.uuid}: {hexdump(val)}  |  {text}")
                    except Exception as e:
                        print(f"  {char.description or char.uuid}: ERROR {e}")

        # Subscribe to ALL notify characteristics
        print("\n=== NOTIFY CHARACTERISTICS (listening 5s) ===")
        received = {}

        def make_handler(uuid, desc):
            def handler(sender, data):
                key = desc or uuid
                if key not in received:
                    received[key] = []
                received[key].append(data)
                print(f"  [{desc or uuid}] {hexdump(data)}")
            return handler

        for service in client.services:
            for char in service.characteristics:
                if "notify" in char.properties:
                    try:
                        await client.start_notify(char.uuid, make_handler(char.uuid, char.description))
                        print(f"  Subscribed: {char.description or char.uuid}")
                    except Exception as e:
                        print(f"  Failed: {char.description or char.uuid} - {e}")

        await asyncio.sleep(5)

        # Also try writing the Kingsmith status query to vendor chars
        print("\n=== TRYING VENDOR COMMANDS ===")
        # ph4-walkingpad uses: f7 a2 01 (ask stats) on the write char
        vendor_write_chars = [
            "0000ffc2-0000-1000-8000-00805f9b34fb",
            "0000fff2-0000-1000-8000-00805f9b34fb",
        ]
        for wc in vendor_write_chars:
            try:
                # Ask stats command from ph4-walkingpad protocol
                cmd = bytes([0xf7, 0xa2, 0x01, 0xa2 ^ 0x01, 0xfd])
                await client.write_gatt_char(wc, cmd)
                print(f"  Wrote to {wc}: {hexdump(cmd)}")
                await asyncio.sleep(1)
            except Exception as e:
                print(f"  Write to {wc} failed: {e}")

        # Read training status
        try:
            ts = await client.read_gatt_char("00002ad3-0000-1000-8000-00805f9b34fb")
            print(f"\n  Training Status: {hexdump(ts)}")
        except Exception as e:
            print(f"\n  Training Status: {e}")

        # Read machine features
        try:
            mf = await client.read_gatt_char("00002acc-0000-1000-8000-00805f9b34fb")
            print(f"  Machine Features: {hexdump(mf)}")
            if len(mf) >= 4:
                features = struct.unpack_from("<I", mf, 0)[0]
                feat_names = [
                    "Avg Speed", "Cadence", "Total Distance", "Inclination",
                    "Elevation Gain", "Pace", "Step Count", "Resistance Level",
                    "Stair Count", "Expended Energy", "Heart Rate", "Metabolic Equivalent",
                    "Elapsed Time", "Remaining Time", "Power Measurement", "Force on Belt",
                    "User Data Retention"
                ]
                print("  Supported features:")
                for i, name in enumerate(feat_names):
                    if features & (1 << i):
                        print(f"    - {name}")
        except Exception as e:
            print(f"  Machine Features: {e}")

        print("\nDone!")

asyncio.run(main())
