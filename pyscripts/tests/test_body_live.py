"""Settings > Calibration's path end to end: a client against a running tracker, on the
board's real cameras. What test_body_take.py cannot show: that a take runs on real
frames beside the link, the picture and the tracking loop, and leaves nothing behind.

Saves nothing: every take is cancelled, or refused for want of tag 1. With the device
out of view it checks the refusal, with it in view the solve starting and being
cancelled. Run it with the app closed: the tracker talks to one app.

    uv run pyscripts/tests/test_body_live.py [--port 8000]
"""
import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import protocol
from test_camera_live import Client

TAKE_S = 6.0
LINK_SILENCE_S = 3.5   # the tracker ends a session after 3 s without a heartbeat


class BodyClient(Client):
    def __init__(self, port: int) -> None:
        super().__init__(port)
        self.bodies = []

    def _on_message(self, msg: bytes) -> None:
        if msg[0] == protocol.BODY_STATUS:
            self.bodies.append(json.loads(msg[1:]))
        else:
            super()._on_message(msg)

    def body(self, text: str) -> tuple[bool, str]:
        return self.command(protocol.BODY, text)

    def where(self) -> dict:
        """The tracker's state, asked for now."""
        self.bodies.clear()
        ok, detail = self.body("status")
        assert ok, detail
        self.pump(0.3)
        assert self.bodies, "no BODY_STATUS after asking"
        return self.bodies[-1]


def run(client: BodyClient) -> None:
    ok, detail = client.command(protocol.HELLO, bytes([protocol.VERSION]))
    assert ok, f"HELLO refused: {detail}"

    status = client.where()
    assert status["state"] == "idle", status
    print(f"  in use        {status['current']}")
    assert not client.body("save")[0], "nothing to save yet"
    assert not client.body("finish")[0], "nothing to finish yet"

    client.need("preview=on")
    client.need("track=position")
    client.wait_tracking()

    # A take on real frames.
    assert client.body("start")[0]
    client.bodies.clear()
    client.statuses.clear()
    client.previews.clear()
    client.pump(TAKE_S)
    capture = client.bodies[-1]["capture"]
    assert 1.5 * TAKE_S <= len(client.bodies) <= 2.5 * TAKE_S, f"{len(client.bodies)} statuses in {TAKE_S} s"
    assert capture["left"] is not None and capture["left"] < 60 - TAKE_S + 1, capture
    assert 8 * TAKE_S <= capture["frames"] <= 11 * TAKE_S, f"kept {capture['frames']} pairs in {TAKE_S} s"
    assert capture["level"] is not None, capture
    assert client.previews, "the picture should go on during a take"
    fps = client.statuses[-1]["fps"]
    print(f"  take          {capture['frames']} pairs in {TAKE_S:.0f} s, level {capture['level']}, "
          f"{fps} fps, tags {[(t['id'], t['seen']) for t in capture['tags']]}")
    assert not client.body("start")[0], "already capturing"

    assert client.body("finish")[0]
    client.pump(0.6)
    status = client.bodies[-1]
    tag_1_seen = any(t["id"] == status["anchor"] and t["seen"] for t in capture["tags"])
    if tag_1_seen:
        assert status["state"] == "solving", status
        assert client.body("cancel")[0]
        print("  finish        solve started, then cancelled")
    else:
        assert status["state"] == "failed" and f"Tag {status['anchor']}" in status["reason"], status
        print(f"  finish        {status['reason']}")
    assert client.where()["state"] in ("idle", "failed")
    client.body("cancel")
    assert client.where()["state"] == "idle"

    # The app goes away mid-take: the take ends, the tracker waits for the next app.
    assert client.body("start")[0]
    client.pump(1.0)
    time.sleep(LINK_SILENCE_S)
    ok, detail = client.command(protocol.HELLO, bytes([protocol.VERSION]))
    assert ok, f"HELLO refused: {detail}"
    assert client.where()["state"] == "idle", "losing the app should end a take"
    print("  app gone      take ended")

    client.need("preview=off")
    client.need("track=off")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    run(BodyClient(args.port))
    print("OK")
