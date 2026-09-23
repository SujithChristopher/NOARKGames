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
import heapq
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
from typing import Optional

import cv2
import numpy as np
import rapidtag
import toml
from scipy.optimize import least_squares
from scipy.sparse import lil_matrix
from scipy.spatial.transform import Rotation

from rigid_body import (
    DEFAULT_TAG_IDS,
    TAG_SIZE_M,
    load_cameras,
    load_device,
    stereo_extrinsic,
    tag_corners,
)
from stereo_capture import StereoCapture
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
# Above this the tags place the tracked point in materially different spots, and
# the reported position steps as the visible set changes. Good takes measure
# well under 2 mm; the one that shipped a 29 mm error measured 81 mm.
AGREEMENT_LIMIT_MM = 10.0
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
        # Whether each frame index holds a genuinely simultaneous pair. The
        # rigid body itself is solved from same-camera pairings and does not
        # care, but anything cross-camera — refitting the stereo extrinsic —
        # must use only the frames where this is true.
        self.paired: list = []

    def add(self, name: str, detections: dict) -> None:
        self.frames[name].append(detections)

    def add_pair(self, det0: dict, det1: dict, paired: bool) -> None:
        self.frames[self.camera_names[0]].append(det0)
        self.frames[self.camera_names[1]].append(det1)
        self.paired.append(bool(paired))

    def keep_only(self, allowed) -> None:
        """Drop every detection outside `allowed`, in place."""
        allowed = set(allowed)
        for name, frames in self.frames.items():
            self.frames[name] = [
                {mid: c for mid, c in frame.items() if mid in allowed}
                for frame in frames
            ]

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
            paired=np.asarray(self.paired, dtype=bool),
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
        if "paired" in data:
            collector.paired = [bool(x) for x in data["paired"]]
        else:
            # Takes recorded before the capture was synchronised: the frames
            # were paired by index with no check, and measured on this board
            # that put them nearly three frame periods apart.
            collector.paired = [False] * max(
                len(collector.frames[n]) for n in names
            )
        return collector


def _overlay_status(collector, brightness, tag_px, remaining, tag_ids):
    """Lines for the preview window: what is good, and what still needs doing.

    Returns (text, colour) pairs rather than a formatted block, so the window
    can show at a glance which items are problems — during a take the person is
    holding a device in front of the cameras and is not going to read prose.
    """
    GOOD, WARN, BAD = (120, 220, 120), (60, 200, 255), (80, 80, 255)
    counts = collector.counts()
    lines = [
        (f"{len(collector.paired)} frames   {remaining:.0f}s left   "
         f"{100.0 * np.mean(collector.paired):.0f}% paired", (230, 230, 230)),
    ]

    if brightness:
        mean = float(np.mean(brightness))
        if mean < 40:
            lines.append((f"image {mean:.0f}/255  TOO DARK - add light", BAD))
        elif mean > 200:
            lines.append((f"image {mean:.0f}/255  very bright - check glare", WARN))
        else:
            lines.append((f"image {mean:.0f}/255  ok", GOOD))
    if tag_px:
        size = float(np.median(tag_px))
        lines.append((f"tag size ~{size:.0f} px"
                      + ("  (small - move closer)" if size < 45 else ""),
                      WARN if size < 45 else GOOD))

    pairs = {}
    for name in collector.camera_names:
        for frame in collector.frames[name]:
            ids = sorted(frame)
            for i, a in enumerate(ids):
                for b in ids[i + 1:]:
                    pairs[(a, b)] = pairs.get((a, b), 0) + 1
    strong = {t for (a, b), n in pairs.items() if n >= MIN_SAMPLES_PER_MARKER
              for t in (a, b)}

    # One line per tag state: done / seen but not yet usable / never seen.
    done = sorted(t for t in tag_ids if t in strong)
    weak = sorted(t for t in tag_ids if t in counts and t not in strong)
    unseen = sorted(t for t in tag_ids if t not in counts)
    lines.append((f"paired up: {done if done else 'none yet'}",
                  GOOD if done else WARN))
    if weak:
        lines.append((f"seen, needs a neighbour: {weak}", WARN))
    if unseen:
        lines.append((f"NOT SEEN: {unseen}", BAD))
    if not weak and not unseen and done:
        lines.append(("coverage complete - keep turning for more angles", GOOD))
    return lines


def _draw_overlay(image: np.ndarray, lines) -> np.ndarray:
    """Put the status lines on a dimmed strip so they stay readable."""
    if not lines:
        return image
    height = 24 * len(lines) + 16
    panel = image[:height].copy()
    cv2.rectangle(panel, (0, 0), (panel.shape[1], height), (0, 0, 0), -1)
    cv2.addWeighted(panel, 0.55, image[:height], 0.45, 0, image[:height])
    for index, (text, colour) in enumerate(lines):
        cv2.putText(image, text, (12, 28 + 24 * index),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, colour, 1, cv2.LINE_AA)
    return image


