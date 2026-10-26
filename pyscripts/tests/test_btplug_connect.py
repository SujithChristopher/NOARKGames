import asyncio
import sys

from bleak import BleakScanner, BleakClient
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import protocol  # noqa: E402

HEARTBEAT = protocol.encode(protocol.HEARTBEAT)
# The tracker streams only to an app that said HELLO; STOP ends its session.
HELLO = protocol.encode_reliable(protocol.HELLO, 1, bytes([protocol.VERSION]))
STOP = protocol.encode_reliable(protocol.STOP, 2)

DEVICE_NAME   = "NOARK_Tracker"
SERVICE_UUID  = "4e4f4152-4b00-0000-0000-000000000000"
POSITION_UUID = "4e4f4152-4b01-0000-0000-000000000000"
COMMAND_UUID  = "4e4f4152-4b02-0000-0000-000000000000"

packet_count = 0

def notification_handler(sender, data: bytearray):
    global packet_count
    kind, payload = protocol.decode(bytes(data))
    if kind != protocol.POSITION:
        print(f"[RX] message 0x{kind:02x}: {payload[:60]!r}")
        return
    x, y, z = protocol.decode_vec3(bytes(data))
    label = "POSITION"
    packet_count += 1
    print(f"[RX #{packet_count:04d}] {label:<8}  x={x:+.4f}  y={y:+.4f}  z={z:+.4f}")

async def main():
    print(f"[BLE] Scanning for '{DEVICE_NAME}'...")
    
    # Scan for 10 seconds
    devices = await BleakScanner.discover(timeout=10.0)
    print(f"[BLE] Scan complete — {len(devices)} device(s) found:")
    
    target_device = None
    for d in devices:
        name = d.name or ""
        # Bleak BLEDevice might not expose rssi directly depending on version, 
        # but we mainly care about the name.
        print(f"  addr={d.address}  name={name!r}")
        if name == DEVICE_NAME:
            target_device = d
            
    if not target_device:
        print(f"\n[BLE] '{DEVICE_NAME}' not in scan results.")
        if not devices:
            print("      No devices found at all — check Bluetooth adapter and RPi proximity.")
        else:
            print("      Check RPi is running ble_streamer.py and device name matches exactly.")
        sys.exit(1)

    print(f"\n[BLE] Connecting to {target_device.name} @ {target_device.address}...")
    
    async with BleakClient(target_device) as client:
        print(f"[BLE] Connected: {client.is_connected}")
        
        # Dump GATT
        print("[BLE] GATT map:")
        for service in client.services:
            marker = "  <- NOARK service" if service.uuid.lower() == SERVICE_UUID.lower() else ""
            print(f"  service  {service.uuid}{marker}")
            for char in service.characteristics:
                print(f"    char   {char.uuid}  caps={char.properties}")

        # Subscribe
        await client.start_notify(POSITION_UUID, notification_handler)
        print("\n[BLE] Subscribed to position notifications — streaming (Ctrl+C to stop)\n")

        # HELLO so the tracker starts streaming
        try:
            await client.write_gatt_char(COMMAND_UUID, HELLO, response=False)
        except Exception as e:
            print(f"[BLE] Write without response failed or not supported by char: {e}")
            # Try with response if false fails
            try:
                await client.write_gatt_char(COMMAND_UUID, HELLO, response=True)
            except Exception as e:
                pass

        try:
            while client.is_connected:
                await asyncio.sleep(1.0)   # the tracker gives up after 3 s of silence
                try:
                    await client.write_gatt_char(COMMAND_UUID, HEARTBEAT, response=False)
                except:
                    pass
        except asyncio.CancelledError:
            pass
            
        # Cleanup
        try:
            await client.stop_notify(POSITION_UUID)
            await client.write_gatt_char(COMMAND_UUID, STOP, response=False)
        except Exception as e:
            print(f"Error during cleanup: {e}")
            
    print(f"\n[BLE] Disconnected — {packet_count} packet(s) received total")

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[BLE] Stopped by user")
