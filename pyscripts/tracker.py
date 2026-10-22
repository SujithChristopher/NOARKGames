import argparse
import collections
import csv
import json
import logging
import os
import sys
import platform
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

import cv2
import numpy as np
import rapidtag
import toml
from scipy.optimize import least_squares

import protocol
from corner_stabilizer import CornerStabilizer
from filters import ExponentialMovingAverageFilter3D
from frame_recorder import FrameRecorder
from link import Link
from storage import Storage
from rigid_body import RigidBody, load_cameras, load_device, stereo_extrinsic
from stereo_capture import StereoCapture
from trunk.snapshot_packet import encode_snapshot
from trunk.tracker import TrunkProcess
from udp_streamer import UDPStreamer


_SCRIPT_DIR = Path(__file__).parent

_APRILTAG_DICT = "DICT_APRILTAG_36h11"

# The PREVIOUS 5-tag bracket, hand measured: each entry is the device tip in
# that marker's own frame. Kept only so an uncalibrated rig still starts.
#
# It does not describe the current body, which carries tags 1-8 — and ids 4 and
# 8 appear in both, so on today's hardware this table silently supplies stale
# offsets for two tags and nothing for the rest. Run rigidbody_calib.py; the
# calibrated geometry in rigid_body.py replaces this entirely.
MARKER_OFFSETS = {
    4:  np.array([0.00,  0.01,    -0.069]),
    8:  np.array([0.00,  0.01,   -0.069]),
    12: np.array([0.00,  0.0,    -0.1075]),
    14: np.array([-0.09, 0.0,    -0.069]),
    20: np.array([0.1,   0.0,    -0.069]),
}

# 50 mm AprilTag corner model: TL, TR, BR, BL (AprilTag detector corner order)
_L = 0.05
_MARKER_PTS = np.array([
    [-_L / 2,  _L / 2, 0],
    [ _L / 2,  _L / 2, 0],
    [ _L / 2, -_L / 2, 0],
    [-_L / 2, -_L / 2, 0],
], dtype=np.float64)

# rapidtag can refine AprilTag corners itself: the fast ArUco detector finds the
# tags, then a border-only refit runs on a small crop per tag, in parallel. It
# matches the full-resolution AprilTag fit to 0.0001 px. Older builds lack the
# flag, so they keep the cornerSubPix pass below.
_DETECTOR_PARAMS = rapidtag.DetectorParameters()
_CROP_REFINE = hasattr(_DETECTOR_PARAMS, "april_tag_refine_full_resolution")
if _CROP_REFINE:
    _DETECTOR_PARAMS.april_tag_refine_full_resolution = True  # corner_refinement_method stays 0
else:
    print("[RIG] rapidtag lacks april_tag_refine_full_resolution; using cornerSubPix.")

def _set_detector_refine(mode: str) -> None:
    """Point the shared detector at one refinement: crop (rapidtag's border
    refit), contour (lines fitted to the tag's threshold contour, in rapidtag),
    or neither — subpix and none leave the detector alone; subpix runs
    cornerSubPix afterwards."""
    if _CROP_REFINE:
        _DETECTOR_PARAMS.april_tag_refine_full_resolution = mode == "crop"
    _DETECTOR_PARAMS.corner_refinement_method = (
        rapidtag.CORNER_REFINE_CONTOUR if mode == "contour" else rapidtag.CORNER_REFINE_NONE
    )


_SUBPIX_CRITERIA = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 40, 0.01)

# Stabilizer key for the whole-body pose, kept out of the marker-id space.
_BOARD_KEY = -1


def _parse_cpus(spec: str) -> set:
    """Turn "4-7" or "0,2,5" into a set of core numbers."""
    cores = set()
    for part in str(spec).split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            lo, hi = part.split("-", 1)
            cores.update(range(int(lo), int(hi) + 1))
        else:
            cores.add(int(part))
    return cores


def _pin_to_cpus(spec) -> None:
    """Confine this process to `spec`, re-executing under taskset to do it.

    The board is 4+3+1: cpu0-3 are the little cores at capacity 382, cpu4-6 the
    big ones at 889, cpu7 the prime at 1024. Left alone the scheduler is free to
    run marker detection on a little core while the game holds a big one, and
    detection is the longest stage in the loop.

    os.sched_setaffinity() is not enough on its own. It binds the calling thread
    and whatever is spawned afterwards, but OpenCV and rapidtag build their
    thread pools while their modules are imported — before any of our code runs
    — so those threads keep the wide mask. Measured: 5 threads confined and 21
    still free to roam. Under taskset every thread starts confined, 14 of 14,
    and the pools size themselves to the cores they can actually see instead of
    oversubscribing eight.

    Re-executing costs one interpreter startup and means the setting works the
    same whether Godot, a terminal or systemd started us.
    """
    if not spec:
        return
    cores = _parse_cpus(spec) & set(range(os.cpu_count() or 1))
    if not cores:
        print(f"[CPU] No usable cores in {spec!r}; leaving affinity alone.")
        return
    try:
        if os.sched_getaffinity(0) == cores:
            print(f"[CPU] Running on cores {sorted(cores)}")
            return
    except (AttributeError, OSError):
        return                                    # not Linux; nothing to do

    spec = ",".join(str(core) for core in sorted(cores))
    try:
        print(f"[CPU] Re-executing on cores {spec}", flush=True)
        os.execvp("taskset", ["taskset", "-c", spec, sys.executable, *sys.argv])
    except OSError as exc:
        # No taskset: bind what we can and say what that leaves behind.
        print(f"[CPU] taskset unavailable ({exc}); pinning this thread only — "
              "detector threads already started will stay unpinned.")
        try:
            os.sched_setaffinity(0, cores)
        except OSError as inner:
            print(f"[CPU] Could not pin: {inner}")


# Where Godot's Settings autoload keeps the file (Linux/Windows/macOS; on Android the
# tracker does not run). Godot passes the exact path with --settings.
DEFAULT_SETTINGS_PATH = Path.home() / "Documents" / "NOARK_demo" / "settings.json"
DATA_ROOT = Path.home() / "Documents" / "NOARK_demo" / "data"


def _load_settings(path: Path = DEFAULT_SETTINGS_PATH) -> dict:
    if path.exists():
        with open(path) as f:
            return json.load(f)
    print(f"[RIG] No settings file at {path}; using the tracker's built-in defaults.")
    return {"debug": True}


# ── Pose helpers (module-level, no class state needed) ────────────────────────

def _kabsch(src: np.ndarray, dst: np.ndarray):
    """Closed-form rigid alignment dst ≈ R @ src + t."""
    cs, cd = src.mean(0), dst.mean(0)
    H = (src - cs).T @ (dst - cd)
    U, _, Vt = np.linalg.svd(H)
    R = Vt.T @ U.T
    if np.linalg.det(R) < 0:
        Vt[2] *= -1
        R = Vt.T @ U.T
    return R, cd - R @ cs


def _refine_corners(gray: np.ndarray, corners: list) -> list:
    """Sub-pixel corner refinement on raw-frame corner detections.

    rapidtag doesn't do sub-pixel refinement itself (detection only, see its
    README), so this still runs regardless of detector backend.
    """
    refined = []
    for c in corners:
        pts = np.asarray(c, dtype=np.float32).reshape(-1, 1, 2)
        cv2.cornerSubPix(gray, pts, (5, 5), (-1, -1), _SUBPIX_CRITERIA)
        refined.append(pts.reshape(1, 4, 2))
    return refined


def _draw_markers(img: np.ndarray, corners: list, ids: np.ndarray) -> np.ndarray:
    """Minimal stand-in for cv2.aruco.drawDetectedMarkers (debug window only)."""
    for c, mid in zip(corners, ids.flatten()):
        pts = np.asarray(c, dtype=np.int32).reshape(-1, 1, 2)
        cv2.polylines(img, [pts], True, (0, 255, 0), 2)
        cx, cy = pts.reshape(-1, 2).mean(axis=0).astype(int)
        cv2.putText(img, str(int(mid)), (cx, cy), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 255), 2)
    return img


