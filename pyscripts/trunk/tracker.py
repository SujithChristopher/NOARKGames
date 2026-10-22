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
            (trunk_reference "model": from minisam3d's own frame, which
            stands in for the neutral, so there is no NO_NEUTRAL / CAPTURING)
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
from .icp import ROT_MAX_DEG, Neutral, Registration, rot_deg, trunk_angles
from .pose import RZ, TRUNK_JOINTS, mean_rotation
from .pose import anatomical_frame as anatomical_frame_pose
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
    # How the rotation is measured: "icp" (stereo shell registered to the
    # neutral shell) or a minisam3d model, "msam_r18" / "msam_v3rot" (pose.py).
    # Switchable live with CONFIG trunk_method=<value>.
    "trunk_method": "icp",
    # What the angles are measured from: "neutral" (a captured neutral pose) or,
    # minisam3d only, "model" (the model's own frame: upright and squarely
    # facing a level camera = 0; no capture, camera tilt reads as an offset).
    # Switchable live with CONFIG trunk_reference=<value>.
    "trunk_reference": "neutral",
    # Thresholds in the model frame, which reads camera tilt and the model's
    # own bias as posture: wider than the neutral ones above.
    "trunk_model_warn_deg": 15.0,
    "trunk_model_comp_deg": 25.0,
    # Camera mounted upside down: true / false / "auto" (whichever way up
    # trunk_seg finds a torso). trunk_seg and the student only work upright.
    "trunk_rot180": "auto",
    # neck + shoulders heatmap confidence, per model (or one number for all):
    # under min_conf the frame is not used (held, then OCCLUDED); under
    # doubt_conf it is used but marked uncertain. Measured 2026-10-21, r18
    # seated: normal tracking p5 2.9 / median 3.9, and every stretch that read
    # 5-10 deg off while the subject sat still (an arm or object in front) was
    # under 2.3. v3rot runs lower: p5 0.15 / median 2.5.
    "trunk_msam_min_conf": {"msam_r18": 2.5, "msam_v3rot": 1.0},
    "trunk_msam_doubt_conf": {"msam_r18": 2.9, "msam_v3rot": 1.5},
    # OCCLUDED this long (the subject left, or turned away) drops the neutral:
    # they rarely sit back down the same way (+8.5 deg flexion measured).
    "trunk_reneutral_s": 10.0,
    # p90 of the trunk rotation's spread about its mean over a neutral capture.
    # The max let one outlier frame reject a still subject (r18 jitters ~0.8 deg
    # frame to frame).
    "trunk_msam_neutral_deg": 4.0,
    # Once a second while tracking, a journal line with the angles next to the
    # rotation in camera axes (x right, y down, z forward), to tell an axis
    # leaking between flexion / lateral / axial in the split from the model.
    "trunk_debug": False,
    # Cores for the trunk worker. The prime core (7) is the measured choice on
    # this board: with the hand tracker on 4-7 it cost hand tracking 1-3 fps
    # (~33.5 -> 31-34) at 11-12 Hz of trunk updates. Little cores (0-3) kept
    # hand tracking but gave 2 Hz, and they are the game's. "" = no pin.
    "trunk_cpus": "7",
}


@dataclass
class PoseNeutral:
    """minisam3d's neutral: the trunk rotation and anatomical frame, camera axes."""
    R_trunk: np.ndarray
    R_neu: np.ndarray


# The anatomical frame (lateral = patient's left, up, anterior) of someone
# upright and squarely facing the camera, in camera axes (x right, y down, z forward).
CAM_FRAME = np.array([[1.0, 0, 0], [0, -1.0, 0], [0, 0, -1.0]]).T


# minisam3d's trunk rotation of someone upright and squarely facing a level
# camera: the student predicts MHR global joint rotations (in camera axes), which
# carry c_spine3's bind orientation, so the rest pose is not identity but this
# axis permutation. Measured 2026-10-22 (r18, seated, CAM_FRAME F^T R from the
# model's own joints): within ~5 deg of it on every frame, the rest being the
# segment's tilt against the neck-hip line plus noise.
MODEL_REST = np.array([[0.0, 0, -1], [-1, 0, 0], [0, 1, 0]])


