import argparse
import csv
import json
import logging
import os
import platform
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

import cv2
import numpy as np
import toml
from cv2 import aruco
from scipy.optimize import least_squares

from filters import ExponentialMovingAverageFilter3D
from udp_streamer import UDPStreamer


_SCRIPT_DIR = Path(__file__).parent

MARKER_OFFSETS = {
    4:  np.array([0.00,  0.1,    -0.069]),
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
    """Sub-pixel corner refinement on raw-frame corner detections."""
    refined = []
    for c in corners:
        pts = c.reshape(-1, 1, 2).astype(np.float32)
        cv2.cornerSubPix(gray, pts, (5, 5), (-1, -1), _SUBPIX_CRITERIA)
        refined.append(pts.reshape(1, 4, 2))
    return refined


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
    rvec_st   = cv2.Rodrigues(R_st)[0]        # (3, 1)

    obj = _MARKER_PTS.reshape(-1, 1, 3)

    def _residual(p: np.ndarray) -> np.ndarray:
        rv = p[:3].reshape(3, 1)
        tv = p[3:].reshape(3, 1)
        # cam0: fisheye projection onto raw frame
        proj0, _ = cv2.fisheye.projectPoints(obj, rv, tv, K0, D0)
        # cam1: compose model→cam0 with stereo cam0→cam1
        rv1, tv1, *_ = cv2.composeRT(rv, tv, rvec_st, T_st)
        proj1, _ = cv2.fisheye.projectPoints(obj, rv1, tv1, K1, D1)
        return np.concatenate([
            (proj0.reshape(-1, 2) - c0).ravel(),
            (proj1.reshape(-1, 2) - c1).ravel(),
        ])

    x0 = np.concatenate([rvec_init.flatten(), t_init.flatten()]).astype(np.float64)
    sol = least_squares(_residual, x0, method="lm")
    return sol.x[:3], sol.x[3:]


class TrackerClass:
    def __init__(
        self,
        stereo_calib_path: Path,
        aruco_calib_path: Path,
        settings: Optional[dict] = None,
        record_frames: bool = False,
        fps_value: int = 30,
        flip_frames: bool = True,
    ) -> None:
        if settings is None:
            settings = {}

        self.record_frames      = record_frames
        self.fps_value          = fps_value
        self.flip_frames        = flip_frames
        self._stereo_calib_path = stereo_calib_path

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

        # ── ArUco / stream / display settings ─────────────────────────────────
        ac = toml.load(aruco_calib_path)
        self.marker_length     = ac["aruco"]["marker_length"]
        self.marker_separation = ac["aruco"]["marker_spacing"]
        self.udp_ip            = settings.get("udp_ip",   ac["stream_data"]["ip"])
        self.udp_port          = settings.get("udp_port", ac["stream_data"]["port"])
        self.display           = settings.get("display",  ac["display"]["display"])
        self._camera_model     = ac["camera"].get("model", "OV9281")
        self._camera_fov       = ac["camera"].get("fov", 160)

        # ── Remaining state ───────────────────────────────────────────────────
        self.filter         = ExponentialMovingAverageFilter3D(alpha=0.4)
        self.marker_offsets = MARKER_OFFSETS

        self.detector = self._init_detector()
        self.board    = self._init_board()

        self.picam2   = None   # cam0: primary (tracking + display)
        self.picam1   = None   # cam1: stereo second view
        self._executor        = None
        self._frame_period_us = 1_000_000 / self.fps_value
        self._skew_baseline_us = 0.0   # measured cam0→cam1 sensor phase offset
        self.tvec_dist    = np.zeros(3)
        self.save_path    = None
        self._send_count  = 0
        self.csv_writer   = None
        self.record       = False
        self.received_message: bytes = b""
        self._rec_file0 = self._rec_file1 = None
        self._ts_file0  = self._ts_file1  = None

        self._curr_session = os.path.join(
            "Session-" + datetime.today().strftime("%Y-%m-%d"), "MovementData"
        )

        # ── Cameras + transport ───────────────────────────────────────────────
        if platform.system() == "Linux":
            self._init_rpi_cameras()
        else:
            raise RuntimeError("Stereo tracking requires RPi dual-camera hardware.")

        self._init_udp_socket()

    # ── Detector / board ──────────────────────────────────────────────────────

    def _init_detector(self):
        params = aruco.DetectorParameters()
        params.useAruco3Detection     = True
        params.cornerRefinementMethod = aruco.CORNER_REFINE_CONTOUR
        dictionary = aruco.getPredefinedDictionary(aruco.DICT_APRILTAG_36h11)
        return aruco.ArucoDetector(dictionary, params)

    def _init_board(self):
        return aruco.GridBoard(
            size=(1, 1),
            markerLength=self.marker_length,
            markerSeparation=self.marker_separation,
            dictionary=self.detector.getDictionary(),
        )

    # ── Cameras ───────────────────────────────────────────────────────────────

    def _init_rpi_cameras(self) -> None:
        from picamera2 import Picamera2
        import libcamera

        cam_config    = {"format": "YUV420", "size": self.frame_size}
        cam_controls  = {"FrameRate": self.fps_value, "ExposureTime": 5000}
        # cam_transform = libcamera.Transform(vflip=1)

        self.picam2 = Picamera2(camera_num=0)
        self.picam2.configure(self.picam2.create_video_configuration(
            cam_config, controls=cam_controls,
        ))
        self.picam2.start()

        # cam1 is always active — used for stereo_pnp on every frame
        self.picam1 = Picamera2(camera_num=1)
        self.picam1.configure(self.picam1.create_video_configuration(
            cam_config, controls=cam_controls,
        ))
        self.picam1.start()

        # Concurrent grab: issue both captures in parallel so the inter-camera
        # gap collapses to the sensors' fixed phase offset (not a full frame).
        self._executor = ThreadPoolExecutor(max_workers=2)
        self._measure_phase_offset(int(self.fps_value))  # ~1 s of frames

    @staticmethod
    def _grab(cam):
        """Grab one frame + its sensor capture timestamp (ns)."""
        req  = cam.capture_request()
        arr  = req.make_array("main")          # copy — safe after release
        ts   = req.get_metadata().get("SensorTimestamp", 0)
        req.release()
        return arr, ts

    def _capture_pair(self):
        """Grab both cameras concurrently; return (frame0, frame1, ts0, ts1)."""
        f0 = self._executor.submit(self._grab, self.picam2)
        f1 = self._executor.submit(self._grab, self.picam1)
        frame0, ts0 = f0.result()
        frame1, ts1 = f1.result()
        return frame0, frame1, ts0, ts1

    def _measure_phase_offset(self, n_frames: int) -> None:
        """Establish the baseline cam0→cam1 sensor skew over n_frames."""
        skews = []
        for _ in range(max(1, n_frames)):
            _, _, ts0, ts1 = self._capture_pair()
            skews.append((ts1 - ts0) / 1000.0)  # ns → µs
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

        # Markers detected in cam0
        if ids0 is not None:
            for i, mid in enumerate(ids0_flat):
                mid = int(mid)
                c0 = corners0[i].reshape(4, 2).astype(np.float64)
                if mid in cam1_by_id and allow_stereo:
                    rvec, tvec = _stereo_pnp(
                        c0, cam1_by_id[mid],
                        self.K0, self.D0, self.K1, self.D1,
                        self.R_st, self.T_st,
                    )
                else:
                    rvec, tvec = _single_cam_pnp(c0, self.K0, self.D0)
                if rvec is not None:
                    result_ids.append(mid)
                    result_rvecs.append(rvec)
                    result_tvecs.append(tvec)

        # Markers visible only in cam1 (not in cam0). _single_cam_pnp returns the
        # pose in cam1's frame; transform it into cam0's frame so it is co-framed
        # with the stereo and cam0-only poses (otherwise the centroid jumps by the
        # stereo baseline whenever a marker drops to cam1-only).
        for mid, c1 in cam1_by_id.items():
            if mid not in result_ids:
                rvec1, tvec1 = _single_cam_pnp(c1, self.K1, self.D1)
                if rvec1 is not None:
                    R1   = cv2.Rodrigues(rvec1)[0]
                    R_c0 = self.R_st.T @ R1
                    t_c0 = self.R_st.T @ (tvec1.reshape(3, 1) - self.T_st)
                    result_ids.append(mid)
                    result_rvecs.append(cv2.Rodrigues(R_c0)[0].flatten())
                    result_tvecs.append(t_c0.flatten())

        return result_ids, result_rvecs, result_tvecs

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
        h, w = self.frame_size[1], self.frame_size[0]

        # Capture Y planes (grayscale) from both cameras concurrently
        frame0, frame1, ts0, ts1 = self._capture_pair()
        raw0 = frame0[:h, :w]
        raw1 = frame1[:h, :w]
        if self.flip_frames:
            raw0 = cv2.flip(raw0, 1)
            raw1 = cv2.flip(raw1, 1)
        if self.record_frames and self._rec_file0 is not None:
            self._write_frames(raw0, raw1, ts0, ts1)

        # Frames are stereo-usable only when this pair's skew matches the
        # measured baseline; a large deviation means a dropped/duplicated frame.
        skew_us = (ts1 - ts0) / 1000.0
        allow_stereo = abs(skew_us - self._skew_baseline_us) < 0.5 * self._frame_period_us

        # Detect on raw fisheye frames (corner-undistort pipeline)
        corners0, ids0, _ = self.detector.detectMarkers(raw0)
        corners1, ids1, _ = self.detector.detectMarkers(raw1)

        if ids0 is not None:
            corners0 = _refine_corners(raw0, corners0)
        if ids1 is not None:
            corners1 = _refine_corners(raw1, corners1)

        # Poll command from Godot
        cmd = self._recv_command()
        if cmd:
            self.received_message = cmd

        # Pose estimation: stereo_pnp where possible, single-cam fallback elsewhere
        ids, rvecs, tvecs = self._estimate_poses(
            corners0, ids0, corners1, ids1, allow_stereo=allow_stereo
        )

        if ids:
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
                disp0 = aruco.drawDetectedMarkers(disp0, corners0, np.array(ids0))
            if ids1 is not None:
                disp1 = aruco.drawDetectedMarkers(disp1, corners1, np.array(ids1))
            disp0 = cv2.resize(disp0, (350, 200))
            disp1 = cv2.resize(disp1, (350, 200))
            cv2.imshow("frame", np.hstack([disp0, disp1]))

    def run(self) -> None:
        import time

        last_heartbeat = time.time()
        last_rate_log  = time.time()

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
                elapsed = now - last_rate_log
                if elapsed >= 5.0:
                    logger.debug("[Rate] %.1f pkt/s  (%d packets in %.1fs)",
                                 self._send_count / elapsed, self._send_count, elapsed)
                    self._send_count = 0
                    last_rate_log    = now

                if self.received_message == b"STOP":
                    break

                if self.display and cv2.waitKey(1) & 0xFF == ord("q"):
                    break
        finally:
            if self.record_frames and self._rec_file0 is not None:
                self._close_rec_files()
            if self.picam1 is not None:
                self.picam1.stop()
            if self._executor is not None:
                self._executor.shutdown(wait=True)
            if hasattr(self, "udp_streamer"):
                self.udp_streamer.stop()
            if self.display:
                cv2.destroyAllWindows()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--record", action="store_true", help="Record raw frames from both cameras")
    parser.add_argument("--fps", type=int, default=30, choices=[15, 30, 60])
    parser.add_argument("--flip", action=argparse.BooleanOptionalAction, default=False)
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
        settings=settings,
        record_frames=args.record,
        fps_value=args.fps,
        flip_frames=args.flip,
    )
    tracker.run()