def _progress(collector, brightness, tag_px, remaining, tag_ids, reference_id) -> str:
    """What the take still needs, while there is still time to get it.

    A calibration take is minutes of someone holding a device in front of two
    cameras, and until now the only way to find out it was too dark, or that one
    face never got shown, was to solve it afterwards and start again. Everything
    here is cheap to compute and answers a question the person can act on
    immediately: is the image usable, and which tags still need views.
    """
    counts = collector.counts()
    lines = [f"  {len(collector.paired)} frames, {remaining:.0f}s left, "
             f"{100.0 * np.mean(collector.paired):.0f}% paired"]

    if brightness:
        mean = float(np.mean(brightness))
        # 8-bit mono: tags stop detecting reliably once the image is this dark,
        # and the corners degrade well before detection fails outright.
        verdict = ("DARK - add light, detection and corner accuracy both suffer"
                   if mean < 40 else
                   "bright - check for glare on the tags" if mean > 200 else "ok")
        size = f", tags ~{np.median(tag_px):.0f} px" if tag_px else ""
        lines.append(f"    image: mean level {mean:.0f}/255 ({verdict}){size}")

    missing = [t for t in tag_ids if t not in counts]
    thin = [t for t in counts if counts[t] < 40 and t not in missing]
    if missing:
        lines.append(f"    NOT SEEN yet: tags {missing} - turn those faces to the cameras")
    if thin:
        lines.append(f"    thin so far:  tags {sorted(thin)}")

    # Pairs are what the geometry is actually built from, so report the tags
    # that have no strong partner rather than only how often each was seen.
    pairs = {}
    for name in collector.camera_names:
        for frame in collector.frames[name]:
            ids = sorted(frame)
            for i, a in enumerate(ids):
                for b in ids[i + 1:]:
                    pairs[(a, b)] = pairs.get((a, b), 0) + 1
    linked = {t for (a, b), n in pairs.items() if n >= MIN_SAMPLES_PER_MARKER
              for t in (a, b)}
    unlinked = [t for t in counts if t not in linked]
    if unlinked:
        lines.append(f"    no strong pairing yet: tags {sorted(unlinked)} - "
                     "show them alongside a neighbour")
    if not missing and not thin and not unlinked:
        lines.append(f"    coverage looks good ({len(counts)} tags, "
                     f"{sum(1 for n in pairs.values() if n >= MIN_SAMPLES_PER_MARKER)} strong pairs)")
    return "\n".join(lines)


