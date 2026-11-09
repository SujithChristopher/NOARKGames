"""A run through experiment.py with made-up frames, written by the real FrameRecorder.

    uv run pyscripts/tests/test_experiment.py
"""
import csv
import json
import sys
import tempfile
import time
from types import SimpleNamespace
from pathlib import Path

import msgpack
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import protocol
from experiment import CAPTURE_TIMEOUT_S, POSE_COLUMNS, TARGET_COLUMNS, Experiments
from frame_recorder import FrameRecorder

FRAME = np.zeros((8, 16), dtype=np.uint8)
FRAMES = 30
TABLE = {"centre": [0.1, 0.4], "basis": [1.0, 0.0, 0.0, 1.0], "k": 1000.0, "y0": 0.0}


class FakeSync:
    """The trigger line as a screen watches it: a level and a count."""
    available = True
    edges_available = True

    def __init__(self) -> None:
        self.level = 0
        self.event_count = 0
        self.closed = False

    def get_value(self) -> int:
        return self.level

    def close(self) -> None:
        self.closed = True


def rows(path: Path) -> list:
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh))


class Rig:
    def __init__(self, root: Path) -> None:
        self.rigid = root / "rigidbody.toml"
        self.rigid.write_text("[made]\nup = true\n")
        self.exp = Experiments(
            root / "experiments",
            lambda: {"solver": "joint"},
            lambda out, meta: FrameRecorder(out, metadata=meta, target_hz=0, chunk_frames=10),
            lambda: 2 * FRAME.size,
            lambda: [self.rigid, root / "not_there.toml"],
            lambda: (self.phase, self.nudges),
            self.open_monitor,
        )
        self.monitors: list = []
        self.phase = SimpleNamespace(phase_us=12.5, jitter_us=3.0, drift_ppm=50.0, n=30)
        self.nudges = 0
        self.ns = 1_000_000_000
        self.now = 1000.0

    def open_monitor(self):
        monitor = FakeSync()
        self.monitors.append(monitor)
        return monitor

    def tick(self, pose) -> None:
        self.ns += 10_000_000
        self.now += 0.01
        self.exp.images(FRAME, FRAME, self.ns, self.ns + 1, [self.ns, self.ns])
        self.exp.frame(pose, np.array([[1], [3]]), None, now=self.now)
        # A camera gives the writers time; a loop like this one outruns their queue.
        recorder = self.exp._recorder
        while recorder is not None and any(w.backlog for w in recorder._writers):
            time.sleep(0.001)

    def still(self, x=0.2, wobble=0.0):
        """A pose at table x = (x - 0.1) m, z at the table centre."""
        tip = np.array([x + wobble, 0.05, 0.4])
        return tip, np.array([0.1, 0.2, 0.3]), np.array([0.0, 0.0, 0.5])


def unpack(path: Path) -> list:
    with open(path, "rb") as fh:
        return list(msgpack.Unpacker(fh, raw=False))


def test_commands_need_a_run(rig: Rig) -> None:
    assert not rig.exp.command("capture 1 1 1 0 0 30 5")[0]
    assert not rig.exp.command("meta a 1")[0]
    assert rig.exp.command("stop stopped")[0], "a stop with no run does no harm"
    assert not rig.exp.command("start ../evil 10 t1")[0], "the name is a folder"
    assert not rig.exp.command("start grid 1000000000000 t1")[0], "no disk for that"
    assert not rig.exp.command("start grid 10")[0], "a run needs its name"
    assert not rig.exp.command("start grid 10 ../evil")[0], "the run's name is a folder too"
    assert not rig.exp.command("nonsense")[0]
    print("  refused               no run, a bad name, no disk")


