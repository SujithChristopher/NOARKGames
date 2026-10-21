"""The tracker's end of the app link: protocol state over one transport.

The transport (UDPStreamer / BLEStreamer) only moves messages. This adds what
docs/PROTOCOL.md asks of the tracker, the same over both:

* each app command (HELLO, SESSION, STOP, CONFIG, TRUNK) is handed to the
  tracker once and acknowledged with its result; a retry of the last one gets
  the same ACK again without being applied twice;
* a message bigger than the transport takes goes out as CHUNKs, paced;
* a TRACKER_HEARTBEAT when nothing else was sent for a while, so the app can
  tell a live tracker that sees no marker from a dead one; it carries the
  tracker's state (idle, cameras starting, tracking), sent at once on a change;
* `silent_for()`, how long since the app was last heard.
"""

import threading
import time

import protocol

HEARTBEAT_S = 0.5
# BlueZ drops a notification whose value is replaced before it went out; a burst
# of chunks back to back would lose most of them.
CHUNK_GAP_S = 0.015


class Link:
    def __init__(self, transport) -> None:
        self.transport = transport
        self.connected = False        # a HELLO arrived and the app has not gone quiet
        self.last_heard = 0.0
        self._last_sent = 0.0
        self._last_ack = None         # (seq, ack message) of the last command handled
        self._chunk_id = 0
        self.state = protocol.STATE_IDLE

    def poll(self, handler) -> None:
        """Handle everything that arrived. `handler(kind, body) -> (ok, detail)`
        applies one command; its result goes back as the ACK."""
        while True:
            msg = self.transport.receive()
            if not msg:
                return
            self.last_heard = time.time()
            kind, payload = protocol.decode(msg)
            if kind == protocol.HEARTBEAT:
                continue
            if kind not in protocol.RELIABLE:
                print(f"[LINK] Unknown message type 0x{kind:02x}, ignored", flush=True)
                continue
            try:
                seq, body = protocol.split_seq(payload)
            except ValueError:
                print(f"[LINK] Malformed message 0x{kind:02x}, ignored", flush=True)
                continue
            if kind != protocol.HELLO and self._last_ack and self._last_ack[0] == seq:
                self.send(self._last_ack[1])   # our ACK was lost; the app retried
                continue
            if kind == protocol.HELLO:
                ok, detail = self._hello(body)
                if ok:
                    ok, more = handler(kind, body)
                    detail = more or detail
            elif not self.connected:
                # Talking without a HELLO: an app from before a tracker restart.
                # Refusing makes it start over with HELLO.
                ok, detail = False, "no HELLO"
            else:
                ok, detail = handler(kind, body)
            ack = protocol.encode_ack(seq, ok, detail)
            self._last_ack = (seq, ack)
            self.send(ack)

    def _hello(self, body: bytes):
        version = body[0] if body else 0
        if version != protocol.VERSION:
            print(f"[LINK] App speaks protocol v{version}, this tracker v{protocol.VERSION}", flush=True)
            return False, f"tracker speaks protocol v{protocol.VERSION}"
        if not self.connected:
            print("[LINK] App connected", flush=True)
        self.connected = True
        return True, f"v{protocol.VERSION}"

    def send(self, message: bytes) -> None:
        if len(message) <= self.transport.max_message:
            self.transport.send(message)
            self._last_sent = time.time()
            return
        self._chunk_id = (self._chunk_id + 1) & 0xFF
        parts = protocol.chunk(message, self._chunk_id, self.transport.max_message)

        def paced():
            for p in parts:
                self.transport.send(p)
                self._last_sent = time.time()
                time.sleep(CHUNK_GAP_S)
        threading.Thread(target=paced, name="link-chunks", daemon=True).start()

    def tick(self) -> None:
        """Once a frame: keep the app's liveness check fed."""
        if self.connected and time.time() - self._last_sent >= HEARTBEAT_S:
            self._heartbeat()

    def set_state(self, state: int) -> None:
        """The tracker's state for the app's status line; a change goes out now."""
        if state != self.state:
            self.state = state
            if self.connected:
                self._heartbeat()

    def _heartbeat(self) -> None:
        self.send(protocol.encode(protocol.TRACKER_HEARTBEAT, bytes([self.state])))

    def silent_for(self) -> float:
        return time.time() - self.last_heard

    def reset(self) -> None:
        """The app is gone: forget it, and wait for the next HELLO."""
        self.connected = False
        self._last_ack = None
        self.transport.reset()
