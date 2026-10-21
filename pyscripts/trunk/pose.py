"""Trunk rotation from minisam3d, the upper-body 3D pose student distilled from SAM 3D Body.

The alternative to the stereo shell + ICP: one camera, no depth. The student
(E:/NOARK_CV/minisam3d) predicts 14 upper-body joints and the global rotation
of 9 MHR segments; segment 0 is c_spine3, the upper thoracic segment where
NOARK's sternum rigid body sits. Trunk angles are that rotation relative to the
one captured at neutral.

Input contract, as the student was trained (minisam3d/docs/npu.md and
NOARK_backbone 19_sam3d_export.py): the reference camera's fisheye frame
undistorted to a pinhole image with balance 0, upright, grayscale; a square
crop around the upper body from `crop_affine`, 256x256, float /255, input
`image`. The models are W8A16 QDQ ONNX from AI Hub and run on the HTP through
the same session as trunk_seg.

The crop comes from the previous frame's keypoints while they are confident.
Otherwise it is seeded from the trunk_seg torso box and refined once from the
student's own keypoints, the two-pass crop minisam3d's infer_frames.py uses.
"""

import math
from pathlib import Path

import cv2
import numpy as np

MODELS_DIR = Path(__file__).parent / "models"
MODELS = {
    # settings.json trunk_method -> model dir. r18: ResNet-18 r18_v3mix_all_rep2
    # (noark_v3, best on the test split). v3rot: MobileNetV2 v3rot_loso_all.
    "msam_r18": "minisam3d_r18_w8a16",
    "msam_v3rot": "minisam3d_v3rot_w8a16",
}
IN = 256
NAMES = ["nose", "left_eye", "right_eye", "left_ear", "right_ear", "neck",
         "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
         "left_wrist", "right_wrist", "left_hip", "right_hip"]
J = {n: i for i, n in enumerate(NAMES)}
K = len(NAMES)
UPPER_FOR_CROP = [J[n] for n in ("nose", "left_ear", "right_ear", "neck", "left_shoulder",
                                 "right_shoulder", "left_elbow", "right_elbow",
                                 "left_wrist", "right_wrist")]
TRUNK_JOINTS = [J["neck"], J["left_shoulder"], J["right_shoulder"]]
TRUNK_ROT = 0                       # ROT_JOINTS[0] = ("trunk", c_spine3)
CROP_SCALE = 1.35                   # data.py / pack_noark.upper_box
RZ = np.diag([-1.0, -1.0, 1.0])     # a 180 deg image rotation = the camera turned about z


def crop_affine(center, size):
    """minisam3d.data.crop_affine without rotation: a size x size box at center -> IN x IN."""
    s = IN / size
    M = np.array([[s, 0, 0], [0, s, 0]], np.float64)
    M[:, 2] = np.array([IN / 2, IN / 2]) - M[:, :2] @ center
    return M


def box_of(pts):
    lo, hi = pts.min(0), pts.max(0)
    return (lo + hi) / 2, max(max(hi - lo) * CROP_SCALE, 16.0)


def rot6d_to_mat(r6):
    a, b = r6[:, :3], r6[:, 3:]
    x = a / np.linalg.norm(a, axis=1, keepdims=True)
    y = b - (x * b).sum(1, keepdims=True) * x
    y /= np.linalg.norm(y, axis=1, keepdims=True)
    return np.stack([x, y, np.cross(x, y)], -1)


def mean_rotation(Rs):
    """Chordal L2 mean of rotation matrices."""
    U, _, Vt = np.linalg.svd(np.sum(Rs, axis=0))
    R = U @ Vt
    if np.linalg.det(R) < 0:
        U[:, -1] *= -1
        R = U @ Vt
    return R


def rot_deg(R):
    return float(np.degrees(np.arccos(np.clip((np.trace(R) - 1) / 2, -1, 1))))


def anatomical_frame(xyz):
    """Columns (x lateral = patient's left, u up, a anterior) in camera axes, from
    the neutral joints: the icp.anatomical_frame convention, but from landmarks."""
    x = xyz[J["left_shoulder"]] - xyz[J["right_shoulder"]]
    x /= np.linalg.norm(x)
    u = xyz[J["neck"]] - (xyz[J["left_hip"]] + xyz[J["right_hip"]]) / 2
    u = u - (u @ x) * x
    u /= np.linalg.norm(u)
    a = np.cross(x, u)
    return np.column_stack([x, u, a])


