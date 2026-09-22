"""Self-calibrate the marker rigid body from live camera detections.

The device carries several AprilTags on different faces, and the tracker needs
each one's fixed offset to the device tip. Those offsets used to be hand
measured (`tracker.py`'s MARKER_OFFSETS), which is why every marker reported the
tip in a slightly different place and the position stepped as the visible set
changed.

This measures the body instead. Every frame where two tags are seen in the same
camera constrains their relative pose; accumulate enough of those and the whole
cluster is solved as one rigid body, expressed in a reference tag's frame. Only
the tip offset stays hand measured, and only in the reference tag's frame — the
other tags' offsets follow from the solved geometry.

Nothing but corners is kept. A frame is detected, its four corners per visible
tag are appended, and the image is dropped; a 60 s take is ~1.2 MB rather than
~4 GB of raw frames.

Note the cameras are *not* frame synchronised here, unlike in tracking: the
solve pairs tags seen in the same frame of the same camera, so the two cameras
contribute independent observations and never need to agree on an instant.

Usage:
    .venv/bin/python pyscripts/rigidbody_calib.py --seconds 60
    .venv/bin/python pyscripts/rigidbody_calib.py --from corners.npz   # re-solve
"""

import argparse
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

import cv2
import numpy as np
import rapidtag
import toml
from scipy.optimize import least_squares
from scipy.sparse import lil_matrix
from scipy.spatial.transform import Rotation

from tracker import (
    _APRILTAG_DICT,
    _MARKER_PTS,
    MARKER_OFFSETS,
    _draw_markers,
    _refine_corners,
)

_SCRIPT_DIR = Path(__file__).parent

# Solved poses worse than this are dropped before they reach the averaging: a
# tag caught at a glancing angle or half out of frame fits its own corners badly
# and would drag the transform with it.
MAX_POSE_RMSE_PX = 1.5
# Below this many co-visible observations a tag's transform is not worth
# claiming, so it is left out of the calibration rather than solved badly.
MIN_SAMPLES_PER_MARKER = 20
# Fraction of the take used to solve; the remainder scores the result on frames
# it never saw.
CALIBRATION_FRACTION = 0.5


# ── Per-tag pose ──────────────────────────────────────────────────────────────

def _marker_pose(corners: np.ndarray, K: np.ndarray, D: np.ndarray):
    """Lowest-error positive-depth IPPE pose for one square tag.

    IPPE_SQUARE returns both branches of the planar ambiguity. The one that
    reprojects better is taken, which is reliable at the angles this rig is
    calibrated at and is why the take should include tilted views rather than
    only face-on ones.
    """
    und = cv2.fisheye.undistortPoints(
        corners.reshape(-1, 1, 2).astype(np.float64), K, D, P=K
    ).reshape(4, 2)
    # Indexed, not unpacked: the return arity has grown across OpenCV versions
    # (4.13 appends the per-solution reprojection error).
    solutions = cv2.solvePnPGeneric(
        _MARKER_PTS, und, K, None, flags=cv2.SOLVEPNP_IPPE_SQUARE
    )
    if not solutions[0]:
        return None

    best = None
    for rvec, tvec in zip(solutions[1], solutions[2]):
        tvec = np.asarray(tvec, dtype=np.float64).reshape(3)
        if tvec[2] <= 0:
            continue
        projected, _ = cv2.projectPoints(_MARKER_PTS, rvec, tvec, K, None)
        residual = projected.reshape(4, 2) - und
        rmse = float(np.sqrt(np.mean(np.sum(residual**2, axis=1))))
        if best is None or rmse < best["rmse_px"]:
            best = {"R": cv2.Rodrigues(rvec)[0], "t": tvec, "rmse_px": rmse}
    return best


# ── Robust SE(3) averaging ────────────────────────────────────────────────────

def _robust_limit(values, sigma: float = 3.5, floor: float = 0.0) -> float:
    """Median + sigma robust standard deviations, via the MAD."""
    values = np.asarray(values, dtype=np.float64)
    median = float(np.median(values))
    mad = float(np.median(np.abs(values - median)))
    return median + sigma * max(1.4826 * mad, floor)


