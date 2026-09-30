"""The calibrated marker rigid body, and the board poses solved from it.

`rigidbody_calib.py` measures where every tag sits relative to a reference tag
and writes it to a TOML; this loads that back and uses it to solve one pose for
the whole cluster.

The point of solving the cluster jointly is that a pose from four corners of one
small square is weakly constrained in depth and out-of-plane tilt. Twenty corners
spread over several faces are not, so a single PnP over every visible corner is
far better conditioned than averaging a pose per tag — and averaging is what the
tracker used to do, which is why its reported point stepped whenever the visible
set changed.

Lives in its own module so `tracker.py` (which consumes a calibration) and
`rigidbody_calib.py` (which produces one) can share it without importing each
other.
"""

from pathlib import Path
from typing import Optional

import cv2
import numpy as np
import rapidtag
import toml
from scipy.optimize import least_squares

TAG_SIZE_M = 0.05

# Fallback used only when calibration/device.toml is missing.
DEFAULT_TAG_IDS = tuple(range(1, 9))

# One tag's corners in its own frame, in the order the AprilTag detector reports
# them: top-left, top-right, bottom-right, bottom-left.
def tag_corners(size_m: float) -> np.ndarray:
    """One tag's corners in its own frame, for a given printed size."""
    half = size_m / 2.0
    return np.array(
        [
            [-half,  half, 0.0],
            [ half,  half, 0.0],
            [ half, -half, 0.0],
            [-half, -half, 0.0],
        ],
        dtype=np.float64,
    )


MARKER_PTS = tag_corners(TAG_SIZE_M)


# ── Configuration ─────────────────────────────────────────────────────────────

def load_device(path: Path) -> dict:
    """The hand-authored description of the rig being calibrated.

    Separate from the calibration this script writes: this says what the device
    *is* (its tags, and where the tracked point sits on it), while rigidbody.toml
    records what was *measured* about it.
    """
    if not path.exists():
        print(f"[CALIB] No device file at {path}; using built-in defaults.")
        return {
            "name": "unnamed",
            "tag_ids": list(DEFAULT_TAG_IDS),
            "tag_size_m": TAG_SIZE_M,
            "reference_id": None,
            "tip_tag": None,
            "tip": np.zeros(3),
            "camera_order": ("cam0", "cam1"),
            "exposure_us": 10000,
            "gain": 1.0,
            "isp": None,
            "stereo_pose": None,
            "solver": None,
        }
    data = toml.load(path)
    device = data.get("device", {})
    tip = data.get("tip", {})
    cameras = data.get("cameras", {})
    tracking = data.get("tracking", {})
    return {
        # Which estimator turns corners into a board pose: see RigidBody.POSE_SOLVERS.
        "solver": (tracking.get("solver") or "").strip().lower() or None,
        "camera_order": (
            cameras.get("stream0", "cam0"),
            cameras.get("stream1", "cam1"),
        ),
        "exposure_us": int(cameras.get("exposure_us", 10000)),
        "gain": float(cameras.get("gain", 1.0)),
        # "" / "none" / "raw" all mean the unprocessed sensor bytes; TOML has no
        # null, so the file says it with an empty string.
        "isp": (cameras.get("isp") or "").strip().lower() or None,
        # None means "decide from whether the calibration carries its own
        # extrinsic"; true/false is an explicit override.
        "stereo_pose": cameras.get("stereo_pose"),
        "name": device.get("name", "unnamed"),
        "tag_ids": list(device.get("tag_ids", DEFAULT_TAG_IDS)),
        "tag_size_m": float(device.get("tag_size_m", TAG_SIZE_M)),
        "reference_id": device.get("reference_id"),
        "tip_tag": tip.get("tag"),
        "tip": np.asarray(tip.get("offset_m", [0.0, 0.0, 0.0]), dtype=np.float64),
    }


