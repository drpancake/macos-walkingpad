#!/usr/bin/env python3
"""Discover BLE services and characteristics on the WalkingPad."""

import asyncio
from bleak import BleakClient

ADDRESS = "YOUR_DEVICE_ADDRESS"  # Use walkingpad.py scan to find this

async def discover():
    async with BleakClient(ADDRESS) as client:
        print(f"Connected: {client.is_connected}")
        for service in client.services:
            print(f"\nService: {service.uuid} - {service.description}")
            for char in service.characteristics:
                props = ", ".join(char.properties)
                print(f"  Char: {char.uuid} [{props}] - {char.description}")

asyncio.run(discover())