def capture(seconds: float, frame_size, display: bool, tag_ids=(),
            reference_id=None, exposure_us: int = 10000,
            gain: float = 4.0, isp: Optional[str] = None) -> CornerCollector:
    """Detect tags in both cameras for `seconds`, keeping only the corners.

    Captures through StereoCapture, the same synchronised source the tracker
    uses. The rigid body is solved from tags sharing one camera's frame and so
    is indifferent to cross-camera timing, but the stereo extrinsic refit is
    not — and an unsynchronised loop pairs frames nearly three frame periods
    apart on this board while looking perfectly healthy from userspace. Each
    frame therefore records whether its pair was genuinely simultaneous.
    """
    capture_source = StereoCapture(
        frame_size=frame_size, exposure_us=exposure_us, gain=gain, isp=isp
    )
    collector = CornerCollector()
    print(
        f"[CALIB] Capturing {seconds:.0f}s. Rotate the device slowly so every "
        "marker is seen together with its neighbours, from a range of angles."
    )
    deadline = time.perf_counter() + seconds
    last_report = time.perf_counter()
    brightness: list = []
    tag_px: list = []
    overlay: list = []
    last_overlay = 0.0
    try:
        while time.perf_counter() < deadline:
            now_frame = time.perf_counter()
            raw0, raw1, _ts0, _ts1, paired = capture_source.next_pair()
            frames = (raw0, raw1)
            detected = rapidtag.detect_markers_batch(list(frames), _APRILTAG_DICT)

            per_camera = []
            for frame, (corners, ids) in zip(frames, detected):
                detections = {}
                if ids:
                    # Sub-pixel refinement matters more here than in tracking:
                    # this error is baked into the calibration that every later
                    # frame inherits, rather than averaging out over time.
                    refined = _refine_corners(frame, corners)
                    for mid, c in zip(np.asarray(ids).flatten(), refined):
                        detections[int(mid)] = np.asarray(
                            c, dtype=np.float64
                        ).reshape(4, 2)
                per_camera.append(detections)
            collector.add_pair(per_camera[0], per_camera[1], paired)

            capture_source.maybe_resync()

            if display:
                # The status is recomputed a couple of times a second, not every
                # frame: it walks the whole take to count pairs, and the point
                # of the preview is that it must not slow the capture it is
                # reporting on.
                if now_frame - last_overlay >= 0.4:
                    last_overlay = now_frame
                    overlay = _overlay_status(
                        collector, brightness, tag_px, deadline - now_frame,
                        tag_ids,
                    )
                tiles = []
                for frame, (corners, ids) in zip(frames, detected):
                    tile = cv2.cvtColor(frame, cv2.COLOR_GRAY2BGR)
                    if ids:
                        tile = _draw_markers(
                            tile, corners, np.asarray(ids, dtype=int).reshape(-1, 1)
                        )
                    tiles.append(cv2.resize(tile, (640, 400)))
                try:
                    cv2.imshow("rigidbody calibration",
                               _draw_overlay(np.hstack(tiles), overlay))
                    if cv2.waitKey(1) & 0xFF == ord("q"):
                        print("[CALIB] Stopped early from the preview window.")
                        break
                except cv2.error as exc:
                    # Headless, or over SSH without X: the take is still fine,
                    # it just runs on the terminal reports instead.
                    display = False
                    print(f"[CALIB] No preview window ({exc.err.strip()}); "
                          "continuing without it.", flush=True)

            brightness.append(float(raw0.mean()))
            tag_px.extend(
                float(np.mean(np.linalg.norm(c - np.roll(c, -1, axis=0), axis=1)))
                for c in per_camera[0].values()
            )

            now = now_frame
            if now - last_report >= 5.0:
                last_report = now
                print(_progress(collector, brightness, tag_px, deadline - now,
                                tag_ids, reference_id), flush=True)
                brightness.clear()
                tag_px.clear()
    finally:
        capture_source.close()
        if display:
            cv2.destroyAllWindows()

    paired_pct = 100.0 * np.mean(collector.paired) if collector.paired else 0.0
    print(f"[CALIB] {paired_pct:.0f}% of frames were a simultaneous pair")
    return collector


# ── Solve ─────────────────────────────────────────────────────────────────────

def _pairwise_transforms(collector, poses, end_frame):
    """Relative transform samples for every co-visible *pair* of tags.

    Not just pairs involving the reference: on a body whose tags wrap around it,
    a far-side tag may never share a frame with the reference, and pairing only
    against the reference would drop it. Every pair is measured here and the
    chain back to the reference is found afterwards.
    """
    pairs: dict[tuple, list] = {}
    for name in collector.camera_names:
        for frame_index in range(min(end_frame, len(poses[name]))):
            good = {
                mid: pose
                for mid, pose in poses[name][frame_index].items()
                if pose["rmse_px"] <= MAX_POSE_RMSE_PX
            }
            ids = sorted(good)
            for i, a in enumerate(ids):
                for b in ids[i + 1:]:
                    # A point in b's frame reaches the camera through b's pose,
                    # and the camera reaches a's frame through a's inverse pose.
                    pairs.setdefault((a, b), []).append(
                        {
                            "R": good[a]["R"].T @ good[b]["R"],
                            "t": good[a]["R"].T @ (good[b]["t"] - good[a]["t"]),
                        }
                    )
    return pairs


def _invert(transform: dict) -> dict:
    R = transform["R"].T
    return {**transform, "R": R, "t": -R @ transform["t"]}


def _compose(outer: dict, inner: dict) -> dict:
    """outer ∘ inner — inner's frame into outer's parent frame."""
    return {
        "R": outer["R"] @ inner["R"],
        "t": outer["R"] @ inner["t"] + outer["t"],
    }


