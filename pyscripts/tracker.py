import argparse
import collections
import csv
import json
import logging
import os
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

from corner_stabilizer import CornerStabilizer
from filters import ExponentialMovingAverageFilter3D
from rigid_body import RigidBody
from udp_streamer import UDPStreamer


_SCRIPT_DIR = Path(__file__).parent

_APRILTAG_DICT = "DICT_APRILTAG_36h11"

# Hand-measured fallback, used only when no rigidbody.toml has been produced
# yet: each entry is the device tip expressed in that marker's own frame. These
# were measured by hand and disagree with each other by centimetres, which is
# what `rigidbody_calib.py` exists to replace — see MARKER_OFFSETS' use in
# _get_centroid() versus the joint board solve in rigid_body.py.
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

_SUBPIX_CRITERIA = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 40, 0.01)

# Stabilizer key for the whole-body pose, kept out of the marker-id space.
_BOARD_KEY = -1


def _load_settings() -> dict:
    path = _SCRIPT_DIR.parent / "settings.json"
    if path.exists():
        with open(path) as f:
            return json.load(f)
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


class TrackerClass:
    PHASE_WINDOW = 90   # frames of timestamp history the phase/resync fit uses

    def __init__(
        self,
        stereo_calib_path: Path,
        aruco_calib_path: Path,
        rigidbody_path: Path,
        settings: Optional[dict] = None,
        record_frames: bool = False,
        fps_value: Optional[int] = None,
        flip_frames: bool = True,
        stereo_refine: bool = True,
        frame_sync: bool = True,
        phase_tol_us: float = 200.0,
        resync_every_s: float = 5.0,
        resync_threshold_us: float = 1000.0,
    ) -> None:
        if settings is None:
            settings = {}

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
        sc = toml.load(stereo_calib_path)

        self.K0 = np.array(sc["cam0"]["camera_matrix"])
        self.D0 = np.array(sc["cam0"]["dist_coeffs"]).reshape(4, 1)
        self.K1 = np.array(sc["cam1"]["camera_matrix"])
        self.D1 = np.array(sc["cam1"]["dist_coeffs"]).reshape(4, 1)
        self.R_st = np.array(sc["stereo"]["R"])
        self.T_st = np.array(sc["stereo"]["T"]).reshape(3, 1) / 1000.0  # mm → m

        res = sc["cam0"]["resolution"]
        self.frame_size = (res[0], res[1])  # (width, height)

        # ── marker / stream / display settings ────────────────────────────────
        ac = toml.load(aruco_calib_path)
        self.udp_ip            = settings.get("udp_ip",   ac["stream_data"]["ip"])
        self.udp_port          = settings.get("udp_port", ac["stream_data"]["port"])
        self.display           = settings.get("display",  ac["display"]["display"])
        self._camera_model     = ac["camera"].get("model", "OV9281")
        self._camera_fov       = ac["camera"].get("fov", 160)

        # Refining the board pose across both cameras is the better estimator,
        # but it runs in Python and costs roughly 5 ms a frame of pure compute
        # plus the contention that brings — measured ~32 -> ~17 fps end to end.
        # Turn it off to trade the cross-baseline depth constraint for rate.
        self.stereo_refine = stereo_refine

        # ── Rigid body ────────────────────────────────────────────────────────
        # When the marker cluster has been calibrated, every visible tag feeds
        # one joint PnP for the whole body; without a calibration we fall back
        # to averaging each tag's hand-measured offset independently.
        self.rig = RigidBody.load(rigidbody_path)
        if self.rig is not None:
            print(f"[RIG] Calibrated body: {self.rig.describe()}")
        else:
            print(
                f"[RIG] No calibration at {rigidbody_path} — falling back to the "
                "hand-measured MARKER_OFFSETS. Run pyscripts/rigidbody_calib.py."
            )

        # ── Remaining state ───────────────────────────────────────────────────
        self.filter         = ExponentialMovingAverageFilter3D(alpha=1)
        self.stabilizer     = CornerStabilizer(
            threshold_px=settings.get("corner_deadband_px", 0.25)
        )
        self.marker_offsets = MARKER_OFFSETS

        self.cam0     = None   # primary (tracking + display)
        self.cam1     = None   # stereo second view
        self._executor        = None
        # Placeholder — replaced with the sensor's true frame period once the
        # cameras are running (from rcam.FrameSync, or measured in
        # _measure_phase_offset() when frame sync is unavailable).
        self._frame_period_us = 0.0
        self._skew_baseline_us = 0.0   # measured cam0→cam1 sensor phase offset
        self._frame_sync   = None      # rcam.FrameSync once both cameras are up
        self._resync_busy  = threading.Event()
        # Sensor timestamps the resync/phase report work off. Appended from
        # process_frame, snapshotted elsewhere — a deque with maxlen is the
        # whole synchronisation, no lock needed.
        self._recent_ns    = (
            collections.deque(maxlen=self.PHASE_WINDOW),
            collections.deque(maxlen=self.PHASE_WINDOW),
        )
        self._last_seq     = [None, None]
        self._dropped      = [0, 0]    # frames the sensors made that never arrived
        self._repairs      = 0         # times the capture queues had to be re-paired
        self.tvec_dist    = np.zeros(3)
        self.save_path    = None
        self._send_count  = 0
        self._frame_count = 0
        self._stage_time  = {"capture": 0.0, "detect": 0.0, "refine": 0.0, "pose": 0.0}
        self.csv_writer   = None
        self.record       = False
        self.received_message: bytes = b""
        self._stop_requested = False
        self._rec_file0 = self._rec_file1 = None
        self._ts_file0  = self._ts_file1  = None

        self._curr_session = os.path.join(
            "Session-" + datetime.today().strftime("%Y-%m-%d"), "MovementData"
        )

        # ── Cameras + transport ───────────────────────────────────────────────
        if platform.system() == "Linux":
            self._init_cameras()
        else:
            raise RuntimeError("Stereo tracking requires Radxa Dragon Q6A dual-camera hardware.")

        self._init_udp_socket()

    # ── Cameras ───────────────────────────────────────────────────────────────

    def _init_cameras(self) -> None:
        from rcam import Camera, list_cameras

        labels = list_cameras()
        if len(labels) < 2:
            raise RuntimeError(
                f"Stereo tracking requires two OV9281 cameras; found {labels or 'none'} "
                "(is the driver loaded? try: sudo modprobe ov9282)"
            )

        # No FrameRate control means the sensor free-runs at whatever rate its
        # current exposure/blanking allows — i.e. max achievable fps.
        cam_controls = {"ExposureTime": 5000}
        if self.fps_value is not None:
            cam_controls["FrameRate"] = self.fps_value

        self.cam0 = Camera(labels[0])
        self.cam0.configure(size=self.frame_size, bit_depth=8)
        self.cam0.set_controls(cam_controls)
        self.cam0.start()

        # cam1 is always active — used for stereo_pnp on every frame
        self.cam1 = Camera(labels[1])
        self.cam1.configure(size=self.frame_size, bit_depth=8)
        self.cam1.set_controls(cam_controls)
        self.cam1.start()

        # Concurrent grab: issue both captures in parallel so the inter-camera
        # gap collapses to the sensors' fixed phase offset (not a full frame).
        self._executor = ThreadPoolExecutor(max_workers=2)

        self._init_frame_sync()
        self._align_pairing()
        self._measure_phase_offset(60)  # fixed calibration sample, independent of target fps

    # ── Frame synchronisation ─────────────────────────────────────────────────

    def _init_frame_sync(self) -> None:
        """Bring cam1's frame phase onto cam0's before tracking starts.

        The two sensors self-clock off separate 24 MHz crystals with no FSIN
        wiring between them, so they free-run at an arbitrary phase — cold, that
        can be most of a frame period. Stereo triangulation of a *moving* marker
        then fuses two different instants, which shows up as a position error
        proportional to hand speed (half a frame at 90 fps is ~5.5 ms).

        rcam.FrameSync walks cam1 onto cam0 by briefly stretching its vertical
        blanking, which lands the pair inside ~100 µs. The crystals still differ
        by ~50 ppm (~3 ms/minute), so run() tops the alignment up from the
        sensor timestamps as they arrive — see _resync().
        """
        from rcam import FrameSync

        try:
            self._frame_sync = FrameSync(self.cam0, self.cam1)
        except RuntimeError as exc:
            # The v4l2-ctl fallback backend exposes no buffer timestamps, so
            # there is nothing to measure a phase from. Tracking still works;
            # the sensors just free-run and the skew gating falls back to
            # software arrival times.
            print(f"[SYNC] Frame sync unavailable: {exc}")
            self._frame_sync = None
            return

        self._frame_period_us = self._frame_sync.period_us
        if not self.frame_sync_enabled:
            print("[SYNC] Frame sync disabled (--no-frame-sync); sensors free-run.")
            return

        print(
            f"[SYNC] Aligning cam1 → cam0 "
            f"({self._frame_period_us / 1000:.2f} ms frame period, "
            f"{self._frame_sync.line_time_us:.2f} µs/line):"
        )
        self._frame_sync.align(tol_us=self.phase_tol_us)

    def _drain(self, cam, n: int) -> None:
        """Discard n queued frames from one camera without copying pixels out."""
        for _ in range(n):
            try:
                cam.capture_meta()
            except RuntimeError:       # v4l2-ctl fallback has no capture_meta
                cam.capture_buffer()

    def _pair_slip(self, n_pairs: int = 15) -> float:
        """Median cam0→cam1 skew over n_pairs, in µs."""
        skews = sorted((ts1 - ts0) / 1000.0
                       for _, _, ts0, ts1 in
                       (self._capture_pair() for _ in range(max(1, n_pairs))))
        return skews[len(skews) // 2]

    def _align_pairing(self, max_iters: int = 4) -> None:
        """Pair the two capture queues on the same frame, not just the same phase.

        Aligning the sensors puts both exposures at the same instant, but each
        camera has its own V4L2 buffer queue and capture_array_meta() returns
        the *oldest* one. cam0 starts streaming while cam1 is still being
        configured, so it banks several frames the other never had — measured
        cold, three. Draining both in step preserves that offset forever (which
        is why it survived every flush), and software arrival timestamps cannot
        see it at all: both grabs return "now" in userspace whether the buffer
        is fresh or 50 ms stale.

        The sensor timestamps make it visible as a skew of whole frame periods,
        and the fix is asymmetric: drop exactly that many frames from whichever
        camera is behind.
        """
        if not self._frame_period_us:
            return
        for _ in range(max_iters):
            skew_us = self._pair_slip()
            slip = int(round(skew_us / self._frame_period_us))
            if slip == 0:
                return
            # skew > 0 means cam1's frame is the newer one, i.e. cam0 is the
            # camera handing back stale buffers.
            lagging, count = (self.cam0, slip) if slip > 0 else (self.cam1, -slip)
            print(f"[SYNC] Capture queues {slip:+d} frames apart "
                  f"({skew_us / 1000:+.1f} ms) — dropping {count} stale frame(s)")
            self._drain(lagging, min(count, 8))

    def _catch_up(self, raw0, raw1, ts0: int, ts1: int, max_iters: int = 3):
        """Pull the lagging camera forward until the pair is simultaneous again.

        With the sensors free-running faster than this loop can consume them,
        the driver drops whichever frames don't fit in a camera's queue — and it
        doesn't drop the same ones on both, so the pairing slips a frame every
        few hundred frames and then stays slipped. Jitter is ~100 µs against a
        half-period of several ms, so a whole-frame slip is never noise.

        Re-grabbing (rather than only draining) keeps the frame usable: the
        lagging camera's newer frames are already sitting in its queue, so this
        returns without waiting on the sensor, and the pair can still be
        triangulated instead of falling back to two single-camera poses.
        """
        for _ in range(max_iters):
            skew_us = (ts1 - ts0) / 1000.0
            slip = int(round((skew_us - self._skew_baseline_us) / self._frame_period_us))
            if slip == 0:
                break
            count = min(abs(slip), 8)
            if slip > 0:   # cam1's frame is the newer one, so cam0 is behind
                self._drain(self.cam0, count - 1)
                raw0, ts0, seq = self._grab(self.cam0)
                self._note_meta(0, ts0, seq)
            else:
                self._drain(self.cam1, count - 1)
                raw1, ts1, seq = self._grab(self.cam1)
                self._note_meta(1, ts1, seq)
            self._repairs += 1
        return raw0, raw1, ts0, ts1

    def _phase_now(self):
        """Inter-camera phase from the timestamps process_frame already kept.

        Pure arithmetic over the two deques — it takes no frames of its own, so
        it is safe to call from the reporting path mid-capture.
        """
        if self._frame_sync is None:
            return None
        from rcam import phase_from_timestamps

        stamps = [list(d) for d in self._recent_ns]
        if min(len(x) for x in stamps) < 10:
            return None
        return phase_from_timestamps(stamps[0], stamps[1], self._frame_sync.period_us)

    def _resync(self) -> None:
        """Top up the alignment against the ~50 ppm drift between the crystals.

        Runs on its own thread: a nudge is two v4l2-ctl calls around a sleep of
        roughly a frame period, and doing that inline would stall tracking for
        as long. The measurement itself takes no frames — it reuses the
        timestamps already collected — and the one stretched frame interval a
        nudge produces is absorbed by _catch_up() on the next pair.
        """
        if self._frame_sync is None or self._resync_busy.is_set():
            return
        stamps = [list(d) for d in self._recent_ns]
        if min(len(x) for x in stamps) < 30:
            return
        self._resync_busy.set()

        def work():
            try:
                report = self._frame_sync.resync_if_needed(
                    stamps[0], stamps[1], self.resync_threshold_us
                )
                if report is not None:
                    print(f"[SYNC] Phase was {report.phase_us:+.0f} µs — nudged")
            except Exception as exc:  # a failed nudge must not end the session
                print(f"[SYNC] Resync failed: {exc!r}")
            finally:
                self._resync_busy.clear()

        threading.Thread(target=work, name="resync", daemon=True).start()

    @staticmethod
    def _grab(cam):
        """Grab one frame plus the kernel's frame timestamp (ns) and sequence.

        The timestamp is CLOCK_MONOTONIC as stamped by CAMSS in its frame-done
        interrupt, so it carries ~100 µs of jitter rather than the 1–2 ms a
        userspace arrival time picks up. That is what lets the skew gate below
        tell a genuinely simultaneous pair from one that slipped a frame.
        `sequence` is the driver's frame counter: a gap in it means the sensor
        produced a frame that never reached us, which a timestamp gap alone
        cannot separate from this thread being descheduled.

        Both are None on rcam's v4l2-ctl fallback backend, where the buffer
        header isn't reachable — fall back to a software stamp there.
        """
        arr, ts_ns, seq = cam.capture_array_meta()
        if ts_ns is None:
            ts_ns = time.perf_counter_ns()
        return arr, ts_ns, seq

    def _note_meta(self, i: int, ts: int, seq: Optional[int]) -> None:
        """Record one camera's frame timestamp and account for skipped frames."""
        self._recent_ns[i].append(ts)
        if seq is not None:
            last = self._last_seq[i]
            if last is not None and seq - last > 1:
                self._dropped[i] += seq - last - 1
            self._last_seq[i] = seq

    def _capture_pair(self):
        """Grab both cameras concurrently; return (frame0, frame1, ts0, ts1) in ns."""
        f0 = self._executor.submit(self._grab, self.cam0)
        f1 = self._executor.submit(self._grab, self.cam1)
        frame0, ts0, seq0 = f0.result()
        frame1, ts1, seq1 = f1.result()
        self._note_meta(0, ts0, seq0)
        self._note_meta(1, ts1, seq1)
        return frame0, frame1, ts0, ts1

    def _measure_phase_offset(self, n_frames: int) -> None:
        """Establish the baseline cam0→cam1 capture skew over n_frames.

        With frame sync applied this lands near zero and the gating in
        process_frame() is effectively "this pair is simultaneous"; with
        --no-frame-sync (or on the fallback backend) it is whatever phase the
        sensors happened to free-run into, and the gate still catches a pair
        that slipped a frame relative to that baseline.

        When no FrameSync is available the frame period isn't readable from the
        sensor either, so it is measured here — with no configured FrameRate
        target the real rate is whatever the sensor free-runs at, and the gating
        tolerance must scale off that, not off a requested value.
        """
        skews = []
        t_start = time.perf_counter()
        for _ in range(max(1, n_frames)):
            _, _, ts0, ts1 = self._capture_pair()
            skews.append((ts1 - ts0) / 1000.0)  # ns → µs
        if not self._frame_period_us:
            elapsed = time.perf_counter() - t_start
            self._frame_period_us = elapsed / len(skews) * 1_000_000
        self._skew_baseline_us = sum(skews) / len(skews)
        std = (sum((s - self._skew_baseline_us) ** 2 for s in skews) / len(skews)) ** 0.5
        pct = self._skew_baseline_us / self._frame_period_us * 100
        print(
            f"[SYNC] Phase offset: {self._skew_baseline_us:.0f} µs ± {std:.0f} µs "
            f"({pct:.1f}% of frame period). Stereo gated on deviation from baseline."
        )

    # ── Recording ─────────────────────────────────────────────────────────────

    def _open_rec_files(self, base_path: str) -> None:
        rec_dir = Path(base_path) / "recordings" / datetime.now().strftime("rec_%H-%M-%S")
        rec_dir.mkdir(parents=True, exist_ok=True)

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

    def _init_udp_socket(self) -> None:
        self.udp_streamer = UDPStreamer(ip=self.udp_ip, port=self.udp_port)
        self.udp_streamer.start()

    def _recv_command(self) -> bytes:
        return self.udp_streamer.get_command()

    def _send_coordinates(
        self,
        command: str,
        centroid: np.ndarray,
        ref_rvec: np.ndarray,
        ref_tvec: np.ndarray,
        ref_id: int,
    ) -> None:
        code_map = {"STOP": -99.0, "START": 2.0, "RESET": 5.0}
        data = np.array(
            [code_map.get(command, 2.0), *centroid, *ref_rvec, *ref_tvec, float(ref_id)],
            dtype=np.float32,
        )
        self.udp_streamer.send(data.tolist())
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
        # PnP jitter. Keys are per view and per marker, so a marker appearing or
        # leaving counts as movement and forces a fresh solve.
        corner_sets = {f"c0_{mid}": c for mid, c in det0.items()}
        corner_sets.update({f"c1_{mid}": c for mid, c in det1.items()})

        def compute():
            if det0 and det1 and allow_stereo and self.stereo_refine:
                rvec, tvec = self.rig.stereo_pose(
                    det0, det1, self.K0, self.D0, self.K1, self.D1,
                    self.R_st, self.T_st,
                )
                if rvec is not None:
                    return rvec, tvec
            if det0:
                return self.rig.mono_pose(det0, self.K0, self.D0)
            rvec, tvec = self.rig.mono_pose(det1, self.K1, self.D1)
            if rvec is None:
                return None, None
            # cam1-only: re-express in cam0's frame, or the point jumps by the
            # stereo baseline whenever cam0 loses sight of the body.
            return self.rig.pose_in_cam1_frame(rvec, tvec, self.R_st, self.T_st)

        return self.stabilizer.stabilize(_BOARD_KEY, corner_sets, compute)

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

    def _select_hospitalid(self) -> None:
        if self.save_path is None:
            self.save_path = os.path.join(
                os.path.expanduser("~/Documents/NOARK/data"),
                self._hid,
                self._curr_session,
            )
            os.makedirs(self.save_path, exist_ok=True)
            csv_path = os.path.join(
                self.save_path,
                datetime.now().strftime("%Y_%m_%d_%H_%M_%S") + "_data.csv",
            )
            self.csv_writer = csv.writer(open(csv_path, "w", newline=""))
            self.csv_writer.writerow(["Time", "X", "Y", "Z"])

            if self.record_frames and self._rec_file0 is not None:
                self._close_rec_files()
            if self.record_frames:
                self._open_rec_files(self.save_path)

    # ── Main loop ─────────────────────────────────────────────────────────────

    def process_frame(self) -> None:
        # Capture grayscale frames from both cameras concurrently
        t0 = time.perf_counter()
        raw0, raw1, ts0, ts1 = self._capture_pair()
        if abs((ts1 - ts0) / 1000.0 - self._skew_baseline_us) >= 0.5 * self._frame_period_us:
            raw0, raw1, ts0, ts1 = self._catch_up(raw0, raw1, ts0, ts1)
        self._frame_count += 1
        if self.flip_frames:
            raw0 = cv2.flip(raw0, 1)
            raw1 = cv2.flip(raw1, 1)
        if self.record_frames and self._rec_file0 is not None:
            self._write_frames(raw0, raw1, ts0, ts1)
        t1 = time.perf_counter()
        self._stage_time["capture"] += t1 - t0

        # Frames are stereo-usable only when this pair's skew matches the
        # measured baseline; a large deviation means the pair slipped a frame
        # (a drop, or a phase nudge stretching one interval), so triangulating
        # it would fuse two different instants.
        skew_us = (ts1 - ts0) / 1000.0  # ns → µs
        allow_stereo = abs(skew_us - self._skew_baseline_us) < 0.5 * self._frame_period_us

        # Detect on raw fisheye frames (corner-undistort pipeline). rapidtag's
        # batch API applies flat (frame x scale) parallelism across cores when
        # given every camera's frame at once — faster than a detector call per
        # camera (see rcam/bench_rapidtag.py).
        (corners0, ids0), (corners1, ids1) = rapidtag.detect_markers_batch(
            [raw0, raw1], _APRILTAG_DICT
        )
        ids0 = np.array(ids0, dtype=int).reshape(-1, 1) if ids0 else None
        ids1 = np.array(ids1, dtype=int).reshape(-1, 1) if ids1 else None
        t2 = time.perf_counter()
        self._stage_time["detect"] += t2 - t1

        if ids0 is not None:
            corners0 = _refine_corners(raw0, corners0)
        if ids1 is not None:
            corners1 = _refine_corners(raw1, corners1)
        t3 = time.perf_counter()
        self._stage_time["refine"] += t3 - t2

        # Poll command from Godot. STOP is latched immediately, independent of
        # marker visibility below — otherwise a STOP arriving while markers
        # are in view gets acked-and-cleared before run()'s exit check sees it.
        cmd = self._recv_command()
        if cmd:
            self.received_message = cmd
            if cmd == b"STOP":
                self._stop_requested = True

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

            if self.received_message:
                if self.received_message == b"STOP":
                    self._send_coordinates("STOP", centroid, ref_rvec, ref_tvec, ref_id)
                    self.received_message = b""
                elif self.received_message.startswith(b"USER:"):
                    self._hid = self.received_message.decode().split(":")[1]
                    if self.save_path is None:
                        self._select_hospitalid()
                    self._send_coordinates("START", centroid, ref_rvec, ref_tvec, ref_id)
                    self.record = True
                elif self.received_message.startswith(b"CHANGE:"):
                    self.save_path = None
                    self._hid = self.received_message.decode().split(":")[1]
                    self._select_hospitalid()
                    self._send_coordinates("START", centroid, ref_rvec, ref_tvec, ref_id)
                    self.record = True
                elif self.received_message == b"RESET":
                    self._send_coordinates("RESET", centroid, ref_rvec, ref_tvec, ref_id)
                else:
                    self._send_coordinates("START", centroid, ref_rvec, ref_tvec, ref_id)

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

    def run(self) -> None:
        last_heartbeat = time.time()
        last_rate_log  = time.time()
        last_resync    = time.time()

        try:
            while True:
                try:
                    self.process_frame()
                    if self.received_message:
                        last_heartbeat = time.time()
                    if time.time() - last_heartbeat > 3.0:
                        print("Lost connection to Godot, exiting…")
                        break
                except Exception as exc:
                    print(f"Error: {exc} — Godot likely closed")
                    break

                now = time.time()
                if (
                    self._frame_sync is not None
                    and self.frame_sync_enabled
                    and self.resync_every_s > 0
                    and now - last_resync >= self.resync_every_s
                ):
                    last_resync = now
                    self._resync()

                elapsed = now - last_rate_log
                if elapsed >= 5.0:
                    fps = self._frame_count / elapsed
                    pkt_rate = self._send_count / elapsed
                    n = max(self._frame_count, 1)
                    stage_ms = {k: (v / n) * 1000.0 for k, v in self._stage_time.items()}
                    print(f"[FPS] cam0: {fps:.1f}  cam1: {fps:.1f}  "
                          f"({pkt_rate:.1f} pkt/s sent, "
                          f"{self._dropped} sensor frames skipped)")
                    report = self._phase_now()
                    if report is not None:
                        print(f"[SYNC] phase: {report.phase_us:+.0f} µs  "
                              f"jitter: {report.jitter_us:.0f} µs  "
                              f"drift: {report.drift_ppm:+.0f} ppm  "
                              f"({abs(report.phase_us) / self._frame_period_us * 100:.2f}% "
                              f"of a frame)  re-paired: {self._repairs}")
                    print(f"[STAGE ms/frame] capture: {stage_ms['capture']:.2f}  "
                          f"detect: {stage_ms['detect']:.2f}  "
                          f"refine: {stage_ms['refine']:.2f}  "
                          f"pose: {stage_ms['pose']:.2f}")
                    self._frame_count = 0
                    self._send_count  = 0
                    self._dropped     = [0, 0]
                    self._repairs     = 0
                    self._stage_time  = {k: 0.0 for k in self._stage_time}
                    last_rate_log     = now

                if self._stop_requested:
                    print("STOP received from Godot, exiting…")
                    break

                if self.display and cv2.waitKey(1) & 0xFF == ord("q"):
                    break
        finally:
            if self.record_frames and self._rec_file0 is not None:
                self._close_rec_files()
            if self.cam0 is not None:
                self.cam0.stop()
            if self.cam1 is not None:
                self.cam1.stop()
            if self._executor is not None:
                self._executor.shutdown(wait=True)
            if hasattr(self, "udp_streamer"):
                self.udp_streamer.stop()
            if self.display:
                cv2.destroyAllWindows()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--record", action="store_true", help="Record raw frames from both cameras")
    parser.add_argument("--fps", type=int, default=None, choices=[15, 30, 60, 90, 100],
                         help="Cap the sensor FrameRate. Omit to free-run at max achievable fps.")
    parser.add_argument("--flip", action=argparse.BooleanOptionalAction, default=False)
    parser.add_argument("--stereo-refine", action=argparse.BooleanOptionalAction,
                        default=True,
                        help="Refine the board pose across both cameras. Better "
                             "depth, but costs roughly half the frame rate; "
                             "--no-stereo-refine solves on cam0 alone.")
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
    settings = _load_settings()

    tracker = TrackerClass(
        stereo_calib_path=_SCRIPT_DIR / "calibration" / "sterio_calibration.toml",
        aruco_calib_path=_SCRIPT_DIR / "calibration" / "good.toml",
        rigidbody_path=args.rigidbody,
        stereo_refine=args.stereo_refine,
        settings=settings,
        record_frames=args.record,
        fps_value=args.fps,
        flip_frames=args.flip,
        frame_sync=args.frame_sync,
        phase_tol_us=args.phase_tol,
        resync_every_s=args.resync_every,
        resync_threshold_us=args.resync_threshold,
    )
    tracker.run()