def _robust_average_transform(candidates: list) -> dict:
    """Average many noisy observations of one fixed transform.

    Iteratively drops the samples furthest from the current consensus in both
    rotation and translation. A tag briefly mis-detected, or caught in the
    IPPE branch flip, shows up as a large outlier rather than a small bias, so
    rejecting on a robust spread beats weighting everything.
    """
    if len(candidates) < MIN_SAMPLES_PER_MARKER:
        raise RuntimeError(
            f"only {len(candidates)} relative poses; need {MIN_SAMPLES_PER_MARKER}"
        )
    rotations = Rotation.from_matrix(np.asarray([c["R"] for c in candidates]))
    translations = np.asarray([c["t"] for c in candidates], dtype=np.float64)
    keep = np.ones(len(candidates), dtype=bool)

    for _ in range(6):
        mean_rotation = rotations[keep].mean()
        rotation_error = np.degrees((mean_rotation.inv() * rotations).magnitude())
        median_translation = np.median(translations[keep], axis=0)
        translation_error = 1000.0 * np.linalg.norm(
            translations - median_translation, axis=1
        )
        new_keep = (
            rotation_error <= _robust_limit(rotation_error[keep], floor=0.5)
        ) & (
            translation_error <= _robust_limit(translation_error[keep], floor=0.5)
        )
        if new_keep.sum() < MIN_SAMPLES_PER_MARKER or np.array_equal(new_keep, keep):
            break
        keep = new_keep

    mean_rotation = rotations[keep].mean()
    median_translation = np.median(translations[keep], axis=0)
    rotation_error = np.degrees((mean_rotation.inv() * rotations[keep]).magnitude())
    translation_error = 1000.0 * np.linalg.norm(
        translations[keep] - median_translation, axis=1
    )
    return {
        "R": mean_rotation.as_matrix(),
        "t": median_translation,
        "sample_count": len(candidates),
        "used_count": int(keep.sum()),
        "rotation_spread_deg": float(np.median(rotation_error)),
        "translation_spread_mm": float(np.median(translation_error)),
    }


# ── Capture ───────────────────────────────────────────────────────────────────

class CornerCollector:
    """Detected corners per frame per camera — never the frames themselves."""

    def __init__(self, camera_names=("cam0", "cam1")):
        self.camera_names = camera_names
        self.frames = {name: [] for name in camera_names}

    def add(self, name: str, detections: dict) -> None:
        self.frames[name].append(detections)

    def counts(self) -> dict:
        counts: dict[int, int] = {}
        for frames in self.frames.values():
            for frame in frames:
                for mid in frame:
                    counts[mid] = counts.get(mid, 0) + 1
        return dict(sorted(counts.items()))

    def save(self, path: Path) -> None:
        """Flatten to an .npz so a take can be re-solved without recapturing.

        Stored as one row per observation — camera, frame, marker, 8 corner
        coordinates — because the per-frame dicts are ragged and npz wants
        rectangles. msgpack would be the obvious alternative but is not
        installed in this project's venv.
        """
        rows, corners = [], []
        for cam_index, name in enumerate(self.camera_names):
            for frame_index, frame in enumerate(self.frames[name]):
                for mid, c in frame.items():
                    rows.append((cam_index, frame_index, mid))
                    corners.append(np.asarray(c, dtype=np.float64).reshape(8))
        np.savez_compressed(
            path,
            index=np.asarray(rows, dtype=np.int64),
            corners=np.asarray(corners, dtype=np.float64),
            camera_names=np.asarray(self.camera_names),
            frame_counts=np.asarray(
                [len(self.frames[n]) for n in self.camera_names], dtype=np.int64
            ),
        )

    @classmethod
    def load(cls, path: Path) -> "CornerCollector":
        data = np.load(path, allow_pickle=False)
        names = tuple(str(n) for n in data["camera_names"])
        collector = cls(names)
        for name, count in zip(names, data["frame_counts"]):
            collector.frames[name] = [{} for _ in range(int(count))]
        for (cam_index, frame_index, mid), corner in zip(
            data["index"], data["corners"]
        ):
            collector.frames[names[cam_index]][frame_index][int(mid)] = corner.reshape(
                4, 2
            )
        return collector


