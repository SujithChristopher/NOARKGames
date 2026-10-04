"""BLE GATT peripheral streamer for NOARK position data.

Python acts as GATT server (peripheral); Godot uses GDBLE as client (central).

UUIDs
-----
Service   : 4e4f4152-4b00-0000-0000-000000000000
Position  : 4e4f4152-4b01-0000-0000-000000000000  (read + notify, Python → Godot;
            also the text CFG:/TRK: packets, exactly as over UDP)
Command   : 4e4f4152-4b02-0000-0000-000000000000  (write,         Godot → Python)

Wire format: 11 × float32 little-endian (44 bytes)
  [msg_code, cx, cy, cz, rvx, rvy, rvz, tx, ty, tz, ref_id]
  msg_code: 2.0 = START, -99.0 = STOP, 5.0 = RESET

Advertising
-----------
BlueZ advertises for us where it can. On the Radxa's AIC8800 it cannot: the
kernel rejects the advertising data (MGMT Add Extended Advertising Data →
Invalid Parameters, even for a bare 3-byte flags field, on 7.0.11-qcom), while
the controller itself accepts it. So when BlueZ's advertising fails,
RawAdvertiser drives the controller directly with `sudo -n hcitool` — the GATT
service is still BlueZ's, only the advertisement bypasses the kernel. That
needs /etc/sudoers.d/noark-ble (radxa may run /usr/bin/hcitool, nothing else).
"""

import asyncio
import struct
import subprocess
import threading
import uuid
from collections import deque
from typing import Any, Optional

from dbus_next.errors import DBusError
from bless import (
    BlessGATTCharacteristic,
    BlessServer,
    GATTAttributePermissions,
    GATTCharacteristicProperties,
)

SERVICE_UUID      = "4e4f4152-4b00-0000-0000-000000000000"
POSITION_CHAR_UUID = "4e4f4152-4b01-0000-0000-000000000000"
COMMAND_CHAR_UUID  = "4e4f4152-4b02-0000-0000-000000000000"

_IDLE_PACKET = bytearray(struct.pack("f" * 11, *([0.0] * 11)))

# Seconds between re-enabling the raw advertisement while nobody is subscribed:
# a connection ends the advertising set, so this is what makes a reconnect work.
_READVERTISE_S = 2.0


class RawAdvertiser:
    """Legacy connectable advertising on one extended-advertising set, by HCI.

    Advert: flags + complete local name. Scan response: the 128-bit service
    UUID (both together exceed a legacy advert's 31 bytes). Handle 5 keeps
    clear of the sets BlueZ allocates from 1.
    """

    HANDLE = 0x05

    def __init__(self, name: str, service_uuid: str) -> None:
        name_b = name.encode()[:29]
        self._adv = bytes([2, 0x01, 0x06, len(name_b) + 1, 0x09]) + name_b
        self._scan = bytes([17, 0x07]) + uuid.UUID(service_uuid).bytes[::-1]

    @staticmethod
    def _hci(ocf: int, payload: bytes) -> int:
        """Send one LE command; return its status byte (raises if hcitool fails)."""
        r = subprocess.run(
            ["sudo", "-n", "hcitool", "-i", "hci0", "cmd", "0x08", f"0x{ocf:04x}",
             *(f"{b:02x}" for b in payload)],
            capture_output=True, text=True, timeout=3,
        )
        if r.returncode != 0:
            raise RuntimeError((r.stderr or r.stdout).strip() or f"hcitool exit {r.returncode}")
        # Command Complete, last line: "  <ncmd> <ocf lo> <ocf hi> <status> ..."
        return int(r.stdout.strip().splitlines()[-1].split()[3], 16)

    def start(self) -> None:
        h = self.HANDLE
        # The set may still be on from a previous run (the controller outlives
        # us), and its parameters can't change while it is: Command Disallowed.
        self.enable(False)
        steps = [
            # Set Extended Advertising Parameters: legacy ADV_IND (connectable,
            # scannable), 100 ms, all channels, public address, 1M PHY.
            (0x0036, bytes([h, 0x13, 0x00, 0xA0, 0, 0, 0xA0, 0, 0, 0x07, 0, 0,
                            0, 0, 0, 0, 0, 0, 0, 0x7F, 0x01, 0, 0x01, 0, 0])),
            (0x0037, bytes([h, 0x03, 0x01, len(self._adv)]) + self._adv),
            (0x0038, bytes([h, 0x03, 0x01, len(self._scan)]) + self._scan),
        ]
        for ocf, payload in steps:
            status = self._hci(ocf, payload)
            if status:
                raise RuntimeError(f"HCI 0x{ocf:04x} status 0x{status:02x}")
        self.enable()

    def enable(self, on: bool = True) -> None:
        self._hci(0x0039, bytes([1 if on else 0, 1, self.HANDLE, 0, 0, 0]))