def _single_cam_pnp(corners: np.ndarray, K: np.ndarray, D: np.ndarray):
    """
    Corner-undistort single-camera PnP.
    Undistorts corners to pinhole space, then runs solvePnP with zero distortion.
    """
    und = cv2.fisheye.undistortPoints(corners.reshape(-1, 1, 2).astype(np.float64), K, D, P=K)
    ok, rvec, tvec = cv2.solvePnP(
        _MARKER_PTS, und, K, None, flags=cv2.SOLVEPNP_ITERATIVE
    )
    if ok:
        return rvec.flatten(), tvec.flatten()
    return None, None


def _stereo_pnp(
    c0: np.ndarray, c1: np.ndarray,
    K0: np.ndarray, D0: np.ndarray,
    K1: np.ndarray, D1: np.ndarray,
    R_st: np.ndarray, T_st: np.ndarray,
):
    """
    Joint multi-view PnP: one 6-DOF pose minimising reprojection in both cameras.
    Initialised via stereo triangulation + Kabsch fit (stereo_tri).
    Uses the fisheye model on raw corners (corner-undistort pipeline).
    """
    # Normalised (z=1) coords for triangulation — no P arg → normalized output
    n0 = cv2.fisheye.undistortPoints(
        c0.reshape(-1, 1, 2).astype(np.float64), K0, D0
    ).reshape(-1, 2).T  # (2, 4)
    n1 = cv2.fisheye.undistortPoints(
        c1.reshape(-1, 1, 2).astype(np.float64), K1, D1
    ).reshape(-1, 2).T  # (2, 4)

    P0 = np.hstack([np.eye(3),  np.zeros((3, 1))])  # cam0 is reference
    P1 = np.hstack([R_st,       T_st])               # T_st in metres
    Xh = cv2.triangulatePoints(P0, P1, n0, n1)
    pts3d = (Xh[:3] / Xh[3]).T  # (4, 3) in cam0 frame

    # Kabsch: fit marker model to triangulated points, reject outlier corners
    R_init, t_init = _kabsch(_MARKER_PTS, pts3d)
    res = np.linalg.norm((R_init @ _MARKER_PTS.T).T + t_init - pts3d, axis=1)
    if len(res) > 3 and res.max() > 3 * np.median(res):
        mask = res <= 3 * np.median(res)
        if mask.sum() >= 3:
            R_init, t_init = _kabsch(_MARKER_PTS[mask], pts3d[mask])

    rvec_init = cv2.Rodrigues(R_init)[0]      # (3, 1)

    # EXPERIMENT: skip the least_squares (LM) reprojection refinement below and
    # return the closed-form triangulation + Kabsch estimate directly, to
    # measure its contribution to per-frame cost.
    return rvec_init.flatten(), t_init.flatten()


# Which cameras the board pose is solved from, and how each reads at startup.
# "cam0"/"cam1" are rcam's enumeration order (stream 0 is the CAM2 connector on
# this board), not the stereo calibration's labels — device.toml [cameras] maps
# between the two.
_CAMERA_CHOICES = {
    "both": "both, fitted together",
    "cam0": "stream 0 alone",
    "cam1": "stream 1 alone",
}