def capture(seconds: float, frame_size, display: bool) -> CornerCollector:
    """Detect tags in both cameras for `seconds`, keeping only the corners."""
    from rcam import Camera, list_cameras

    labels = list_cameras()
    if len(labels) < 2:
        raise RuntimeError(
            f"stereo calibration needs two cameras; found {labels or 'none'}"
        )

    cameras = []
    for label in labels[:2]:
        cam = Camera(label)
        cam.configure(size=frame_size, bit_depth=8)
        cam.set_controls({"ExposureTime": 5000})
        cam.start()
        cameras.append(cam)

    collector = CornerCollector()
    executor = ThreadPoolExecutor(max_workers=2)
    print(
        f"[CALIB] Capturing {seconds:.0f}s. Rotate the device slowly so every "
        "marker is seen together with the reference, from a range of angles."
    )
    deadline = time.perf_counter() + seconds
    last_report = time.perf_counter()
    try:
        while time.perf_counter() < deadline:
            futures = [executor.submit(cam.capture_array) for cam in cameras]
            frames = [f.result() for f in futures]
            detected = rapidtag.detect_markers_batch(frames, _APRILTAG_DICT)

            for name, frame, (corners, ids) in zip(
                collector.camera_names, frames, detected
            ):
                detections = {}
                if ids:
                    # Sub-pixel refinement matters more here than in tracking:
                    # this error is baked into the calibration every later frame
                    # inherits, rather than averaging out over time.
                    refined = _refine_corners(frame, corners)
                    for mid, c in zip(np.asarray(ids).flatten(), refined):
                        detections[int(mid)] = np.asarray(c, dtype=np.float64).reshape(
                            4, 2
                        )
                collector.add(name, detections)

            if display:
                tiles = []
                for frame, (corners, ids) in zip(frames, detected):
                    tile = cv2.cvtColor(frame, cv2.COLOR_GRAY2BGR)
                    if ids:
                        tile = _draw_markers(
                            tile, corners, np.asarray(ids, dtype=int).reshape(-1, 1)
                        )
                    tiles.append(cv2.resize(tile, (480, 300)))
                cv2.imshow("rigidbody calibration", np.hstack(tiles))
                if cv2.waitKey(1) & 0xFF == ord("q"):
                    break

            now = time.perf_counter()
            if now - last_report >= 5.0:
                last_report = now
                remaining = deadline - now
                print(
                    f"  {len(collector.frames['cam0'])} frames, "
                    f"{remaining:.0f}s left, seen: {collector.counts()}"
                )
    finally:
        executor.shutdown(wait=True)
        for cam in cameras:
            cam.stop()
        if display:
            cv2.destroyAllWindows()
    return collector


# ── Solve ─────────────────────────────────────────────────────────────────────

def _pairwise_transforms(collector, poses, cameras, reference_id, end_frame):
    """Every same-frame observation of a tag alongside the reference tag."""
    candidates: dict[int, list] = {}
    for name in collector.camera_names:
        for frame_index in range(min(end_frame, len(poses[name]))):
            frame_poses = poses[name][frame_index]
            reference = frame_poses.get(reference_id)
            if reference is None or reference["rmse_px"] > MAX_POSE_RMSE_PX:
                continue
            for mid, pose in frame_poses.items():
                if mid == reference_id or pose["rmse_px"] > MAX_POSE_RMSE_PX:
                    continue
                # A point in the tag's frame reaches the camera through the tag
                # pose, and the camera reaches the reference frame through the
                # inverse reference pose.
                candidates.setdefault(mid, []).append(
                    {
                        "R": reference["R"].T @ pose["R"],
                        "t": reference["R"].T @ (pose["t"] - reference["t"]),
                    }
                )
    return candidates