class BLEStreamer:
    """Thread-safe BLE GATT peripheral that mirrors the UDP interface."""

    def __init__(self, device_name: str = "NOARK_Tracker") -> None:
        self.device_name = device_name
        self._server: Optional[BlessServer] = None
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._thread: Optional[threading.Thread] = None
        self._ready = threading.Event()
        # Every write, in order: the tracker drains CFG:/TRUNK: alongside the
        # heartbeat, and a single slot let the next heartbeat overwrite them.
        self._commands: deque[bytes] = deque(maxlen=64)
        self._running = False
        self._connected = False
        self._streaming = False

    # ── public API (called from camera thread) ────────────────────────────────

    def start(self) -> None:
        """Start the BLE GATT server; blocks until advertising begins (≤10 s)."""
        self._thread = threading.Thread(target=self._run_loop, daemon=True)
        self._thread.start()
        if not self._ready.wait(timeout=10):
            raise RuntimeError("BLE server did not start within 10 seconds")

    def send(self, data: list) -> None:
        """Notify connected central with an 11-float position packet."""
        if not self._streaming and self._running:
            self._streaming = True
            print("[BLE] Streaming position data")
        self.send_raw(struct.pack("f" * len(data), *data))

    def send_raw(self, payload: bytes) -> None:
        """Notify any other packet on the position characteristic, as UDP sends
        it as a datagram: Godot tells the text ones (CFG:, TRK:) from the
        44-byte position packet by size and prefix, the same as over UDP."""
        if not self._running or self._loop is None:
            return
        # Value and notification are set together on the loop's thread: dbus
        # isn't thread-safe, and setting the value here could let the next
        # packet overwrite it before this one went out.
        self._loop.call_soon_threadsafe(self._notify, bytearray(payload))

    def get_command(self) -> bytes:
        """Return the oldest command written by Godot, or b'' if none."""
        try:
            return self._commands.popleft()
        except IndexError:
            return b""

    def reset(self) -> None:
        """Clear connection state so the server keeps advertising for a new central."""
        self._connected = False
        self._streaming = False
        self._commands.clear()
        print("[BLE] Waiting for reconnect — advertising continues")

    def stop(self) -> None:
        """Gracefully stop advertising and the asyncio loop."""
        if self._connected:
            print("[BLE] Central disconnected")
        self._running = False
        self._connected = False
        self._streaming = False
        # _serve() sees _running drop, stops advertising and unregisters.
        if self._thread:
            self._thread.join(timeout=3)

    # ── asyncio server ────────────────────────────────────────────────────────

    def _run_loop(self) -> None:
        self._loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self._loop)
        self._loop.run_until_complete(self._serve())

    async def _serve(self) -> None:
        self._server = BlessServer(name=self.device_name, loop=self._loop)
        self._server.read_request_func  = self._on_read
        self._server.write_request_func = self._on_write

        await self._server.add_new_service(SERVICE_UUID)

        # Position: Godot reads + subscribes to notifications
        await self._server.add_new_characteristic(
            SERVICE_UUID,
            POSITION_CHAR_UUID,
            GATTCharacteristicProperties.read | GATTCharacteristicProperties.notify,
            _IDLE_PACKET,
            GATTAttributePermissions.readable,
        )

        # Command: Godot writes commands ("STOP", "USER:xxx", "RESET", …)
        await self._server.add_new_characteristic(
            SERVICE_UUID,
            COMMAND_CHAR_UUID,
            (
                GATTCharacteristicProperties.write
                | GATTCharacteristicProperties.write_without_response
            ),
            None,
            GATTAttributePermissions.writeable,
        )

        raw: Optional[RawAdvertiser] = None
        try:
            await self._server.start()
        except DBusError as exc:
            # The GATT application registered; only the advertisement failed.
            print(f"[BLE] BlueZ advertising failed ({exc}); advertising by raw HCI")
            raw = RawAdvertiser(self.device_name, SERVICE_UUID)
            try:
                await asyncio.to_thread(raw.start)
            except Exception as hci_exc:
                print(f"[BLE] Raw HCI advertising failed too: {hci_exc}")
                await self._server.app.unregister(self._server.adapter)
                return
        # Give BlueZ time to register the GATT application before accepting connections
        await asyncio.sleep(2.0)
        self._running = True
        self._ready.set()
        print(f"[BLE] Advertising as '{self.device_name}'")
        print(f"[BLE] Service UUID : {SERVICE_UUID}")
        print(f"[BLE] Position char: {POSITION_CHAR_UUID}")
        print(f"[BLE] Command char : {COMMAND_CHAR_UUID}")
        print("[BLE] Peripheral ready — waiting for central to connect")

        last_adv = asyncio.get_running_loop().time()
        while self._running:
            await asyncio.sleep(0.1)
            now = asyncio.get_running_loop().time()
            if raw and now - last_adv >= _READVERTISE_S:
                last_adv = now
                if not await self._server.is_connected():
                    try:
                        await asyncio.to_thread(raw.enable)
                    except Exception as exc:
                        print(f"[BLE] Re-advertise failed: {exc}")

        try:
            if raw:
                await asyncio.to_thread(raw.enable, False)
                await self._server.app.unregister(self._server.adapter)
            else:
                await self._server.stop()
        except Exception as exc:
            print(f"[BLE] Shutdown: {exc}")

    def _notify(self, value: bytearray) -> None:
        char = self._server.get_characteristic(POSITION_CHAR_UUID) if self._server else None
        if char is None:
            return
        char.value = value
        try:
            self._server.update_value(SERVICE_UUID, POSITION_CHAR_UUID)
        except Exception as exc:
            print(f"[BLE] Notify failed: {exc}")

    def _on_read(self, characteristic: BlessGATTCharacteristic, **_: Any) -> bytearray:
        return characteristic.value or bytearray(_IDLE_PACKET)

    def _on_write(self, characteristic: BlessGATTCharacteristic, value: Any, **_: Any) -> None:
        if characteristic.uuid.lower() == COMMAND_CHAR_UUID.lower():
            self._commands.append(bytes(value))
            if not self._connected:
                self._connected = True
                print("[BLE] Central connected")
