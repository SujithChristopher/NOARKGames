"""BLE central test receiver for NOARK position data — simplepyble version.

Mirrors what Godot/GDBLE does: scans for NOARK_Tracker, connects, subscribes
to position notifications, and prints decoded packets.

Run this on the PC to verify BLE communication from the RPi before involving
Godot/Rust at all.

Usage
-----
    pip install simplepyble
    python pyscripts/test_ble_receiver.py
"""

import sys
import time

import simplepyble
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


def on_notification(data: bytes) -> None:
    global packet_count
    kind, payload = protocol.decode(bytes(data))
    if kind != protocol.POSITION:
        print(f"[RX] message 0x{kind:02x}: {payload[:60]!r}")
        return
    _, (x, y, z), _, _ = protocol.decode_position(bytes(data))
    label = "POSITION"
    packet_count += 1
    print(f"[RX #{packet_count:04d}] {label:<8}  x={x:+.4f}  y={y:+.4f}  z={z:+.4f}")


def main() -> None:
    # ── adapter check ─────────────────────────────────────────────────────────
    adapters = simplepyble.Adapter.get_adapters()
    if not adapters:
        print("[BLE] No Bluetooth adapters found.")
        print("      • Make sure Bluetooth is enabled in Windows Settings")
        print("      • If no built-in BT, plug in a USB Bluetooth dongle")
        sys.exit(1)

    adapter = adapters[0]
    print(f"[BLE] Adapter: {adapter.identifier()}  addr={adapter.address()}")

    # Power on if the adapter supports it and reports itself off
    try:
        if not adapter.is_powered():
            print("[BLE] Adapter is off — powering on…")
            adapter.power_on()
            time.sleep(1.5)
    except Exception:
        pass  # some adapters don't expose power state; continue anyway

    # ── scan ──────────────────────────────────────────────────────────────────
    print(f"[BLE] Scanning 10 s for '{DEVICE_NAME}'…")
    adapter.scan_for(10_000)

    peripherals = adapter.scan_get_results()
    print(f"[BLE] Scan complete — {len(peripherals)} device(s) found:")

    target = None
    for p in peripherals:
        name = p.identifier()
        addr = p.address()
        rssi = p.rssi() if hasattr(p, "rssi") else "?"
        print(f"  rssi={rssi:>4}  addr={addr}  name={name!r}")
        if name == DEVICE_NAME:
            target = p

    if target is None:
        print(f"\n[BLE] '{DEVICE_NAME}' not in scan results.")
        if not peripherals:
            print("      No devices found at all — check Bluetooth adapter and RPi proximity.")
        else:
            print("      Check RPi is running ble_streamer.py and device name matches exactly.")
        sys.exit(1)

    # ── connect ───────────────────────────────────────────────────────────────
    print(f"\n[BLE] Connecting to {target.identifier()} @ {target.address()}…")
    target.connect()
    print(f"[BLE] Connected: {target.is_connected()}")

    # Dump GATT map — useful for UUID mismatch debugging
    print("[BLE] GATT map:")
    for svc in target.services():
        marker = "  ← NOARK service" if svc.uuid().lower() == SERVICE_UUID.lower() else ""
        print(f"  service  {svc.uuid()}{marker}")
        for ch in svc.characteristics():
            print(f"    char   {ch.uuid()}  caps={ch.capabilities()}")

    # ── subscribe ─────────────────────────────────────────────────────────────
    target.notify(SERVICE_UUID, POSITION_UUID, on_notification)
    print("\n[BLE] Subscribed to position notifications — streaming (Ctrl+C to stop)\n")

    target.write_command(SERVICE_UUID, COMMAND_UUID, HELLO)

    try:
        while target.is_connected():
            time.sleep(1.0)   # the tracker gives up after 3 s of silence
            target.write_command(SERVICE_UUID, COMMAND_UUID, HEARTBEAT)
    except KeyboardInterrupt:
        pass

    # ── cleanup ───────────────────────────────────────────────────────────────
    try:
        target.unsubscribe(SERVICE_UUID, POSITION_UUID)
        target.write_command(SERVICE_UUID, COMMAND_UUID, STOP)
    except Exception:
        pass

    target.disconnect()
    print(f"\n[BLE] Disconnected — {packet_count} packet(s) received total")


if __name__ == "__main__":
    main()
