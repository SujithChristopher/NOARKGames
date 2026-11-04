"""Measuring the device's tags from the app (body_take.py, body_solve.py): takes with
a known answer, drawn through the real lenses, through the real solve. No cameras.

What a real take adds that these cannot show is the detector's own error, so an
accuracy here is the best case. Needs the board's venv (rapidtag). About 3 minutes.

    uv run pyscripts/tests/test_body_take.py
"""
import json
import shutil
import sys
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cv2
import numpy as np
import toml
from scipy.spatial.transform import Rotation

import protocol
from body_take import BodyTake
from rigid_body import RigidBody, load_cameras, stereo_extrinsic, tag_corners

CALIBRATION = Path(__file__).resolve().parents[1] / "calibration"
STEREO = CALIBRATION / "sterio_calibration.toml"
TAG_SIZE = 0.05
TIP = [0.0, 0.01, -0.069]
PAIRS = 240
SOLVE_LIMIT_S = 180.0

DEVICE_TOML = """# The device.
[device]
name = "test rig"
# Only comment that must survive.
tag_ids = [1, 2, 3, 4, 5]
tag_size_m = 0.05
reference_id = 1

[tip]
tag = 1
offset_m = [0.0, 0.01, -0.069]

[cameras]
stream0 = "cam0"
stream1 = "cam1"
isp = "pisp"
"""


def tag(euler, mm) -> tuple:
    return (Rotation.from_euler("xyz", euler, degrees=True).as_matrix(), np.array(mm, float) / 1000.0)


# The shape of the real bracket: tag 1 in front, two on the sides, two on the far end.
BODY = {
    1: tag([0, 0, 0], [0, 0, 0]),
    2: tag([0, -60, 0], [-49, 0, -29]),
    3: tag([0, 60, 0], [49, 0, -29]),
    4: tag([-154, -88, 154], [-52, 0, -187]),
    5: tag([-143, 88, -143], [52, 0, -187]),
}
ROOM_TAG = (Rotation.from_euler("xyz", [170, 10, 5], degrees=True).as_matrix(), np.array([0.15, -0.12, 0.55]))
ROOM_ID = 9


def frames(body: dict, pairs=PAIRS, still=False, room_tag=False):
    """(tags in camera 0, tags in camera 1) per pair, for `body` turned in front of the
    real lenses: what the tracker would hand over, with detector-like noise."""
    cameras, size = load_cameras(STEREO)
    R_st, T_st = stereo_extrinsic(STEREO)
    T_st = T_st.reshape(3)
    rng = np.random.default_rng(11)
    square = tag_corners(TAG_SIZE)
    centre = np.mean([t for _, t in body.values()], axis=0)
    out = []
    for frame in range(pairs):
        phase = 2 * np.pi * frame / pairs
        if still:
            euler = np.array([180.0, 0.0, 0.0]) + rng.normal(0, 0.2, 3)
        else:
            euler = np.array([180 + 45 * np.sin(3 * phase), 50 * np.sin(5 * phase + 1), 30 * np.sin(2 * phase)])
        R = Rotation.from_euler("xyz", euler, degrees=True).as_matrix()
        where = np.array([0.08 * np.sin(2 * phase), 0.05 * np.cos(3 * phase), 0.45 + 0.05 * np.sin(phase)])
        t = where - R @ centre
        pair = []
        for index, name in enumerate(("cam0", "cam1")):
            K, D = cameras[name]
            Rc, tc = (R, t) if index == 0 else (R_st @ R, R_st @ t + T_st)
            poses = [(mid, Rc @ r, Rc @ p + tc) for mid, (r, p) in body.items()]
            if room_tag:
                r, p = ROOM_TAG
                poses.append((ROOM_ID, r, p) if index == 0 else (ROOM_ID, R_st @ r, R_st @ p + T_st))
            found = {}
            for mid, r, p in poses:
                if p[2] <= 0.05 or r[:, 2] @ -(p / np.linalg.norm(p)) < np.cos(np.radians(70)):
                    continue   # turned away: the detector would not read it
                pixels, _ = cv2.fisheye.projectPoints(
                    square.reshape(-1, 1, 3), cv2.Rodrigues(r)[0], p.reshape(3, 1), K, D)
                pixels = pixels.reshape(4, 2)
                if pixels.min() < 2 or pixels[:, 0].max() > size[0] - 2 or pixels[:, 1].max() > size[1] - 2:
                    continue
                found[mid] = pixels + rng.normal(0, 0.25, (4, 2))
            pair.append(found)
        out.append(pair)
    return out