def _chain_transforms(pairs, reference_id):
    """Every tag's transform into the reference frame, hopping where needed.

    Grows out from the reference, always taking the *tightest* edge available —
    a greedy spanning tree over co-visibility, ordered by how consistently each
    pair was measured rather than by how often. Sample count is a poor guide:
    two tags can share thousands of frames from one bad angle and still disagree
    by centimetres, and every hop compounds, so the cheapest route by spread
    beats the busiest one.

    A tag that shares frames with the reference is one hop away; a tag on the
    far side of the body reaches it through whichever tags bridge the two, which
    is the only way it can be solved at all.
    """
    edges: dict[int, list] = {}
    for (a, b), samples in pairs.items():
        if len(samples) < MIN_SAMPLES_PER_MARKER:
            continue
        averaged = _robust_average_transform(samples)   # maps b's frame into a's
        cost = averaged["translation_spread_mm"]
        edges.setdefault(a, []).append((b, averaged, cost))
        edges.setdefault(b, []).append((a, _invert(averaged), cost))

    transforms = {
        reference_id: {
            "R": np.eye(3),
            "t": np.zeros(3),
            "sample_count": 0,
            "used_count": 0,
            "rotation_spread_deg": 0.0,
            "translation_spread_mm": 0.0,
            "hops": 0,
            "via": [],
        }
    }
    # Min-heap on edge spread, so a loose edge is only used when it is the sole
    # way to reach a tag. `mid` breaks ties and keeps the dicts out of the
    # comparison.
    frontier = [
        (cost, mid, reference_id, edge) for mid, edge, cost in edges.get(reference_id, [])
    ]
    heapq.heapify(frontier)
    while frontier:
        cost, mid, parent, edge = heapq.heappop(frontier)
        if mid in transforms:
            continue
        chained = _compose(transforms[parent], edge)
        transforms[mid] = {
            **edge,
            "R": chained["R"],
            "t": chained["t"],
            "hops": transforms[parent]["hops"] + 1,
            "via": transforms[parent]["via"] + [parent],
            "edge_spread_mm": cost,
        }
        for neighbour, next_edge, next_cost in edges.get(mid, []):
            if neighbour not in transforms:
                heapq.heappush(frontier, (next_cost, neighbour, mid, next_edge))
    return transforms


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
            frame_poses = poses[name][frame_index]
            detections = collector.frames[name][frame_index]
            visible = [m for m in transforms if m in detections]
            if len(visible) < 2:
                continue
            # The view's own board pose is seeded from whichever visible tag
            # fits its corners best, carried onto the board through that tag's
            # transform. Requiring the *reference* tag here would throw away
            # every frame showing only the far side of the body — exactly the
            # frames that pin the far-side tags down.
            seed = None
            for mid in visible:
                pose = frame_poses.get(mid)
                if pose is None or pose["rmse_px"] > MAX_POSE_RMSE_PX:
                    continue
                if seed is None or pose["rmse_px"] < seed[0]:
                    R_board = pose["R"] @ transforms[mid]["R"].T
                    seed = (
                        pose["rmse_px"],
                        R_board,
                        pose["t"] - R_board @ transforms[mid]["t"],
                    )
            if seed is None:
                continue
            views.append(
                {
                    "camera": name,
                    "visible": visible,
                    "detections": detections,
                    "R": seed[1],
                    "t": seed[2],
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
    # Generous, and scaled to the problem: least_squares stops as soon as it
    # converges, so a high cap costs nothing when it does — but a cap that bites
    # is dangerous. A fixed 100 was enough for ~600 views and silently truncated
    # at ~1250, leaving one tag 29 mm out of place while the *median* held-out
    # reprojection still improved. The take got better and the calibration got
    # worse, which is exactly the failure a cap should never produce quietly.
    budget = max(400, 2 * len(views))
    result = least_squares(
        residuals,
        x0,
        jac_sparsity=sparsity.tocsr(),
        method="trf",
        loss="soft_l1",
        f_scale=0.5,
        x_scale="jac",
        max_nfev=budget,
    )
    for mid in marker_ids:
        transforms[mid]["R"], transforms[mid]["t"] = unpack(result.x, mid)
    return {
        "views": len(views),
        "budget": budget,
        "initial_rmse_px": initial,
        "final_rmse_px": rmse(result.x),
        "success": bool(result.success),
    }


def _tag_agreement(collector, poses, transforms, start_frame) -> dict:
    """How far apart the tags place the same physical point, within one frame.

    The reprojection scores cannot see a misplaced tag that is rarely visible:
    the median is set by whichever tags appear in most frames, so one tag 29 mm
    out of place barely moves it — and then throws the tracked point by that
    much whenever it comes into view.

    Comparing the tags against each other does see it. Every visible tag is used
    on its own to place the reference frame's origin, and the spread between
    those answers is the geometry's disagreement with itself. Being a
    within-frame comparison it needs no stationary device, so it works on the
    calibration take itself.
    """
    spreads = []
    for name in collector.camera_names:
        for frame_index in range(start_frame, len(poses[name])):
            frame_poses = poses[name][frame_index]
            visible = [m for m in transforms if m in frame_poses]
            if len(visible) < 2:
                continue
            points = []
            for mid in visible:
                # Reusing the poses the solve already computed rather than
                # redoing the IPPE work: this pass covers every held-out frame
                # and doubled the runtime when it solved them a second time.
                pose = frame_poses[mid]
                if pose["rmse_px"] > MAX_POSE_RMSE_PX:
                    continue
                R, t = transforms[mid]["R"], transforms[mid]["t"]
                # The tag's own pose carried onto the body, then the body origin.
                R_board = pose["R"] @ R.T
                points.append(pose["t"] - R_board @ t)
            if len(points) < 2:
                continue
            points = np.asarray(points)
            spreads.append(float(np.max(np.linalg.norm(points - points.mean(0), axis=1))))
    if not spreads:
        return {"frames": 0, "median_mm": float("nan"), "p95_mm": float("nan")}
    return {
        "frames": len(spreads),
        "median_mm": 1000.0 * float(np.median(spreads)),
        "p95_mm": 1000.0 * float(np.percentile(spreads, 95)),
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


def solve(collector, cameras, reference_id) -> dict:
    """Corners in, rigid body out."""
    poses = {}
    print("[CALIB] Solving per-tag poses...", flush=True)
    t_stage = time.perf_counter()
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

    print(f"[CALIB]   {time.perf_counter() - t_stage:.1f}s", flush=True)

    frame_count = min(len(collector.frames[n]) for n in collector.camera_names)
    end_frame = int(frame_count * CALIBRATION_FRACTION)
    print(
        f"[CALIB] Solving on frames [0, {end_frame}); "
        f"validating on {frame_count - end_frame} held out."
    )

    pairs = _pairwise_transforms(collector, poses, end_frame)
    transforms = _chain_transforms(pairs, reference_id)
    for mid in sorted(transforms):
        if mid == reference_id:
            continue
        item = transforms[mid]
        route = (
            "direct"
            if item["hops"] == 1
            else "via " + "->".join(str(v) for v in item["via"][1:] + [mid])
        )
        scope = "hop" if item["hops"] > 1 else "pair"
        print(
            f"  tag {mid:2d} -> tag {reference_id}: used "
            f"{item['used_count']}/{item['sample_count']}, "
            f"t={np.round(1000 * item['t'], 1)} mm, {scope} spread "
            f"{item['translation_spread_mm']:.2f} mm / "
            f"{item['rotation_spread_deg']:.2f}°  ({route})"
        )

    unreached = sorted(set(collector.counts()) - set(transforms))
    if unreached:
        print(
            f"  NOT solved: tags {unreached} — never seen often enough "
            f"alongside any tag that reaches tag {reference_id}. Turn the device "
            "so they share the view with a neighbour."
        )
    if len(transforms) < 2:
        raise RuntimeError(
            f"no tag could be chained back to tag {reference_id}; check it is "
            "visible and rotate the device more slowly"
        )

    print("[CALIB] Bundle adjusting (the slow stage)...", flush=True)
    t_stage = time.perf_counter()
    bundle = _bundle_adjust(
        collector, poses, cameras, transforms, reference_id, end_frame
    )
    print(f"[CALIB]   {time.perf_counter() - t_stage:.1f}s", flush=True)
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

    agreement = _tag_agreement(collector, poses, transforms, end_frame)
    print(
        f"[CALIB] Tag agreement: median {agreement['median_mm']:.2f} mm, "
        f"p95 {agreement['p95_mm']:.2f} mm "
        f"(how far apart the tags place the same point)"
    )
    return {
        "transforms": transforms,
        "bundle": bundle,
        "validation": validation,
        "agreement": agreement,
    }


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


def write_toml(path: Path, result, reference_id, tip_ref, cameras_path, frames,
               isp=None) -> None:
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
            "isp": isp or "raw",
            "frames": frames,
            "bundle_views": result["bundle"]["views"],
            "bundle_initial_rmse_px": result["bundle"]["initial_rmse_px"],
            "bundle_final_rmse_px": result["bundle"]["final_rmse_px"],
            "bundle_success": result["bundle"]["success"],
            "validation_frames": result["validation"]["frames"],
            "validation_median_px": result["validation"]["median_px"],
            "validation_p95_px": result["validation"]["p95_px"],
            "agreement_median_mm": result["agreement"]["median_mm"],
            "agreement_p95_mm": result["agreement"]["p95_mm"],
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


def tip_in_reference(transforms, tip_tag: int, tip) -> np.ndarray:
    """Carry a tip measured in one tag's frame into the reference frame.

    The tracked point is a physical spot on the device — where the patient's
    hand sits — so it is measured against whichever tag is convenient. Keeping
    that tag explicit means the measurement survives re-solving against a
    different reference, instead of silently becoming a number in the wrong
    frame.
    """
    if tip_tag not in transforms:
        raise SystemExit(
            f"[CALIB] Tip is measured against tag {tip_tag}, which this "
            f"calibration does not contain (it has {sorted(transforms)})."
        )
    item = transforms[tip_tag]
    return item["R"] @ np.asarray(tip, dtype=np.float64).reshape(3) + item["t"]


def record_tip(path: Path, tip, tip_tag: Optional[int]) -> None:
    """Write the measured tip back into the hand-authored device file.

    Edited as text rather than re-dumped, so the comments explaining what the
    numbers mean — which are most of that file's value — survive.
    """
    lines = path.read_text().splitlines()
    in_tip = False
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("["):
            in_tip = stripped == "[tip]"
            continue
        if not in_tip:
            continue
        if stripped.startswith("offset_m"):
            lines[index] = (
                "offset_m = ["
                + ", ".join(f"{float(v):.6g}" for v in tip)
                + "]"
            )
        elif stripped.startswith("tag ") or stripped.startswith("tag="):
            if tip_tag is not None:
                lines[index] = f"tag = {int(tip_tag)}"
    path.write_text("\n".join(lines) + "\n")
    print(f"[CALIB] Recorded the tip in {path}")


def retip(path: Path, tip, tip_tag: Optional[int]) -> None:
    """Point an existing calibration at a different tip, in place.

    The tip never enters the solve — it only converts the solved geometry into
    the per-tag offsets the tracker consumes — so moving it is arithmetic on a
    finished calibration rather than a reason to recapture.
    """
    data = toml.load(path)
    transforms = {
        int(mid): {
            "R": np.asarray(item["rotation_marker_to_reference"], dtype=np.float64),
            "t": np.asarray(item["translation_marker_to_reference_m"], dtype=np.float64),
        }
        for mid, item in data["markers"].items()
    }
    reference_id = int(data["meta"]["reference_id"])
    if tip_tag is None:
        tip_tag = reference_id
    tip_ref = tip_in_reference(transforms, tip_tag, tip)
    if tip_tag != reference_id:
        print(
            f"[CALIB] Tip measured in tag {tip_tag}'s frame "
            f"({np.round(1000 * np.asarray(tip), 1)} mm) -> tag {reference_id}'s "
            f"frame ({np.round(1000 * tip_ref, 1)} mm)"
        )
    data["meta"]["tip_in_reference_m"] = list(map(float, tip_ref))
    data["meta"]["tip_measured_in_tag"] = int(tip_tag)
    data["meta"]["tip_measured_m"] = list(map(float, np.asarray(tip, dtype=float)))
    data["offsets"] = {
        str(mid): offset.tolist()
        for mid, offset in tip_offsets(transforms, tip_ref).items()
    }
    with path.open("w", encoding="utf-8") as stream:
        toml.dump(data, stream)
    print(
        f"[CALIB] Tip set to {np.round(1000 * tip_ref, 1)} mm in tag "
        f"{data['meta']['reference_id']}'s frame"
    )
    for mid, offset in sorted(data["offsets"].items(), key=lambda kv: int(kv[0])):
        print(f"  tag {int(mid):2d}: {np.round(1000 * np.asarray(offset), 1)} mm")


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

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--seconds", type=float, default=60.0,
                        help="How long to capture for (default: 60).")
    parser.add_argument("--device", type=Path,
                        default=_SCRIPT_DIR / "calibration" / "device.toml",
                        help="Description of the rig being calibrated: its tags, "
                             "reference and tip. Every setting below defaults to "
                             "what this file says.")
    parser.add_argument("--reference", type=int, default=None,
                        help="Override the device file's reference_id. Falls back "
                             "to whichever tag is seen most in the take.")
    parser.add_argument("--tags", type=int, nargs="+", default=None, metavar="ID",
                        help="Override the device file's tag_ids. Anything else "
                             "detected is discarded.")
    parser.add_argument("--tip", type=float, nargs=3, default=None, metavar=("X", "Y", "Z"),
                        help="The device tip in the reference tag's frame, in metres: "
                             "X right along the tag's top edge, Y up its left edge, Z "
                             "out of the printed face (so the tip is normally negative "
                             "Z). Overrides the device file's [tip] offset_m.")
    parser.add_argument("--tip-tag", type=int, default=None, metavar="ID",
                        help="The tag --tip is measured against. Overrides the "
                             "device file's [tip] tag.")
    parser.add_argument("--set-tip", type=float, nargs=3, default=None,
                        metavar=("X", "Y", "Z"),
                        help="Point an existing calibration (--out) at this tip and "
                             "exit. No capture, no re-solve — the tip is not part of "
                             "the geometry.")
    parser.add_argument("--out", type=Path,
                        default=_SCRIPT_DIR / "calibration" / "rigidbody.toml",
                        help="Where to write the calibration.")
    parser.add_argument("--save-corners", type=Path, default=None,
                        help="Where to keep this take's corners. Defaults to a "
                             "timestamped file under calibration/takes/ — a take "
                             "is minutes of someone's time and a few hundred kB, "
                             "so it is kept by default rather than on request. "
                             "Pass 'none' to skip.")
    parser.add_argument("--from", dest="from_corners", type=Path, default=None,
                        help="Re-solve from a saved corner dump instead of capturing.")
    parser.add_argument("--isp", default=None, metavar="MODE",
                        help="Image pipeline: pisp, vc4, or raw. Overrides "
                             "device.toml. Calibrate in the mode you track in.")
    parser.add_argument("--exposure", type=int, default=None, metavar="US",
                        help="Exposure in microseconds, overriding device.toml. "
                             "Keep it a multiple of the mains half-period "
                             "(10000 at 50 Hz, 8333 at 60 Hz) or the image "
                             "pulses in brightness frame to frame.")
    parser.add_argument("--gain", type=float, default=3.0,
                        help="Analogue gain 1.0-16.0, overriding device.toml. "
                             "Raise exposure first where the motion allows: gain "
                             "amplifies the noise that corner accuracy depends on.")
    parser.add_argument("--force", action="store_true",
                        help="Write the calibration even if it fails its checks.")
    parser.add_argument("--display", action=argparse.BooleanOptionalAction,
                        default=True,
                        help="Live preview of the detections with a coverage and "
                             "exposure readout. On by default: a take is someone "
                             "standing in front of the cameras, and the things "
                             "that spoil one (too dark, a face never shown) are "
                             "only fixable while it is still running. "
                             "--no-display for headless runs.")
    parser.add_argument("--list", action="store_true",
                        help="Just report which tags the cameras can see, then "
                             "exit. Use this first to find the ids on your "
                             "device and pick a reference.")
    args = parser.parse_args()

    device = load_device(args.device)
    tag_ids = args.tags if args.tags is not None else device["tag_ids"]
    exposure_us = args.exposure if args.exposure is not None else device["exposure_us"]
    gain = args.gain if args.gain is not None else device["gain"]
    isp = device["isp"] if args.isp is None else (args.isp.lower() or None)
    if isp in ("none", "raw"):
        isp = None
    # Printed and stamped into the calibration, so a take can never be quietly
    # reused under a different pipeline: the gamma curve shifts depth ~0.8 mm.
    print(f"[CALIB] Image pipeline: {isp or 'raw'}")
    print(f"[CALIB] Device '{device['name']}': tags {tag_ids}")

    # A rig with differently sized tags needs its object-point model rebuilt;
    # every solve below measures against this one array.
    if abs(device["tag_size_m"] - TAG_SIZE_M) > 1e-9:
        global _MARKER_PTS
        _MARKER_PTS = tag_corners(device["tag_size_m"])
        print(f"[CALIB] Tag size {device['tag_size_m'] * 1000:.0f} mm")

    cameras, frame_size = load_cameras(
        _SCRIPT_DIR / "calibration" / "sterio_calibration.toml",
        device["camera_order"],
    )
    if tuple(device["camera_order"]) != ("cam0", "cam1"):
        print(f"[CALIB] Camera streams mapped {device['camera_order']} "
              "(per device.toml [cameras])")

    if args.list:
        seconds = 5.0 if args.seconds == 60.0 else args.seconds
        seen = capture(seconds, frame_size, args.display, tag_ids,
                       exposure_us=exposure_us, gain=gain, isp=isp)
        counts = seen.counts()
        expected = {mid: n for mid, n in counts.items() if mid in set(tag_ids)}
        unexpected = {mid: n for mid, n in counts.items() if mid not in set(tag_ids)}
        if unexpected:
            print(f"        (ignoring tags outside --tags: {unexpected})")
        counts = expected
        if not counts:
            print("[CALIB] No tags seen. Check the device is in view and lit.")
        else:
            print(f"[CALIB] Tags visible: {sorted(counts)}")
            print(f"        observations each: {counts}")
            print(
                f"        Pick one as --reference (the most-seen is "
                f"{max(counts, key=counts.get)}), measure the tip in its frame, "
                "and pass it as --tip X Y Z."
            )
        raise SystemExit(0)

    if args.set_tip is not None:
        tip_tag = args.tip_tag if args.tip_tag is not None else device["tip_tag"]
        # Record it in the device file as well as the calibration: the
        # measurement describes the rig, so it should survive the next
        # recalibration rather than living only in the generated output.
        if args.device.exists():
            record_tip(args.device, args.set_tip, tip_tag)
        if args.out.exists():
            retip(args.out, args.set_tip, tip_tag)
        else:
            print(
                f"[CALIB] No calibration at {args.out} yet — the tip is saved in "
                f"{args.device.name} and will be used by the next calibration."
            )
        raise SystemExit(0)

    # Deliberately no fallback to MARKER_OFFSETS: that table describes the
    # previous 5-tag body and its ids 4 and 8 collide with the current bracket,
    # so defaulting from it would quietly calibrate a new body against an old
    # measurement. Zero is honest instead — it just means "the reference tag's
    # centre", which is a real point, and the geometry is unaffected either way.
    tip = device["tip"] if args.tip is None else np.asarray(args.tip, dtype=np.float64)
    tip_tag = args.tip_tag if args.tip_tag is not None else device["tip_tag"]
    tip_is_origin = not np.any(tip)

    if args.from_corners:
        collector = CornerCollector.load(args.from_corners)
        print(f"[CALIB] Loaded corners <- {args.from_corners}")
    else:
        collector = capture(args.seconds, frame_size, args.display,
                            tag_ids, device["reference_id"],
                            exposure_us=exposure_us, gain=gain, isp=isp)
        # Kept somewhere durable unless refused: /tmp is cleared on reboot and
        # by periodic cleanup, and a take lost that way costs another session
        # in front of the cameras. Re-solving one is free.
        if str(args.save_corners).lower() != "none":
            target = args.save_corners
            if target is None:
                target = (
                    _SCRIPT_DIR / "calibration" / "takes"
                    / f"corners_{datetime.now():%Y%m%d_%H%M%S}.npz"
                )
            target.parent.mkdir(parents=True, exist_ok=True)
            collector.save(target)
            print(f"[CALIB] Saved corners -> {target}")

    collector.keep_only(tag_ids)
    counts = collector.counts()
    if not counts:
        raise SystemExit(
            f"[CALIB] None of the expected tags {tag_ids} were seen. Check "
            f"tag_ids in {args.device} against the ids on the device "
            "(--list reports what the cameras can see)."
        )

    reference = args.reference if args.reference is not None else device["reference_id"]
    if reference is None:
        reference = max(counts, key=counts.get)
        print(f"[CALIB] Reference tag {reference} (seen most, {counts[reference]}x)")
    elif reference not in counts:
        raise SystemExit(
            f"[CALIB] Reference tag {reference} was never seen; "
            f"tags in this take: {sorted(counts)}"
        )
    if tip_tag is None:
        tip_tag = reference
    if tip_is_origin:
        print(
            f"[CALIB] Tip is unset in {args.device.name}: tracking tag {tip_tag}'s "
            "centre. The geometry below is unaffected — measure the hand position "
            "and apply it with --set-tip X Y Z, no recapture needed."
        )
    else:
        print(
            f"[CALIB] Tip at {np.round(1000 * tip, 1)} mm in tag {tip_tag}'s frame"
        )

    frames = min(len(collector.frames[n]) for n in collector.camera_names)
    print(f"[CALIB] {frames} frames per camera, detections: {counts}")

    result = solve(collector, cameras, reference)

    # Only now can a tip measured against some other tag be expressed in the
    # reference frame — that conversion is exactly what the solve produces.
    tip_ref = tip_in_reference(result["transforms"], tip_tag, tip)
    if tip_tag != reference and not tip_is_origin:
        print(
            f"[CALIB] Tip -> tag {reference}'s frame: "
            f"{np.round(1000 * tip_ref, 1)} mm"
        )

    # Both of these produced a calibration that looked fine by reprojection and
    # threw the tracked point by centimetres, so neither is advisory.
    problems = []
    if not result["bundle"]["success"]:
        problems.append(
            f"the bundle did not converge within {result['bundle']['budget']} "
            "evaluations, so some tags are left wherever the solve stopped"
        )
    if result["agreement"]["median_mm"] > AGREEMENT_LIMIT_MM:
        problems.append(
            f"the tags disagree about the tracked point by "
            f"{result['agreement']['median_mm']:.1f} mm "
            f"(limit {AGREEMENT_LIMIT_MM:.0f} mm), so the reported position will "
            "jump as the visible set changes"
        )
    if problems and not args.force:
        print("\n[CALIB] NOT WRITING the calibration:")
        for problem in problems:
            print(f"  - {problem}")
        print(
            f"  Nothing was changed; {args.out.name} still holds the previous "
            "calibration. Re-record with more even coverage of the weak tags, or "
            "pass --force to write it anyway."
        )
        raise SystemExit(1)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    write_toml(
        args.out, result, reference, tip_ref,
        _SCRIPT_DIR / "calibration" / "sterio_calibration.toml", frames, isp,
    )
    report_against_hardcoded(result["transforms"], tip_ref)
    print(f"\n[CALIB] Wrote {args.out}")