def model_frame(rot180, zero=None):
    """trunk_reference "model": minisam3d's own frame as the neutral, i.e. its
    rest pose upright facing a level camera, or `zero` (a rotation set with
    "Set zero") in place of that rest pose; the axes stay the camera's either
    way. Upside down, PoseTrunk has already turned the rotations into the
    physical camera's axes, so the reference turns with them."""
    R = RZ if rot180 else np.eye(3)
    return PoseNeutral(R @ MODEL_REST if zero is None else zero, R @ CAM_FRAME)


def _log_pose_frame(F, conf):
    """How the anatomical frame built from the neutral joints sits against the
    camera's (lateral +x, up -y, anterior -z) and how sure the joints were: a
    badly placed axis moves one movement into another angle."""
    from .pose import J

    cam = CAM_FRAME
    off = [float(np.degrees(np.arccos(np.clip(F[:, i] @ cam[:, i], -1, 1)))) for i in range(3)]
    print(f"[TRUNK] neutral frame vs camera: lateral {off[0]:.0f} deg, up {off[1]:.0f} deg, "
          f"anterior {off[2]:.0f} deg; conf neck {conf[J['neck']]:.1f} "
          f"shoulders {conf[J['left_shoulder']]:.1f}/{conf[J['right_shoulder']]:.1f} "
          f"hips {conf[J['left_hip']]:.1f}/{conf[J['right_hip']]:.1f}", flush=True)


