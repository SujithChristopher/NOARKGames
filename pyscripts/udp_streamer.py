"""UDP transport between the tracker and Godot (docs/PROTOCOL.md).

The tracker binds; Godot sends first, and the tracker answers whoever sent it
the last message. One datagram is one protocol message — this class only moves
bytes; protocol.py says what they mean and link.py keeps the link.
"""

import socket
from typing import Optional

RECEIVE_BUFFER = 2048


class UDPStreamer:
    """Synchronous UDP socket; BLEStreamer (ble_streamer.py) has the same interface."""

    # Larger messages go out as CHUNKs (link.py). Under the 1500-byte Ethernet
    # MTU, though loopback would take more, so a remote app works too.
    max_message = 1400

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
        try:
            self._socket.sendto(message, self._addr)
        except OSError:
            pass   # the app has gone; the link's liveness check notices

    def receive(self) -> bytes:
        """The next message from Godot, or b'' if none."""
        if self._socket is None:
            return b""
        try:
            data, self._addr = self._socket.recvfrom(RECEIVE_BUFFER)
            return data
        except OSError:
            return b""

    def reset(self) -> None:
        """Forget the app's address until it speaks again."""
        self._addr = None

    def stop(self) -> None:
        """Close the UDP socket."""
        if self._socket:
            self._socket.close()
            self._socket = None