def _bundle_adjust(collector, poses, cameras, transforms, reference_id, end_frame):
    """Refine every tag transform jointly against the raw corners.

    The pairwise average above inherits each tag's own IPPE tilt bias, because a
    square's fronto-parallel pose is only weakly constrained by four corners.
    Fitting all tags at once — with one throwaway board pose per view — makes
    every observed corner agree with a single rigid body instead, which is what
    removes that bias.
    """
    marker_ids = [m for m in sorted(transforms) if m != reference_id]
    offsets = {mid: 6 * i for i, mid in enumerate(marker_ids)}
    view_start = 6 * len(marker_ids)

    views = []
    for name in collector.camera_names:
        for frame_index in range(min(end_frame, len(poses[name]))):
            reference = poses[name][frame_index].get(reference_id)
            detections = collector.frames[name][frame_index]
            visible = [m for m in transforms if m in detections]
            if (
                reference is None
                or reference["rmse_px"] > MAX_POSE_RMSE_PX
                or len(visible) < 2
            ):
                continue
            views.append(
                {
                    "camera": name,
                    "visible": visible,
                    "detections": detections,
                    "R": reference["R"],
                    "t": reference["t"],
                }
            )
    if not views:
        raise RuntimeError("no views show two tags at once; nothing to bundle adjust")

    parts = []
    for mid in marker_ids:
        parts.append(Rotation.from_matrix(transforms[mid]["R"]).as_rotvec())
        parts.append(transforms[mid]["t"])
    for view in views:
        parts.append(Rotation.from_matrix(view["R"]).as_rotvec())
        parts.append(view["t"])
    x0 = np.concatenate(parts)

    def unpack(parameters, mid):
        if mid == reference_id:
            return np.eye(3), np.zeros(3)
        o = offsets[mid]
        return (
            Rotation.from_rotvec(parameters[o : o + 3]).as_matrix(),
            parameters[o + 3 : o + 6],
        )

    def residuals(parameters):
        out = []
        for index, view in enumerate(views):
            o = view_start + 6 * index
            rvec, tvec = parameters[o : o + 3], parameters[o + 3 : o + 6]
            K, D = cameras[view["camera"]]
            for mid in view["visible"]:
                R, t = unpack(parameters, mid)
                object_points = _MARKER_PTS @ R.T + t
                projected, _ = cv2.fisheye.projectPoints(
                    object_points.reshape(-1, 1, 3), rvec, tvec, K, D
                )
                out.append(
                    (projected.reshape(4, 2) - view["detections"][mid]).ravel()
                )
        return np.concatenate(out)

    # Each residual block touches only its own view's pose and its own tag, so
    # the Jacobian is almost entirely zeros; saying so turns an intractable
    # dense solve into a quick sparse one.
    rows = sum(8 * len(view["visible"]) for view in views)
    sparsity = lil_matrix((rows, len(x0)), dtype=np.uint8)
    row = 0
    for index, view in enumerate(views):
        o = view_start + 6 * index
        for mid in view["visible"]:
            sparsity[row : row + 8, o : o + 6] = 1
            if mid != reference_id:
                sparsity[row : row + 8, offsets[mid] : offsets[mid] + 6] = 1
            row += 8

    def rmse(parameters):
        return float(np.sqrt(np.mean(residuals(parameters).reshape(-1, 2) ** 2) * 2.0))

    initial = rmse(x0)
    result = least_squares(
        residuals,
        x0,
        jac_sparsity=sparsity.tocsr(),
        method="trf",
        loss="soft_l1",
        f_scale=0.5,
        x_scale="jac",
        max_nfev=100,
    )
    for mid in marker_ids:
        transforms[mid]["R"], transforms[mid]["t"] = unpack(result.x, mid)
    return {
        "views": len(views),
        "initial_rmse_px": initial,
        "final_rmse_px": rmse(result.x),
        "success": bool(result.success),
    }


def _board_corners(transforms, mid) -> np.ndarray:
    """One tag's corners in the reference tag's frame."""
    return _MARKER_PTS @ transforms[mid]["R"].T + transforms[mid]["t"]


def _validate(collector, cameras, transforms, start_frame) -> dict:
    """Score the body on frames it was not solved from.

    One PnP over every visible tag at once: if the geometry is right the whole
    cluster reprojects together, and if a tag is misplaced this is where it
    shows, because nothing here is free to absorb the error.
    """
    errors = []
    for name in collector.camera_names:
        K, D = cameras[name]
        for frame in collector.frames[name][start_frame:]:
            visible = [m for m in sorted(transforms) if m in frame]
            if len(visible) < 2:
                continue
            object_points = np.concatenate([_board_corners(transforms, m) for m in visible])
            raw = np.concatenate([frame[m] for m in visible])
            undistorted = cv2.fisheye.undistortPoints(
                raw.reshape(-1, 1, 2), K, D, P=K
            ).reshape(-1, 2)
            ok, rvec, tvec = cv2.solvePnP(
                object_points, undistorted, K, None, flags=cv2.SOLVEPNP_ITERATIVE
            )
            if not ok or tvec.reshape(3)[2] <= 0:
                continue
            projected, _ = cv2.fisheye.projectPoints(
                object_points.reshape(-1, 1, 3), rvec, tvec, K, D
            )
            residual = projected.reshape(-1, 2) - raw
            errors.append(float(np.sqrt(np.mean(np.sum(residual**2, axis=1)))))
    if not errors:
        raise RuntimeError("no held-out frames show two tags at once")
    return {
        "frames": len(errors),
        "median_px": float(np.median(errors)),
        "p95_px": float(np.percentile(errors, 95)),
    }


