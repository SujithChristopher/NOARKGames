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
from rigid_body import RigidBody, load_cameras, load_device, stereo_extrinsic
from stereo_capture import StereoCapture
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
    def __init__(
        self,
        stereo_calib_path: Path,
        aruco_calib_path: Path,
        rigidbody_path: Path,
        device_path: Path,
        settings: Optional[dict] = None,
        record_frames: bool = False,
        fps_value: Optional[int] = None,
        flip_frames: bool = True,
        stereo_refine: Optional[bool] = None,
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
        camera = ac.get("camera", {})
        self.udp_ip            = settings.get("udp_ip",   stream.get("ip", "127.0.0.1"))
        self.udp_port          = settings.get("udp_port", stream.get("port", 8000))
        self.display           = settings.get(
            "display", ac.get("display", {}).get("display", False)
        )
        self._camera_model     = camera.get("model", "OV9281")
        self._camera_fov       = camera.get("fov", 160)

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
        self.stereo_refine = have_refit if stereo_refine is None else stereo_refine
        if self.rig is not None and self.rig.stereo is not None:
            # Measured against this rig, with these cameras, in this order.
            self.R_st, self.T_st = self.rig.stereo
        if tuple(self._camera_order) != ("cam0", "cam1"):
            print(f"[RIG] Camera streams mapped {tuple(self._camera_order)} "
                  "(device.toml [cameras])")
        if self.rig is not None:
            print(f"[RIG] Calibrated body: {self.rig.describe()}")
            if self.stereo_refine and not have_refit:
                print(
                    "[RIG] WARNING: stereo refinement forced on without a "
                    "self-calibrated extrinsic — verify it before trusting the "
                    "output."
                )
            elif not self.stereo_refine:
                # Not a limitation being worked around: measured on this rig a
                # joint solve over one camera's tags jitters 1.02 mm against
                # 1.19 mm for the two-camera fit, at a quarter of the cost. A
                # multi-tag board is already well conditioned in depth, so the
                # baseline adds little. --stereo-refine forces it on.
                print("[RIG] Solving on cam0 alone (measured no worse than stereo, 4x cheaper).")
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
            threshold_px=settings.get("corner_deadband_px", 0.25)
        )
        self.marker_offsets = MARKER_OFFSETS

        self.cam0     = None   # primary (tracking + display)
        self.cam1     = None   # stereo second view
        self._executor        = None
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

        # ── Transport + cameras ───────────────────────────────────────────────
        # Bind before bringing the cameras up, not after. Frame-sync alignment
        # takes tens of seconds, and Godot starts heartbeating the moment it
        # spawns us: with nothing listening yet those datagrams hit a closed
        # port, and Godot's socket is a *connected* one, so Linux bounces an
        # ICMP port-unreachable that can leave it erroring. The tracker would
        # then see no heartbeat, exit on its 3 s timeout as soon as the loop
        # started, and be respawned by Godot's watchdog into the same long wait
        # — a silent crash loop that looks exactly like "no UDP position".
        #
        # Binding first costs nothing: nothing reads the socket until the loop
        # starts, and the kernel buffers whatever arrives meanwhile.
        self._init_udp_socket()

        if platform.system() == "Linux":
            self._init_cameras()
        else:
            raise RuntimeError("Stereo tracking requires Radxa Dragon Q6A dual-camera hardware.")

    # ── Cameras ───────────────────────────────────────────────────────────────
    # Phase alignment, queue pairing and drift resync all live in
    # StereoCapture, shared with rigidbody_calib.py so both see the same frames.

    def _init_cameras(self) -> None:
        self.capture = StereoCapture(
            frame_size=self.frame_size,
            fps_value=self.fps_value,
            frame_sync=self.frame_sync_enabled,
            phase_tol_us=self.phase_tol_us,
            resync_threshold_us=self.resync_threshold_us,
            exposure_us=self._exposure_us,
            gain=self._gain,
            isp=self._isp,
        )
        self.cam0 = self.capture.cam0
        self.cam1 = self.capture.cam1

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
        raw0, raw1, ts0, ts1, allow_stereo = self.capture.next_pair()
        self._frame_count += 1
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
                if self.resync_every_s > 0 and now - last_resync >= self.resync_every_s:
                    last_resync = now
                    self.capture.maybe_resync()

                elapsed = now - last_rate_log
                if elapsed >= 5.0:
                    fps = self._frame_count / elapsed
                    pkt_rate = self._send_count / elapsed
                    n = max(self._frame_count, 1)
                    stage_ms = {k: (v / n) * 1000.0 for k, v in self._stage_time.items()}
                    print(f"[FPS] cam0: {fps:.1f}  cam1: {fps:.1f}  "
                          f"({pkt_rate:.1f} pkt/s sent, "
                          f"{self.capture.dropped} sensor frames skipped)")
                    report = self.capture.phase_report()
                    if report is not None:
                        print(f"[SYNC] phase: {report.phase_us:+.0f} µs  "
                              f"jitter: {report.jitter_us:.0f} µs  "
                              f"drift: {report.drift_ppm:+.0f} ppm  "
                              f"({abs(report.phase_us) / self.capture.frame_period_us * 100:.2f}% "
                              f"of a frame)  re-paired: {self.capture.repairs}")
                    print(f"[STAGE ms/frame] capture: {stage_ms['capture']:.2f}  "
                          f"detect: {stage_ms['detect']:.2f}  "
                          f"refine: {stage_ms['refine']:.2f}  "
                          f"pose: {stage_ms['pose']:.2f}")
                    self._frame_count = 0
                    self._send_count  = 0
                    self.capture.reset_counters()
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
            if getattr(self, "capture", None) is not None:
                self.capture.close()
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
                        default=None,
                        help="Refine the board pose across both cameras. Defaults "
                             "to on only when the calibration carries a "
                             "self-calibrated stereo extrinsic, since a wrong one "
                             "is far worse than using a single camera.")
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
        device_path=_SCRIPT_DIR / "calibration" / "device.toml",
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