class Bench:
    """A BodyTake on a temporary rig, with the clock in the test's hands."""

    def __init__(self, previous=BODY, take_s=PAIRS * 0.1, **options) -> None:
        self.dir = Path(tempfile.mkdtemp(prefix="body_take_"))
        self.rig = self.dir / "rigidbody.toml"
        self.device = self.dir / "device.toml"
        self.device.write_text(DEVICE_TOML)
        self._write_rig(previous)
        self.changes = 0
        self.now = 1000.0
        self.image = np.full((80, 128), 100, np.uint8)
        self.take = BodyTake(self.rig, self.device, STEREO, on_change=self._changed,
                             takes_dir=self.dir / "takes", take_s=take_s, **options)

    def _changed(self) -> None:
        self.changes += 1

    def _write_rig(self, body) -> None:
        self.rig.write_text(toml.dumps({
            "meta": {"reference_id": 1, "tag_size_m": TAG_SIZE, "tip_in_reference_m": TIP,
                     "marker_ids": sorted(body), "created": "2026-01-01T10:00:00",
                     "agreement_median_mm": 1.5},
            "markers": {str(m): {"rotation_marker_to_reference": r.tolist(),
                                 "translation_marker_to_reference_m": t.tolist()}
                        for m, (r, t) in body.items()},
        }))

    def command(self, text: str):
        return self.take.command(text, self.now)

    def status(self) -> dict:
        self.take.command("status", self.now)
        kind, payload = protocol.decode(self.take.poll(self.now))
        assert kind == protocol.BODY_STATUS, f"unexpected message {kind:#x}"
        return json.loads(payload)

    def feed(self, pairs) -> None:
        for det0, det1 in pairs:
            self.take.frame(self.now, det0, det1, True, self.image)
            self.now += 0.1
            self.take.poll(self.now)

    def solved(self) -> dict:
        """Waits for the real solve; the status once it is done."""
        started = time.time()
        while self.take.state == "solving":
            assert time.time() - started < SOLVE_LIMIT_S, "the solve took too long"
            time.sleep(0.2)
            self.now += 0.2
            self.take.poll(self.now)
        return self.status()

    def done(self) -> None:
        self.take.close()
        shutil.rmtree(self.dir, ignore_errors=True)


def rows(status: dict) -> dict:
    return {row["id"]: row for row in status["result"]["tags"]}


def test_a_changed_body_is_measured_saved_and_can_be_put_back():
    # Tags 2 and 3 swap places, 4 moves 30 mm, 5 comes off and a new tag 9 goes on.
    new = {
        1: BODY[1],
        2: BODY[3],
        3: BODY[2],
        4: (BODY[4][0], BODY[4][1] + np.array([0.03, 0.0, 0.0])),
        9: BODY[5],
    }
    bench = Bench()
    try:
        old_text = bench.rig.read_text()
        assert bench.status()["current"]["tags"] == [1, 2, 3, 4, 5]

        ok, _ = bench.command("start")
        assert ok
        bench.feed(frames(new))
        bench.now += 0.1
        bench.take.poll(bench.now)
        assert bench.take.state == "solving", "the take should end by itself"
        status = bench.solved()

        assert status["state"] == "review", status
        result = status["result"]
        assert result["ok"], result
        tags = rows(status)
        assert tags[1]["state"] == "same", tags[1]
        assert tags[2]["state"] == "moved" and tags[3]["state"] == "moved", tags
        assert 25 < tags[4]["moved_mm"] < 35 and tags[4]["state"] == "moved", tags[4]
        assert tags[9]["state"] == "new", tags[9]
        assert result["gone"] == [5], result
        assert bench.rig.read_text() == old_text, "nothing changes before Save"
        assert bench.changes == 0

        ok, detail = bench.command("save")
        assert ok, detail
        assert bench.changes == 1, "the tracker should be told to use it"
        body = RigidBody.load(bench.rig)
        assert body.reference_id == 1
        assert list(body.marker_ids) == [1, 2, 3, 4, 9]
        for mid, (_, truth) in new.items():
            error_mm = 1000 * np.linalg.norm(body.transforms[mid][1] - truth)
            assert error_mm < 2.0, f"tag {mid} is {error_mm:.2f} mm out"
        assert np.allclose(body.tip_ref, TIP), "the tracked point is fixed to tag 1"

        device = bench.device.read_text()
        assert toml.loads(device)["device"]["tag_ids"] == [1, 2, 3, 4, 5, 9], "a new tag should be remembered"
        assert "Only comment that must survive." in device

        status = bench.status()
        assert status["state"] == "idle" and status["current"]["tags"] == [1, 2, 3, 4, 9], status
        assert status["current"]["can_restore"]

        ok, detail = bench.command("restore")
        assert ok, detail
        assert bench.rig.read_text() == old_text, "restore should put back the previous one"
        assert bench.changes == 2
        status = bench.status()
        assert status["current"]["tags"] == [1, 2, 3, 4, 5] and not status["current"]["can_restore"], status
        assert not bench.command("restore")[0], "nothing left to restore"
    finally:
        bench.done()
    print("  a changed body: measured, saved, tracked point kept, put back")