def load_cameras(path: Path, order=("cam0", "cam1")) -> tuple[dict, tuple]:
    """Intrinsics for each camera stream, plus the resolution to configure at.

    `order` maps the streams rcam enumerates onto the sections of the stereo
    calibration, because the calibration tool's idea of cam0/cam1 need not match
    the order the cameras come up in. The returned dict is keyed by *stream*.
    """
    sc = toml.load(path)
    cameras = {
        f"cam{index}": (
            np.array(sc[section]["camera_matrix"]),
            np.array(sc[section]["dist_coeffs"]).reshape(4, 1),
        )
        for index, section in enumerate(order)
    }
    resolution = sc[order[0]]["resolution"]
    return cameras, (resolution[0], resolution[1])


def stereo_extrinsic(path: Path, order=("cam0", "cam1")):
    """Rotation and translation from stream0 to stream1, in metres.

    Stored as cam0 -> cam1 in the calibration's own labelling, so when the
    streams map onto those sections the other way round, what is wanted is the
    inverse transform.
    """
    sc = toml.load(path)
    R = np.array(sc["stereo"]["R"])
    T = np.array(sc["stereo"]["T"]).reshape(3, 1) / 1000.0  # mm -> m
    if tuple(order) == ("cam1", "cam0"):
        R = R.T
        T = -R @ T
    return R, T