class TrackerClass:
    def __init__(
        self,
        stereo_calib_path: Path,
        aruco_calib_path: Path,
        rigidbody_path: Path,
        device_path: Path,
        settings: Optional[dict] = None,
        settings_path: Optional[Path] = None,
        record_frames: bool = False,
        fps_value: Optional[int] = None,
        flip_frames: bool = True,
        stereo_refine: Optional[bool] = None,
        solver: Optional[str] = None,
        camera: Optional[str] = None,
        frame_sync: bool = True,
        phase_tol_us: float = 200.0,
        resync_every_s: float = 5.0,
        resync_threshold_us: float = 1000.0,
    ) -> None:
        if settings is None:
            settings = {}
        # Re-read at every HELLO for what can change live (_reload_settings).
        self._settings_path = settings_path

        self.record_frames      = record_frames
        self.fps_value          = fps_value
        self.flip_frames        = flip_frames
        self._stereo_calib_path = stereo_calib_path

        # ── Frame synchronisation knobs (see _init_frame_sync) ────────────────
        self.frame_sync_enabled  = frame_sync
        self.phase_tol_us        = phase_tol_us
        self.resync_every_s      = resync_every_s
        self.resync_threshold_us = resync_threshold_us

        # ── Stereo intrinsics + extrinsics ────────────────────────────────────
        # Which stereo-calibration section describes which camera stream comes
        # from device.toml: the calibration tool labels its own cam0/cam1, and
        # that need not match the order rcam enumerates them in. Getting it
        # wrong is not subtle — measured on this rig, the wrong mapping put
        # 370 mm of jitter on a static device.
        device = load_device(device_path)
        self._camera_order = device["camera_order"]
        self._exposure_us = device["exposure_us"]
        self._gain = device["gain"]
        self._isp = device["isp"]
        self._rigidbody_path = rigidbody_path
        cameras, self.frame_size = load_cameras(stereo_calib_path, self._camera_order)
        (self.K0, self.D0) = cameras["cam0"]
        (self.K1, self.D1) = cameras["cam1"]
        self.R_st, self.T_st = stereo_extrinsic(stereo_calib_path, self._camera_order)

        # ── marker / stream / display settings ────────────────────────────────
        # settings.json is the source of truth. The legacy single-camera aruco
        # calibration is consulted only for keys it does not set, and only when
        # it still exists: the stereo pipeline takes its intrinsics from
        # sterio_calibration.toml, so that file is otherwise vestigial and its
        # absence must not stop tracking.
        ac = toml.load(aruco_calib_path) if Path(aruco_calib_path).exists() else {}
        stream = ac.get("stream_data", {})
        # Not `camera`: that is the constructor's camera-choice argument, and
        # binding it here silently discarded --camera.
        camera_section = ac.get("camera", {})
        self.udp_ip            = settings.get("udp_ip",   stream.get("ip", "127.0.0.1"))
        self.udp_port          = int(settings.get("udp_port", stream.get("port", 8000)))
        # One transport or the other, never both: "udp" when Godot runs on this
        # board, "ble" when it runs on a tablet. Either way the tracker is the
        # long-running side (the noark-tracker service) and the app connects to
        # it. Godot reads the same key (its own settings.json) to pick its side.
        self.stream_type       = settings.get("stream_type", "ble")
        if self.stream_type not in ("udp", "ble"):
            print(f"[NET] Unknown stream_type {self.stream_type!r}, using ble.")
            self.stream_type = "ble"
        self.ble_device_name   = settings.get("ble_device_name", "NOARK_Tracker")
        self.display           = settings.get(
            "display", ac.get("display", {}).get("display", False)
        )
        self._camera_model     = camera_section.get("model", "OV9281")
        self._camera_fov       = camera_section.get("fov", 160)

        # Refining the board pose across both cameras is the better estimator,
        # but only with an extrinsic that actually describes this pair, and it
        # costs roughly half the frame rate (~32 -> ~17 fps end to end).
        #
        # Left unset it turns itself on only when the calibration carries a
        # self-calibrated extrinsic. The checkerboard stereo file is not enough:
        # it labels its own cam0/cam1, which need not match the order rcam
        # enumerates the cameras in, and a mismatched extrinsic does not degrade
        # gracefully — measured on this rig it put 370 mm of jitter on a static
        # device, against 2.4 mm for one camera alone.
        self._stereo_requested = stereo_refine

        # ── Rigid body ────────────────────────────────────────────────────────
        # When the marker cluster has been calibrated, every visible tag feeds
        # one joint PnP for the whole body; without a calibration we fall back
        # to averaging each tag's hand-measured offset independently.
        self.rig = RigidBody.load(rigidbody_path)
        have_refit = self.rig is not None and self.rig.stereo is not None

        # Which cameras the pose is solved from, and by which estimator.
        #
        # Both live in settings.json, because that is the only file the Godot
        # app reads and the only one that reaches the tracker when the game
        # launches it — global_script.gd runs tracker.py with no arguments, so a
        # knob that exists only on the command line cannot affect a real
        # session. device.toml keeps the *rig's* description; these two are
        # choices about how to use it.
        #
        # Precedence throughout: command line, settings.json, device.toml,
        # then the built-in default.
        self.camera_choice = (
            camera
            or (settings.get("tracker_camera") or "").strip().lower()
            or self._camera_default(stereo_refine, device["stereo_pose"], have_refit)
        )
        if self.camera_choice not in _CAMERA_CHOICES:
            raise SystemExit(
                f"Unknown tracker_camera {self.camera_choice!r}; "
                f"expected one of {', '.join(_CAMERA_CHOICES)}"
            )
        self.stereo_refine = self.camera_choice == "both"
        # Which single stream leads when only one is used, and when the other
        # is the only one that can see the device.
        self._primary = 1 if self.camera_choice == "cam1" else 0

        self.solver = (
            solver
            or (settings.get("tracker_solver") or "").strip().lower()
            or device["solver"]
            or "joint"
        )
        if self.solver not in RigidBody.POSE_SOLVERS:
            raise SystemExit(
                f"Unknown tracker_solver {self.solver!r}; "
                f"expected one of {', '.join(RigidBody.POSE_SOLVERS)}"
            )
        if self.rig is not None and self.rig.stereo is not None:
            # Measured against this rig, with these cameras, in this order.
            self.R_st, self.T_st = self.rig.stereo
        if tuple(self._camera_order) != ("cam0", "cam1"):
            print(f"[RIG] Camera streams mapped {tuple(self._camera_order)} "
                  "(device.toml [cameras])")
        if self.rig is not None:
            print(f"[RIG] Calibrated body: {self.rig.describe()}")
            if self.solver == "ransac":
                print("[RIG] Pose solver: rapidtag RANSAC (rejects disagreeing corners).")
            else:
                print("[RIG] Pose solver: joint PnP over every visible corner.")
            print(f"[RIG] Cameras: {_CAMERA_CHOICES[self.camera_choice]}")
            if self.stereo_refine and not have_refit:
                print(
                    "[RIG] Stereo pose from the calibration file's extrinsic "
                    "(no self-calibrated refit). Verified mapping "
                    f"{tuple(self._camera_order)}."
                )
            elif self.stereo_refine:
                print("[RIG] Stereo pose from the self-calibrated extrinsic.")
            else:
                # Not a limitation being worked around: a multi-tag board is
                # already well conditioned in depth, so the 78 mm baseline adds
                # little. Measured with the mapping corrected, cam1 alone was as
                # quiet as the two-camera fit (0.21 mm) at a quarter of the cost.
                print("[RIG] One camera is enough here; the baseline adds little "
                      "to a multi-tag board.")
        else:
            print(
                f"[RIG] No calibration at {rigidbody_path} — falling back to "
                f"MARKER_OFFSETS for tags {sorted(MARKER_OFFSETS)}. That table "
                "describes the PREVIOUS bracket, so positions will be wrong on "
                "the current 1-8 body. Run pyscripts/rigidbody_calib.py."
            )

        # ── Remaining state ───────────────────────────────────────────────────
        self.filter         = ExponentialMovingAverageFilter3D(alpha=1)
        self.stabilizer     = CornerStabilizer(
            threshold_px=settings.get("corner_deadband_px", 0)  # 0 = stabilizer off: every frame is solved
        )
        self.marker_offsets = MARKER_OFFSETS
        # Contour is the default. Crop refine (rapidtag 0.1.10) gave garbage poses on
        # this rig, so it is opt-in: settings.json tracker_refine = "crop". Track with
        # the refinement the rigid body was calibrated with (rigidbody.toml meta.refine).
        want = (settings.get("tracker_refine") or "contour").strip().lower()
        if want == "crop" and _CROP_REFINE:
            self.refine_mode = "crop"
        else:
            self.refine_mode = "subpix" if want == "subpix" else "contour"
        _set_detector_refine(self.refine_mode)

        self.cam0     = None   # primary (tracking + display)
        self.cam1     = None   # stereo second view
        self._executor        = None
        self.tvec_dist    = np.zeros(3)
        self.save_path    = None
        self._send_count  = 0
        self._frame_count = 0
        self._stage_time  = {"capture": 0.0, "detect": 0.0, "refine": 0.0, "pose": 0.0}
        self.csv_writer   = None
        self._csv_file    = None
        self.record       = False
        self._hid: Optional[str] = None
        # Frames for this session, written raw alongside tracking when
        # settings.json asks. Costs ~1.2 ms a pair and 61 MB/s of disk.
        self.record_session = bool(settings.get("recording", False))
        # The sensor is left free-running: tracking wants every frame it can
        # get. The recorder decimates to its own rate instead, so the two are
        # independent.
        self.recording_hz = float(settings.get("recording_fps", 30))
        # An hour at 30 Hz is 110 GB per camera; 900 frames is 30 s and ~0.9 GB,
        # which copies and resumes sanely. 0 disables rotation.
        self.recording_chunk = int(settings.get("recording_chunk_frames", 900))
        # 1.0 keeps the sensor's 1280x800. 0.5 quarters the storage but cost
        # 37% of the tag detections when measured, so it suits recordings kept
        # for review rather than for re-running the analysis.
        self.recording_scale = float(settings.get("recording_scale", 1.0))
        self.recorder: Optional[FrameRecorder] = None
        self._sync_chip = settings.get("sync_chip", "gpiochip4")
        self._sync_pin = settings.get("sync_pin", "PIN_11")
        self._rec_file0 = self._rec_file1 = None
        self._rec_dir: Optional[Path] = None
        # Settings > Storage in the app: list / delete recordings, off the loop.
        self.storage = Storage(DATA_ROOT, self._recording_dirs)
        self._ts_file0  = self._ts_file1  = None

        self._curr_session = os.path.join(
            "Session-" + datetime.today().strftime("%Y-%m-%d"), "MovementData"
        )

        # ── Transport + cameras ───────────────────────────────────────────────
        # The cameras are off until the app asks for tracking (CONFIG
        # track=on, while a game runs) and go off again a little after it stops
        # asking: tracking nobody costs most of two cores and heats the board.
        # They come up on their own thread (_manage_cameras), so the link keeps
        # answering through the seconds that takes.
        self._init_transport()
        if platform.system() != "Linux":
            raise RuntimeError("Stereo tracking requires Radxa Dragon Q6A dual-camera hardware.")
        self.capture: Optional[StereoCapture] = None
        self._cam_thread: Optional[threading.Thread] = None
        self._cam_result = None            # the thread's StereoCapture, or its exception
        self._cam_retry_at = 0.0
        self._want_tracking = False        # CONFIG track=on|off
        self._tracking = False             # wanted, and the cameras are up
        self._unwanted_since: Optional[float] = None
        # Seconds the cameras stay up after tracking stops: from a game back
        # to its menu and into the next game should not wait for them.
        self.camera_off_s = float(settings.get("camera_idle_off_s", 20))
        self.restart_requested = False     # RESTART: run() returns, main exits non-zero
        self._init_trunk(settings)

    # ── Trunk ─────────────────────────────────────────────────────────────────
    # The same pair also sees the patient's torso. trunk/ turns it into trunk
    # angles from a captured neutral on its own thread; the hand loop only
    # hands it the newest pair, so trunk work never delays hand tracking.

    def _init_trunk(self, settings: dict) -> None:
        self.trunk: Optional[TrunkProcess] = None
        self._trunk_sent_seq = -1
        self._trunk_logged = None
        self._trunk_settings = settings
        self._trunk_csv = None
        if settings.get("trunk_debug"):
            self._open_trunk_csv()
        # Live switch (CONFIG trunk=on|off): off stops feeding and reporting the
        # trunk process; on after a start with it disabled loads it then.
        self.trunk_on = bool(settings.get("trunk_enabled", True))
        if not self.trunk_on:
            print("[TRUNK] Disabled (settings.json trunk_enabled).")
            return
        try:
            self.trunk = TrunkProcess(
                self.K0, self.D0, self.K1, self.D1, self.R_st, self.T_st,
                self.frame_size, settings,
            )
        except Exception as exc:
            # No NPU, no model, no onnxruntime-qnn: hand tracking carries on.
            print(f"[TRUNK] Unavailable, hand tracking only: {exc}")
            return
        print(f"[TRUNK] Tracking from stream{1 if self.trunk.swap else 0} "
              f"at {self.trunk.size[0]}x{self.trunk.size[1]} in its own process.")

    def _set_trunk(self, on: bool) -> None:
        """Turn trunk tracking on or off mid-session. The first `on` after a
        start with it disabled loads the model (a brief stall in the loop)."""
        self.trunk_on = on
        if on and self.trunk is None:
            self._trunk_settings = {**self._trunk_settings, "trunk_enabled": True}
            self._init_trunk(self._trunk_settings)
            self.trunk_on = self.trunk is not None
        print(f"[TRUNK] {'On' if self.trunk_on else 'Off'} (live).")

    def _trunk_command(self, arg: bytes):
        """TRUNK `neutral` starts a neutral capture (in the model frame: sets the
        zero; `zero_clear` drops it again); `snapshot` sends the
        subject picker's image; `select=<n>` follows person n of it (-1 = the
        centre-most again). -> (ok, detail) for the ACK."""
        if self.trunk is None or not self.trunk_on:
            return False, "trunk tracking is off"
        arg = arg.strip()
        if arg == b"neutral":
            print("[TRUNK] Neutral capture requested.")
            self.trunk.capture_neutral()
        elif arg == b"zero_clear":
            print("[TRUNK] Zero clear requested.")
            self.trunk.clear_zero()
        elif arg == b"snapshot":
            self.trunk.request_snapshot()
        elif arg.startswith(b"select="):
            try:
                self.trunk.select(int(arg[7:]))
            except ValueError:
                return False, f"bad select: {arg.decode(errors='replace')}"
        else:
            return False, f"unknown trunk command: {arg.decode(errors='replace')}"
        return True, arg.decode()

    def _send_snapshot(self) -> None:
        """Ship a snapshot the trunk process has produced, if any."""
        snap = self.trunk.take_snapshot()
        if snap is None:
            return
        message = encode_snapshot(snap)
        self.link.send(message)   # chunked and paced by the link
        print(f"[TRUNK] Snapshot sent: {len(snap.people)} people, {len(message)} B")

    def _send_trunk(self) -> None:
        """One TRUNK_STATUS per trunk update, CSV:
        state,level,lvl_flex,lvl_lat,lvl_axi,flex,lat,axi,progress,has_neutral,
        reason,capture_result,people,locked,q_how,q_rms_mm,q_frac,raw_pts,mask_px,held,
        hz,method,doubt,reference
        (trunk/tracker.py has the states and levels.)
        """
        st = self.trunk.status()
        self._send_snapshot()
        if st.seq == self._trunk_sent_seq:
            return
        self._trunk_sent_seq = st.seq
        if self._trunk_csv is not None:
            self._log_trunk(st)
        f, l, a = st.angles
        self.link.send(protocol.encode(
            protocol.TRUNK_STATUS,
            f"{st.state},{st.level},{st.levels[0]},{st.levels[1]},{st.levels[2]},"
            f"{f:.2f},{l:.2f},{a:.2f},{st.progress:.2f},{int(st.has_neutral)},"
            f"{st.reason},{st.capture_result},{st.people},{int(st.locked)},"
            f"{st.q_how},{st.q_rms_mm:.1f},{st.q_frac:.2f},{st.raw_pts},{st.mask_px},"
            f"{int(st.held)},{st.hz:.1f},{st.method},{st.doubt},{st.reference}"))
        # One journal line whenever the state, level or this frame's outcome
        # changes, with the quality numbers: why a reading was bad (a shrunk
        # mask or cloud, a poor fit) is not visible from the angles alone.
        key = (st.state, st.level, st.q_how, st.doubt)
        if key != self._trunk_logged:
            self._trunk_logged = key
            print(f"[TRUNK] {st.state_name} lvl={st.level} how={st.q_how or '-'} "
                  f"held={int(st.held)} ang=({f:+.1f},{l:+.1f},{a:+.1f}) "
                  f"rms={st.q_rms_mm:.1f}mm frac={st.q_frac:.2f} "
                  f"pts={st.raw_pts} mask={st.mask_px} people={st.people}"
                  f"{' doubt=' + st.doubt if st.doubt else ''}", flush=True)

    # ── Cameras ───────────────────────────────────────────────────────────────
    # Phase alignment, queue pairing and drift resync all live in
    # StereoCapture, shared with rigidbody_calib.py so both see the same frames.

    def _start_cameras(self) -> None:
        """Bring the pair up on a thread; _manage_cameras picks the result up."""
        def work():
            t0 = time.time()
            try:
                capture = StereoCapture(
                    frame_size=self.frame_size,
                    fps_value=self.fps_value,
                    frame_sync=self.frame_sync_enabled,
                    phase_tol_us=self.phase_tol_us,
                    resync_threshold_us=self.resync_threshold_us,
                    exposure_us=self._exposure_us,
                    gain=self._gain,
                    isp=self._isp,
                )
            except Exception as exc:
                print(f"[CAM] Could not start the cameras: {exc!r}", flush=True)
                self._cam_result = exc
                return
            print(f"[CAM] Cameras up in {time.time() - t0:.1f} s.", flush=True)
            self._cam_result = capture

        self._cam_result = None
        self._cam_thread = threading.Thread(target=work, name="cameras", daemon=True)
        self._cam_thread.start()

    def _stop_cameras(self) -> None:
        self.capture.close()
        self.capture = None
        self.cam0 = self.cam1 = None
        print("[CAM] Cameras off (idle).", flush=True)

    def _manage_cameras(self, now: float) -> None:
        """Once a loop: cameras up while the app wants tracking, off
        `camera_idle_off_s` after it stops; the state goes to the app."""
        if self._cam_thread is not None and not self._cam_thread.is_alive():
            self._cam_thread = None
            result, self._cam_result = self._cam_result, None
            if isinstance(result, StereoCapture):
                self.capture = result
                self.cam0, self.cam1 = result.cam0, result.cam1
            else:
                self._cam_retry_at = now + 5.0

        want = self._want_tracking and self.link.connected
        if want:
            self._unwanted_since = None
            if self.capture is None and self._cam_thread is None and now >= self._cam_retry_at:
                print("[CAM] Tracking requested: starting the cameras.", flush=True)
                self._start_cameras()
        elif self.capture is not None:
            if self._unwanted_since is None:
                self._unwanted_since = now
            elif now - self._unwanted_since >= self.camera_off_s:
                self._stop_cameras()

        tracking = want and self.capture is not None
        if tracking != self._tracking:
            self._set_tracking(tracking)
        if tracking:
            self.link.set_state(protocol.STATE_TRACKING)
        elif not want:
            self.link.set_state(protocol.STATE_IDLE)
        elif self._cam_thread is None:
            self.link.set_state(protocol.STATE_FAILED)    # waiting to retry
        else:
            self.link.set_state(protocol.STATE_STARTING)

    def _set_tracking(self, on: bool) -> None:
        """Tracking starts or stops. A session's recording covers only the
        tracked stretches: the games, not the menus between them."""
        self._tracking = on
        print(f"[TRACK] {'Tracking' if on else 'Idle'}.", flush=True)
        self._frame_count = 0
        self._send_count = 0
        self._stage_time = {k: 0.0 for k in self._stage_time}
        if on:
            self.capture.reset_counters()
            if self._hid is not None:
                self._start_session_recording()
        else:
            self._stop_session_recording()

    # ── Recording ─────────────────────────────────────────────────────────────

    def _open_rec_files(self, base_path: str) -> None:
        rec_dir = Path(base_path) / "recordings" / datetime.now().strftime("rec_%H-%M-%S")
        rec_dir.mkdir(parents=True, exist_ok=True)
        self._rec_dir = rec_dir

        metadata = {
            "patient_id":   self._hid,
            "session":      self._curr_session,
            "start_time":   datetime.now().isoformat(timespec="seconds"),
            "fps":          self.fps_value,
            "flip":         self.flip_frames,
            "resolution":   list(self.frame_size),
            "camera_model": self._camera_model,
            "fov":          self._camera_fov,
            "frame_sync":   self.frame_sync_enabled and self._frame_sync is not None,
            "calibration":  str(self._stereo_calib_path),
        }
        with open(rec_dir / "metadata.json", "w") as f:
            json.dump(metadata, f, indent=2)

        self._rec_file0 = open(rec_dir / "cam0_frame.msgpack", "wb")
        self._rec_file1 = open(rec_dir / "cam1_frame.msgpack", "wb")
        self._ts_file0  = open(rec_dir / "cam0_timestamp.msgpack", "wb")
        self._ts_file1  = open(rec_dir / "cam1_timestamp.msgpack", "wb")
        print(f"[REC] Recording to {rec_dir}")

    def _write_frames(
        self, frame0: np.ndarray, frame1: np.ndarray, sensor_ts0: int, sensor_ts1: int
    ) -> None:
        """Pack one frame pair. sensor_ts* are CLOCK_MONOTONIC ns from CAMSS —
        pair frames across cameras on those in post, not on frame index."""
        import msgpack
        import msgpack_numpy as mpn
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")
        self._rec_file0.write(msgpack.packb(frame0, default=mpn.encode))
        self._rec_file1.write(msgpack.packb(frame1, default=mpn.encode))
        self._ts_file0.write(msgpack.packb([ts, sensor_ts0]))
        self._ts_file1.write(msgpack.packb([ts, sensor_ts1]))

    def _close_rec_files(self) -> None:
        for fh in (self._rec_file0, self._rec_file1, self._ts_file0, self._ts_file1):
            if fh:
                fh.close()
        self._rec_file0 = self._rec_file1 = self._ts_file0 = self._ts_file1 = None
        print("[REC] Recording closed")

    # ── Transport ─────────────────────────────────────────────────────────────

    def _init_transport(self) -> None:
        if self.stream_type == "ble":
            # Imported here so a UDP-only install never needs bless.
            from ble_streamer import BLEStreamer
            self.streamer = BLEStreamer(self.ble_device_name)
        else:
            self.streamer = UDPStreamer(ip=self.udp_ip, port=self.udp_port)
        self.streamer.start()
        self.link = Link(self.streamer)

    def _end_link(self, why: str) -> None:
        """The app has gone (closed, crashed, out of range). The tracker
        outlives it, over either transport: the session closes and it waits for
        the next HELLO."""
        print(f"[LINK] {why}; session closed, waiting for the app.", flush=True)
        self._want_tracking = False
        self._close_session()
        self.link.reset()

    def _on_message(self, kind: int, body: bytes):
        """One app command, from Link.poll -> (ok, detail) for its ACK."""
        if kind == protocol.HELLO:
            # A new app: idle until it asks for tracking.
            self._want_tracking = False
            self._reload_settings()
            return True, ""
        if kind == protocol.RESTART:
            print("[LINK] RESTART from the app; exiting for systemd to start again.", flush=True)
            self.restart_requested = True
            return True, "restarting"
        if kind == protocol.CONFIG:
            return self._apply_config(body)
        if kind == protocol.TRUNK:
            return self._trunk_command(body)
        if kind == protocol.STORAGE:
            return self.storage.command(body.decode(errors="replace").strip())
        if kind == protocol.SESSION:
            hid = body.decode(errors="replace").strip()
            if not hid:
                return False, "empty patient id"
            self._open_session(hid)
            return True, hid
        if kind == protocol.STOP:
            # The session ends now; the link itself when the app goes quiet.
            print("[LINK] STOP from the app; session closed.")
            self._close_session()
            return True, ""
        return False, "unknown command"

    # settings.json key -> CONFIG key, for what can change without a restart.
    # The rest (cameras, transport, trunk thresholds, cores) need
    # `systemctl restart noark-tracker`.
    _LIVE_SETTINGS = {
        "tracker_solver": "solver", "tracker_refine": "refine",
        "tracker_camera": "camera", "corner_deadband_px": "deadband",
        "trunk_enabled": "trunk", "trunk_method": "trunk_method",
        "trunk_reference": "trunk_reference", "recording": "recording", "recording_fps": "recording_fps",
        "recording_scale": "recording_scale",
        "recording_chunk_frames": "recording_chunk_frames",
    }

    def _reload_settings(self) -> None:
        """At each HELLO: apply what settings.json now says, so an edit made in
        the app since the tracker started takes effect when the app connects
        (over UDP the two share the file)."""
        if self._settings_path is None or not Path(self._settings_path).exists():
            return
        try:
            settings = _load_settings(Path(self._settings_path))
        except (OSError, ValueError) as exc:
            print(f"[CFG] could not re-read {self._settings_path}: {exc}")
            return
        for name, key in self._LIVE_SETTINGS.items():
            if name not in settings:
                continue
            value = settings[name]
            if isinstance(value, bool):
                value = "on" if value else "off"
            try:
                self._apply_setting(key, str(value))
            except ValueError as exc:
                print(f"[CFG] settings.json {name}={value!r} ignored: {exc}")

    def _apply_config(self, payload: bytes):
        """CONFIG `<key>=<value>` from the app -> (ok, detail) for its ACK.
        Bad values are reported and refused, never fatal mid-session."""
        try:
            key, value = payload.decode().strip().split("=", 1)
            self._apply_setting(key, value)
        except ValueError as exc:
            print(f"[CFG] refused {payload!r}: {exc}")
            return False, str(exc)
        print(f"[CFG] {key} = {value}")
        return True, f"{key}={value}"

    def _apply_setting(self, key: str, value: str) -> None:
        """One live setting (docs/PROTOCOL.md, CONFIG). ValueError if refused.

        Keys: solver (joint|ransac), refine (crop|contour|subpix|none),
        camera (both|cam0|cam1), deadband (px; 0 = stabilizer off),
        trunk (on|off), trunk_method (icp|msam_r18|msam_v3rot),
        trunk_reference (neutral|model),
        track (on|off: the app wants tracking now; the cameras run only then),
        recording (on|off), recording_fps, recording_scale (0-1],
        recording_chunk_frames — the recording ones from the next session.
        """
        if key == "solver" and value in RigidBody.POSE_SOLVERS:
            self.solver = value
        elif key == "refine" and value in ("crop", "contour", "subpix", "none"):
            if value == "crop" and not _CROP_REFINE:
                raise ValueError("rapidtag build has no crop refine")
            self.refine_mode = value
            _set_detector_refine(value)
        elif key == "camera" and value in _CAMERA_CHOICES:
            self.camera_choice = value
            self.stereo_refine = value == "both"
            self._primary = 1 if value == "cam1" else 0
        elif key == "deadband":
            self.stabilizer.threshold_px = max(0.0, float(value))
        elif key == "trunk" and value in ("on", "off"):
            if (value == "on") != self.trunk_on:
                self._set_trunk(value == "on")
        elif key == "trunk_method" and value in ("icp", "msam_r18", "msam_v3rot"):
            if self._trunk_settings.get("trunk_method", "icp") != value:
                self._trunk_settings = {**self._trunk_settings, "trunk_method": value}
                if self.trunk is not None:
                    self.trunk.set_method(value)
        elif key == "trunk_reference" and value in ("neutral", "model"):
            if self._trunk_settings.get("trunk_reference", "neutral") != value:
                self._trunk_settings = {**self._trunk_settings, "trunk_reference": value}
                if self.trunk is not None:
                    self.trunk.set_reference(value)
        elif key == "track" and value in ("on", "off"):
            self._want_tracking = value == "on"
        elif key == "recording" and value in ("on", "off"):
            self.record_session = value == "on"
        elif key == "recording_fps" and float(value) > 0:
            self.recording_hz = float(value)
        elif key == "recording_scale" and 0 < float(value) <= 1:
            self.recording_scale = float(value)
        elif key == "recording_chunk_frames" and int(value) >= 0:
            self.recording_chunk = int(value)
        else:
            raise ValueError(f"unknown key or value: {key}={value}")

    def _open_trunk_csv(self) -> None:
        """trunk_debug: every trunk update next to the rigid body's latest pose,
        for scoring a trunk method against the marker strapped to the sternum
        (per-axis gain and cross-talk). One file per tracker start."""
        out = DATA_ROOT.parent / "trunk_debug"
        out.mkdir(parents=True, exist_ok=True)
        path = out / datetime.now().strftime("trunk_%Y-%m-%d_%H-%M-%S.csv")
        self._trunk_csv = open(path, "w", newline="", buffering=1)   # line by line: survives a kill
        self._trunk_csv_writer = csv.writer(self._trunk_csv)
        self._trunk_csv_writer.writerow([
            "time", "method", "state", "held", "doubt", "has_neutral", "flex", "lat", "axi",
            "cam_rx", "cam_ry", "cam_rz", "conf", "people",
            "marker_age_s", "marker_id", "marker_rx", "marker_ry", "marker_rz",
            "marker_tx", "marker_ty", "marker_tz", "flip", "reference"])
        self._marker = None
        print(f"[TRUNK] Debug log: {path}", flush=True)

    def _log_trunk(self, st) -> None:
        now = time.time()
        m = self._marker
        marker = ([round(now - m[0], 3), m[1], *np.round(m[2], 5), *np.round(m[3], 5)]
                  if m is not None else ["", "", "", "", "", "", "", ""])
        self._trunk_csv_writer.writerow([
            f"{now:.3f}", st.method, st.state_name, int(st.held), st.doubt, int(st.has_neutral),
            *(f"{a:.2f}" for a in st.angles), *(f"{c:.2f}" for c in st.cam_rot),
            f"{st.q_frac:.2f}", st.people, *marker, int(self.flip_frames), st.reference])

    def _send_position(self, centroid, ref_rvec, ref_tvec, ref_id: int) -> None:
        if self._trunk_csv is not None:
            self._marker = (time.time(), int(ref_id), np.ravel(ref_rvec), np.ravel(ref_tvec))
        self.link.send(protocol.encode_position(
            ref_id, np.ravel(centroid), np.ravel(ref_rvec), np.ravel(ref_tvec)))
        self._send_count += 1

    # ── Pose estimation ───────────────────────────────────────────────────────

    def _estimate_poses(self, corners0, ids0, corners1, ids1, allow_stereo=True):
        """
        Per-marker pose using stereo_pnp when the marker is visible in both
        cameras, falling back to single-cam PnP for markers in one view only.
        When allow_stereo is False (frames too skewed for valid triangulation)
        every marker is solved single-cam from its own view.
        Returns (ids, rvecs, tvecs) as parallel Python lists.
        """
        ids0_flat = np.array(ids0).flatten() if ids0 is not None else np.array([], dtype=int)
        ids1_flat = np.array(ids1).flatten() if ids1 is not None else np.array([], dtype=int)

        # Index cam1 corners by marker ID
        cam1_by_id: dict[int, np.ndarray] = {}
        if ids1 is not None:
            for i, mid in enumerate(ids1_flat):
                cam1_by_id[int(mid)] = corners1[i].reshape(4, 2).astype(np.float64)

        result_ids, result_rvecs, result_tvecs = [], [], []

        # Markers detected in cam0. Each solve is routed through the stabilizer,
        # which reuses the previous pose when the marker's corners are static.
        if ids0 is not None:
            for i, mid in enumerate(ids0_flat):
                mid = int(mid)
                c0 = corners0[i].reshape(4, 2).astype(np.float64)
                if mid in cam1_by_id and allow_stereo:
                    c1 = cam1_by_id[mid]
                    rvec, tvec = self.stabilizer.stabilize(
                        mid, {"c0": c0, "c1": c1},
                        lambda c0=c0, c1=c1: _stereo_pnp(
                            c0, c1, self.K0, self.D0, self.K1, self.D1,
                            self.R_st, self.T_st,
                        ),
                    )
                else:
                    rvec, tvec = self.stabilizer.stabilize(
                        mid, {"c0": c0},
                        lambda c0=c0: _single_cam_pnp(c0, self.K0, self.D0),
                    )
                if rvec is not None:
                    result_ids.append(mid)
                    result_rvecs.append(rvec)
                    result_tvecs.append(tvec)

        # Markers visible only in cam1 (not in cam0): solved in cam1 then
        # transformed into cam0's frame (see _cam1_pose).
        for mid, c1 in cam1_by_id.items():
            if mid not in result_ids:
                rvec, tvec = self.stabilizer.stabilize(
                    mid, {"c1": c1},
                    lambda c1=c1: self._cam1_pose(c1),
                )
                if rvec is not None:
                    result_ids.append(mid)
                    result_rvecs.append(rvec)
                    result_tvecs.append(tvec)

        return result_ids, result_rvecs, result_tvecs

    def _cam1_pose(self, c1: np.ndarray):
        """Single-cam PnP on cam1, transformed into cam0's frame.

        _single_cam_pnp returns the pose in cam1's frame; the stereo and
        cam0-only poses live in cam0's frame, so this re-expresses it there
        (otherwise the centroid jumps by the stereo baseline on cam1-only).
        """
        rvec1, tvec1 = _single_cam_pnp(c1, self.K1, self.D1)
        if rvec1 is None:
            return None, None
        R1   = cv2.Rodrigues(rvec1)[0]
        R_c0 = self.R_st.T @ R1
        t_c0 = self.R_st.T @ (tvec1.reshape(3, 1) - self.T_st)
        return cv2.Rodrigues(R_c0)[0].flatten(), t_c0.flatten()

    def _board_pose(self, corners0, ids0, corners1, ids1, allow_stereo=True):
        """One pose for the whole marker cluster, from every visible corner.

        Replaces the per-marker solve-and-average: the tags are one rigid body,
        so fitting them together uses the constraint that averaging throws away.
        Up to 40 corners across two cameras condition the pose far better than
        any one tag's four.

        Returns (rvec, tvec) in cam0's frame, or (None, None) when nothing that
        belongs to the calibrated body is in view.
        """
        det0 = self._detections_by_id(corners0, ids0)
        det1 = self._detections_by_id(corners1, ids1)
        if not det0 and not det1:
            return None, None

        # Freeze the pose while every contributing corner is static: the solve
        # is the expensive part of the frame, and a still device only produces
        # PnP jitter. Keys are per view and per marker, so the stabilizer sees
        # a marker appear or leave as a change of measurement and re-solves.
        #
        # Only the views the solve actually reads are gated on. Handing it both
        # cameras while tracking on one made the freeze markedly rarer — every
        # corner set has to hold still at once — and let noise in a camera that
        # contributes nothing to the answer decide whether to recompute it.
        # Decide which views the answer comes from once, so the gate and the
        # solve cannot drift apart. One camera: the configured one leads, and
        # the other stands in when only it can see the body.
        if det0 and det1 and allow_stereo and self.stereo_refine:
            views = ("c0", "c1")
        elif self._primary == 0:
            views = ("c0",) if det0 else ("c1",)
        else:
            views = ("c1",) if det1 else ("c0",)

        corner_sets = {}
        if "c0" in views:
            corner_sets.update({f"c0_{mid}": c for mid, c in det0.items()})
        if "c1" in views:
            corner_sets.update({f"c1_{mid}": c for mid, c in det1.items()})

        def compute():
            if views == ("c0", "c1"):
                rvec, tvec = self.rig.stereo_pose(
                    det0, det1, self.K0, self.D0, self.K1, self.D1,
                    self.R_st, self.T_st, self.solver,
                )
                if rvec is not None:
                    return rvec, tvec
                # Stereo declined this frame; fall back to the lead camera. The
                # gate covered both views, which only costs an extra solve.
                return (self.rig.mono_pose(det0, self.K0, self.D0, self.solver)
                        if self._primary == 0 else self._pose_from_cam1(det1))
            # A single-camera answer still comes back in cam0's frame, or the
            # point jumps by the stereo baseline whenever the lead camera loses
            # sight of the device.
            if views == ("c0",):
                return self.rig.mono_pose(det0, self.K0, self.D0, self.solver)
            return self._pose_from_cam1(det1)

        return self.stabilizer.stabilize(_BOARD_KEY, corner_sets, compute)

    def _pose_from_cam1(self, det1: dict):
        """cam1's own solve, carried into cam0's frame."""
        rvec, tvec = self.rig.mono_pose(det1, self.K1, self.D1, self.solver)
        if rvec is None:
            return None, None
        return self.rig.pose_in_cam1_frame(rvec, tvec, self.R_st, self.T_st)

    @staticmethod
    def _camera_default(stereo_refine, configured, have_refit) -> str:
        """The camera choice when neither the command line nor settings.json says.

        Preserves what the older booleans meant, so a rig configured before
        `tracker_camera` existed keeps behaving the same: --stereo-refine, then
        device.toml's stereo_pose, then "only when the calibration brought its
        own extrinsic" — since a stereo fit against the wrong extrinsic is far
        worse than one camera on its own.
        """
        if stereo_refine is not None:
            return "both" if stereo_refine else "cam0"
        if configured is not None:
            return "both" if configured else "cam0"
        return "both" if have_refit else "cam0"

    @staticmethod
    def _detections_by_id(corners, ids) -> dict:
        """{marker id: (4, 2) corners} for one camera's detections."""
        if ids is None:
            return {}
        return {
            int(mid): np.asarray(c, dtype=np.float64).reshape(4, 2)
            for mid, c in zip(np.asarray(ids).flatten(), corners)
        }

    def _get_centroid(self, ids, rvecs, tvecs) -> np.ndarray:
        transformed = []
        for mid, rvec, tvec in zip(ids, rvecs, tvecs):
            if mid in self.marker_offsets:
                R = cv2.Rodrigues(rvec)[0]
                pt = (R @ self.marker_offsets[mid].reshape(3, 1) + tvec.reshape(3, 1)).flatten()
                transformed.append(pt)
        return np.nanmean(transformed, axis=0) if transformed else np.zeros(3)

    # ── CSV recording ─────────────────────────────────────────────────────────

    def _open_session(self, hid: str) -> None:
        """SESSION: the app repeats it every heartbeat, so the same id again is
        a no-op; a different one closes this session and opens theirs."""
        if not hid or hid == self._hid:
            return
        if self._hid is not None:
            print(f"[SESSION] Patient {self._hid} -> {hid}")
            self._close_session()
        self._hid = hid
        self.save_path = os.path.join(DATA_ROOT, self._hid, self._curr_session)
        os.makedirs(self.save_path, exist_ok=True)
        csv_path = os.path.join(
            self.save_path,
            datetime.now().strftime("%Y_%m_%d_%H_%M_%S") + "_data.csv",
        )
        self._csv_file = open(csv_path, "w", newline="")
        self.csv_writer = csv.writer(self._csv_file)
        self.csv_writer.writerow(["Time", "X", "Y", "Z"])

        if self.record_frames and self._rec_file0 is not None:
            self._close_rec_files()
        if self.record_frames:
            self._open_rec_files(self.save_path)
        if self._tracking:
            self._start_session_recording()
        self.record = True

    def _close_session(self) -> None:
        """End the patient's session: the next SESSION, even for the same
        patient, opens a new one (a BLE reconnect starts recording again)."""
        self._stop_session_recording()
        if self._csv_file is not None:
            self._csv_file.close()
        self._csv_file = self.csv_writer = None
        self.save_path = self._hid = None
        self.record = False

    def _start_session_recording(self) -> None:
        """Begin recording this session's frames, if settings.json asks for it.

        Started here rather than at launch because the patient id is what names
        the directory, and that only arrives with the SESSION message.
        """
        if not self.record_session or self.recorder is not None:
            return
        out_dir = (
            Path(self.save_path).parent / "Video"
            / datetime.now().strftime("rec_%H-%M-%S")
        )
        self.recorder = FrameRecorder(
            out_dir,
            metadata={
                "patient_id": self._hid,
                "session": self._curr_session,
                "resolution": list(self.frame_size),
                "camera_order": list(self._camera_order),
                "exposure_us": self._exposure_us,
                "gain": self._gain,
                "isp": self._isp or "raw",
                "rigidbody": str(self._rigidbody_path),
            },
            sync_chip=self._sync_chip,
            sync_pin=self._sync_pin,
            target_hz=self.recording_hz,
            chunk_frames=self.recording_chunk,
            scale=self.recording_scale,
        )

    def _recording_dirs(self) -> list:
        """The recordings being written now, which Storage must not delete."""
        dirs = [self.recorder.out_dir] if self.recorder is not None else []
        if self._rec_file0 is not None:
            dirs.append(self._rec_dir)
        return dirs

    def _stop_session_recording(self) -> None:
        if self.recorder is not None:
            self.recorder.close()
            self.recorder = None

    # ── Main loop ─────────────────────────────────────────────────────────────

    def process_frame(self) -> None:
        # Capture grayscale frames from both cameras concurrently
        t0 = time.perf_counter()
        raw0, raw1, ts0, ts1, allow_stereo = self.capture.next_pair()
        if self.recorder is not None:
            # Full resolution, before the flip: what is written should be what
            # the sensor saw. recording_scale shrinks it on the writer thread,
            # after this, so detection below always runs on the full frame
            # whatever the recording is configured to keep.
            self.recorder.add(raw0, raw1, ts0, ts1, self.capture.last_sequence)
        self._frame_count += 1
        if self.trunk is not None and self.trunk_on:
            # Before the flip: the stereo calibration describes the sensor image.
            self.trunk.submit(raw0, raw1)
        if self.flip_frames:
            raw0 = cv2.flip(raw0, 1)
            raw1 = cv2.flip(raw1, 1)
        if self.record_frames and self._rec_file0 is not None:
            self._write_frames(raw0, raw1, ts0, ts1)
        t1 = time.perf_counter()
        self._stage_time["capture"] += t1 - t0

        # Detect on raw fisheye frames (corner-undistort pipeline). rapidtag's
        # batch API applies flat (frame x scale) parallelism across cores when
        # given every camera's frame at once — faster than a detector call per
        # camera (see rcam/bench_rapidtag.py).
        (corners0, ids0), (corners1, ids1) = rapidtag.detect_markers_batch(
            [raw0, raw1], _APRILTAG_DICT, _DETECTOR_PARAMS
        )
        ids0 = np.array(ids0, dtype=int).reshape(-1, 1) if ids0 else None
        ids1 = np.array(ids1, dtype=int).reshape(-1, 1) if ids1 else None
        t2 = time.perf_counter()
        self._stage_time["detect"] += t2 - t1

        if self.refine_mode == "subpix":
            if ids0 is not None:
                corners0 = _refine_corners(raw0, corners0)
            if ids1 is not None:
                corners1 = _refine_corners(raw1, corners1)
        t3 = time.perf_counter()
        self._stage_time["refine"] += t3 - t2

        # Before pose estimation: a STOP or SESSION must not wait for a marker
        # to be in view (recording exists for exactly the frames that fail).
        self.link.poll(self._on_message)
        self.link.tick()
        storage_list = self.storage.poll()
        if storage_list and self.link.connected:
            self.link.send(storage_list)

        if self.trunk is not None and self.trunk_on:
            self._send_trunk()

        # Pose estimation. With a calibrated body it is one joint solve over
        # every visible corner; without one, a pose per marker whose tip offsets
        # are then averaged.
        if self.rig is not None:
            board_rvec, board_tvec = self._board_pose(
                corners0, ids0, corners1, ids1, allow_stereo=allow_stereo
            )
            have_pose = board_rvec is not None
        else:
            ids, rvecs, tvecs = self._estimate_poses(
                corners0, ids0, corners1, ids1, allow_stereo=allow_stereo
            )
            have_pose = bool(ids)
        self._stage_time["pose"] += time.perf_counter() - t3

        if have_pose:
            if self.rig is not None:
                centroid = self.filter.update(self.rig.tip(board_rvec, board_tvec))
                # The pose is already in the reference tag's frame, so Godot's
                # set_origin() applies that one tag's tip offset and lands on
                # exactly this centroid.
                ref_id   = self.rig.reference_id
                ref_rvec = board_rvec
                ref_tvec = board_tvec
            else:
                centroid = self.filter.update(self._get_centroid(ids, rvecs, tvecs))
                ref_id   = ids[0]
                ref_rvec = rvecs[0]
                ref_tvec = tvecs[0]

            if self.link.connected:
                self._send_position(centroid, ref_rvec, ref_tvec, ref_id)

                if self.record and self.csv_writer:
                    self.csv_writer.writerow(
                        [datetime.now().strftime("%d/%m/%Y %H:%M:%S"), *centroid]
                    )

        if self.display:
            disp0 = cv2.cvtColor(raw0, cv2.COLOR_GRAY2BGR)
            disp1 = cv2.cvtColor(raw1, cv2.COLOR_GRAY2BGR)
            if ids0 is not None:
                disp0 = _draw_markers(disp0, corners0, ids0)
            if ids1 is not None:
                disp1 = _draw_markers(disp1, corners1, ids1)
            disp0 = cv2.resize(disp0, (350, 200))
            disp1 = cv2.resize(disp1, (350, 200))
            cv2.imshow("frame", np.hstack([disp0, disp1]))

    def _idle_step(self) -> None:
        """A loop without tracking: the link and storage only. Cameras still
        up in their grace period are drained, so their queues are fresh when
        tracking resumes."""
        if self.capture is not None:
            self.capture.next_pair()
        else:
            time.sleep(0.02)
        self.link.poll(self._on_message)
        self.link.tick()
        storage_list = self.storage.poll()
        if storage_list and self.link.connected:
            self.link.send(storage_list)

    def _release_starting_cameras(self) -> None:
        """Exiting while the cameras are still coming up: wait, then free them."""
        self._cam_thread.join(timeout=60)
        if isinstance(self._cam_result, StereoCapture):
            self._cam_result.close()

    def run(self) -> None:
        """Track until stopped (Ctrl-C, the service stopping). Apps come and go."""
        last_rate_log  = time.time()
        last_resync    = time.time()

        try:
            while not self.restart_requested:
                self._manage_cameras(time.time())
                if self._tracking:
                    self.process_frame()
                else:
                    self._idle_step()
                if self.link.connected and self.link.silent_for() > 3.0:
                    self._end_link("No heartbeat for 3 s")

                now = time.time()
                if self.capture is None:
                    last_rate_log = now
                    continue
                if self.resync_every_s > 0 and now - last_resync >= self.resync_every_s:
                    last_resync = now
                    self.capture.maybe_resync()

                elapsed = now - last_rate_log
                if not self._tracking:
                    last_rate_log = now
                elif elapsed >= 5.0:
                    fps = self._frame_count / elapsed
                    pkt_rate = self._send_count / elapsed
                    n = max(self._frame_count, 1)
                    stage_ms = {k: (v / n) * 1000.0 for k, v in self._stage_time.items()}
                    print(f"[FPS] cam0: {fps:.1f}  cam1: {fps:.1f}  "
                          f"({pkt_rate:.1f} pkt/s sent, "
                          f"{self.capture.dropped} sensor frames skipped, "
                          f"{self.capture.stale_skipped} stale pairs skipped)")
                    report = self.capture.phase_report()
                    if report is not None:
                        print(f"[SYNC] phase: {report.phase_us:+.0f} µs  "
                              f"jitter: {report.jitter_us:.0f} µs  "
                              f"drift: {report.drift_ppm:+.0f} ppm  "
                              f"({abs(report.phase_us) / self.capture.frame_period_us * 100:.2f}% "
                              f"of a frame)  re-paired: {self.capture.repairs}")
                    if self.recorder is not None:
                        print(f"[REC] {self.recorder.status}")
                    print(f"[STAGE ms/frame] capture: {stage_ms['capture']:.2f}  "
                          f"detect: {stage_ms['detect']:.2f}  "
                          f"refine: {stage_ms['refine']:.2f}  "
                          f"pose: {stage_ms['pose']:.2f}")
                    self._frame_count = 0
                    self._send_count  = 0
                    self.capture.reset_counters()
                    self._stage_time  = {k: 0.0 for k in self._stage_time}
                    last_rate_log     = now

                if self.display and cv2.waitKey(1) & 0xFF == ord("q"):
                    break
            if self.restart_requested:
                time.sleep(0.3)   # lets the ACK out over BLE before the transport stops
        finally:
            # Each step on its own: one failing (the trunk worker already gone
            # after a Ctrl-C) must not skip the rest — a skipped streamer.stop()
            # leaves the BLE advertisement on with nothing behind it.
            steps = []
            if self.record_frames and self._rec_file0 is not None:
                steps.append(self._close_rec_files)
            steps.append(self._stop_session_recording)
            if getattr(self, "trunk", None) is not None:
                steps.append(self.trunk.stop)
            if getattr(self, "capture", None) is not None:
                steps.append(self.capture.close)
            if getattr(self, "_cam_thread", None) is not None:
                steps.append(self._release_starting_cameras)
            if hasattr(self, "streamer"):
                steps.append(self.streamer.stop)
            if self.display:
                steps.append(cv2.destroyAllWindows)
            for step in steps:
                try:
                    step()
                except Exception as exc:
                    print(f"[EXIT] {getattr(step, '__qualname__', step)}: {exc!r}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--settings", type=Path, default=DEFAULT_SETTINGS_PATH,
                        help="The user settings file (default: ~/Documents/NOARK_demo/settings.json).")
    parser.add_argument("--record", action="store_true", help="Record raw frames from both cameras")
    parser.add_argument("--fps", type=int, default=60, choices=[15, 30, 60, 90, 100],
                         help="Cap the sensor FrameRate. Omit to free-run at max achievable fps.")
    parser.add_argument("--flip", action=argparse.BooleanOptionalAction, default=False)
    parser.add_argument("--cpus", default=None, metavar="LIST",
                        help="Cores to run on, e.g. 4-7, overriding "
                             "settings.json tracker_cpus. On this board 0-3 are "
                             "the little cores and 4-7 the big ones.")
    parser.add_argument("--stereo-refine", action=argparse.BooleanOptionalAction,
                        default=None,
                        help="Refine the board pose across both cameras. Defaults "
                             "to on only when the calibration carries a "
                             "self-calibrated stereo extrinsic, since a wrong one "
                             "is far worse than using a single camera.")
    parser.add_argument("--camera", choices=sorted(_CAMERA_CHOICES), default=None,
                        help="Which cameras the pose is solved from. Defaults to "
                             "settings.json tracker_camera.")
    parser.add_argument("--solver", choices=RigidBody.POSE_SOLVERS, default=None,
                        help="How the board pose is estimated from the visible "
                             "corners: 'joint' fits all of them, 'ransac' uses "
                             "rapidtag's consensus fit and drops corners that "
                             "disagree. Defaults to device.toml [tracking] solver.")
    parser.add_argument("--rigidbody", type=Path,
                        default=_SCRIPT_DIR / "calibration" / "rigidbody.toml",
                        help="Calibrated marker geometry from rigidbody_calib.py. "
                             "Without it the hand-measured MARKER_OFFSETS are used.")
    parser.add_argument("--frame-sync", action=argparse.BooleanOptionalAction, default=True,
                        help="Align the two sensors' frame phase before tracking, and top "
                             "the alignment up as the crystals drift apart. "
                             "--no-frame-sync lets them free-run.")
    parser.add_argument("--phase-tol", type=float, default=200.0,
                        help="Stop aligning once the two sensors are within this many µs "
                             "(default: 200, near the measurement floor).")
    parser.add_argument("--resync-every", type=float, default=5.0,
                        help="Seconds between mid-session phase checks (0 disables).")
    parser.add_argument("--resync-threshold", type=float, default=1000.0,
                        help="Only re-nudge once the phase has drifted past this many µs. "
                             "Each nudge costs one stretched frame interval, so keep it "
                             "well above the ~150 µs measurement jitter (default: 1000).")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.WARNING, format="%(asctime)s %(message)s",
        datefmt="%H:%M:%S", force=True,
    )
    logging.getLogger(__name__).setLevel(logging.DEBUG)
    settings = _load_settings(args.settings)

    # Before anything spawns a thread.
    _pin_to_cpus(args.cpus if args.cpus is not None else settings.get("tracker_cpus"))

    tracker = TrackerClass(
        stereo_calib_path=_SCRIPT_DIR / "calibration" / "sterio_calibration.toml",
        aruco_calib_path=_SCRIPT_DIR / "calibration" / "good.toml",
        rigidbody_path=args.rigidbody,
        device_path=_SCRIPT_DIR / "calibration" / "device.toml",
        stereo_refine=args.stereo_refine,
        solver=args.solver,
        camera=args.camera,
        settings=settings,
        settings_path=args.settings,
        record_frames=args.record,
        fps_value=args.fps,
        flip_frames=args.flip,
        frame_sync=args.frame_sync,
        phase_tol_us=args.phase_tol,
        resync_every_s=args.resync_every,
        resync_threshold_us=args.resync_threshold,
    )
    tracker.run()
    if tracker.restart_requested:
        sys.exit(75)   # non-zero: systemd (Restart=on-failure) starts it again
