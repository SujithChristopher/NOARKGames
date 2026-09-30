"""UDP streamer for NOARK position data.

Python acts as UDP server; Godot acts as client (sends commands, receives position).

Wire format: 11 × float32 little-endian (44 bytes)
  [msg_code, cx, cy, cz, rvx, rvy, rvz, tx, ty, tz, ref_id]
  msg_code: 2.0 = START, -99.0 = STOP, 5.0 = RESET
"""

import socket
import struct
from typing import Optional


class UDPStreamer:
    """Synchronous UDP socket wrapper that mirrors the BLEStreamer interface."""

    def __init__(self, ip: str = "localhost", port: int = 8000) -> None:
        self.ip = ip
        self.port = port
        self._socket: Optional[socket.socket] = None
        self._addr: Optional[tuple] = None

    def start(self) -> None:
        """Bind the UDP socket and set it non-blocking."""
        self._socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._socket.bind((self.ip, self.port))
        self._socket.setblocking(False)
        print("UDP socket bound to", self._socket.getsockname())

    def send(self, data: list) -> None:
        """Send an 11-float position packet to the last known Godot address."""
        if self._socket is None or self._addr is None:
            return
        self._socket.sendto(struct.pack("f" * len(data), *data), self._addr)

    def send_raw(self, payload: bytes) -> None:
        """Send a non-position datagram (e.g. a CFG ack); Godot tells it by size."""
        if self._socket is None or self._addr is None:
            return
        self._socket.sendto(payload, self._addr)

    def get_command(self) -> bytes:
        """Return the latest command from Godot, or b'' if none."""
        if self._socket is None:
            return b""
        try:
            data, self._addr = self._socket.recvfrom(30)
            return data
        except socket.error:
            return b""

    def stop(self) -> None:
        """Close the UDP socket."""
        if self._socket:
            self._socket.close()
            self._socket = None
