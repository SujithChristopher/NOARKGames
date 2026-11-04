"""The Camera tab's path end to end: a client against a running tracker, on the
board's real cameras. What the fakes in test_camera_view.py cannot show: that a
change reaches the sensor, that the image follows, and that it stops afterwards.

Exposure and gain are put back at the end; nothing is saved (only the app writes
settings.json). Run it with the app closed: the tracker talks to one app.

    uv run pyscripts/tests/test_camera_live.py [--port 8000]
"""
import argparse
import json
import socket
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cv2
import numpy as np

import protocol

CAMERA_START_S = 15.0
CHANGE_S = 2.0   # a status every 0.5 s, the image follows in a few frames
CAMERAS_OFF_S = 23.0   # camera_idle_off_s (20 s) after track=off


class Client:
    def __init__(self, port: int) -> None:
        self.addr = ("127.0.0.1", port)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(0.05)
        self.seq = 0
        self.last_beat = 0.0
        self.parts = {}
        self.state = None
        self.acks = {}
        self.statuses = []
        self.previews = []

    def _on_message(self, msg: bytes) -> None:
        kind = msg[0]
        if kind == protocol.CHUNK:
            msg_id, index, total = msg[1], msg[2], msg[3]
            if index == 0 or msg_id not in self.parts:
                self.parts[msg_id] = {}
            self.parts[msg_id][index] = msg[4:]
            if len(self.parts[msg_id]) == total:
                parts = self.parts.pop(msg_id)
                self._on_message(b"".join(parts[i] for i in range(total)))
        elif kind == protocol.ACK:
            seq, ok, detail = protocol.decode_ack(msg)
            self.acks[seq] = (ok, detail)
        elif kind == protocol.TRACKER_HEARTBEAT:
            self.state = msg[1]
        elif kind == protocol.CAMERA_STATUS:
            self.statuses.append(json.loads(msg[1:]))
        elif kind == protocol.PREVIEW:
            self.previews.append(msg[1:])

    def pump(self, seconds: float) -> None:
        end = time.time() + seconds
        while time.time() < end:
            if time.time() - self.last_beat >= 0.5:
                self.last_beat = time.time()
                self.sock.sendto(protocol.encode(protocol.HEARTBEAT), self.addr)
            try:
                self._on_message(self.sock.recvfrom(4096)[0])
            except TimeoutError:
                pass

    def command(self, kind: int, body: bytes | str = b"") -> tuple[bool, str]:
        self.seq += 1
        seq = self.seq
        self.sock.sendto(protocol.encode_reliable(kind, seq, body), self.addr)
        end = time.time() + 3.0
        while seq not in self.acks:
            assert time.time() < end, f"no ACK for {kind:#x} {body!r}"
            self.pump(0.02)
        return self.acks[seq]

    def config(self, text: str) -> tuple[bool, str]:
        return self.command(protocol.CONFIG, text)

    def need(self, text: str) -> None:
        ok, detail = self.config(text)
        assert ok, f"{text} was refused: {detail}"

    def settled(self) -> dict:
        """A status from after a change has had time to land."""
        self.pump(CHANGE_S)
        self.statuses.clear()
        self.pump(0.7)
        assert self.statuses, "no CAMERA_STATUS for 0.7 s"
        return self.statuses[-1]

    def wait_tracking(self) -> None:
        end = time.time() + CAMERA_START_S
        while self.state != protocol.STATE_TRACKING:
            assert time.time() < end, f"cameras not tracking; state {self.state}"
            self.pump(0.1)


def near(value: float, want: float, within: float = 0.02) -> bool:
    return abs(value - want) <= within * want


