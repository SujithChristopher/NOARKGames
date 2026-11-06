"""Experiments run from the app (the main menu's Experiments button), written on the board.

The app says where the device should be and when to capture; the tracker writes what it
measured, because only it has the images, the whole pose and the sensor timestamps, and
because over BLE the app is on a tablet. A run is one folder:

    {DOCUMENTS}/NOARK_demo/experiments/<experiment>/<label>_<date>_<time>/
        metadata.json   what was run and how; `status` says whether it finished
        targets.csv     one row per capture attempt (TARGET_COLUMNS)
        poses.csv       one row per camera frame captured (POSE_COLUMNS)
        recording/      the same frames as images: frame_recorder.py's format, with the
                        mocap trigger's edges (sync_events.msgpack, written as they come) and
                        phase_log.msgpack, [monotonic_ns, phase_us, jitter_us, drift_ppm, n,
                        nudged] a second for the whole run
        calibration/    the rig's files as they were for this run

Every frame of a capture is kept, whatever settings.json `recording_fps` says, and at full
size: a static capture is short, and a frame skipped is a sample lost. A rejected attempt
stays in the files too; `accepted` in targets.csv says which to use. Pair a row with its
images on sensor_ns, as for any recording. sensor_ns, the trigger's edges and the phase log
are all CLOCK_MONOTONIC, so a pulse is placed against a frame or a capture by comparison.

    idle -> ready <-> capturing
              `-> idle (stop, a link lost, a new HELLO)
"""

import csv
import json
import re
import shutil
import subprocess
import time
from collections.abc import Callable
from datetime import datetime
from pathlib import Path
from typing import Optional

import msgpack
import numpy as np

import protocol

IDLE, READY, CAPTURING = "idle", "ready", "capturing"

FORMAT_VERSION = 1
# Nothing but failed frames for this long: the device is out of view, stop filling the disk.
CAPTURE_TIMEOUT_S = 5.0
STATUS_EVERY_S = 0.25
PHASE_EVERY_S = 1.0
# The disk a run needs is worked out at start; a margin for the rest of its files.
DISK_MARGIN = 1.2

POSE_COLUMNS = [
    "target", "attempt", "row", "col", "frame", "pose_ok", "wall_time_unix",
    "sensor_ns0", "sensor_ns1", "seq0", "seq1", "sync",
    "tip_x_m", "tip_y_m", "tip_z_m",
    "rvec_x", "rvec_y", "rvec_z", "tvec_x_m", "tvec_y_m", "tvec_z_m",
    "table_x_mm", "table_y_mm", "tags_cam0", "tags_cam1",
]
TARGET_COLUMNS = [
    "target", "attempt", "row", "col", "expected_x_mm", "expected_y_mm",
    "accepted", "reason", "frames_ok", "frames_failed", "fps",
    "wall_start_unix", "wall_end_unix", "sensor_ns_start", "sensor_ns_end",
    "sync_edges", "sync_first_rise_ns", "phase_us",
    "tip_mean_x_m", "tip_mean_y_m", "tip_mean_z_m",
    "tip_std_x_mm", "tip_std_y_mm", "tip_std_z_mm",
    "table_mean_x_mm", "table_mean_y_mm", "offset_x_mm", "offset_y_mm", "max_dev_mm",
]


def _commit() -> str:
    """The code that wrote this run, marked if it was not the committed code."""
    try:
        run = subprocess.run(
            ["git", "describe", "--always", "--dirty"], cwd=Path(__file__).parent,
            capture_output=True, text=True, timeout=2,
        )
        return run.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