def solve(collector, cameras, reference_id, tip_ref) -> dict:
    """Corners in, rigid body out."""
    poses = {}
    for name in collector.camera_names:
        K, D = cameras[name]
        poses[name] = [
            {mid: _marker_pose(c, K, D) for mid, c in frame.items()}
            for frame in collector.frames[name]
        ]
        # Drop tags whose pose could not be solved at all, so downstream code
        # can assume every entry is a pose.
        poses[name] = [
            {mid: p for mid, p in frame.items() if p is not None} for frame in poses[name]
        ]

    frame_count = min(len(collector.frames[n]) for n in collector.camera_names)
    end_frame = int(frame_count * CALIBRATION_FRACTION)
    print(
        f"[CALIB] Solving on frames [0, {end_frame}); "
        f"validating on {frame_count - end_frame} held out."
    )

    candidates = _pairwise_transforms(collector, poses, cameras, reference_id, end_frame)
    transforms = {
        reference_id: {
            "R": np.eye(3),
            "t": np.zeros(3),
            "sample_count": 0,
            "used_count": 0,
            "rotation_spread_deg": 0.0,
            "translation_spread_mm": 0.0,
        }
    }
    for mid in sorted(candidates):
        if len(candidates[mid]) < MIN_SAMPLES_PER_MARKER:
            print(
                f"  skipping tag {mid}: {len(candidates[mid])} co-visible views "
                f"(need {MIN_SAMPLES_PER_MARKER})"
            )
            continue
        transforms[mid] = _robust_average_transform(candidates[mid])
        item = transforms[mid]
        print(
            f"  tag {mid:2d} -> tag {reference_id}: used "
            f"{item['used_count']}/{item['sample_count']}, "
            f"t={np.round(1000 * item['t'], 1)} mm, spread "
            f"{item['translation_spread_mm']:.2f} mm / "
            f"{item['rotation_spread_deg']:.2f}°"
        )
    if len(transforms) < 2:
        raise RuntimeError(
            "no tag was seen alongside the reference often enough; check that "
            f"tag {reference_id} is visible and rotate the device more slowly"
        )

    bundle = _bundle_adjust(
        collector, poses, cameras, transforms, reference_id, end_frame
    )
    print(
        f"[CALIB] Bundle adjustment: {bundle['views']} views, "
        f"RMSE {bundle['initial_rmse_px']:.3f} -> {bundle['final_rmse_px']:.3f} px"
    )
    for mid in sorted(transforms):
        if mid != reference_id:
            print(
                f"  refined tag {mid:2d}: "
                f"t={np.round(1000 * transforms[mid]['t'], 1)} mm"
            )

    validation = _validate(collector, cameras, transforms, end_frame)
    print(
        f"[CALIB] Held-out reprojection: N={validation['frames']}, "
        f"median={validation['median_px']:.3f} px, "
        f"p95={validation['p95_px']:.3f} px"
    )
    return {"transforms": transforms, "bundle": bundle, "validation": validation}


# ── Output ────────────────────────────────────────────────────────────────────

def tip_offsets(transforms, tip_ref) -> dict:
    """The tip in each tag's own frame — a drop-in MARKER_OFFSETS table.

    The tip is known in the reference tag's frame; a point there maps into tag
    i's frame by inverting that tag's transform, so one measured number spreads
    to every tag through the solved geometry.
    """
    tip_ref = np.asarray(tip_ref, dtype=np.float64).reshape(3)
    return {
        mid: item["R"].T @ (tip_ref - item["t"]) for mid, item in transforms.items()
    }


def write_toml(path: Path, result, reference_id, tip_ref, cameras_path, frames) -> None:
    transforms = result["transforms"]
    offsets = tip_offsets(transforms, tip_ref)
    payload = {
        "meta": {
            "format_version": 1,
            "created": datetime.now().isoformat(timespec="seconds"),
            "dictionary": _APRILTAG_DICT,
            "tag_size_m": float(_MARKER_PTS[1, 0] * 2),
            "reference_id": reference_id,
            "marker_ids": sorted(transforms),
            "tip_in_reference_m": list(map(float, tip_ref)),
            "stereo_calibration": str(cameras_path),
            "frames": frames,
            "bundle_views": result["bundle"]["views"],
            "bundle_initial_rmse_px": result["bundle"]["initial_rmse_px"],
            "bundle_final_rmse_px": result["bundle"]["final_rmse_px"],
            "bundle_success": result["bundle"]["success"],
            "validation_frames": result["validation"]["frames"],
            "validation_median_px": result["validation"]["median_px"],
            "validation_p95_px": result["validation"]["p95_px"],
        },
        "markers": {
            str(mid): {
                "rotation_marker_to_reference": item["R"].tolist(),
                "translation_marker_to_reference_m": item["t"].tolist(),
                "samples_total": item["sample_count"],
                "samples_used": item["used_count"],
                "translation_spread_mm": item["translation_spread_mm"],
                "rotation_spread_deg": item["rotation_spread_deg"],
            }
            for mid, item in transforms.items()
        },
        # The tip in each tag's own frame, i.e. what MARKER_OFFSETS held by hand.
        "offsets": {str(mid): offset.tolist() for mid, offset in offsets.items()},
    }
    with path.open("w", encoding="utf-8") as stream:
        toml.dump(payload, stream)