class RigidBody:
    """Every tag's corners in the reference tag's frame, as one point cloud."""

    #: Estimators `mono_pose` can dispatch to.
    #:
    #: "joint"  — seed from the best single tag, then one OpenCV ITERATIVE PnP
    #:            over every visible corner. Every corner is trusted equally.
    #: "ransac" — rapidtag's `estimate_rigid_body_pose`: RANSAC over the same
    #:            corners, dropping ones the consensus disagrees with, then a
    #:            refit on the inliers.
    #:
    #: The trade is not obvious in advance. RANSAC protects against a tag whose
    #: calibrated place on the body is wrong, or a corner the detector put in
    #: the wrong spot — but the calibration's own per-tag disagreement is
    #: ~7 mm median, so it has plenty to reject, and dropping a tag *moves* the
    #: solution. An earlier experiment with hand-rolled rejection in this
    #: pipeline made jitter worse (1.57 -> 1.94 mm) for exactly that reason.
    POSE_SOLVERS = ("joint", "ransac")

    def __init__(self, reference_id: int, transforms: dict, tip_ref: np.ndarray,
                 meta: dict, stereo: Optional[tuple] = None):
        self.reference_id = reference_id
        # (R, T) cam0 -> cam1 measured against this very rig, when the
        # calibration refit it. Preferred over the checkerboard stereo
        # calibration, which describes whichever cameras were plugged in the
        # day it was made and in whatever order that tool labelled them.
        self.stereo = stereo
        self.tip_ref = np.asarray(tip_ref, dtype=np.float64).reshape(3)
        self.meta = meta
        # The printed size the geometry was solved at. Taken from the
        # calibration rather than the module default so a body measured with a
        # different tag size still reprojects correctly.
        self.tag_size_m = float(meta.get("tag_size_m", TAG_SIZE_M))
        self.marker_pts = tag_corners(self.tag_size_m)
        # marker id -> (rotation, translation) mapping that tag's frame into the
        # reference tag's frame.
        self.transforms = transforms
        self.corners_reference = {
            mid: self.marker_pts @ R.T + t for mid, (R, t) in transforms.items()
        }
        self.marker_ids = tuple(sorted(transforms))
        # rapidtag's view of the same geometry, built on first use.
        self._rapid_body = None
        # Which tags the last RANSAC solve kept, for diagnostics.
        self.last_ransac = None

    # ── Loading ───────────────────────────────────────────────────────────────

    @classmethod
    def load(cls, path: Path) -> Optional["RigidBody"]:
        """Read a calibration, or return None when there isn't one yet."""
        path = Path(path)
        if not path.exists():
            return None
        data = toml.load(path)
        transforms = {
            int(mid): (
                np.asarray(item["rotation_marker_to_reference"], dtype=np.float64),
                np.asarray(item["translation_marker_to_reference_m"], dtype=np.float64),
            )
            for mid, item in data["markers"].items()
        }
        stereo = None
        if "stereo_refined" in data:
            refined = data["stereo_refined"]
            stereo = (
                np.asarray(refined["rotation_cam0_to_cam1"], dtype=np.float64),
                np.asarray(refined["translation_cam0_to_cam1_m"], dtype=np.float64).reshape(3, 1),
            )
        return cls(
            reference_id=int(data["meta"]["reference_id"]),
            transforms=transforms,
            tip_ref=np.asarray(data["meta"]["tip_in_reference_m"], dtype=np.float64),
            meta=data["meta"],
            stereo=stereo,
        )

    def describe(self) -> str:
        meta = self.meta
        stereo = "self-calibrated stereo" if self.stereo is not None else "no stereo refit"
        return (
            f"{stereo}, " +
            f"tags {list(self.marker_ids)} about tag {self.reference_id}, "
            f"bundle RMSE {meta.get('bundle_final_rmse_px', float('nan')):.3f} px, "
            f"held-out median {meta.get('validation_median_px', float('nan')):.3f} px"
        )

    # ── Pose ──────────────────────────────────────────────────────────────────

    def tip(self, rvec, tvec) -> np.ndarray:
        """Where the device tip lands, given a board pose."""
        R = cv2.Rodrigues(np.asarray(rvec, dtype=np.float64).reshape(3, 1))[0]
        return R @ self.tip_ref + np.asarray(tvec, dtype=np.float64).reshape(3)

    def _stack(self, detections: dict):
        """Every visible tag's corners as one board, object and image points."""
        visible = [mid for mid in self.marker_ids if mid in detections]
        if not visible:
            return None
        return (
            np.concatenate([self.corners_reference[mid] for mid in visible]),
            np.concatenate(
                [np.asarray(detections[mid], dtype=np.float64).reshape(4, 2) for mid in visible]
            ),
            visible,
        )

    def _seed_pose(self, detections: dict, visible, K, D):
        """Best single-tag board pose, to start the joint solve from.

        A small tag cluster is nearly planar, and ITERATIVE PnP started cold can
        settle into the mirrored solution. IPPE_SQUARE needs a square centred on
        the origin, which only holds in a tag's *own* frame, so the seed is
        solved there and carried onto the board through that tag's calibrated
        transform — geometric initialisation, with no dependence on the previous
        frame.
        """
        candidates = []  # (rmse, R_board, t_board, tag it came from)
        for mid in visible:
            corners = np.asarray(detections[mid], dtype=np.float64).reshape(4, 2)
            und = cv2.fisheye.undistortPoints(
                corners.reshape(-1, 1, 2), K, D, P=K
            ).reshape(4, 2)
            solutions = cv2.solvePnPGeneric(
                self.marker_pts, und, K, None, flags=cv2.SOLVEPNP_IPPE_SQUARE
            )
            if not solutions[0]:
                continue
            R_marker, t_marker = self.transforms[mid]
            for rvec_tag, tvec_tag in zip(solutions[1], solutions[2]):
                tvec_tag = np.asarray(tvec_tag, dtype=np.float64).reshape(3)
                if tvec_tag[2] <= 0:
                    continue
                # p_cam = R_tag p_local + t_tag and p_ref = R_m2r p_local + t_m2r,
                # so the board pose is R_tag R_m2r' with the origin shifted.
                R_board = cv2.Rodrigues(rvec_tag)[0] @ R_marker.T
                t_board = tvec_tag - R_board @ t_marker
                projected, _ = cv2.fisheye.projectPoints(
                    self.corners_reference[mid].reshape(-1, 1, 3),
                    cv2.Rodrigues(R_board)[0], t_board.reshape(3, 1), K, D,
                )
                residual = projected.reshape(4, 2) - corners
                rmse = float(np.sqrt(np.mean(np.sum(residual**2, axis=1))))
                candidates.append((rmse, R_board, t_board))
        if not candidates:
            self._last_inliers = []
            return None

        # A tag that decodes to the wrong id (a stray square, a reflection)
        # lands far from where the calibration puts it. Left in, it drags the
        # joint least-squares fit to a pose metres away, and the tag with the
        # smallest own residual can be that very tag. So pick the pose that the
        # most tags agree with, and let the rest be dropped by the caller.
        def agreeing(R_board, t_board):
            rvec_board = cv2.Rodrigues(R_board)[0]
            ok = []
            for mid in visible:
                projected, _ = cv2.fisheye.projectPoints(
                    self.corners_reference[mid].reshape(-1, 1, 3),
                    rvec_board, t_board.reshape(3, 1), K, D,
                )
                err = np.sqrt(np.sum(
                    (projected.reshape(4, 2) - np.asarray(detections[mid], dtype=np.float64).reshape(4, 2)) ** 2,
                    axis=1)).max()
                if err <= self.INLIER_PX:
                    ok.append(mid)
            return ok

        scored = [(agreeing(R, t), rmse, R, t) for rmse, R, t in candidates]
        inliers, _, R_best, t_best = max(scored, key=lambda s: (len(s[0]), -s[1]))
        self._last_inliers = inliers
        return cv2.Rodrigues(R_best)[0], t_best.reshape(3, 1)

    # Max corner error, in pixels, for a tag to agree with a candidate pose.
    # Normal tags sit within a few px of a single-tag seed; a misidentified one
    # is hundreds away, so the exact value is not delicate.
    INLIER_PX = 12.0

    def drop_outlier_tags(self, detections: dict, K, D) -> dict:
        """`detections` without the tags that disagree with the consensus pose."""
        visible = [mid for mid in self.marker_ids if mid in detections]
        if len(visible) < 3:
            return detections  # two tags cannot outvote each other
        if self._seed_pose(detections, visible, K, D) is None:
            return detections
        keep = set(self._last_inliers)
        return {mid: c for mid, c in detections.items() if mid in keep or mid not in visible}

    def _rapidtag_body(self):
        """The same geometry handed to rapidtag, built once and reused.

        rapidtag derives each tag's corners from `tag_size_m` itself, using the
        same TL/TR/BR/BL order and the same
        `p_reference = R p_marker + t` convention this module writes, so the
        calibration transfers across unchanged.
        """
        if self._rapid_body is None:
            ids = list(self.marker_ids)
            self._rapid_body = rapidtag.RigidBody(
                self.tag_size_m,
                ids,
                [self.transforms[mid][0].tolist() for mid in ids],
                [self.transforms[mid][1].reshape(3).tolist() for mid in ids],
            )
        return self._rapid_body

    def ransac_pose(self, detections: dict, K, D, iterations: int = 100,
                    reprojection_error: float = 3.0, seed: int = 0):
        """rapidtag's RANSAC pose over every visible corner in one camera.

        The corners are fisheye-undistorted into pinhole space first and
        rapidtag is handed zero distortion, because it models OpenCV's plumb-bob
        coefficients and these cameras are calibrated with the fisheye model —
        passing the fisheye coefficients straight through would silently apply
        the wrong lens.

        `seed` is fixed rather than drawn per frame so the same corners always
        produce the same pose; a re-randomised RANSAC would add jitter of its
        own on a device that is not moving.

        Returns (rvec, tvec) in the camera's frame, matching `mono_pose`, and
        stashes the last inlier report in `self.last_ransac` for diagnostics.
        """
        self.last_ransac = None
        ids, corners = [], []
        for mid, points in detections.items():
            if mid not in self.transforms:
                continue
            undistorted = cv2.fisheye.undistortPoints(
                np.asarray(points, dtype=np.float64).reshape(-1, 1, 2), K, D, P=K
            ).reshape(4, 2)
            ids.append(int(mid))
            corners.append(undistorted.tolist())
        if not ids:
            return None, None

        pose = rapidtag.estimate_rigid_body_pose(
            corners, ids, self._rapidtag_body(), K.tolist(), None,
            iterations=iterations, reprojection_error=reprojection_error,
            seed=seed,
        )
        if pose is None:
            return None, None
        tvec = np.asarray(pose.tvec, dtype=np.float64)
        if tvec[2] <= 0:
            return None, None
        self.last_ransac = {
            "used": list(pose.used_marker_ids),
            "inliers": list(pose.inlier_marker_ids),
            "rmse_px": float(pose.reprojection_rmse),
        }
        return np.asarray(pose.rvec, dtype=np.float64), tvec

    def mono_pose(self, detections: dict, K, D, solver: str = "joint",
                  screened: bool = False):
        """One board pose from a single camera, by whichever estimator is asked.

        See POSE_SOLVERS for what the choice actually changes.
        """
        if solver == "ransac":
            return self.ransac_pose(detections, K, D)
        if not screened:
            detections = self.drop_outlier_tags(detections, K, D)
        stacked = self._stack(detections)
        if stacked is None:
            return None, None
        object_points, image_points_raw, visible = stacked
        seed = self._seed_pose(detections, visible, K, D)
        if seed is None:
            return None, None
        if len(visible) == 1:
            return seed[0].flatten(), seed[1].flatten()

        rvec, tvec = seed
        undistorted = cv2.fisheye.undistortPoints(
            image_points_raw.reshape(-1, 1, 2), K, D, P=K
        ).reshape(-1, 2)
        ok, rvec, tvec = cv2.solvePnP(
            object_points, undistorted, K, None,
            rvec.copy(), tvec.copy(), True, flags=cv2.SOLVEPNP_ITERATIVE,
        )
        if not ok or float(tvec.reshape(3)[2]) <= 0:
            return None, None
        return rvec.flatten(), tvec.flatten()

    def stereo_pose(self, det0: dict, det1: dict, K0, D0, K1, D1, R_st, T_st,
                    solver: str = "joint"):
        """One pose minimising corner reprojection in both cameras at once.

        The cross-baseline constraint is what tightens depth, so both images are
        fitted together rather than averaging two independent single-camera
        poses. Seeded from the cam0 solve, by whichever solver is in use — the
        refinement itself is the same least-squares fit either way, so the
        solver choice reaches the stereo path only through that seed.
        """
        det0 = self.drop_outlier_tags(det0, K0, D0)
        det1 = self.drop_outlier_tags(det1, K1, D1)
        stacked0 = self._stack(det0)
        stacked1 = self._stack(det1)
        if stacked0 is None or stacked1 is None:
            return None, None
        object0, image0, _ = stacked0
        object1, image1, _ = stacked1

        seed_rvec, seed_tvec = self.mono_pose(det0, K0, D0, solver, screened=True)
        if seed_rvec is None:
            return None, None

        stereo_rvec = cv2.Rodrigues(R_st)[0]
        stereo_tvec = np.asarray(T_st, dtype=np.float64).reshape(3, 1)

        def residual(parameters):
            rvec0 = parameters[:3].reshape(3, 1)
            tvec0 = parameters[3:].reshape(3, 1)
            projected0, _ = cv2.fisheye.projectPoints(
                object0.reshape(-1, 1, 3), rvec0, tvec0, K0, D0
            )
            rvec1, tvec1 = cv2.composeRT(rvec0, tvec0, stereo_rvec, stereo_tvec)[:2]
            projected1, _ = cv2.fisheye.projectPoints(
                object1.reshape(-1, 1, 3), rvec1, tvec1, K1, D1
            )
            return np.concatenate(
                [
                    (projected0.reshape(-1, 2) - image0).ravel(),
                    (projected1.reshape(-1, 2) - image1).ravel(),
                ]
            )

        # Plain LM, no robust loss: the cam0 seed can carry a large cam1
        # residual, and a robust loss would suppress exactly the cross-baseline
        # measurements that tighten depth.
        # 20 evaluations is ample: measured on real takes the solution stops
        # moving after fewer than ten, and the cost here is dominated by the two
        # fisheye projections per residual evaluation, not by the iteration cap.
        result = least_squares(
            residual, np.concatenate([seed_rvec, seed_tvec]), method="lm", max_nfev=20
        )
        if result.x[5] <= 0:
            return None, None
        return result.x[:3], result.x[3:]

    def pose_in_cam1_frame(self, rvec, tvec, R_st, T_st):
        """Carry a pose solved in cam1 into cam0's frame."""
        R1 = cv2.Rodrigues(np.asarray(rvec).reshape(3, 1))[0]
        R_c0 = R_st.T @ R1
        t_c0 = R_st.T @ (np.asarray(tvec).reshape(3, 1) - np.asarray(T_st).reshape(3, 1))
        return cv2.Rodrigues(R_c0)[0].flatten(), t_c0.flatten()
