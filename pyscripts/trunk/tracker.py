"""Realtime trunk tracking: segmentation -> stereo shell -> ICP -> state machine.

`TrunkEngine` does the work, one frame pair at a time, with no threads of its
own. Two front ends feed it the newest pair and never block the caller:

* `TrunkProcess` — a separate process, for tracker.py. A thread is not enough:
  ICP is a Python loop of small numpy calls that holds the GIL, and the hand
  loop waiting on it dropped from 31 to 25 fps when measured, even with the
  trunk pinned to a core of its own. The pair crosses in shared memory at half
  resolution (what the engine works at), so a submit costs two resizes.
* `TrunkThread` — in-process, for trunk_live.py, which also wants the mask.

States
------
NO_NEUTRAL  nothing to compare against yet
CAPTURING   collecting the neutral pose; needs a visible, still torso
TRACKING    angles from neutral, each axis classed OK / WARN / COMPENSATING
OCCLUDED    the torso cannot be measured right now (no torso found, too few
            stereo points, or the registration did not converge)

Levels escalate only after holding for `dwell_s` and drop back with
`hysteresis_deg` of slack, so a reading sitting on a threshold does not flicker.
OCCLUDED is entered only after `occlusion_s` of consecutive failures; until then
the last good reading stands. `capture_result` is the outcome of the last
neutral capture ("ok" or why it failed) and a failed re-capture keeps the
previous neutral.
"""

import multiprocessing as mp
import os
import queue
import threading
import time
from dataclasses import dataclass, field

import cv2
import numpy as np

from .geometry import StereoShell, voxel_downsample
from .icp import Neutral, Registration, trunk_angles
from .segment import mask_iou, pick_subject

NO_NEUTRAL, CAPTURING, TRACKING, OCCLUDED = 0, 1, 2, 3
STATE_NAMES = ("NO_NEUTRAL", "CAPTURING", "TRACKING", "OCCLUDED")
OK, WARN, COMPENSATING = 0, 1, 2
LEVEL_NAMES = ("OK", "WARN", "COMPENSATING")
AXES = ("flexion", "lateral", "axial")

DEFAULTS = {
    "trunk_warn_deg": 8.0,         # scalar for every axis, or {"flexion": .., ...}
    "trunk_comp_deg": 15.0,
    "trunk_hysteresis_deg": 2.0,
    "trunk_dwell_s": 0.3,
    "trunk_occlusion_s": 0.3,
    "trunk_neutral_s": 2.0,
    "trunk_neutral_motion_m": 0.015,   # max centroid std over the capture
    "trunk_min_points": 250,           # voxels in a frame's shell cloud
    "trunk_cloud_points": 1500,        # per-frame cloud cap fed to ICP
    "trunk_neutral_points": 6000,
    "trunk_max_hz": 15.0,
    "trunk_lock_iou": 0.3,         # min overlap with the last mask to stay on the subject
    "trunk_lock_dist": 0.3,        # else: nearest person within this fraction of the image width
    "trunk_snapshot_w": 160,       # picker image width, px
    # Cores for the trunk worker. The prime core (7) is the measured choice on
    # this board: with the hand tracker on 4-7 it cost hand tracking 1-3 fps
    # (~33.5 -> 31-34) at 11-12 Hz of trunk updates. Little cores (0-3) kept
    # hand tracking but gave 2 Hz, and they are the game's. "" = no pin.
    "trunk_cpus": "7",
}


def _per_axis(value):
    if isinstance(value, dict):
        return np.array([float(value.get(a, 0.0)) for a in AXES])
    return np.full(3, float(value))


def _parse_cpus(spec):
    cores = set()
    for part in str(spec).split(","):
        if part.strip():
            a, _, b = part.partition("-")
            cores.update(range(int(a), int(b or a) + 1))
    return cores


@dataclass
class Snapshot:
    """What the subject picker shows: a small frame and one outline per person.

    `people[i]` is the polygon (snapshot pixels) of person i; `select(i)` locks
    onto that same person, whatever has moved since."""
    jpeg: bytes
    size: tuple                           # (w, h) of the image and polygons
    people: list                          # [[(x, y), ...], ...]
    locked: int = -1                      # index of the followed person, -1 = none


