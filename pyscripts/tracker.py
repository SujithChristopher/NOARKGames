import argparse
import csv
import json
import logging
import os
import platform
from datetime import datetime
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

import cv2
import numpy as np
import toml
from cv2 import aruco

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


def _load_settings() -> dict:
    """Read settings.json from the project root (one level above pyscripts/)."""
    path = _SCRIPT_DIR.parent / "settings.json"
    if path.exists():
        with open(path) as f:
            return json.load(f)
    return {"debug": True, "stream_type": "ble", "ble_device_name": "NOARK_Tracker"}


class TrackerClass:
    def __init__(self, cam_calib_path: Path, settings: Optional[dict] = None, camera_index: int = 0, record_frames: bool = False, fps_value: int = 30, flip_frames: bool = True) -> None:
        if settings is None:
            settings = {}

        # ── A: transport settings ─────────────────────────────────────────────
        self.stream_type     = settings.get("stream_type", "ble")
        self.ble_device_name = settings.get("ble_device_name", "NOARK_Tracker")
        self.camera_index    = camera_index
        self.record_frames   = record_frames
        self.fps_value       = fps_value
        self.flip_frames     = flip_frames
        self._calib_path     = cam_calib_path

        # ── B: load calibration from good.toml ───────────────────────────────
        calib = toml.load(cam_calib_path)

        self.camera_matrix = np.array(
            calib["calibration"]["camera_matrix"]
        ).reshape(3, 3)
        # reshape(4,1) is safe whether toml stores flat [k1,k2,k3,k4] or nested
        self.dist_coeffs = np.array(
            calib["calibration"]["dist_coeffs"]
        ).reshape(4, 1)

        self.marker_length     = calib["aruco"]["marker_length"]
        self.marker_separation = calib["aruco"]["marker_spacing"]

        res = calib["camera"]["resolution"]
        self.frame_size      = (res[0], res[1])  # (width, height)
        self._camera_model   = calib["camera"].get("model", "unknown")
        self._camera_fov     = calib["camera"].get("fov", None)

        self.udp_ip   = settings.get("udp_ip",   calib["stream_data"]["ip"])
        self.udp_port = settings.get("udp_port", calib["stream_data"]["port"])
        self.display  = settings.get("display",  calib["display"]["display"])

        # ── C: fisheye undistortion maps (pre-computed once) ──────────────────
        R = np.eye(3)
        self.new_camera_matrix = cv2.fisheye.estimateNewCameraMatrixForUndistortRectify(
            self.camera_matrix,
            self.dist_coeffs,
            self.frame_size,
            R,
            balance=1.0,  # retain all pixels — no black-border crop
        )
        self.map1, self.map2 = cv2.fisheye.initUndistortRectifyMap(
            self.camera_matrix,
            self.dist_coeffs,
            R,
            self.new_camera_matrix,
            self.frame_size,
            cv2.CV_16SC2,
        )
        self.zero_dist = np.zeros((1, 4))
        print("Undistorted camera matrix:\n", self.new_camera_matrix)

        # ── D: remaining state ────────────────────────────────────────────────
        self.filter         = ExponentialMovingAverageFilter3D(alpha=0.4)
        self.default_ids    = [4, 8, 12, 14, 20]
        self.marker_offsets = MARKER_OFFSETS

        self.detector = self._init_detector()
        self.board    = self._init_board()

        self.picam2       = None
        self.picam1       = None   # second camera, only used when record_frames=True
        self.video_frame  = None
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

        # ── E: camera + transport ─────────────────────────────────────────────
        if platform.system() == "Linux":
            self._init_rpi_camera()
        else:
            self._init_camera()

        if self.stream_type == "udp":
            self._init_udp_socket()
        elif self.stream_type == "ble":
            self._init_ble()
        else:
            raise ValueError(f"Unknown stream_type '{self.stream_type}' — use 'udp' or 'ble'")

    # ── detector / board ─────────────────────────────────────────────────────

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

    # ── cameras ──────────────────────────────────────────────────────────────

    def _init_rpi_camera(self) -> None:
        from picamera2 import Picamera2
        import libcamera

        cam_config = {
            "format": "YUV420",
            "size": self.frame_size,
        }
        cam_controls = {"FrameRate": self.fps_value, "ExposureTime": 5000}
        cam_transform = libcamera.Transform(vflip=1)

        self.picam2 = Picamera2(camera_num=0)
        self.picam2.configure(self.picam2.create_video_configuration(
            cam_config, controls=cam_controls, transform=cam_transform,
        ))
        self.picam2.start()

        if self.record_frames:
            self.picam1 = Picamera2(camera_num=1)
            self.picam1.configure(self.picam1.create_video_configuration(
                cam_config, controls=cam_controls, transform=cam_transform,
            ))
            self.picam1.start()
        # Undistortion maps are already computed in __init__ — nothing to do here

    def _init_camera(self) -> None:
        self.camera = cv2.VideoCapture(self.camera_index, cv2.CAP_DSHOW)
        self.camera.set(cv2.CAP_PROP_FRAME_WIDTH,  self.frame_size[0])
        self.camera.set(cv2.CAP_PROP_FRAME_HEIGHT, self.frame_size[1])
        self.camera.set(cv2.CAP_PROP_FPS, self.fps_value)

    # ── dual-camera recording ─────────────────────────────────────────────────

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
            "calibration":  str(self._calib_path),
        }
        with open(rec_dir / "metadata.json", "w") as f:
            json.dump(metadata, f, indent=2)

        self._rec_file0 = open(rec_dir / "cam0_frame.msgpack", "wb")
        self._rec_file1 = open(rec_dir / "cam1_frame.msgpack", "wb")
        self._ts_file0  = open(rec_dir / "cam0_timestamp.msgpack", "wb")
        self._ts_file1  = open(rec_dir / "cam1_timestamp.msgpack", "wb")
        print(f"[REC] Recording to {rec_dir}")

    def _write_frames(self, frame0: np.ndarray, frame1: np.ndarray) -> None:
        import msgpack
        import msgpack_numpy as mpn
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")
        self._rec_file0.write(msgpack.packb(frame0, default=mpn.encode))
        self._rec_file1.write(msgpack.packb(frame1, default=mpn.encode))
        self._ts_file0.write(msgpack.packb(ts))
        self._ts_file1.write(msgpack.packb(ts))

    def _close_rec_files(self, stop_camera: bool = False) -> None:
        for fh in (self._rec_file0, self._rec_file1, self._ts_file0, self._ts_file1):
            if fh:
                fh.close()
        self._rec_file0 = self._rec_file1 = self._ts_file0 = self._ts_file1 = None
        if stop_camera and self.picam1 is not None:
            self.picam1.stop()
            self.picam1 = None
        print("[REC] Recording closed")

    # ── transport init ────────────────────────────────────────────────────────

    def _init_udp_socket(self) -> None:
        self.udp_streamer = UDPStreamer(ip=self.udp_ip, port=self.udp_port)
        self.udp_streamer.start()

    def _init_ble(self) -> None:
        from ble_streamer import BLEStreamer
        self.ble_streamer = BLEStreamer(device_name=self.ble_device_name)
        self.ble_streamer.start()

    # ── transport send / receive ──────────────────────────────────────────────

    def _recv_command(self) -> bytes:
        """Return the latest command from Godot, or b'' if none."""
        if self.stream_type == "udp":
            return self.udp_streamer.get_command()
        elif self.stream_type == "ble":
            return self.ble_streamer.get_command()
        return b""

    def _send_coordinates(
        self,
        command: str,
        centroid: np.ndarray,
        ref_rvec: np.ndarray,
        ref_tvec: np.ndarray,
        ref_id: int,
    ) -> None:
        """Stream 11 floats to Godot: [code, cx,cy,cz, rvx,rvy,rvz, tx,ty,tz, ref_id]."""
        code_map = {"STOP": -99.0, "START": 2.0, "RESET": 5.0}
        msg_code = code_map.get(command, 2.0)
        data = np.array(
            [msg_code, *centroid, *ref_rvec, *ref_tvec, float(ref_id)],
            dtype=np.float32,
        )

        if self.stream_type == "udp":
            self.udp_streamer.send(data.tolist())
        elif self.stream_type == "ble":
            self.ble_streamer.send(data.tolist())
        self._send_count += 1

    # ── pose estimation ───────────────────────────────────────────────────────

    def estimate_pose(self, corners):
        marker_points = np.array(
            [
                [-self.marker_length / 2,  self.marker_length / 2, 0],
                [ self.marker_length / 2,  self.marker_length / 2, 0],
                [ self.marker_length / 2, -self.marker_length / 2, 0],
                [-self.marker_length / 2, -self.marker_length / 2, 0],
            ],
            dtype=np.float32,
        )
        rvecs, tvecs = [], []
        for corner in corners:
            success, rvec, tvec = cv2.solvePnP(
                marker_points, corner,
                self.new_camera_matrix,  # undistorted intrinsics
                self.zero_dist,          # image already undistorted
                flags=cv2.SOLVEPNP_ITERATIVE,
            )
            if success:
                rvecs.append(rvec.flatten())
                tvecs.append(tvec.flatten())
        return np.array(rvecs), np.array(tvecs)

    def _draw_axes(self, rvecs, tvecs) -> None:
        for rvec, tvec in zip(rvecs, tvecs):
            cv2.drawFrameAxes(
                self.video_frame,
                self.new_camera_matrix,  # must match estimate_pose
                self.zero_dist,
                rvec, tvec, 0.05,
            )

    def _get_centroid(self, ids, rvecs, tvecs) -> np.ndarray:
        ids   = np.array(ids).flatten()
        tvecs = np.array(tvecs).reshape(len(ids), 3)
        rvecs = np.array(rvecs).reshape(len(ids), 3)

        transformed = np.full((len(ids), 3), np.nan)
        for index, _id in enumerate(ids):
            if _id in self.marker_offsets:
                transformed[index] = (
                    cv2.Rodrigues(rvecs[index])[0]
                    @ self.marker_offsets[_id].reshape(3, 1)
                    + tvecs[index].reshape(3, 1)
                ).T[0]
        return np.nanmean(transformed, axis=0).flatten()

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

            if self.record_frames and self.picam1 is not None:
                if self._rec_file0 is not None:
                    self._close_rec_files(stop_camera=False)
                self._open_rec_files(self.save_path)

    # ── main loop ─────────────────────────────────────────────────────────────

    def process_frame(self) -> None:
        # Capture
        h, w = self.frame_size[1], self.frame_size[0]
        if platform.system() == "Linux":
            raw0 = self.picam2.capture_array()[:h, :w]
            if self.flip_frames:
                raw0 = cv2.flip(raw0, 1)
            if self.record_frames and self.picam1 is not None and self._rec_file0 is not None:
                raw1 = self.picam1.capture_array()[:h, :w]
                if self.flip_frames:
                    raw1 = cv2.flip(raw1, 1)
                self._write_frames(raw0, raw1)
            self.video_frame = cv2.remap(raw0, self.map1, self.map2, cv2.INTER_LINEAR)
        else:
            ret, self.video_frame = self.camera.read()
            if not ret or self.video_frame is None:
                return

        # Poll command from Godot
        cmd = self._recv_command()
        if cmd:
            self.received_message = cmd

        # Detect markers
        corners, ids, _ = self.detector.detectMarkers(self.video_frame)
        if ids is not None:
            self.video_frame = aruco.drawDetectedMarkers(self.video_frame, corners, ids)
            rvecs, tvecs = self.estimate_pose(corners)

            self._draw_axes(rvecs, tvecs)
            centroid = self.filter.update(self._get_centroid(ids, rvecs, tvecs))

            # First detected marker is the reference for Godot's set_origin()
            ref_id   = int(np.array(ids).flatten()[0])
            ref_rvec = rvecs[0]
            ref_tvec = tvecs[0]

            # Dispatch command
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
            self.video_frame = cv2.resize(self.video_frame, (350, 200))
            cv2.imshow("frame", self.video_frame)

    def run(self) -> None:
        import time

        last_heartbeat = time.time()
        last_rate_log  = time.time()
        use_heartbeat  = self.stream_type == "udp"

        try:
            while True:
                try:
                    self.process_frame()
                    if self.received_message:
                        last_heartbeat = time.time()
                    if use_heartbeat and time.time() - last_heartbeat > 3.0:
                        print("Lost connection to Godot, exiting…")
                        break
                except Exception as exc:
                    if use_heartbeat:
                        print(f"Error: {exc} — Godot likely closed")
                        break
                    raise

                now = time.time()
                elapsed = now - last_rate_log
                if elapsed >= 5.0:
                    logger.debug("[Rate] %.1f pkt/s  (%d packets in %.1fs)",
                                 self._send_count / elapsed, self._send_count, elapsed)
                    self._send_count = 0
                    last_rate_log    = now

                if self.received_message == b"STOP":
                    if self.stream_type == "ble":
                        self.received_message = b""
                        self.record = False
                        self.save_path = None
                        if hasattr(self, "ble_streamer"):
                            self.ble_streamer.reset()
                    else:
                        break
                if self.display and cv2.waitKey(1) & 0xFF == ord("q"):
                    break
        finally:
            if self.record_frames:
                self._close_rec_files(stop_camera=True)
            if self.stream_type == "udp" and hasattr(self, "udp_streamer"):
                self.udp_streamer.stop()
            if self.stream_type == "ble" and hasattr(self, "ble_streamer"):
                print("[BLE] Stopping BLE streamer")
                self.ble_streamer.stop()
            if self.display:
                cv2.destroyAllWindows()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--camera", type=int, default=0, help="Camera index for tracking (0, 1, …)")
    parser.add_argument("--record", action="store_true", help="Record raw frames from both cameras")
    parser.add_argument("--fps", type=int, default=30, choices=[15, 30, 60], help="Camera FPS for capture and recording")
    parser.add_argument("--flip", action=argparse.BooleanOptionalAction, default=True, help="Flip frames horizontally (default: on)")
    args = parser.parse_args()

    logging.basicConfig(level=logging.WARNING, format="%(asctime)s %(message)s", datefmt="%H:%M:%S", force=True)
    logging.getLogger(__name__).setLevel(logging.DEBUG)
    settings = _load_settings()

    CALIB_PATH = _SCRIPT_DIR / "calibration" / "good.toml"
    tracker = TrackerClass(
        cam_calib_path=CALIB_PATH,
        settings=settings,
        camera_index=args.camera,
        record_frames=args.record,
        fps_value=args.fps,
        flip_frames=args.flip,
    )
    tracker.run()
