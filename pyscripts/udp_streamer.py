"""UDP transport between the tracker and Godot (docs/PROTOCOL.md).

The tracker binds; Godot connects and sends first, and the tracker answers
whoever sent it the last message. One datagram is one protocol message — this
class only moves bytes, protocol.py says what they mean.
"""

import socket
from typing import Optional

# Godot's messages are small (a patient id, a CFG line); this only bounds them.
MAX_MESSAGE = 1024


class UDPStreamer:
    """Synchronous UDP socket; BLEStreamer (ble_streamer.py) has the same interface."""

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

    def send(self, message: bytes) -> None:
        """One message to the last known Godot address (none yet: dropped)."""
        if self._socket is None or self._addr is None:
            return
        self._socket.sendto(message, self._addr)

    def receive(self) -> bytes:
        """The next message from Godot, or b'' if none."""
        if self._socket is None:
            return b""
        try:
            data, self._addr = self._socket.recvfrom(MAX_MESSAGE)
            return data
        except socket.error:
            return b""

    def stop(self) -> None:
        """Close the UDP socket."""
        if self._socket:
            self._socket.close()
            self._socket = None
