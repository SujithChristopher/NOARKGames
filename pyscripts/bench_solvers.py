"""Compare the board-pose solvers on the same frames.

The question this answers is narrow: given identical detected corners, does
rapidtag's RANSAC fit report a steadier point than the joint fit over every
corner, and what does it cost?

Both solvers run on the *same* detections from the *same* capture, so nothing
in the comparison depends on the device being held identically twice, or on the
detector finding the same tags in two separate takes. The only difference
between the two columns is the estimator.

Hold the device still and pointed at the cameras. Jitter on a stationary device
is the number that matters: the reported point should not move, and every
millimetre it does move is estimator noise the patient sees as a twitching
cursor.

    uv run pyscripts/bench_solvers.py --seconds 20
    uv run pyscripts/bench_solvers.py --seconds 20 --stereo

Movement during the take inflates both columns equally and makes the absolute
numbers meaningless, so the script reports how far the point travelled overall
and says so when the take looks like it moved.
"""

import argparse
import time
from pathlib import Path

import numpy as np
import rapidtag

from rigid_body import RigidBody, load_cameras, load_device, stereo_extrinsic
from stereo_capture import StereoCapture
from tracker import _APRILTAG_DICT, _refine_corners

_SCRIPT_DIR = Path(__file__).resolve().parent


def _detections(frame, corners, ids, keep) -> dict:
    """{marker id: (4, 2) refined corners}, restricted to the calibrated body."""
    if not ids:
        return {}
    refined = _refine_corners(frame, corners)
    out = {}
    for mid, c in zip(np.asarray(ids).flatten(), refined):
        mid = int(mid)
        if mid in keep:
            out[mid] = np.asarray(c, dtype=np.float64).reshape(4, 2)
    return out


def _noise_mm(points: np.ndarray) -> float:
    """Frame-to-frame estimator noise, separated from real movement.

    A held-still take measures jitter as spread about the mean, but the device
    is rarely held still enough for that, and any drift is then counted as
    estimator noise. The second difference x[t-1] - 2x[t] + x[t+1] cancels
    anything moving at constant velocity, so smooth hand movement passes through
    it as nearly zero while independent per-frame error does not. For noise of
    standard deviation s on each sample that combination has variance 6s^2,
    hence the sqrt(6).

    This does understate noise that is correlated between neighbouring frames —
    a slow bias wander reads as movement here — so it is a floor, not the whole
    error.
    """
    if len(points) < 3:
        return float("nan")
    second = points[:-2] - 2.0 * points[1:-1] + points[2:]
    return float(
        np.sqrt(np.mean(np.sum(second**2, axis=1)) / 6.0) * 1000.0
    )


