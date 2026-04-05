import csv
import json
import logging
import os
import platform
import socket
import struct
from datetime import datetime
from typing import Optional

logger = logging.getLogger(__name__)

import cv2
import numpy as np
import toml
from cv2 import aruco

from filters import ExponentialMovingAverageFilter3D


MARKER_OFFSETS = {
    4:  np.array([0.00,  0.1,    -0.069]),
    8:  np.array([0.00,  0.01,   -0.069]),
    12: np.array([0.00,  0.0,    -0.1075]),
    14: np.array([-0.09, 0.0,    -0.069]),
    20: np.array([0.1,   0.0,    -0.069]),
}


def _load_settings() -> dict:
    """Read settings.json from the project root (one level above pyscripts/)."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(script_dir, "..", "settings.json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return {"debug": True, "stream_type": "ble", "ble_device_name": "NOARK_Tracker"}


class TrackerClass:
    def __init__(self, cam_calib_path: str, settings: Optional[dict] = None) -> None:
        if settings is None:
            settings = {}

        # ── A: transport settings ─────────────────────────────────────────────
        self.stream_type     = settings.get("stream_type", "ble")
        self.ble_device_name = settings.get("ble_device_name", "NOARK_Tracker")

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
        self.frame_size = (res[0], res[1])  # (width, height)

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

        self.picam2 = self.map1_rpi = self.map2_rpi = None
        self.video_frame  = None
        self.tvec_dist    = np.zeros(3)
        self.save_path    = None
        self._send_count  = 0
        self.csv_writer   = None
        self.record       = False
        self.received_message: bytes = b""
        self.addr         = None

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

        self.picam2 = Picamera2()
        config = self.picam2.create_video_configuration(
            {"format": "YUV420", "size": self.frame_size},
            controls={"FrameRate": 100, "ExposureTime": 5000},
            transform=libcamera.Transform(vflip=1),
        )
        self.picam2.configure(config)
        self.picam2.start()
        # Undistortion maps are already computed in __init__ — nothing to do here

    def _init_camera(self) -> None:
        self.camera = cv2.VideoCapture(0, cv2.CAP_DSHOW)
        self.camera.set(cv2.CAP_PROP_FRAME_WIDTH,  self.frame_size[0])
        self.camera.set(cv2.CAP_PROP_FRAME_HEIGHT, self.frame_size[1])
        self.camera.set(cv2.CAP_PROP_FPS, 30)

    # ── transport init ────────────────────────────────────────────────────────

    def _init_udp_socket(self) -> None:
        self.udp_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp_socket.bind((self.udp_ip, self.udp_port))
        self.udp_socket.setblocking(False)
        print("UDP socket bound to", self.udp_socket.getsockname())

    def _init_ble(self) -> None:
        from ble_streamer import BLEStreamer
        self.ble_streamer = BLEStreamer(device_name=self.ble_device_name)
        self.ble_streamer.start()

    # ── transport send / receive ──────────────────────────────────────────────

    def _recv_command(self) -> bytes:
        """Return the latest command from Godot, or b'' if none."""
        if self.stream_type == "udp":
            try:
                data, self.addr = self.udp_socket.recvfrom(30)
                return data
            except socket.error:
                return b""
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

        if self.stream_type == "udp" and self.addr is not None:
            self.udp_socket.sendto(struct.pack("f" * len(data), *data), self.addr)
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

    # ── main loop ─────────────────────────────────────────────────────────────

    def process_frame(self) -> None:
        # Capture
        if platform.system() == "Linux":
            self.video_frame = self.picam2.capture_array()
            self.video_frame = cv2.flip(self.video_frame, 1)  # flip before remap
        else:
            ret, self.video_frame = self.camera.read()
            if not ret or self.video_frame is None:
                return

        # Undistort — always applied on both platforms
        self.video_frame = cv2.remap(
            self.video_frame, self.map1, self.map2, cv2.INTER_LINEAR
        )

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
                    break
                if self.display and cv2.waitKey(1) & 0xFF == ord("q"):
                    break
        finally:
            if self.stream_type == "ble" and hasattr(self, "ble_streamer"):
                print("[BLE] Stopping BLE streamer")
                self.ble_streamer.stop()
            if self.display:
                cv2.destroyAllWindows()


if __name__ == "__main__":
    logging.basicConfig(level=logging.WARNING, format="%(asctime)s %(message)s", datefmt="%H:%M:%S", force=True)
    logging.getLogger(__name__).setLevel(logging.DEBUG)
    settings = _load_settings()
    script_dir = os.path.dirname(os.path.abspath(__file__))
    CALIB_PATH = os.path.join(script_dir, "calibration", "good.toml")
    tracker = TrackerClass(cam_calib_path=CALIB_PATH, settings=settings)
    tracker.run()
