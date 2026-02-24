#!/usr/bin/env python3
"""Discover BLE services and characteristics on the WalkingPad."""

import asyncio
from bleak import BleakClient

ADDRESS = "B77D8D0E-3780-81A2-F193-5A68232DFDD1"

async def discover():
    async with BleakClient(ADDRESS) as client:
        print(f"Connected: {client.is_connected}")
        for service in client.services:
            print(f"\nService: {service.uuid} - {service.description}")
            for char in service.characteristics:
                props = ", ".join(char.properties)
                print(f"  Char: {char.uuid} [{props}] - {char.description}")

asyncio.run(discover())