def report_against_hardcoded(transforms, tip_ref) -> None:
    """Print the solved offsets beside the hand-measured ones they replace."""
    offsets = tip_offsets(transforms, tip_ref)
    print("\n[CALIB] Solved offsets vs the hand-measured MARKER_OFFSETS:")
    for mid in sorted(offsets):
        solved = offsets[mid]
        if mid in MARKER_OFFSETS:
            measured = np.asarray(MARKER_OFFSETS[mid], dtype=np.float64)
            delta = 1000.0 * np.linalg.norm(solved - measured)
            print(
                f"  tag {mid:2d}: solved {np.round(1000 * solved, 1)} mm  "
                f"measured {np.round(1000 * measured, 1)} mm  "
                f"differ {delta:.1f} mm"
            )
        else:
            print(f"  tag {mid:2d}: solved {np.round(1000 * solved, 1)} mm  (new)")


# ── Entry point ───────────────────────────────────────────────────────────────

def load_cameras(path: Path) -> tuple[dict, tuple]:
    """Intrinsics per camera, plus the resolution to configure the sensors at."""
    sc = toml.load(path)
    cameras = {
        name: (
            np.array(sc[name]["camera_matrix"]),
            np.array(sc[name]["dist_coeffs"]).reshape(4, 1),
        )
        for name in ("cam0", "cam1")
    }
    resolution = sc["cam0"]["resolution"]
    return cameras, (resolution[0], resolution[1])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--seconds", type=float, default=60.0,
                        help="How long to capture for (default: 60).")
    parser.add_argument("--reference", type=int, default=4,
                        help="Tag every other tag is expressed relative to "
                             "(default: 4, the lowest id on the bracket).")
    parser.add_argument("--tip", type=float, nargs=3, default=None, metavar=("X", "Y", "Z"),
                        help="The device tip in the reference tag's frame, in metres. "
                             "Defaults to that tag's existing MARKER_OFFSETS entry.")
    parser.add_argument("--out", type=Path,
                        default=_SCRIPT_DIR / "calibration" / "rigidbody.toml",
                        help="Where to write the calibration.")
    parser.add_argument("--save-corners", type=Path, default=None,
                        help="Also dump the detected corners here (.npz) so the "
                             "take can be re-solved without recapturing.")
    parser.add_argument("--from", dest="from_corners", type=Path, default=None,
                        help="Re-solve from a saved corner dump instead of capturing.")
    parser.add_argument("--display", action="store_true",
                        help="Show the detections while capturing.")
    args = parser.parse_args()

    cameras, frame_size = load_cameras(
        _SCRIPT_DIR / "calibration" / "sterio_calibration.toml"
    )

    tip = args.tip
    if tip is None:
        if args.reference not in MARKER_OFFSETS:
            parser.error(
                f"tag {args.reference} has no hand-measured offset to fall back "
                "on; pass --tip X Y Z (metres, in that tag's frame)"
            )
        tip = MARKER_OFFSETS[args.reference]
    tip = np.asarray(tip, dtype=np.float64)
    print(f"[CALIB] Reference tag {args.reference}, tip at "
          f"{np.round(1000 * tip, 1)} mm in its frame")

    if args.from_corners:
        collector = CornerCollector.load(args.from_corners)
        print(f"[CALIB] Loaded corners <- {args.from_corners}")
    else:
        collector = capture(args.seconds, frame_size, args.display)
        if args.save_corners:
            collector.save(args.save_corners)
            print(f"[CALIB] Saved corners -> {args.save_corners}")

    frames = min(len(collector.frames[n]) for n in collector.camera_names)
    print(f"[CALIB] {frames} frames per camera, detections: {collector.counts()}")

    result = solve(collector, cameras, args.reference, tip)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    write_toml(
        args.out, result, args.reference, tip,
        _SCRIPT_DIR / "calibration" / "sterio_calibration.toml", frames,
    )
    report_against_hardcoded(result["transforms"], tip)
    print(f"\n[CALIB] Wrote {args.out}")