def test_a_run(rig: Rig) -> Path:
    ok, path = rig.exp.command("start grid 60 trial_03")
    assert ok, path
    run = Path(path)
    assert run.name.startswith("trial_03_"), run.name
    assert not rig.exp.command("start grid 60 trial_03")[0], "one run at a time"
    assert rig.exp.command("meta table_frame " + json.dumps(TABLE))[0]
    assert rig.exp.command('meta notes "a note"')[0]

    # Frames outside a capture are nothing to do with the run.
    rig.tick(rig.still())
    sync = rig.exp._recorder.sync
    sync._note_edge(rig.ns, 1, 1)                   # a pulse between captures: no capture's

    # The phase log: a row a second, marking when the alignment moved, on disk at once.
    rig.exp.poll(100.0)
    rig.exp.poll(100.5)
    rig.nudges = 1
    rig.exp.poll(101.0)
    phases = unpack(run / "recording" / "phase_log.msgpack")
    assert [p[1:] for p in phases] == [[12.5, 3.0, 50.0, 30, 0], [12.5, 3.0, 50.0, 30, 1]], phases

    assert rig.exp.command("capture 1 1 1 90.0 0.0 30 5")[0]
    assert not rig.exp.command("capture 2 1 2 0 0 30 5")[0], "one capture at a time"
    assert rig.exp.capturing
    rig.tick(None)                                  # a failed frame is a row, not one of the 30
    rise = rig.ns + 5
    sync._note_edge(rise, 1, 2)                     # and two edges during this capture
    sync._note_edge(rise + 3, 0, 3)
    # A crash at this point would lose nothing: they are on disk already.
    assert len(unpack(run / "recording" / "sync_events.msgpack")) == 3
    for _ in range(FRAMES):
        rig.tick(rig.still())
    assert not rig.exp.capturing
    edges_target_1 = rise
    rig.tick(rig.still())                           # and nothing more is saved

    status = json.loads(rig.exp.poll(0.0)[1:])
    assert status["state"] == "ready" and status["last"]["accepted"], status
    assert status["last"]["frames_ok"] == FRAMES and status["last"]["frames_failed"] == 1

    # The device moves during a capture: kept, not accepted, and asked for again.
    assert rig.exp.command("capture 2 1 2 0 0 30 5")[0]
    for i in range(FRAMES):
        rig.tick(rig.still(wobble=i * 0.001))
    last = json.loads(rig.exp.poll(0.0)[1:])["last"]
    assert not last["accepted"] and last["reason"] == "moved" and last["attempt"] == 1, last
    assert rig.exp.command("capture 2 1 2 0 0 30 5")[0]
    for _ in range(FRAMES):
        rig.tick(rig.still(x=0.1))
    last = json.loads(rig.exp.poll(0.0)[1:])["last"]
    assert last["accepted"] and last["attempt"] == 2, last

    assert rig.exp.command("stop complete")[0]
    assert not rig.exp.capturing

    print("  capture               30 good frames, failed ones logged, a move rejected")
    return run, edges_target_1