class Student:
    """One minisam3d QDQ model on the NPU: crop -> (uv crop px, xyz, conf, rotations)."""

    def __init__(self, name):
        from .segment import npu_session

        if name not in MODELS:
            raise ValueError(f"unknown minisam3d model {name!r} (have {sorted(MODELS)})")
        path = MODELS_DIR / MODELS[name] / "model.onnx"
        if not path.exists():
            raise FileNotFoundError(path)
        self.name = name
        self.sess = npu_session(path)
        self.outs = [o.name for o in self.sess.get_outputs()]

    def __call__(self, crop):
        ys = dict(zip(self.outs, self.sess.run(None, {"image": crop[None, None].astype(np.float32) / 255.0})))
        maps, xyz, rot = ys["maps"][0], ys["xyz"].reshape(K, 3), ys["rot"].reshape(-1, 6)
        _, h, w = maps.shape
        lg = maps[:K].reshape(K, -1)
        lg = lg - lg.max(1, keepdims=True)
        p = np.exp(lg)
        p /= p.sum(1, keepdims=True)
        gx = (np.tile(np.arange(w), h) + 0.5) / w
        gy = (np.repeat(np.arange(h), w) + 0.5) / h
        uv = np.stack([p @ gx, p @ gy], -1) * IN
        conf = p.max(1) * math.sqrt(h * w)
        return uv, xyz.astype(np.float64), conf, rot6d_to_mat(rot.astype(np.float64))


class PoseTrunk:
    """Per-frame trunk rotation from the reference camera's working-size frame.

    `measure(left, mask, rot180)` -> ((R_trunk (3,3) camera axes, xyz (K,3)
    camera axes, conf (K,)), "") or (None, reason)."""

    def __init__(self, K_ref, D_ref, sensor, size, model, min_conf=2.0):
        """K_ref/D_ref: the reference camera at sensor resolution (sensor = (W, H));
        size = the working (w, h) the frames and masks arrive at."""
        w, h = size
        s = w / sensor[0]
        Ks = np.diag([s, s, 1.0]) @ K_ref
        Kp = cv2.fisheye.estimateNewCameraMatrixForUndistortRectify(Ks, D_ref, (w, h), np.eye(3), balance=0.0)
        self.maps = cv2.fisheye.initUndistortRectifyMap(Ks, D_ref, np.eye(3), Kp, (w, h), cv2.CV_16SC2)
        self.size = (w, h)
        self.student = Student(model)
        self.min_conf = float(min_conf)
        self._prev = None
        self._rot180 = None                 # last confident keypoints (upright pinhole px)

    def set_model(self, model):
        if model != self.student.name:
            self.student = Student(model)
            self._prev = None

    def reset(self):
        self._prev = None

    def upright(self, left, rot180):
        u = cv2.remap(left, *self.maps, cv2.INTER_LINEAR)
        return cv2.rotate(u, cv2.ROTATE_180) if rot180 else u

    def _seed(self, mask, rot180):
        """Upper-body box from the torso mask (raw fisheye px) in the upright pinhole image."""
        m = self.upright(mask, rot180)
        ys, xs = np.nonzero(m)
        if len(xs) < 50:
            return None
        x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
        tw, th = x1 - x0, y1 - y0
        # torso (shoulders..hips, arms removed) -> the head-to-hands box: up for
        # the head, wider for the arms. The refine pass fixes the rest.
        return np.array([(x0 + x1) / 2, y0 + 0.25 * th]), max(1.8 * tw, 1.5 * th)

    def _run(self, img, center, side):
        M = crop_affine(center, side)
        crop = cv2.warpAffine(img, M, (IN, IN), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)
        uv, xyz, conf, rots = self.student(crop)
        Mi = cv2.invertAffineTransform(M)
        return np.c_[uv, np.ones(K)] @ Mi.T, xyz, conf, rots

    def _infer(self, left, mask, rot180):
        img = self.upright(left, rot180)
        if self._prev is not None:
            out = self._run(img, *box_of(self._prev[UPPER_FOR_CROP]))
        else:
            seed = self._seed(mask, rot180)
            if seed is None:
                return None
            out = self._run(img, *seed)
            out = self._run(img, *box_of(out[0][UPPER_FOR_CROP]))
        return out

    def measure(self, left, mask, rot180):
        """rot180: the camera is mounted upside down (the engine decides, for
        trunk_seg and the student alike)."""
        if rot180 != self._rot180:
            self._prev = None            # keypoints from the other way up
        self._rot180 = rot180
        out = self._infer(left, mask, rot180)
        if out is None:
            self._prev = None
            return None, "no_torso"
        kp, xyz, conf, rots = out
        if conf[TRUNK_JOINTS].min() < self.min_conf:
            self._prev = None
            return None, "low_conf"
        self._prev = kp
        R = rots[TRUNK_ROT]
        if rot180:
            R, xyz = RZ @ R, xyz @ RZ.T
        return (R, xyz, conf), ""