def run(client: Client) -> None:
    ok, detail = client.command(protocol.HELLO, bytes([protocol.VERSION]))
    assert ok, f"HELLO refused: {detail}"
    client.need("preview=on")
    client.need("track=position")
    client.wait_tracking()

    first = client.settled()
    print(f"  as it was     {first}")
    original_exposure, original_gain = first["ask"]
    try:
        client.need("gain=1")
        client.need("exposure=10000")
        high = client.settled()
        assert near(high["exposure"][0], 10000) and near(high["exposure"][1], 10000), high
        assert high["gain"] == [1.0, 1.0], high
        print(f"  10000 us x1   level {high['level']}, tags {high['tags']}, {high['fps']} fps")

        client.need("exposure=2000")
        low = client.settled()
        assert near(low["exposure"][0], 2000) and near(low["exposure"][1], 2000), low
        assert low["level"][0] < 0.7 * high["level"][0], (low["level"], high["level"])
        assert low["level"][1] < 0.7 * high["level"][1], (low["level"], high["level"])
        print(f"  2000 us x1    level {low['level']}")

        client.need("gain=4")
        bright = client.settled()
        assert bright["gain"] == [4.0, 4.0], bright
        assert bright["level"][0] > 1.2 * low["level"][0], (bright["level"], low["level"])
        print(f"  2000 us x4    level {bright['level']}")

        client.need("exposure=25000")
        capped = client.settled()
        assert capped["ask"][0] == 25000, capped
        assert capped["exposure"][0] < 17000, capped
        print(f"  asked 25000   sensor took {capped['exposure']}")

        for bad in ("exposure=0", "exposure=inf", "gain=99", "gain=0"):
            ok, detail = client.config(bad)
            assert not ok, f"{bad} was accepted"
            print(f"  {bad:<13} refused: {detail}")

        client.pump(1.0)
        assert client.previews, "no PREVIEW"
        picture = cv2.imdecode(np.frombuffer(client.previews[-1], np.uint8), cv2.IMREAD_COLOR)
        assert picture is not None and picture.shape == (200, 640, 3), "bad preview"
        print(f"  preview       {picture.shape[1]}x{picture.shape[0]}, "
              f"{len(client.previews[-1])} B")

        # A window of whole seconds, away from the start: 5 pictures a second.
        client.previews.clear()
        client.statuses.clear()
        client.pump(4.0)
        rate = len(client.previews) / 4.0
        assert 3.5 <= rate <= 5.5, f"{rate} pictures a second"
        assert 6 <= len(client.statuses) <= 9, f"{len(client.statuses)} statuses in 4 s"
        print(f"  rates         {rate} pictures/s, {len(client.statuses) / 4.0} statuses/s")
    finally:
        client.config(f"exposure={int(original_exposure)}")
        # device.toml may say 0, which the sensor reads as 1 and CONFIG refuses.
        client.config(f"gain={max(original_gain, 1)}")

    client.need("preview=off")
    client.pump(0.3)
    client.statuses.clear()
    client.previews.clear()
    client.pump(1.5)
    assert not client.statuses and not client.previews, "still sending with preview off"
    print("  preview off   nothing sent")

    client.need("track=off")
    change_while_the_cameras_start(client, int(original_exposure))
    client.need("track=off")
    client.command(protocol.STOP)


def change_while_the_cameras_start(client: Client, original_exposure: int) -> None:
    """The cameras are built with the values of the moment they were asked for.
    A change after that, while they come up, must still reach them."""
    client.pump(CAMERAS_OFF_S)
    client.need("preview=on")
    client.need("track=position")
    client.pump(0.5)
    assert client.state != protocol.STATE_TRACKING, "cameras were still up; cannot test this"
    want = 3000 if original_exposure != 3000 else 4000
    client.need(f"exposure={want}")
    client.statuses.clear()
    client.wait_tracking()
    client.pump(1.5)
    assert client.statuses, "no CAMERA_STATUS"
    status = client.statuses[-1]
    print(f"  set starting  asked {want}, sensor took {status['exposure']}")
    assert near(status["exposure"][0], want) and near(status["exposure"][1], want), status
    client.config(f"exposure={original_exposure}")
    client.need("preview=off")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8000)
    run(Client(parser.parse_args().port))
    print("\nOK")