def test_a_tag_fixed_in_the_room_is_left_out():
    bench = Bench(take_s=1000)
    try:
        bench.command("start")
        bench.feed(frames(BODY, room_tag=True))
        assert bench.command("finish")[0]
        started = time.time()
        status = bench.solved()
        assert status["state"] == "review", status
        result = status["result"]
        assert result["ok"], result
        assert result["dropped"] == [ROOM_ID], result
        assert ROOM_ID not in rows(status)
        assert all(row["state"] == "same" for row in result["tags"]), result["tags"]
    finally:
        bench.done()
    print(f"  a tag fixed in the room: left out, solved in {time.time() - started:.0f} s")


def test_a_device_that_hardly_turned_is_refused():
    bench = Bench(take_s=1000)
    try:
        before = bench.rig.read_text()
        bench.command("start")
        bench.feed(frames(BODY, still=True))
        bench.command("finish")
        status = bench.solved()
        result = status["result"]
        assert not result["ok"], result
        assert any("turn" in problem for problem in result["problems"]), result
        assert not bench.command("save")[0], "a refused take cannot be saved"
        assert bench.rig.read_text() == before
        assert bench.changes == 0
    finally:
        bench.done()
    print("  a device that hardly turned: refused, nothing saved")


def test_every_other_tag_moved_says_tag_1_may_have():
    # The whole cluster shifted relative to tag 1: as if tag 1 itself had been moved.
    shift = np.array([0.0, 0.0, 0.04])
    new = {mid: (r, t + (shift if mid != 1 else 0)) for mid, (r, t) in BODY.items()}
    bench = Bench(take_s=1000)
    try:
        bench.command("start")
        bench.feed(frames(new))
        bench.command("finish")
        status = bench.solved()
        result = status["result"]
        assert result["ok"], result
        assert any("Tag 1" in warning for warning in result["warnings"]), result
    finally:
        bench.done()
    print("  every other tag moved: warns that tag 1 itself may have")


def test_while_capturing_it_says_what_the_take_still_needs():
    bench = Bench()
    try:
        assert not bench.command("save")[0], "nothing to save yet"
        assert not bench.command("finish")[0], "nothing to finish yet"
        assert bench.command("start")[0]
        assert not bench.command("start")[0], "already capturing"

        status = bench.status()
        assert status["state"] == "capturing" and status["capture"]["left"] is None, "the clock waits for the cameras"

        # Tags 1 and 2 together at the tracker's 60 fps: 10 pairs a second are kept.
        det = next({mid: pair[0][mid] for mid in (1, 2)} for pair in frames(BODY) if {1, 2} <= set(pair[0]))
        one_alone = {3: det[1]}
        for i in range(600):
            bench.take.frame(bench.now, det, {}, True, bench.image)
            bench.now += 1 / 60
        for i in range(30):
            bench.take.frame(bench.now, one_alone, {}, True, bench.image)
            bench.now += 0.1
        status = bench.status()
        capture = status["capture"]
        assert 125 <= capture["frames"] <= 135, f"should keep about 10 pairs a second, kept {capture['frames']}"
        assert capture["left"] < 24, capture
        assert capture["level"] == 100.0, capture
        assert capture["tag_px"] > 0, capture
        by_id = {row["id"]: row for row in capture["tags"]}
        assert by_id[1]["joined"], "the fixed tag is the start"
        assert by_id[2]["joined"], by_id[2]
        assert by_id[3]["seen"] > 0 and not by_id[3]["joined"], by_id[3]
        assert by_id[4]["seen"] == 0 and not by_id[4]["joined"], "a tag that was on the body should be listed"

        # Going away ends a take, not what it would have replaced.
        bench.take.link_lost()
        assert bench.take.state == "idle"
        assert bench.take.poll(bench.now) is None or bench.status()["state"] == "idle"
    finally:
        bench.done()
    print("  while capturing: counts, joined tags, 10 pairs a second")