def test_what_it_wrote(run: Path, rise: int) -> None:
    meta = json.loads((run / "metadata.json").read_text())
    assert meta["status"] == "complete" and meta["finished_at"], meta
    assert meta["label"] == "trial_03"
    assert meta["notes"] == "a note" and meta["table_frame"] == TABLE
    assert meta["tracker"]["solver"] == "joint"
    assert meta["targets_accepted"] == 2 and meta["capture_attempts"] == 3, meta
    assert (run / "calibration" / "rigidbody.toml").exists(), "the rig as it was"

    targets = rows(run / "targets.csv")
    poses = rows(run / "poses.csv")
    assert list(targets[0]) == TARGET_COLUMNS and list(poses[0]) == POSE_COLUMNS
    assert [(t["target"], t["attempt"], t["accepted"]) for t in targets] == [
        ("1", "1", "1"), ("2", "1", "0"), ("2", "2", "1")], targets
    assert len(poses) == 1 + FRAMES * 3, len(poses)

    first = targets[0]
    assert first["frames_failed"] == "1" and first["frames_ok"] == str(FRAMES)
    assert abs(float(first["table_mean_x_mm"]) - 100.0) < 1e-3, first
    assert abs(float(first["offset_x_mm"]) - 10.0) < 1e-3, "measured minus expected"
    assert abs(float(first["fps"]) - 100.0) < 1.0, first
    assert float(first["tip_std_x_mm"]) == 0.0
    assert first["sync_edges"] == "2", "the pulse before the capture is not counted"
    assert first["sync_first_rise_ns"] == str(rise), first
    assert first["phase_us"] == "12.5", first
    assert int(first["sensor_ns_start"]) == int(poses[0]["sensor_ns0"])
    assert int(first["sensor_ns_end"]) == int(poses[FRAMES]["sensor_ns0"])
    assert targets[2]["sync_edges"] == "0" and targets[2]["sync_first_rise_ns"] == ""

    failed = poses[0]
    assert failed["pose_ok"] == "0" and failed["tip_x_m"] == "" and failed["frame"] == "0", failed
    assert failed["tags_cam0"] == "1 3" and failed["tags_cam1"] == ""
    good = poses[1]
    assert good["pose_ok"] == "1" and good["tip_x_m"] == "0.200000" and good["table_x_mm"] == "100.000"
    assert good["frame"] == "1"
    assert all(len(p) == len(POSE_COLUMNS) and None not in p for p in poses)

    # Every row has its images, and the settings' recording rate never thinned them.
    stamps = []
    for path in sorted((run / "recording").glob("cam0_timestamp*.msgpack")):
        with open(path, "rb") as fh:
            stamps += [r[3] for r in msgpack.Unpacker(fh, raw=False)]
    assert stamps == [int(p["sensor_ns0"]) for p in poses], "images and rows pair on sensor_ns"
    recording = json.loads((run / "recording" / "metadata.json").read_text())
    assert recording["target_hz"] == 0 and recording["scale"] == 1.0
    assert meta["images"]["dropped"] == [0, 0], meta["images"]
    assert meta["sync"]["edges"] == 3, meta["sync"]

    # The level kept with each frame's images and the sync column are the same one.
    levels = []
    for path in sorted((run / "recording").glob("cam0_timestamp*.msgpack")):
        levels += [r[0] for r in unpack(path)]
    assert levels == [int(p["sync"]) for p in poses], "sync column"
    edges = unpack(run / "recording" / "sync_events.msgpack")
    assert [e[1:] for e in edges] == [[1, 1], [1, 2], [0, 3]], "not written twice at the close"
    print(f"  files                 {len(targets)} attempts, {len(poses)} frames, images pair with rows")


def test_out_of_view_gives_up(rig: Rig) -> None:
    assert rig.exp.command("start grid 30 t2")[0]
    assert rig.exp.command("capture 1 1 1 0 0 30 5")[0]
    rig.exp.images(FRAME, FRAME, 1, 1, [1, 1])
    rig.exp.frame(None, None, None, now=500.0)
    assert rig.exp.capturing
    rig.exp.images(FRAME, FRAME, 2, 2, [2, 2])
    rig.exp.frame(None, None, None, now=500.0 + CAPTURE_TIMEOUT_S)
    assert not rig.exp.capturing
    last = json.loads(rig.exp.poll(0.0)[1:])["last"]
    assert last["reason"] == "no_pose" and not last["accepted"], last
    rig.exp.link_lost()
    print("  out of view           gives up, not accepted")


def test_link_lost_mid_capture(rig: Rig) -> None:
    ok, path = rig.exp.command("start grid 30 t2")
    assert ok, path
    assert rig.exp.command("capture 1 1 1 0 0 30 5")[0]
    rig.tick(rig.still())
    rig.exp.link_lost()
    assert not rig.exp.capturing
    rig.tick(rig.still())
    meta = json.loads((Path(path) / "metadata.json").read_text())
    assert meta["status"] == "link_lost" and meta["targets_accepted"] == 0, meta
    assert rows(Path(path) / "targets.csv")[0]["reason"] == "stopped"
    saved = json.loads(rig.exp.poll(0.0)[1:])["saved"]
    assert saved["path"] == path and saved["status"] == "link_lost", saved
    print("  link lost             closed, marked, the next run can start")


def test_status_repeats(rig: Rig) -> None:
    assert rig.exp.command("status")[0]
    assert rig.exp.poll(0.0)[0] == protocol.EXPERIMENT_STATUS
    assert rig.exp.poll(1.0) is None, "idle: only when asked"
    assert rig.exp.command("start grid 30 t2")[0]
    assert rig.exp.poll(2.0) is not None
    assert rig.exp.poll(2.1) is None
    assert rig.exp.poll(2.3) is not None, "running: steadily, so a lost one is not fatal"
    rig.exp.close()
    print("  status                on change, steadily during a run")


