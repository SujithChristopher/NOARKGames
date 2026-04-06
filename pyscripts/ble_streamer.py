"""BLE GATT peripheral streamer for NOARK position data.

Python acts as GATT server (peripheral); Godot uses GDBLE as client (central).

UUIDs
-----
Service   : 4e4f4152-4b00-0000-0000-000000000000
Position  : 4e4f4152-4b01-0000-0000-000000000000  (read + notify, Python → Godot)
Command   : 4e4f4152-4b02-0000-0000-000000000000  (write,         Godot → Python)

Wire format: 11 × float32 little-endian (44 bytes)
  [msg_code, cx, cy, cz, rvx, rvy, rvz, tx, ty, tz, ref_id]
  msg_code: 2.0 = START, -99.0 = STOP, 5.0 = RESET
"""

import asyncio
import struct
import threading
from typing import Any, Optional

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


class BLEStreamer:
    """Thread-safe BLE GATT peripheral that mirrors the UDP interface."""

    def __init__(self, device_name: str = "NOARK_Tracker") -> None:
        self.device_name = device_name
        self._server: Optional[BlessServer] = None
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._thread: Optional[threading.Thread] = None
        self._ready = threading.Event()
        self._latest_command: bytes = b""
        self._cmd_lock = threading.Lock()
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
        if not self._running or self._server is None:
            return
        if not self._streaming:
            self._streaming = True
            print("[BLE] Streaming position data")
        data = bytearray(struct.pack("f" * len(data), *data))
        char = self._server.get_characteristic(POSITION_CHAR_UUID)
        if char is None:
            return
        char.value = data
        try:
            future = asyncio.run_coroutine_threadsafe(
                self._server.update_value(SERVICE_UUID, POSITION_CHAR_UUID),
                self._loop,
            )
            future.result(timeout=0.05)
        except Exception:
            pass

    def get_command(self) -> bytes:
        """Return and clear the last command written by Godot, or b'' if none."""
        with self._cmd_lock:
            cmd = self._latest_command
            self._latest_command = b""
        return cmd

    def reset(self) -> None:
        """Clear connection state so the server keeps advertising for a new central."""
        self._connected = False
        self._streaming = False
        with self._cmd_lock:
            self._latest_command = b""
        print("[BLE] Waiting for reconnect — advertising continues")

    def stop(self) -> None:
        """Gracefully stop advertising and the asyncio loop."""
        if self._connected:
            print("[BLE] Central disconnected")
        self._running = False
        self._connected = False
        self._streaming = False
        if self._loop and self._server:
            try:
                asyncio.run_coroutine_threadsafe(self._server.stop(), self._loop)
            except Exception:
                pass

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

        await self._server.start()
        # Give BlueZ time to register the GATT application before accepting connections
        await asyncio.sleep(2.0)
        self._running = True
        self._ready.set()
        print(f"[BLE] Advertising as '{self.device_name}'")
        print(f"[BLE] Service UUID : {SERVICE_UUID}")
        print(f"[BLE] Position char: {POSITION_CHAR_UUID}")
        print(f"[BLE] Command char : {COMMAND_CHAR_UUID}")
        print("[BLE] Peripheral ready — waiting for central to connect")

        while self._running:
            await asyncio.sleep(0.1)

        await self._server.stop()

    def _on_read(self, characteristic: BlessGATTCharacteristic, **_: Any) -> bytearray:
        return characteristic.value or bytearray(_IDLE_PACKET)

    def _on_write(self, characteristic: BlessGATTCharacteristic, value: Any, **_: Any) -> None:
        if characteristic.uuid.lower() == COMMAND_CHAR_UUID.lower():
            with self._cmd_lock:
                self._latest_command = bytes(value)
            if not self._connected:
                self._connected = True
                print("[BLE] Central connected")