def test_a_take_without_tag_1_needs_no_solve():
    bench = Bench()
    try:
        bench.command("start")
        without = [({m: c for m, c in a.items() if m != 1}, {m: c for m, c in b.items() if m != 1})
                   for a, b in frames(BODY, pairs=60)]
        bench.feed(without)
        assert bench.command("finish")[0]
        status = bench.status()
        assert status["state"] == "failed", status
        assert "Tag 1" in status["reason"], status
        assert bench.command("start")[0], "should be able to try again"
        bench.command("cancel")

        bench.command("start")
        bench.command("finish")
        status = bench.status()
        assert status["state"] == "failed" and "Tag 1" in status["reason"], status
    finally:
        bench.done()
    print("  no tag 1: says so at once")


def test_a_solve_can_be_cancelled_or_fail():
    pairs = frames(BODY, pairs=60)

    bench = Bench(python=sys.executable)
    try:
        bench.command("start")
        bench.feed(pairs)
        bench.command("finish")
        assert bench.take.state == "solving"
        process = bench.take._process
        assert not bench.command("start")[0], "a solve is running"
        assert not bench.command("restore")[0], "a solve is running"
        assert bench.command("cancel")[0]
        assert process.wait(timeout=5) is not None, "cancel should end the solve"
        assert bench.status()["state"] == "idle"
    finally:
        bench.done()

    # The solver dies without a word.
    bench = Bench(python="false")
    try:
        bench.command("start")
        bench.feed(pairs)
        bench.command("finish")
        status = bench.solved()
        assert status["state"] == "failed" and status["reason"], status
    finally:
        bench.done()

    # The solver never ends.
    sleeper = Path(tempfile.mkdtemp(prefix="body_take_")) / "sleeper.sh"
    sleeper.write_text('#!/bin/sh\nexec sleep 30\n')
    sleeper.chmod(0o755)
    bench = Bench(python=str(sleeper), solve_timeout_s=1.0)
    try:
        bench.command("start")
        bench.feed(pairs)
        bench.command("finish")
        process = bench.take._process
        status = bench.solved()
        assert status["state"] == "failed" and "too long" in status["reason"], status
        assert process.wait(timeout=5) is not None, "a stuck solve should be ended"
    finally:
        bench.done()
        shutil.rmtree(sleeper.parent, ignore_errors=True)
    print("  a solve: cancelled, dead or stuck, each reported")


def test_the_tracker_takes_a_new_body_at_once():
    import tracker
    from corner_stabilizer import CornerStabilizer
    bench = Bench()
    try:
        stabilizer = CornerStabilizer(0.5)
        running = SimpleNamespace(_rigidbody_path=bench.rig, stabilizer=stabilizer, rig=None)
        tracker.TrackerClass._use_new_rig(running)
        assert list(running.rig.marker_ids) == [1, 2, 3, 4, 5]
        assert running.stabilizer is not stabilizer, 'it may be holding a pose from the old body'
        assert running.stabilizer.threshold_px == 0.5
    finally:
        bench.done()
    print('  the tracker: new body in use, held pose dropped')


if __name__ == '__main__':
    started = time.time()
    test_the_tracker_takes_a_new_body_at_once()
    test_while_capturing_it_says_what_the_take_still_needs()
    test_a_take_without_tag_1_needs_no_solve()
    test_a_solve_can_be_cancelled_or_fail()
    test_a_changed_body_is_measured_saved_and_can_be_put_back()
    test_a_tag_fixed_in_the_room_is_left_out()
    test_a_device_that_hardly_turned_is_refused()
    test_every_other_tag_moved_says_tag_1_may_have()
    print(f"OK in {time.time() - started:.0f} s")