def test_watching_the_trigger(rig: Rig) -> None:
    assert rig.exp.command("watch on") == (True, "sync")
    monitor = rig.monitors[-1]
    status = json.loads(rig.exp.poll(10.0)[1:])
    assert status["sync"] == {"available": True, "level": 0, "edges": 0, "edge_timestamps": True}
    assert rig.exp.poll(10.1) is None
    monitor.level, monitor.event_count = 1, 1
    status = json.loads(rig.exp.poll(10.15)[1:])
    assert status["sync"]["level"] == 1, "a change goes at once"
    assert rig.exp.poll(10.5) is not None, "and steadily while watched"

    # A run takes the line: the monitor lets go, the recorder's line is shown, then back.
    assert rig.exp.command("start grid 30 w1")[0]
    assert monitor.closed and rig.exp._monitor is None
    status = json.loads(rig.exp.poll(11.0)[1:])
    assert "sync" in status, status
    assert rig.exp.command("stop complete")[0]
    assert len(rig.monitors) == 2 and not rig.monitors[-1].closed, "watching again after the run"

    rig.exp.link_lost()
    assert rig.monitors[-1].closed and rig.exp._monitor is None, "a lost link stops watching"
    rig.exp.command("status")
    assert "sync" not in json.loads(rig.exp.poll(12.0)[1:])
    print("  sync                  watched before a run, the run's line during it")


def test_continuous_record(rig: Rig) -> None:
    ok, path = rig.exp.command("start continuous_raw 1000 rec1")
    assert ok, path
    run = Path(path)
    assert not rig.exp.command("record 0")[0], "needs a time limit"
    assert rig.exp.command("record 0.2")[0]
    assert not rig.exp.command("record 5")[0], "one at a time"
    rig.tick(rig.still())
    rig.tick(None)                                  # out of view: kept, recording goes on
    sync = rig.exp._recorder.sync
    sync._note_edge(rig.ns + 1, 1, 1)
    for i in range(10):
        rig.tick(rig.still(wobble=i * 0.01))        # moving: a recording, not a held point
    status = json.loads(rig.exp.poll(rig.now)[1:])
    assert status["capture"]["limit_s"] == 0.2 and status["capture"]["elapsed_s"] > 0, status
    assert rig.exp.capturing
    while rig.exp.capturing:
        rig.tick(rig.still())
    last = json.loads(rig.exp.poll(0.0)[1:])["last"]
    assert last["accepted"] and last["reason"] == "limit", last
    assert rig.exp.command("stop complete")[0]

    targets = rows(run / "targets.csv")
    poses = rows(run / "poses.csv")
    assert len(targets) == 1 and targets[0]["row"] == "" and targets[0]["expected_x_mm"] == ""
    assert targets[0]["offset_x_mm"] == "" and targets[0]["sync_edges"] == "1", targets[0]
    assert int(targets[0]["frames_ok"]) + int(targets[0]["frames_failed"]) == len(poses)
    assert targets[0]["frames_failed"] == "1"
    assert all(p["target"] == "1" and p["row"] == "" for p in poses)
    assert 20 <= len(poses) <= 22, len(poses)      # 0.2 s at 100 Hz, the limit frame included

    # Stopped before its limit: still the recording, accepted.
    assert rig.exp.command("start continuous_raw 1000 rec2")[0]
    assert rig.exp.command("record 60")[0]
    for _ in range(3):
        rig.tick(rig.still())
    assert rig.exp.command("stop complete")[0]
    run2 = Path(json.loads(rig.exp.poll(0.0)[1:])["saved"]["path"])
    t = rows(run2 / "targets.csv")[0]
    assert t["accepted"] == "1" and t["reason"] == "stopped", t
    assert json.loads((run2 / "metadata.json").read_text())["targets_accepted"] == 1
    print("  continuous            every frame to the limit or the stop, one summary row")


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        rig = Rig(Path(tmp))
        test_commands_need_a_run(rig)
        run, rise = test_a_run(rig)
        test_what_it_wrote(run, rise)
        test_out_of_view_gives_up(rig)
        test_link_lost_mid_capture(rig)
        test_status_repeats(rig)
        test_watching_the_trigger(rig)
        test_continuous_record(rig)
    print("OK")


if __name__ == "__main__":
    main()