@dataclass
class TrunkStatus:
    state: int = NO_NEUTRAL
    level: int = OK                       # worst axis, TRACKING only
    levels: tuple = (OK, OK, OK)
    angles: tuple = (0.0, 0.0, 0.0)       # flexion, lateral, axial (deg)
    reason: str = ""                      # why OCCLUDED
    progress: float = 0.0                 # neutral capture, 0..1
    has_neutral: bool = False
    capture_result: str = ""              # "", "ok", or why the last capture failed
    npts: int = 0
    people: int = 0                       # torsos in the last frame
    locked: bool = False                  # following a picked subject, not the centre-most
    rms_mm: float = float("nan")
    how: str = ""                         # direct / odometry
    seq: int = 0
    hz: float = 0.0
    timing_ms: dict = field(default_factory=dict)

    @property
    def state_name(self):
        return STATE_NAMES[self.state]


class TrunkEngine:
    """The per-frame pipeline and state machine. Not thread-safe; one caller."""

    def __init__(self, K0, D0, K1, D1, R, T, size, settings=None):
        from .segment import TorsoSegmenter   # onnxruntime: only where it runs

        cfg = dict(DEFAULTS)
        cfg.update({k: v for k, v in (settings or {}).items() if k in DEFAULTS})
        self.cfg = cfg
        self.warn = _per_axis(cfg["trunk_warn_deg"])
        self.comp = _per_axis(cfg["trunk_comp_deg"])
        self.shell = StereoShell(K0, D0, K1, D1, R, T, size)
        self.seg = TorsoSegmenter()
        self._lock_mask = None            # the followed person's last mask; None = centre-most
        self._seen = None                 # (left image, [masks]) of the last frame
        self._offered = []                # the masks the last snapshot numbered
        self._by_position = False         # the lock last moved by position, not overlap
        self._people = 0
        self.rng = np.random.default_rng(0)
        self.last_view = None             # (left image, mask) of the last frame

        self._neutral = None
        self._reg = None
        self._capture = None              # (t0, [clouds], [centroids], frames_seen)
        self._capture_result = ""
        self._fail_since = None
        self._pending = np.zeros(3, int)  # level each axis is trying to reach
        self._pending_since = np.zeros(3)
        self._levels = np.zeros(3, int)
        self._last = None                 # last good (angles, rms, how)
        self._seq = 0
        self._rate = []

    def small_pair(self, raw0, raw1):
        """Sensor-resolution stream0/stream1 -> (left, right) at working size."""
        left, right = self.shell.reference(raw0, raw1)
        return (cv2.resize(left, self.shell.size, interpolation=cv2.INTER_AREA),
                cv2.resize(right, self.shell.size, interpolation=cv2.INTER_AREA))

    def _cloud(self, ls, rs, timing):
        t1 = time.perf_counter()
        masks = self.seg.instances(ls, self.shell.size)
        t2 = time.perf_counter()
        timing["seg"] = (t2 - t1) * 1e3
        self._seen, self._people = (ls, masks), len(masks)
        mask, _ = pick_subject(masks, self._lock_mask, self.cfg["trunk_lock_iou"],
                               self.cfg["trunk_lock_dist"])
        if mask is not None and self._lock_mask is not None and not self._by_position and \
                mask_iou(mask, self._lock_mask) < self.cfg["trunk_lock_iou"]:
            print("[TRUNK] subject re-acquired by position", flush=True)
        self._by_position = (mask is not None and self._lock_mask is not None and
                             mask_iou(mask, self._lock_mask) < self.cfg["trunk_lock_iou"])
        self.last_view = (ls, mask)
        if mask is None:
            return None, "no_torso" if self._lock_mask is None or not masks else "lost_subject"
        if self._lock_mask is not None:
            self._lock_mask = mask       # follow them as they move
        pts = self.shell.shell(ls, rs, mask)
        cloud = voxel_downsample(pts, max_pts=int(self.cfg["trunk_cloud_points"]),
                                 rng=self.rng)
        timing["stereo"] = (time.perf_counter() - t2) * 1e3
        if len(cloud) < self.cfg["trunk_min_points"]:
            return cloud, "small_cloud"
        return cloud, ""

    def process(self, ls, rs, start_capture=False):
        """One (left, right) pair at working size -> TrunkStatus."""
        now = time.perf_counter()
        timing = {}
        self._seq += 1
        self._rate = [t for t in self._rate if now - t < 2.0] + [now]
        hz = (len(self._rate) - 1) / max(now - self._rate[0], 1e-6) if len(self._rate) > 1 else 0.0

        cloud, bad = self._cloud(ls, rs, timing)
        npts = 0 if cloud is None else len(cloud)

        if start_capture:
            self._capture = (now, [], [], 0)
        st = TrunkStatus(npts=npts, seq=self._seq, hz=hz, timing_ms=timing,
                         people=self._people, locked=self._lock_mask is not None)
        if self._capture is not None and self._capture_step(now, cloud, bad, st):
            pass
        elif self._neutral is None:
            st.state = NO_NEUTRAL
        else:
            self._track(now, cloud, bad, timing, st)
        st.has_neutral = self._neutral is not None
        st.capture_result = self._capture_result
        return st

    def snapshot(self):
        """The last frame with each person outlined, or None before the first.

        The people are numbered here and kept, so a `select` that arrives a
        moment later means the person the user saw, not whoever is 0 by then."""
        if self._seen is None:
            return None
        ls, masks = self._seen
        self._offered = masks
        w = int(self.cfg["trunk_snapshot_w"])
        h = max(1, round(ls.shape[0] * w / ls.shape[1]))
        small = cv2.resize(ls, (w, h), interpolation=cv2.INTER_AREA)
        ok, jpeg = cv2.imencode(".jpg", small, [cv2.IMWRITE_JPEG_QUALITY, 60])
        people, followed = [], -1
        for i, m in enumerate(masks):
            ms = cv2.resize(m, (w, h), interpolation=cv2.INTER_NEAREST)
            cnts, _ = cv2.findContours(ms, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
            if not cnts:
                people.append([])
                continue
            c = cv2.approxPolyDP(max(cnts, key=cv2.contourArea), 1.0, True)
            people.append([(int(x), int(y)) for x, y in c.reshape(-1, 2)])
            if self._lock_mask is not None and followed < 0 and np.array_equal(m, self._lock_mask):
                followed = i
        return Snapshot(jpeg.tobytes() if ok else b"", (w, h), people, followed)

    def select(self, index):
        """Follow person `index` of the last snapshot; -1 goes back to the centre-most.

        The neutral is one torso's cloud, so picking somebody else drops it (the
        state goes to NO_NEUTRAL until the next capture); picking the person
        already followed keeps it."""
        if index is None or index < 0:
            new = None
        elif index < len(self._offered):
            new = self._offered[index]
        else:
            return False
        cur = self._lock_mask if self._lock_mask is not None else (
            self.last_view[1] if self.last_view else None)
        if new is not None and cur is not None and \
                mask_iou(new, cur) >= self.cfg["trunk_lock_iou"]:
            self._lock_mask = new          # same person: keep the neutral
            return True
        if new is None and self._lock_mask is None:
            return True
        self._lock_mask = new
        if self._neutral is not None or self._capture is not None:
            print("[TRUNK] subject changed: neutral cleared", flush=True)
        self._neutral = self._reg = self._capture = None
        self._fail_since, self._last = None, None
        self._levels[:] = OK
        self._pending[:] = OK
        self._capture_result = ""
        return True

    def _track(self, now, cloud, bad, timing, st):
        if bad:
            R_body, info = None, dict(how=bad)
        else:
            t = time.perf_counter()
            R_body, info = self._reg.step(cloud)
            timing["icp"] = (time.perf_counter() - t) * 1e3
        if R_body is not None:
            self._fail_since = None
            angles = trunk_angles(R_body @ self._neutral.R_neu, self._neutral.R_neu)
            self._last = (angles, info["rms"] * 1e3, info["how"])
            self._classify(np.array(angles), now)
        elif self._fail_since is None:
            self._fail_since = now

        if self._fail_since is not None and (
                now - self._fail_since >= self.cfg["trunk_occlusion_s"] or self._last is None):
            st.state, st.reason = OCCLUDED, info["how"]
            self._levels[:] = OK
            self._pending[:] = OK
            return
        st.state = TRACKING
        st.angles, st.rms_mm, st.how = self._last
        st.levels = tuple(int(v) for v in self._levels)
        st.level = int(self._levels.max())

    def _classify(self, angles, now):
        a = np.abs(angles)
        h = self.cfg["trunk_hysteresis_deg"]
        for i in range(3):
            cur = self._levels[i]
            # where the reading belongs, with slack on the way down
            target = COMPENSATING if a[i] >= self.comp[i] else WARN if a[i] >= self.warn[i] else OK
            if target < cur:
                down_to = (COMPENSATING if a[i] >= self.comp[i] - h
                           else WARN if a[i] >= self.warn[i] - h else OK)
                self._levels[i] = min(cur, down_to)
                self._pending[i] = self._levels[i]
                continue
            if target == cur:
                self._pending[i] = cur
                continue
            if self._pending[i] != target:
                self._pending[i], self._pending_since[i] = target, now
            if now - self._pending_since[i] >= self.cfg["trunk_dwell_s"]:
                self._levels[i] = target

    def _capture_step(self, now, cloud, bad, st):
        """Advance a neutral capture. True while it is still running."""
        t0, clouds, cents, seen = self._capture
        seen += 1
        if not bad:
            clouds.append(cloud)
            cents.append(cloud.mean(axis=0))
        self._capture = (t0, clouds, cents, seen)
        dur = self.cfg["trunk_neutral_s"]
        if now - t0 < dur:
            st.state, st.progress = CAPTURING, (now - t0) / dur
            return True

        self._capture = None
        motion = float(np.linalg.norm(np.std(cents, axis=0))) if cents else float("nan")
        if len(clouds) < max(3, 0.6 * seen):
            self._capture_result = "not_visible"
        elif motion > self.cfg["trunk_neutral_motion_m"]:
            self._capture_result = "moving"
        else:
            pooled = voxel_downsample(np.concatenate(clouds),
                                      max_pts=int(self.cfg["trunk_neutral_points"]),
                                      rng=self.rng)
            self._neutral = Neutral(pooled)
            self._reg = Registration(self._neutral)
            self._fail_since, self._last = None, None
            self._levels[:] = OK
            self._pending[:] = OK
            self._capture_result = "ok"
            print(f"[TRUNK] neutral captured: {len(pooled)} pts from "
                  f"{len(clouds)}/{seen} frames, centroid std {motion * 1e3:.0f} mm", flush=True)
            return False
        print(f"[TRUNK] neutral capture failed: {self._capture_result} "
              f"({len(clouds)}/{seen} usable frames, centroid std {motion * 1e3:.0f} mm)",
              flush=True)
        return False


def _pin(cpus, native_id=0):
    cores = _parse_cpus(cpus)
    if not cores:
        return False
    try:
        os.sched_setaffinity(native_id, cores)
        print(f"[TRUNK] worker on cores {sorted(cores)}", flush=True)
    except OSError as exc:
        print(f"[TRUNK] could not pin to {cpus}: {exc}", flush=True)
    return True


def _throttle(cfg, last):
    min_dt = 1.0 / cfg["trunk_max_hz"] if cfg["trunk_max_hz"] > 0 else 0.0
    wait = min_dt - (time.perf_counter() - last)
    if wait > 0:
        time.sleep(wait)
    return time.perf_counter()


class TrunkThread:
    """The engine on a thread of this process. For tools; see TrunkProcess."""

    def __init__(self, K0, D0, K1, D1, R, T, size, settings=None):
        self.engine = TrunkEngine(K0, D0, K1, D1, R, T, size, settings)
        self.shell = self.engine.shell
        self._lock = threading.Condition()
        self._pair = None
        self._stop = False
        self._capture_requested = False
        self._status = TrunkStatus()
        self._thread = threading.Thread(target=self._run, name="trunk", daemon=True)

    @property
    def last_view(self):
        return self.engine.last_view

    def start(self):
        self._thread.start()
        return self

    def stop(self):
        with self._lock:
            self._stop = True
            self._lock.notify()
        self._thread.join(timeout=2.0)

    def submit(self, raw0, raw1):
        with self._lock:
            self._pair = (raw0, raw1)
            self._lock.notify()

    def capture_neutral(self):
        with self._lock:
            self._capture_requested = True

    def snapshot(self):
        with self._lock:
            return self.engine.snapshot()

    def select(self, index):
        with self._lock:
            return self.engine.select(index)

    def status(self) -> TrunkStatus:
        with self._lock:
            return self._status

    def _run(self):
        cfg = self.engine.cfg
        if _pin(cfg["trunk_cpus"], threading.get_native_id()):
            cv2.setNumThreads(1)   # OpenCV's pool would run on the caller's cores
        last = 0.0
        while True:
            with self._lock:
                while self._pair is None and not self._stop:
                    self._lock.wait(0.5)
                if self._stop:
                    return
                pair, self._pair = self._pair, None
                capture, self._capture_requested = self._capture_requested, False
            last = _throttle(cfg, last)
            try:
                st = self.engine.process(*self.engine.small_pair(*pair), capture)
            except Exception as exc:  # keep tracking alive; report it
                print(f"[TRUNK] frame failed: {exc!r}")
                continue
            with self._lock:
                self._status = st


def _process_main(shm_name, shape, lock, seq, new, cmds, out, calib, settings):
    """The trunk process: pin, build the engine, then take the newest pair."""
    from multiprocessing import shared_memory

    cfg = dict(DEFAULTS)
    cfg.update({k: v for k, v in settings.items() if k in DEFAULTS})
    if _pin(cfg["trunk_cpus"]):
        cv2.setNumThreads(1)
    try:
        engine = TrunkEngine(*calib, settings)
    except Exception as exc:
        out.put(exc)
        return
    out.put("ready")
    shm = shared_memory.SharedMemory(name=shm_name)
    buf = np.ndarray((2, *shape), dtype=np.uint8, buffer=shm.buf)
    last_seq, last = 0, 0.0
    capture = False
    try:
        while True:
            while True:
                try:
                    cmd = cmds.get_nowait()
                except queue.Empty:
                    break
                if cmd == "stop":
                    return
                if cmd == "neutral":
                    capture = True
                elif cmd == "snapshot":
                    snap = engine.snapshot()
                    if snap is not None:
                        out.put(snap)
                elif isinstance(cmd, tuple) and cmd[0] == "select":
                    engine.select(cmd[1])
            if not new.wait(0.5):
                continue
            last = _throttle(cfg, last)
            with lock:
                new.clear()
                if seq.value == last_seq:
                    continue
                last_seq = seq.value
                ls, rs = buf[0].copy(), buf[1].copy()
            try:
                st = engine.process(ls, rs, capture)
            except Exception as exc:
                print(f"[TRUNK] frame failed: {exc!r}", flush=True)
                continue
            capture = False
            st.timing_ms = {}               # not worth pickling every frame
            out.put(st)
    finally:
        del buf
        shm.close()


class TrunkProcess:
    """The engine in its own process, fed through shared memory.

    Same interface as TrunkThread. Raises from the constructor if the engine
    cannot start (no NPU, no model), so the caller can carry on without it."""

    def __init__(self, K0, D0, K1, D1, R, T, size, settings=None, timeout_s=60.0):
        from multiprocessing import shared_memory

        settings = dict(settings or {})
        # Geometry decided here too, so submit() can halve the frames itself.
        layout = StereoShell(K0, D0, K1, D1, R, T, size)
        self.swap, self.size = layout.swap, layout.size
        w, h = self.size
        self._shm = shared_memory.SharedMemory(create=True, size=2 * w * h)
        self._buf = np.ndarray((2, h, w), dtype=np.uint8, buffer=self._shm.buf)
        ctx = mp.get_context("spawn")
        self._lock, self._new = ctx.Lock(), ctx.Event()
        self._seq = ctx.Value("Q", 0, lock=False)
        self._cmds, self._out = ctx.Queue(), ctx.Queue()
        self._status = TrunkStatus()
        self._snapshot = None
        # The child imports numpy afresh: keep its BLAS pool to one thread so
        # nothing it does wakes threads on the hand tracker's cores.
        os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
        self._proc = ctx.Process(
            target=_process_main, name="trunk", daemon=True,
            args=(self._shm.name, (h, w), self._lock, self._seq, self._new,
                  self._cmds, self._out, (K0, D0, K1, D1, R, T, size), settings))
        self._proc.start()
        try:
            first = self._out.get(timeout=timeout_s)
        except queue.Empty:
            self.stop()
            raise RuntimeError("trunk process did not start")
        if isinstance(first, Exception):
            self.stop()
            raise first

    def start(self):
        return self

    def submit(self, raw0, raw1):
        """Newest stream0/stream1 pair at sensor resolution."""
        left, right = (raw1, raw0) if self.swap else (raw0, raw1)
        ls = cv2.resize(left, self.size, interpolation=cv2.INTER_AREA)
        rs = cv2.resize(right, self.size, interpolation=cv2.INTER_AREA)
        with self._lock:
            self._buf[0], self._buf[1] = ls, rs
            self._seq.value += 1
            self._new.set()

    def capture_neutral(self):
        self._cmds.put("neutral")

    def request_snapshot(self):
        """Ask for the picker image; it arrives through `take_snapshot`."""
        self._cmds.put("snapshot")

    def select(self, index):
        """Follow person `index` of the last snapshot; -1 = centre-most again."""
        self._cmds.put(("select", int(index)))

    def take_snapshot(self):
        """The newest snapshot not yet taken, or None."""
        self.status()
        snap, self._snapshot = self._snapshot, None
        return snap

    def status(self) -> TrunkStatus:
        while True:
            try:
                item = self._out.get_nowait()
            except queue.Empty:
                return self._status
            if isinstance(item, TrunkStatus):
                self._status = item
            elif isinstance(item, Snapshot):
                self._snapshot = item

    def stop(self):
        try:
            self._cmds.put("stop")
            self._proc.join(timeout=3.0)
            if self._proc.is_alive():
                self._proc.terminate()
        finally:
            self._buf = None
            self._shm.close()
            self._shm.unlink()