def _for_method(value, method):
    """A setting given per trunk method, or one number for all."""
    if isinstance(value, dict):
        return float(value.get(method, 0.0))
    return float(value)


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
    how: str = ""                         # direct / odometry (of the last good fit)
    # This frame's own quality, for working out why a reading was bad:
    q_how: str = ""                       # direct / odometry / failed / gated / no_torso /
                                          # small_cloud / lost_subject
    q_rms_mm: float = float("nan")        # ICP residual of this frame's fit
    q_frac: float = float("nan")          # share of the frame's cloud that matched
    cam_rot: tuple = (float("nan"),) * 3  # neutral -> now as a rotation vector, camera axes, deg
    raw_pts: int = 0                      # shell points before the cloud cap
    mask_px: int = 0                      # torso mask area (working-size pixels)
    held: bool = False                    # angles are the last good ones, not this frame's
    doubt: str = ""                       # used but less trusted: low_conf / arm_over_chest
    seq: int = 0
    hz: float = 0.0                       # trunk updates per second, last 2 s
    method: str = ""                      # icp / msam_r18 / msam_v3rot, what measured it
    reference: str = "neutral"            # neutral / model: what the angles are from
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
        self.model_warn = _per_axis(cfg["trunk_model_warn_deg"])
        self.model_comp = _per_axis(cfg["trunk_model_comp_deg"])
        self._zero = None                 # model frame: (rotation set as zero, rot180 then)
        self.shell = StereoShell(K0, D0, K1, D1, R, T, size)
        self.seg = TorsoSegmenter()
        self._ref = ((K1, D1) if self.shell.swap else (K0, D0)), size
        self.method = "icp"
        self._pose = None                 # pose.PoseTrunk, loaded on first use
        r = cfg["trunk_rot180"]
        self._rot180 = None if r == "auto" else bool(r)   # None = not known yet
        self._rot_auto = r == "auto"
        self._lock_mask = None            # the followed person's last mask; None = centre-most
        self._seen = None                 # (left image, [masks]) of the last frame
        self._offered = []                # the masks the last snapshot numbered
        self._q = (0, 0)                  # raw shell points, mask pixels of the last frame
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
        self._debug_at = 0.0
        self._rest_debug_at = 0.0
        self._seq = 0
        self._rate = []
        self.reference = "model" if cfg["trunk_reference"] == "model" else "neutral"
        self.set_method(cfg["trunk_method"])

    def model_frame(self):
        """Angles from minisam3d's own frame, not a captured neutral."""
        return self.reference == "model" and self.method != "icp"

    def set_reference(self, reference):
        """trunk_reference: "neutral" or "model". Either way the old neutral goes."""
        if reference not in ("neutral", "model"):
            print(f"[TRUNK] unknown trunk_reference {reference!r}", flush=True)
            return False
        if reference != self.reference:
            print(f"[TRUNK] reference {self.reference} -> {reference}", flush=True)
            self.reference = reference
            self._clear_neutral()
        return True

    def clear_zero(self):
        """Model frame: measure from the model's own rest pose again."""
        if self._zero is not None:
            print("[TRUNK] zero cleared: model frame", flush=True)
        self._zero = None
        self._capture_result = ""
        self._levels[:] = OK
        self._pending[:] = OK

    def small_pair(self, raw0, raw1):
        """Sensor-resolution stream0/stream1 -> (left, right) at working size."""
        left, right = self.shell.reference(raw0, raw1)
        return (cv2.resize(left, self.shell.size, interpolation=cv2.INTER_AREA),
                cv2.resize(right, self.shell.size, interpolation=cv2.INTER_AREA))

    def set_method(self, method):
        """Switch how the rotation is measured. A neutral from one method means
        nothing to the other, so a change drops it. False if the model will not
        load (the current method stays)."""
        if method == self.method:
            return True
        if method != "icp":
            from .pose import MODELS, PoseTrunk
            if method not in MODELS:
                print(f"[TRUNK] unknown trunk_method {method!r}", flush=True)
                return False
            try:
                if self._pose is None:
                    (Kr, Dr), sensor = self._ref
                    self._pose = PoseTrunk(Kr, Dr, sensor, self.shell.size, method)
                else:
                    self._pose.set_model(method)
                self._pose.min_conf = _for_method(self.cfg["trunk_msam_min_conf"], method)
                self._pose.doubt_conf = _for_method(self.cfg["trunk_msam_doubt_conf"], method)
            except Exception as exc:
                print(f"[TRUNK] {method} unavailable, staying on {self.method}: {exc!r}", flush=True)
                return False
        print(f"[TRUNK] method {self.method} -> {method}", flush=True)
        self.method = method
        self._clear_neutral()
        return True

    def _clear_neutral(self):
        if self._neutral is not None or self._capture is not None:
            print("[TRUNK] neutral cleared", flush=True)
        self._neutral = self._reg = self._capture = None
        self._zero = None
        self._fail_since, self._last = None, None
        self._levels[:] = OK
        self._pending[:] = OK
        self._capture_result = ""
        if self._pose is not None:
            self._pose.reset()

    def _seg_way(self, ls, rot180):
        """Torso masks in the left frame's own pixels, segmented the right way up."""
        if not rot180:
            return self.seg.instances(ls, self.shell.size)
        masks = self.seg.instances(cv2.rotate(ls, cv2.ROTATE_180), self.shell.size)
        return [cv2.rotate(m, cv2.ROTATE_180) for m in masks]

    def _segment(self, ls):
        """trunk_seg, with trunk_rot180 "auto": until a torso is seen, and
        whenever none is, the other way up is tried too and adopted if it finds one."""
        way = bool(self._rot180)
        masks = self._seg_way(ls, way)
        if masks or not self._rot_auto:
            if masks and self._rot180 is None:
                self._rot180 = way
            return masks
        other = self._seg_way(ls, not way)
        if other:
            self._rot180 = not way
            print(f"[TRUNK] camera is {'upside down' if self._rot180 else 'upright'} "
                  "(trunk_rot180 auto)", flush=True)
        return other

    def _subject(self, ls, timing):
        """trunk_seg on the left frame, then the followed person's mask."""
        t1 = time.perf_counter()
        masks = self._segment(ls)
        t2 = time.perf_counter()
        timing["seg"] = (t2 - t1) * 1e3
        self._seen, self._people = (ls, masks), len(masks)
        self._q = (0, 0)
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
        return mask, ""

    def _pose_obs(self, ls, timing):
        """minisam3d: ((R_trunk, xyz, conf), "") or (None, why)."""
        mask, bad = self._subject(ls, timing)
        if bad:
            return None, bad
        self._q = (0, int(np.count_nonzero(mask)))
        t = time.perf_counter()
        obs, bad = self._pose.measure(ls, mask, bool(self._rot180))
        timing["pose"] = (time.perf_counter() - t) * 1e3
        return obs, bad

    def _cloud(self, ls, rs, timing):
        mask, bad = self._subject(ls, timing)
        if bad:
            return None, bad
        t2 = time.perf_counter()
        pts = self.shell.shell(ls, rs, mask)
        self._q = (len(pts), int(np.count_nonzero(mask)))
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
        if self._rate and now - self._rate[-1] > FRAME_GAP_S and self._fail_since is not None:
            # No frames for a while: the cameras were off (the app idle), not
            # the person away. The occlusion clock starts again from here.
            self._fail_since = now
        self._rate = [t for t in self._rate if now - t < 2.0] + [now]
        hz = (len(self._rate) - 1) / max(now - self._rate[0], 1e-6) if len(self._rate) > 1 else 0.0

        if self.method == "icp":
            cloud, bad = self._cloud(ls, rs, timing)
            npts = 0 if cloud is None else len(cloud)
        else:
            cloud, bad = self._pose_obs(ls, timing)   # (R_trunk, xyz, conf), not a cloud
            npts = 0

        if self.model_frame():
            if self._zero is not None and self._zero[1] != bool(self._rot180):
                self.clear_zero()                       # set the other way up
            self._neutral = model_frame(self._rot180, self._zero and self._zero[0])
        if start_capture:   # in the model frame: "Set zero"
            self._capture = (now, [], [], 0)
        st = TrunkStatus(npts=npts, seq=self._seq, hz=hz, method=self.method,
                         reference="model" if self.model_frame() else "neutral", timing_ms=timing,
                         people=self._people, locked=self._lock_mask is not None,
                         raw_pts=self._q[0], mask_px=self._q[1])
        if self._capture is not None and self._capture_step(now, cloud, bad, st):
            pass
        elif self._neutral is None:
            st.state = NO_NEUTRAL
        else:
            self._track(now, cloud, bad, timing, st)
        # model frame: whether a zero is set (there is always a reference)
        st.has_neutral = self._zero is not None if self.model_frame() else self._neutral is not None
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
        up = cv2.rotate if self._rot180 else (lambda img, _: img)   # show it upright
        small = up(cv2.resize(ls, (w, h), interpolation=cv2.INTER_AREA), cv2.ROTATE_180)
        ok, jpeg = cv2.imencode(".jpg", small, [cv2.IMWRITE_JPEG_QUALITY, 60])
        people, followed = [], -1
        for i, m in enumerate(masks):
            ms = up(cv2.resize(m, (w, h), interpolation=cv2.INTER_NEAREST), cv2.ROTATE_180)
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
        print("[TRUNK] subject changed", flush=True)
        self._clear_neutral()
        return True

    def _pose_step(self, obs):
        """minisam3d's counterpart of Registration.step: neutral -> now, or None
        past the same ~45 deg a seated trunk never reaches."""
        R_body = obs[0] @ self._neutral.R_trunk.T
        if self.model_frame() and self.cfg["trunk_debug"]:
            now = time.perf_counter()
            if now - self._rest_debug_at >= 1.0:
                self._rest_debug_at = now
                # The model's rotation of someone upright facing a level camera,
                # estimated from this frame's own joints: CAM_FRAME F^T R.
                B = CAM_FRAME @ anatomical_frame_pose(obs[1]).T @ obs[0]
                print(f"[TRUNK-DBG] model rest estimate rotvec="
                      f"{np.round(np.degrees(cv2.Rodrigues(B)[0].ravel()), 1).tolist()} "
                      f"matrix={np.round(B, 3).tolist()} off_model_frame={rot_deg(R_body):.0f} deg",
                      flush=True)
        if rot_deg(R_body) > ROT_MAX_DEG:
            return None, dict(how="gated")
        conf = obs[2][TRUNK_JOINTS]
        return R_body, dict(how="direct", frac=float(conf.min()), doubt=obs[3])

    def _track(self, now, cloud, bad, timing, st):
        if bad:
            R_body, info = None, dict(how=bad)
        elif self.method != "icp":
            R_body, info = self._pose_step(cloud)
        else:
            t = time.perf_counter()
            R_body, info = self._reg.step(cloud)
            timing["icp"] = (time.perf_counter() - t) * 1e3
        st.q_how = info["how"]
        st.q_rms_mm = info.get("rms", float("nan")) * 1e3
        st.q_frac = info.get("frac", float("nan"))
        st.held = R_body is None
        st.doubt = info.get("doubt", "")
        if R_body is not None:
            self._fail_since = None
            angles = trunk_angles(R_body @ self._neutral.R_neu, self._neutral.R_neu)
            self._last = (angles, info.get("rms", float("nan")) * 1e3, info["how"])
            cam = np.degrees(cv2.Rodrigues(R_body)[0].ravel())
            st.cam_rot = tuple(float(c) for c in cam)
            if self.cfg["trunk_debug"] and now - self._debug_at >= 1.0:
                self._debug_at = now
                print(f"[TRUNK-DBG] {self.method} flex/lat/axi=({angles[0]:+.1f},{angles[1]:+.1f},"
                      f"{angles[2]:+.1f}) camera rotvec x/y/z=({cam[0]:+.1f},{cam[1]:+.1f},{cam[2]:+.1f})",
                      flush=True)
            if not st.doubt:   # an uncertain reading shows, but does not raise a warning
                self._classify(np.array(angles), now)
        elif self._fail_since is None:
            self._fail_since = now

        if (self._fail_since is not None and self._neutral is not None and not self.model_frame()
                and now - self._fail_since >= self.cfg["trunk_reneutral_s"]):
            print(f"[TRUNK] occluded {self.cfg['trunk_reneutral_s']:.0f} s: neutral dropped", flush=True)
            self._clear_neutral()
            self._capture_result = "away"
            st.state = NO_NEUTRAL
            return

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
        warn, comp = (self.model_warn, self.model_comp) if self.model_frame() else (self.warn, self.comp)
        for i in range(3):
            cur = self._levels[i]
            # where the reading belongs, with slack on the way down
            target = COMPENSATING if a[i] >= comp[i] else WARN if a[i] >= warn[i] else OK
            if target < cur:
                down_to = (COMPENSATING if a[i] >= comp[i] - h
                           else WARN if a[i] >= warn[i] - h else OK)
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
        if not bad and not (self.method != "icp" and cloud[3]):   # an uncertain frame is no neutral
            clouds.append(cloud)
            if self.method == "icp":
                cents.append(cloud.mean(axis=0))
        self._capture = (t0, clouds, cents, seen)
        dur = self.cfg["trunk_neutral_s"]
        if now - t0 < dur:
            st.state, st.progress = CAPTURING, (now - t0) / dur
            return True

        self._capture = None
        if self.method != "icp":
            return self._finish_pose_capture(clouds, seen)
        motion = float(np.linalg.norm(np.std(cents, axis=0))) if cents else float("nan")
        if len(clouds) < max(3, 0.6 * seen):
            self._capture_result = "not_visible"
        elif motion > self.cfg["trunk_neutral_motion_m"]:
            self._capture_result = "moving"
        else:
            pooled = voxel_downsample(np.concatenate(clouds),
                                      max_pts=int(self.cfg["trunk_neutral_points"]),
                                      rng=self.rng)
            # upside down, image-right is the patient's right
            self._neutral = Neutral(pooled, -1.0 if self._rot180 else 1.0)
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

    def _finish_pose_capture(self, obs, seen):
        """minisam3d neutral: the mean trunk rotation over the capture, and the
        anatomical frame from the mean joints. Still = 90% of the rotations
        within trunk_msam_neutral_deg of their mean."""
        spread = float("nan")
        if len(obs) < max(3, 0.6 * seen):
            self._capture_result = "not_visible"
        else:
            R_mean = mean_rotation([o[0] for o in obs])
            spread = float(np.percentile([rot_deg(o[0] @ R_mean.T) for o in obs], 90))
            if spread > self.cfg["trunk_msam_neutral_deg"]:
                self._capture_result = "moving"
            elif self.model_frame():
                # "Set zero": this pose reads 0 from now on, on the model frame's axes.
                self._zero = (R_mean, bool(self._rot180))
                self._fail_since, self._last = None, None
                self._levels[:] = OK
                self._pending[:] = OK
                self._capture_result = "ok"
                off = rot_deg(R_mean @ model_frame(self._rot180).R_trunk.T)
                print(f"[TRUNK] zero set ({self.method}): {len(obs)}/{seen} frames, "
                      f"{off:.1f} deg from the model's rest pose", flush=True)
                return False
            else:
                self._neutral = PoseNeutral(R_mean, anatomical_frame_pose(
                    np.mean([o[1] for o in obs], axis=0)))
                _log_pose_frame(self._neutral.R_neu, np.mean([o[2] for o in obs], axis=0))
                self._fail_since, self._last = None, None
                self._levels[:] = OK
                self._pending[:] = OK
                self._capture_result = "ok"
                print(f"[TRUNK] neutral captured ({self.method}): {len(obs)}/{seen} frames, "
                      f"rotation spread {spread:.1f} deg", flush=True)
                return False
        print(f"[TRUNK] neutral capture failed: {self._capture_result} "
              f"({len(obs)}/{seen} usable frames, rotation spread {spread:.1f} deg)", flush=True)
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

    def set_method(self, method):
        with self._lock:
            return self.engine.set_method(method)

    def set_reference(self, reference):
        with self._lock:
            return self.engine.set_reference(reference)

    def clear_zero(self):
        with self._lock:
            self.engine.clear_zero()

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
                elif cmd == "zero_clear":
                    engine.clear_zero()
                elif cmd == "snapshot":
                    snap = engine.snapshot()
                    if snap is not None:
                        out.put(snap)
                elif isinstance(cmd, tuple) and cmd[0] == "select":
                    engine.select(cmd[1])
                elif isinstance(cmd, tuple) and cmd[0] == "method":
                    engine.set_method(cmd[1])
                elif isinstance(cmd, tuple) and cmd[0] == "reference":
                    engine.set_reference(cmd[1])
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


# A pause in frames longer than this is the tracker idling, not an occlusion.
FRAME_GAP_S = 1.0


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

    def clear_zero(self):
        """Model frame: drop a "Set zero", back to the model's rest pose."""
        self._cmds.put("zero_clear")

    def request_snapshot(self):
        """Ask for the picker image; it arrives through `take_snapshot`."""
        self._cmds.put("snapshot")

    def select(self, index):
        """Follow person `index` of the last snapshot; -1 = centre-most again."""
        self._cmds.put(("select", int(index)))

    def set_method(self, method):
        """icp / msam_r18 / msam_v3rot (see DEFAULTS); clears the neutral."""
        self._cmds.put(("method", str(method)))

    def set_reference(self, reference):
        """neutral / model (see DEFAULTS); clears the neutral."""
        self._cmds.put(("reference", str(reference)))

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
