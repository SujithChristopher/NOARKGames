"""Measuring the device's tags from the app (Settings > Calibration), for when one has
been moved, swapped or added: a take, a solve, a review, and only then the new geometry.

The tracker owns the cameras, so the take is its own frames: corners only, about 10
pairs a second, in the same exposure, image pipeline and corner refinement it tracks
with. The solve takes minutes, so it runs as its own process (body_solve.py) and the
link keeps answering. Nothing replaces rigidbody.toml until the app says save, and
what it replaced can be put back.

One tag is fixed: `[tip] tag` in device.toml. The tracked point is measured from it,
so it is what keeps that point valid while everything else moves. It is also the frame
the geometry is solved in, so "moved" below always means relative to that tag.

    idle -> capturing -> solving -> review -> idle
                                 -> failed
"""

import json
import os
import shutil
import subprocess
import sys
import time
from collections.abc import Callable
from datetime import datetime
from pathlib import Path
from typing import Optional

import numpy as np
import toml

import protocol
from rigid_body import CornerCollector, RigidBody, load_device

IDLE, CAPTURING, SOLVING, REVIEW, FAILED = "idle", "capturing", "solving", "review", "failed"

TAKE_S = 60.0
# The solve's time goes with the views it is given and it took 98 s for 600 pairs on the
# board. Neighbouring frames add little: the tracker's 60 a second would take ten minutes.
KEEP_EVERY_S = 0.1
STATUS_EVERY_S = 0.5
# A normal take is under 2 minutes. Past this something is wrong with it.
SOLVE_TIMEOUT_S = 600.0
# Sightings of two tags together before the list calls them joined. The solve needs 20,
# from half of the frames (the other half checks it), and rejects some of those.
JOINED_PAIRS = 60
# A false detection turns up for a frame or two: not worth a row in the list.
SEEN_TO_LIST = 5

_SOLVER = Path(__file__).with_name("body_solve.py")


