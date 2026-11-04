"""The Camera tab's pictures over the board's hotspot (docs/PROTOCOL.md).

Open only while the hotspot is up, and bound to its address, so the tracker has
no port on any other network. The tablet says PICTURE_HELLO about once a second
to get pictures; quiet for SILENCE_S and it gets none, so nothing is encoded for
nobody. One way and best effort: a lost picture is replaced 0.2 s later.
"""

import socket

import protocol

MAX_DATAGRAM = 1400


class PictureLink:
    PORT = 8010
    SILENCE_S = 3.0

    def __init__(self, ip: str, port: int = PORT) -> None:
        self.ip = ip
        self.port = port
        self.reason = ""
        self._socket = None
        self._client = None
        self._heard = 0.0
        self._chunk_id = 0

    def open(self) -> bool:
        """False, with `reason`, if it cannot bind (the hotspot went away)."""
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setblocking(False)
            sock.bind((self.ip, self.port))
        except OSError as exc:
            self.reason = str(exc)
            return False
        self._socket = sock
        self.port = sock.getsockname()[1]
        return True

    def close(self) -> None:
        if self._socket is not None:
            self._socket.close()
        self._socket = None
        self._client = None

    def poll(self, now: float) -> None:
        """Take in any hellos. Once a frame."""
        while self._socket is not None:
            try:
                data, sender = self._socket.recvfrom(64)
            except OSError:
                return
            if data == bytes([protocol.PICTURE_HELLO]):
                self._client = sender
                self._heard = now

    def has_client(self, now: float) -> bool:
        return self._client is not None and now - self._heard <= self.SILENCE_S

    def send(self, message: bytes) -> None:
        if self._socket is None or self._client is None:
            return
        parts = [message]
        if len(message) > MAX_DATAGRAM:
            self._chunk_id = (self._chunk_id + 1) & 0xFF
            parts = protocol.chunk(message, self._chunk_id, MAX_DATAGRAM)
        for part in parts:
            try:
                self._socket.sendto(part, self._client)
            except OSError:
                return   # the tablet has gone; its silence ends this