class Experiments:
    def __init__(self, root: Path, describe: Callable[[], dict],
                 open_recorder: Callable[[Path, dict], object], frame_bytes: Callable[[], int],
                 snapshot: Callable[[], list],
                 phase: Callable[[], tuple] = lambda: (None, 0)) -> None:
        self.root = Path(root)
        self._describe = describe           # how the tracker is set up now
        self._open_recorder = open_recorder # out_dir, metadata -> FrameRecorder
        self._frame_bytes = frame_bytes     # one pair of images on disk
        self._snapshot = snapshot           # the files that define the rig
        self._phase = phase                 # -> (PhaseReport or None, nudges so far)
        self._phase_file = None
        self._next_phase = 0.0
        self._nudges = 0
        self._state = IDLE
        self._dir: Optional[Path] = None
        self._meta: dict = {}
        self._recorder = None
        self._poses = self._poses_file = None
        self._targets = self._targets_file = None
        self._attempts: dict = {}           # target -> attempts so far
        self._accepted = 0
        self._capture: Optional[dict] = None
        self._pending = None                # this frame's image stamps, until its pose comes
        self._last: Optional[dict] = None   # the last capture's result
        self._saved: Optional[dict] = None  # the last run's end
        self._changed = False
        self._next_status = 0.0

    @property
    def capturing(self) -> bool:
        return self._state == CAPTURING

    # ── Commands ──────────────────────────────────────────────────────────────

    def command(self, text: str) -> tuple[bool, str]:
        """One EXPERIMENT from the app -> (ok, detail) for its ACK."""
        parts = text.split(" ")
        try:
            if parts[0] == "status":
                self._changed = True
                return True, ""
            if parts[0] == "start":
                return self._start(parts[1], int(parts[2]), parts[3])
            if parts[0] == "meta":
                return self._set_meta(parts[1], json.loads(text.split(" ", 2)[2]))
            if parts[0] == "capture":
                return self._start_capture(parts[1:])
            if parts[0] == "stop":
                return self._stop(parts[1])
        except (IndexError, ValueError) as e:
            return False, f"bad command: {e}"
        except OSError as e:   # the disk: a refused run, not a stopped tracker
            return False, str(e)
        return False, f"unknown: {parts[0]}"

    def _start(self, name: str, frames_total: int, label: str) -> tuple[bool, str]:
        if self._state != IDLE:
            return False, "a run is already going"
        if not re.fullmatch(r"[a-z0-9_]+", name):
            return False, "bad experiment name"
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,40}", label):
            return False, "bad run name"
        self.root.mkdir(parents=True, exist_ok=True)
        need = frames_total * self._frame_bytes() * DISK_MARGIN
        free = shutil.disk_usage(self.root).free
        if free < need:
            return False, f"needs {need / 1e9:.1f} GB, {free / 1e9:.1f} GB free"

        started = datetime.now()
        run = started.strftime(f"{label}_%Y-%m-%d_%H-%M-%S")
        self._dir = self.root / name / run
        for again in range(2, 10):   # two runs in one second
            if not self._dir.exists():
                break
            self._dir = self.root / name / f"{run}_{again}"
        self._dir.mkdir(parents=True)
        (self._dir / "calibration").mkdir()
        for path in self._snapshot():
            if Path(path).is_file():
                shutil.copy2(path, self._dir / "calibration")
        self._meta = {
            "format_version": FORMAT_VERSION,
            "experiment": name,
            "label": label,
            "run": self._dir.name,
            "status": "running",
            "started_at": started.isoformat(timespec="seconds"),
            "finished_at": None,
            "code_version": _commit(),
            "tracker": self._describe(),
            "units": {"tip, tvec": "metres, camera frame", "rvec": "Rodrigues, camera frame",
                      "table_*": "mm from the table centre, x right and y down as on screen"},
            "columns": {"targets.csv": TARGET_COLUMNS, "poses.csv": POSE_COLUMNS},
        }
        self._write_meta()
        self._recorder = self._open_recorder(
            self._dir / "recording", {"experiment": name, "run": self._dir.name})
        self._poses_file = open(self._dir / "poses.csv", "w", newline="", buffering=1)
        self._poses = csv.writer(self._poses_file)
        self._poses.writerow(POSE_COLUMNS)
        self._targets_file = open(self._dir / "targets.csv", "w", newline="", buffering=1)
        self._targets = csv.writer(self._targets_file)
        self._targets.writerow(TARGET_COLUMNS)
        self._phase_file = open(self._dir / "recording" / "phase_log.msgpack", "wb")
        self._next_phase = 0.0
        self._nudges = self._phase()[1]
        self._attempts = {}
        self._accepted = 0
        self._last = self._saved = self._capture = self._pending = None
        self._state = READY
        self._changed = True
        print(f"[EXPERIMENT] {name}: writing to {self._dir}", flush=True)
        return True, str(self._dir)

    def _set_meta(self, key: str, value) -> tuple[bool, str]:
        """What the app knows and the tracker does not: the table, the grid, the notes."""
        if self._state == IDLE:
            return False, "no run"
        self._meta[key] = value
        self._write_meta()
        return True, ""

    def _start_capture(self, args: list) -> tuple[bool, str]:
        if self._state != READY:
            return False, f"{self._state}, not ready"
        target, row, col = int(args[0]), int(args[1]), int(args[2])
        expected = (float(args[3]), float(args[4]))
        attempt = self._attempts.get(target, 0) + 1
        self._attempts[target] = attempt
        self._capture = {
            "target": target, "attempt": attempt, "row": row, "col": col, "expected": expected,
            "frames": int(args[5]), "still_mm": float(args[6]),
            "ok": 0, "failed": 0, "tips": [], "table": [], "sensor_ns": [],
            "started": None, "deadline": None,
        }
        self._state = CAPTURING
        self._changed = True
        return True, ""

    def _stop(self, why: str) -> tuple[bool, str]:
        if self._state == IDLE:
            return True, "no run"   # a stop that crossed with the link's end
        if self._capture is not None:
            self._finish_capture("stopped")
        self._pending = None
        self._state = IDLE
        recorder, self._recorder = self._recorder, None
        recorder.close()
        for fh in (self._poses_file, self._targets_file, self._phase_file):
            fh.close()
        self._meta["status"] = why
        self._meta["finished_at"] = datetime.now().isoformat(timespec="seconds")
        self._meta["targets_accepted"] = self._accepted
        self._meta["capture_attempts"] = sum(self._attempts.values())
        self._meta["images"] = {
            "pairs_offered": recorder.frames,
            "dropped": [w.dropped for w in recorder._writers],
        }
        self._meta["sync"] = {
            "line_available": recorder.sync.available,
            "edge_timestamps": recorder.sync.edges_available,
            "edges": recorder.sync.event_count,
        }
        self._write_meta()
        self._saved = {"path": str(self._dir), "status": why, "accepted": self._accepted,
                       "dropped": self._meta["images"]["dropped"]}
        self._changed = True
        print(f"[EXPERIMENT] {why}: {self._accepted} targets in {self._dir}", flush=True)
        return True, str(self._dir)

    def link_lost(self) -> None:
        self._stop("link_lost")

    def close(self) -> None:
        self._stop("tracker_stopped")

    def _write_meta(self) -> None:
        """Whole or not at all: the file is what says what the rest of the folder is."""
        tmp = self._dir / "metadata.json.tmp"
        tmp.write_text(json.dumps(self._meta, indent=2))
        tmp.replace(self._dir / "metadata.json")

    # ── Frames ────────────────────────────────────────────────────────────────

    def images(self, raw0, raw1, ts0, ts1, sequences) -> None:
        """Before the frame is worked on. A capture that begins later in this frame (the
        link is polled there) begins with the next, so every row has its images."""
        if self.capturing:
            sync = self._recorder.add(raw0, raw1, ts0, ts1, sequences)
            self._pending = (ts0, ts1, sequences, sync)

    def frame(self, pose, ids0, ids1, now: Optional[float] = None) -> None:
        """This frame's result. pose: (tip, rvec, tvec), None if none was solved."""
        if self._pending is None:
            return
        now = time.time() if now is None else now
        ts0, ts1, sequences, sync = self._pending
        self._pending = None
        c = self._capture
        if c["started"] is None:
            c["started"] = now
            c["deadline"] = now + CAPTURE_TIMEOUT_S
        number = c["ok"] + c["failed"]
        if ts0 is not None:
            c["sensor_ns"].append(ts0)

        if pose is None:
            c["failed"] += 1
            values = [""] * 11
        else:
            tip, rvec, tvec = (np.ravel(v) for v in pose)
            table = self._to_table(tip)
            c["ok"] += 1
            c["tips"].append(tip.copy())
            if table is not None:
                c["table"].append(table)
            values = [*(f"{v:.6f}" for v in (*tip, *rvec, *tvec)),
                      *(f"{v:.3f}" for v in (table if table is not None else ())),
                      *([""] * (2 if table is None else 0))]
        self._poses.writerow([
            c["target"], c["attempt"], c["row"], c["col"], number, int(pose is not None),
            f"{now:.6f}", ts0, ts1, *sequences, sync, *values, _tags(ids0), _tags(ids1),
        ])
        self._changed = self._changed or number % 5 == 0

        if c["ok"] >= c["frames"]:
            self._finish_capture("")
        elif now >= c["deadline"] and c["ok"] == 0:
            self._finish_capture("no_pose")

    def _to_table(self, tip):
        """Camera frame -> mm on the table, as GlobalScript._apply_position does it."""
        frame = self._meta.get("table_frame")
        if not frame:
            return None
        cx, cz = frame["centre"]
        a, b, c, d = frame["basis"]     # the x column, then the y column
        dx, dz = tip[0] - cx, tip[2] - cz
        return ((a * dx + c * dz) * 1000.0, (b * dx + d * dz) * 1000.0)

    def _finish_capture(self, reason: str) -> None:
        c, self._capture = self._capture, None
        self._state = READY
        row = {"tip_mean": ["", "", ""], "tip_std": ["", "", ""], "table": ["", ""],
               "offset": ["", ""], "dev": ""}
        dev = None
        if c["tips"]:
            tips = np.array(c["tips"])
            mean = tips.mean(axis=0)
            std = tips.std(axis=0) * 1000.0
            # In the table's plane: the depth axis is the noisy one and the device slides
            # on the table, so a move shows here. The table is this plane, turned.
            dev = float(np.linalg.norm((tips - mean)[:, [0, 2]], axis=1).max() * 1000.0)
            row["tip_mean"] = [f"{v:.6f}" for v in mean]
            row["tip_std"] = [f"{v:.3f}" for v in std]
            row["dev"] = f"{dev:.3f}"
        if c["table"]:
            table_mean = np.mean(c["table"], axis=0)
            row["table"] = [f"{v:.3f}" for v in table_mean]
            row["offset"] = [f"{v:.3f}" for v in table_mean - np.array(c["expected"])]
        if not reason and dev is not None and dev > c["still_mm"]:
            reason = "moved"
        accepted = not reason
        self._accepted += int(accepted)
        ns = c["sensor_ns"]
        fps = (len(ns) - 1) * 1e9 / (ns[-1] - ns[0]) if len(ns) > 1 and ns[-1] > ns[0] else 0.0
        # From the first frame's stamp to the last's: a pulse between captures is in
        # sync_events.msgpack and belongs to no capture.
        inside = [e for e in self._recorder.sync.events() if ns and ns[0] <= e[0] <= ns[-1]]
        first_rise = next((e[0] for e in inside if e[1]), "")
        phase = self._phase()[0]
        self._targets.writerow([
            c["target"], c["attempt"], c["row"], c["col"], *c["expected"],
            int(accepted), reason, c["ok"], c["failed"], f"{fps:.1f}",
            f"{c['started'] or 0:.6f}", f"{time.time():.6f}",
            ns[0] if ns else "", ns[-1] if ns else "", len(inside), first_rise,
            f"{phase.phase_us:.1f}" if phase is not None else "",
            *row["tip_mean"], *row["tip_std"], *row["table"], *row["offset"], row["dev"],
        ])
        self._last = {"target": c["target"], "attempt": c["attempt"], "accepted": accepted,
                      "reason": reason, "frames_ok": c["ok"], "frames_failed": c["failed"],
                      "max_dev_mm": dev, "fps": round(fps, 1)}
        self._changed = True

    # ── Status ────────────────────────────────────────────────────────────────

    def poll(self, now: float) -> Optional[bytes]:
        """An EXPERIMENT_STATUS when something changed, and steadily during a run: a lost
        one must not leave the app waiting, so each repeats the last result."""
        running = self._state != IDLE
        if running and now >= self._next_phase:
            self._next_phase = now + PHASE_EVERY_S
            self._log_phase()
        if not self._changed and not (running and now >= self._next_status):
            return None
        self._changed = False
        self._next_status = now + STATUS_EVERY_S
        status = {"state": self._state, "last": self._last, "saved": self._saved}
        if self._capture is not None:
            status["capture"] = {"target": self._capture["target"],
                                 "attempt": self._capture["attempt"],
                                 "frames": self._capture["frames"],
                                 "ok": self._capture["ok"], "failed": self._capture["failed"]}
        return protocol.encode(protocol.EXPERIMENT_STATUS, json.dumps(status))

    def _log_phase(self) -> None:
        """One row of the run's phase log, on disk at once. Nothing while the cameras
        are down or frame sync is off. `nudged`: the alignment moved since the last row."""
        report, nudges = self._phase()
        if report is None:
            return
        nudged = int(nudges != self._nudges)
        self._nudges = nudges
        self._phase_file.write(msgpack.packb([
            time.monotonic_ns(), float(report.phase_us), float(report.jitter_us),
            float(report.drift_ppm), int(report.n), nudged,
        ]))
        self._phase_file.flush()


def _tags(ids) -> str:
    """The tag ids a camera found, as "1 3 7"."""
    return "" if ids is None else " ".join(str(int(i)) for i in np.ravel(ids))