class BodyTake:
    def __init__(self, rig_path, device_path, stereo_path,
                 on_change: Optional[Callable[[], None]] = None,
                 refine: Callable[[], str] = lambda: "contour", isp: Optional[str] = None,
                 takes_dir=None, take_s: float = TAKE_S,
                 solve_timeout_s: float = SOLVE_TIMEOUT_S, python: str = sys.executable) -> None:
        self.rig_path = Path(rig_path)
        self.device_path = Path(device_path)
        self.stereo_path = Path(stereo_path)
        self.takes_dir = Path(takes_dir) if takes_dir else self.rig_path.parent / "takes"
        self._on_change = on_change or (lambda: None)
        self._refine = refine
        self._isp = isp
        self.take_s = take_s
        self.solve_timeout_s = solve_timeout_s
        self._python = python
        device = load_device(self.device_path)
        self.anchor = device["tip_tag"] if device["tip_tag"] is not None else (device["reference_id"] or 1)

        self.state = IDLE
        self.reason = ""
        self._report = None
        self._process: Optional[subprocess.Popen] = None
        self._solve_started = 0.0
        self._candidate = self.takes_dir / "candidate.toml"
        self._report_path = self.takes_dir / "candidate.json"
        self._log_path = self.takes_dir / "solve.log"
        self._changed = False
        self._next_status = 0.0
        self._clear_take()
        self._current = self._read_current()

    @property
    def capturing(self) -> bool:
        return self.state == CAPTURING

    # ── From the app ──────────────────────────────────────────────────────────

    def command(self, text: str, now: Optional[float] = None) -> tuple[bool, str]:
        """One BODY command -> (ok, detail) for its ACK."""
        now = time.time() if now is None else now
        actions = {"status": self._ask_status, "start": self._start, "finish": self._finish,
                   "cancel": self._cancel, "save": self._save, "restore": self._restore}
        if text not in actions:
            return False, f"unknown command: {text}"
        return actions[text](now)

    def link_lost(self) -> None:
        """The app went. A take needs someone holding the device, so it ends; a solve
        does not, and its answer waits for the app to come back."""
        if self.capturing:
            self._cancel(time.time())

    def close(self) -> None:
        """The tracker is stopping."""
        self._stop_solver()

    def _ask_status(self, _now: float) -> tuple[bool, str]:
        self._changed = True
        return True, ""

    def _start(self, _now: float) -> tuple[bool, str]:
        if self.state in (CAPTURING, SOLVING):
            return False, f"already {self.state}"
        self._clear_take()
        self._report = None
        self.reason = ""
        self._set_state(CAPTURING)
        return True, "started"

    def _finish(self, now: float) -> tuple[bool, str]:
        if not self.capturing:
            return False, "no take to finish"
        if not self._seen.get(self.anchor):
            self._fail(f"Tag {self.anchor} was never seen. The hand position is measured "
                       "from it, so the take needs it.")
            return True, "failed"
        try:
            self._start_solver(now)
        except OSError as exc:
            self._fail(f"Could not start the solve: {exc}")
            return True, "failed"
        self._set_state(SOLVING)
        return True, "solving"

    def _cancel(self, _now: float) -> tuple[bool, str]:
        self._stop_solver()
        self._clear_take()
        self._report = None
        self.reason = ""
        self._set_state(IDLE)
        return True, "cancelled"

    def _save(self, _now: float) -> tuple[bool, str]:
        if self.state != REVIEW or not self._report or not self._report["ok"]:
            return False, "nothing to save"
        try:
            RigidBody.load(self._candidate)   # what the tracker is about to load
            self.takes_dir.mkdir(parents=True, exist_ok=True)
            if self.rig_path.exists():
                shutil.copy2(self.rig_path, self.takes_dir / f"rigidbody_{_stamp()}.toml")
            os.replace(self._candidate, self.rig_path)
        except (OSError, ValueError, KeyError) as exc:
            return False, f"could not save: {exc}"
        _record_tag_ids(self.device_path, [row["id"] for row in self._report["tags"]])
        self._report = None
        self._new_rig()
        return True, "saved"

    def _restore(self, _now: float) -> tuple[bool, str]:
        if self.state not in (IDLE, FAILED):
            return False, f"not while {self.state}"
        backups = self._backups()
        if not backups:
            return False, "nothing to restore"
        try:
            os.replace(backups[-1], self.rig_path)
        except OSError as exc:
            return False, f"could not restore: {exc}"
        self._new_rig()
        return True, "restored"

    def _new_rig(self) -> None:
        self._current = self._read_current()
        self._set_state(IDLE)
        self._on_change()

    # ── From the tracking loop ────────────────────────────────────────────────

    def frame(self, now: float, det0: dict, det1: dict, paired: bool, image: np.ndarray) -> None:
        """One tracked pair while capturing: {tag id: (4, 2) corners} per camera. The
        take's clock starts here, because the cameras may still be coming up."""
        if not self.capturing:
            return
        if self._ends_at is None:
            self._ends_at = now + self.take_s
        if now < self._next_keep:
            return
        behind = now - self._next_keep >= KEEP_EVERY_S
        self._next_keep = (now if behind else self._next_keep) + KEEP_EVERY_S
        self._collector.add_pair(det0, det1, paired)
        self._level = float(image[::8, ::8].mean())
        sizes = []
        for found in (det0, det1):
            ids = sorted(found)
            for i, a in enumerate(ids):
                self._seen[a] = self._seen.get(a, 0) + 1
                sizes.append(float(np.linalg.norm(found[a] - np.roll(found[a], -1, axis=0), axis=1).mean()))
                for b in ids[i + 1:]:
                    self._together[(a, b)] = self._together.get((a, b), 0) + 1
        if sizes:
            self._tag_px = float(np.median(sizes))

    def poll(self, now: float) -> Optional[bytes]:
        """Once a loop, with or without cameras: moves the job along, and gives the
        BODY_STATUS now due, if one is."""
        if self.capturing and self._ends_at is not None and now >= self._ends_at:
            self._finish(now)
        if self.state == SOLVING:
            self._check_solver(now)
        due = self.state in (CAPTURING, SOLVING) and now >= self._next_status
        if not due and not self._changed:
            return None
        self._changed = False
        self._next_status = now + STATUS_EVERY_S
        return protocol.encode(protocol.BODY_STATUS, json.dumps(self._status(now), separators=(",", ":")))

    # ── The take ──────────────────────────────────────────────────────────────

    def _clear_take(self) -> None:
        self._collector = CornerCollector()
        self._ends_at = None
        self._next_keep = 0.0
        self._seen = {}
        self._together = {}
        self._level = None
        self._tag_px = None

    def _joined(self) -> set:
        """Tags that reach the fixed tag through others seen beside them."""
        joined = {self.anchor}
        grew = True
        while grew:
            grew = False
            for (a, b), count in self._together.items():
                if count >= JOINED_PAIRS and (a in joined) != (b in joined):
                    joined |= {a, b}
                    grew = True
        return joined

    def _status(self, now: float) -> dict:
        status = {"state": self.state, "anchor": self.anchor, "current": self._current}
        if self.state == CAPTURING:
            joined = self._joined()
            listed = {self.anchor, *self._current["tags"]}
            listed |= {mid for mid, count in self._seen.items() if count >= SEEN_TO_LIST}
            status["capture"] = {
                "left": None if self._ends_at is None else round(max(self._ends_at - now, 0.0), 1),
                "frames": len(self._collector.paired),
                "level": None if self._level is None else round(self._level),
                "tag_px": None if self._tag_px is None else round(self._tag_px),
                "tags": [{"id": mid, "seen": self._seen.get(mid, 0), "joined": mid in joined and mid in self._seen}
                         for mid in sorted(listed)],
            }
        elif self.state == SOLVING:
            status["elapsed"] = round(now - self._solve_started)
        elif self.state == REVIEW:
            status["result"] = self._report
        elif self.state == FAILED:
            status["reason"] = self.reason
        return status

    def _read_current(self) -> dict:
        """What the tracker is using now."""
        body = RigidBody.load(self.rig_path)
        current = {"tags": [], "can_restore": bool(self._backups())}
        if body is not None:
            agreement = body.meta.get("agreement_median_mm")
            current.update(tags=list(body.marker_ids), created=body.meta.get("created", ""),
                           agreement_mm=None if agreement is None else round(agreement, 1))
        return current

    def _backups(self) -> list:
        return sorted(self.takes_dir.glob("rigidbody_*.toml"))

    def _set_state(self, state: str) -> None:
        self.state = state
        self._changed = True

    def _fail(self, reason: str) -> None:
        self.reason = reason
        self._set_state(FAILED)

    # ── The solve ─────────────────────────────────────────────────────────────

    def _start_solver(self, now: float) -> None:
        self.takes_dir.mkdir(parents=True, exist_ok=True)
        take = self.takes_dir / f"corners_{_stamp()}.npz"
        self._collector.save(take)   # kept: a take is someone's time, and re-solving one is free
        self._candidate.unlink(missing_ok=True)
        self._report_path.unlink(missing_ok=True)
        command = ["nice", "-n", "15", self._python, str(_SOLVER),
                   "--take", str(take), "--out", str(self._candidate), "--report", str(self._report_path),
                   "--device", str(self.device_path), "--stereo", str(self.stereo_path),
                   "--previous", str(self.rig_path), "--refine", self._refine(), "--isp", self._isp or "raw"]
        with self._log_path.open("w", encoding="utf-8") as log:
            self._process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        self._solve_started = now

    def _stop_solver(self) -> None:
        if self._process is not None and self._process.poll() is None:
            self._process.kill()
            self._process.wait()
        self._process = None

    def _check_solver(self, now: float) -> None:
        if self._process.poll() is None:
            if now - self._solve_started > self.solve_timeout_s:
                self._stop_solver()
                self._fail(f"The solve took too long (over {self.solve_timeout_s / 60:.0f} min). "
                           "Try again, and check nothing else with tags is in view.")
            return
        self._process = None
        try:
            self._report = json.loads(self._report_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self._fail(f"The solve stopped without an answer. {self._last_log_line()}".strip())
            return
        self._set_state(REVIEW)

    def _last_log_line(self) -> str:
        try:
            lines = self._log_path.read_text(encoding="utf-8", errors="replace").strip().splitlines()
        except OSError:
            return ""
        return lines[-1][:200] if lines else ""


def _stamp() -> str:
    return datetime.now().strftime("%Y%m%d_%H%M%S")


def _record_tag_ids(path: Path, ids: list) -> None:
    """Add what this take found to device.toml's list, which rigidbody_calib.py filters
    by: a new tag would otherwise be thrown away by its next take. Edited as text, as
    record_tip does there, because the comments are most of that file's value. A tag in
    the list and not on the device does no harm, so none is taken off."""
    try:
        wanted = sorted(set(load_device(path)["tag_ids"]) | set(ids))
        lines = path.read_text(encoding="utf-8").splitlines()
        in_device = False
        for index, line in enumerate(lines):
            stripped = line.strip()
            if stripped.startswith("["):
                in_device = stripped == "[device]"
            elif in_device and stripped.startswith("tag_ids"):
                lines[index] = f"tag_ids = {wanted}"
                break
        text = "\n".join(lines) + "\n"
        if toml.loads(text)["device"]["tag_ids"] != wanted:
            raise ValueError("tag_ids is not one line")
        temporary = path.with_name(path.name + ".tmp")
        temporary.write_text(text, encoding="utf-8")
        os.replace(temporary, path)
    except (OSError, ValueError, KeyError) as exc:
        print(f"[RIG] Could not add tags {ids} to {path}: {exc}", flush=True)