def _summarise(name: str, points: list, times: list, tags: list) -> dict:
    if len(points) < 3:
        return {"name": name, "frames": len(points)}
    p = np.asarray(points)
    distance = np.linalg.norm(p - p.mean(axis=0), axis=1) * 1000.0
    second = p[:-2] - 2.0 * p[1:-1] + p[2:]
    per_axis = np.sqrt(np.mean(second**2, axis=0) / 6.0) * 1000.0
    return {
        "name": name,
        "frames": len(p),
        "noise_mm": _noise_mm(p),
        # Per axis, because depth is where a nearly planar tag cluster is weak
        # and where the two solvers are most likely to differ.
        "axis_mm": per_axis.tolist(),
        # Only meaningful on a genuinely still take; printed so a still take
        # still gets its direct answer.
        "spread_mm": float(np.sqrt(np.mean(distance**2))),
        "ms": float(np.mean(times) * 1000.0),
        "tags": float(np.mean(tags)),
        "travel_mm": float(np.linalg.norm(p.max(axis=0) - p.min(axis=0)) * 1000.0),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=float, default=20.0)
    parser.add_argument("--stereo", action=argparse.BooleanOptionalAction, default=None,
                        help="Refine across both cameras. Defaults to device.toml.")
    parser.add_argument("--iterations", type=int, default=100,
                        help="RANSAC iterations (rapidtag default: 100).")
    parser.add_argument("--reprojection-error", type=float, default=3.0,
                        help="RANSAC inlier threshold in pixels (default: 3.0).")
    parser.add_argument("--device", type=Path,
                        default=_SCRIPT_DIR / "calibration" / "device.toml")
    parser.add_argument("--rigidbody", type=Path,
                        default=_SCRIPT_DIR / "calibration" / "rigidbody.toml")
    parser.add_argument("--stereo-calib", type=Path,
                        default=_SCRIPT_DIR / "calibration" / "sterio_calibration.toml")
    args = parser.parse_args()

    device = load_device(args.device)
    rig = RigidBody.load(args.rigidbody)
    if rig is None:
        raise SystemExit(
            f"No calibration at {args.rigidbody}. Run pyscripts/rigidbody_calib.py first."
        )
    cameras, frame_size = load_cameras(args.stereo_calib, device["camera_order"])
    K0, D0 = cameras["cam0"]
    K1, D1 = cameras["cam1"]
    R_st, T_st = stereo_extrinsic(args.stereo_calib, device["camera_order"])
    stereo = args.stereo if args.stereo is not None else bool(device["stereo_pose"])

    print(f"[BENCH] {rig.describe()}")
    print(f"[BENCH] {'stereo' if stereo else 'cam0 only'}, "
          f"isp={device['isp'] or 'raw'}, exposure={device['exposure_us']} us")

    capture = StereoCapture(
        frame_size=frame_size,
        exposure_us=device["exposure_us"],
        gain=device["gain"],
        isp=device["isp"],
    )

    results = {name: ([], [], []) for name in RigidBody.POSE_SOLVERS}
    # How often RANSAC threw a tag away; the count that explains a difference.
    rejected = 0
    solved_frames = 0
    keep = set(rig.marker_ids)

    print(f"[BENCH] Hold the device still for {args.seconds:.0f}s…")
    deadline = time.perf_counter() + args.seconds
    try:
        while time.perf_counter() < deadline:
            raw0, raw1, _ts0, _ts1, _paired = capture.next_pair()
            detected = rapidtag.detect_markers_batch([raw0, raw1], _APRILTAG_DICT)
            det0 = _detections(raw0, *detected[0], keep)
            det1 = _detections(raw1, *detected[1], keep)
            if not det0:
                continue

            frame_points = {}
            for solver in RigidBody.POSE_SOLVERS:
                started = time.perf_counter()
                if stereo and det1:
                    rvec, tvec = rig.stereo_pose(
                        det0, det1, K0, D0, K1, D1, R_st, T_st, solver
                    )
                else:
                    rvec, tvec = rig.mono_pose(det0, K0, D0, solver)
                elapsed = time.perf_counter() - started
                if rvec is None:
                    break
                frame_points[solver] = (rig.tip(rvec, tvec), elapsed)
            if len(frame_points) != len(RigidBody.POSE_SOLVERS):
                # Only frames both solvers answered are compared, or the two
                # columns would summarise different moments.
                continue

            solved_frames += 1
            report = rig.last_ransac
            if report is not None and len(report["inliers"]) < len(report["used"]):
                rejected += 1
            for solver, (point, elapsed) in frame_points.items():
                results[solver][0].append(point)
                results[solver][1].append(elapsed)
                results[solver][2].append(len(det0))

            capture.maybe_resync()
    except KeyboardInterrupt:
        print("\n[BENCH] Interrupted.")
    finally:
        capture.close()

    summaries = [_summarise(name, *results[name]) for name in RigidBody.POSE_SOLVERS]
    if any(s["frames"] < 3 for s in summaries):
        raise SystemExit("[BENCH] Too few frames solved to compare.")

    print(f"\n{'solver':<8}{'frames':>8}{'noise':>8}{'nx':>7}{'ny':>7}{'nz':>7}"
          f"{'spread':>9}{'ms':>8}")
    for s in summaries:
        nx, ny, nz = s["axis_mm"]
        print(f"{s['name']:<8}{s['frames']:>8}{s['noise_mm']:>8.2f}"
              f"{nx:>7.2f}{ny:>7.2f}{nz:>7.2f}{s['spread_mm']:>9.2f}{s['ms']:>8.2f}")
    print("noise = frame-to-frame estimator error in mm, with movement removed")
    print("spread = mm about the take's mean; only meaningful if the rig was held still")

    joint, ransac = summaries[0], summaries[1]
    print(f"\nTags visible per frame: {joint['tags']:.1f}")
    print(f"RANSAC dropped at least one tag in {rejected}/{solved_frames} frames")
    change = 100.0 * (ransac["noise_mm"] - joint["noise_mm"]) / joint["noise_mm"]
    print(f"RANSAC noise {change:+.1f}% vs joint, "
          f"{ransac['ms'] - joint['ms']:+.2f} ms/frame")

    # The decisive number on a moving take: both solvers saw the same corners,
    # so their per-frame disagreement is the whole effect of the choice, with
    # the device's movement cancelling out exactly.
    paired = np.linalg.norm(
        np.asarray(results["ransac"][0]) - np.asarray(results["joint"][0]), axis=1
    ) * 1000.0
    print(f"\nPer-frame disagreement: median {np.median(paired):.3f} mm, "
          f"p95 {np.percentile(paired, 95):.3f} mm, max {paired.max():.3f} mm")
    print(f"  identical (<0.01 mm) on {100.0 * np.mean(paired < 0.01):.1f}% of frames")

    travel = max(s["travel_mm"] for s in summaries)
    print(f"\nThe point travelled {travel:.0f} mm during the take.")
    if travel > 10.0:
        print("  Movement that large makes 'spread' meaningless; 'noise' and the "
              "disagreement above still hold.")


if __name__ == "__main__":
    main()
