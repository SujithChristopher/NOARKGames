"""Check which camera mapping is right, and which pose path is quietest.

Two questions at once, both of which show up as "it went noisy again":

1. **Is the `[cameras]` mapping right?** The stereo calibration labels its own
   cam0/cam1, and that need not match the order rcam enumerates the cameras in.
   Both mappings are tried here, *on the same frames*, so the answer does not
   depend on two takes being held alike. The test needs no ground truth: each
   camera solves the device's pose alone, and the two are expressed in one
   frame. They describe the same point at the same instant, so they must agree.
   Under the wrong mapping the extrinsic describes the opposite baseline and
   they land ~140 mm apart; under the right one, a few mm.

2. **Which path is actually noisy?** cam0 alone, cam1 alone and the two-camera
   fit are solved from the same detections in the same frame, so their noise is
   directly comparable.

    uv run pyscripts/bench_cameras.py --seconds 20

Noise is measured as the frame-to-frame residual with constant velocity removed
(see bench_solvers.py), so a device that drifts during the take does not read as
estimator error.
"""

import argparse
import time
from pathlib import Path

import numpy as np
import rapidtag

from bench_solvers import _detections, _noise_mm
from rigid_body import RigidBody, load_cameras, load_device, stereo_extrinsic
from stereo_capture import StereoCapture
from tracker import _APRILTAG_DICT

_SCRIPT_DIR = Path(__file__).resolve().parent

# How far cam0's and cam1's independent poses may disagree before the mapping
# is the more likely explanation than ordinary error. The wrong mapping was
# measured at 137.9 mm against 4.9 mm for the right one, so anything in between
# is already far outside what a good rig does.
MAPPING_LIMIT_MM = 25.0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=float, default=20.0)
    parser.add_argument("--solver", choices=RigidBody.POSE_SOLVERS, default=None,
                        help="Defaults to device.toml [tracking] solver.")
    parser.add_argument("--device", type=Path,
                        default=_SCRIPT_DIR / "calibration" / "device.toml")
    parser.add_argument("--rigidbody", type=Path,
                        default=_SCRIPT_DIR / "calibration" / "rigidbody.toml")
    parser.add_argument("--stereo-calib", type=Path,
                        default=_SCRIPT_DIR / "calibration" / "sterio_calibration.toml")
    args = parser.parse_args()

    device = load_device(args.device)
    solver = args.solver or device["solver"] or "joint"
    rig = RigidBody.load(args.rigidbody)
    if rig is None:
        raise SystemExit(f"No calibration at {args.rigidbody}.")

    # Both candidate mappings, built up front so each frame can be scored
    # against both. A mapping is the intrinsics for each stream *and* the
    # direction of the extrinsic between them; swapping one without the other
    # would not be a mapping at all.
    configured = tuple(device["camera_order"])
    candidates = {}
    for order in (("cam0", "cam1"), ("cam1", "cam0")):
        cams, frame_size = load_cameras(args.stereo_calib, order)
        R, T = stereo_extrinsic(args.stereo_calib, order)
        candidates[order] = (cams["cam0"], cams["cam1"], R, T)
    (K0, D0), (K1, D1), R_st, T_st = candidates[configured]

    import rcam
    labels = rcam.list_cameras()
    print(f"[CAM] rcam enumerates {labels}; device.toml maps them onto "
          f"{configured} of the stereo calibration.")
    print(f"[CAM] Baseline {1000 * np.linalg.norm(T_st):.1f} mm, solver {solver}")

    capture = StereoCapture(
        frame_size=frame_size,
        exposure_us=device["exposure_us"],
        gain=device["gain"],
        isp=device["isp"],
    )

    paths = {"cam0": [], "cam1": [], "stereo": []}
    times = {name: [] for name in paths}
    tags0, tags1 = [], []
    # Per-frame cam0-vs-cam1 disagreement under each candidate mapping.
    mapping_error = {order: [] for order in candidates}

    print(f"[CAM] Capturing {args.seconds:.0f}s with both cameras seeing the device…")
    deadline = time.perf_counter() + args.seconds
    keep = set(rig.marker_ids)
    try:
        while time.perf_counter() < deadline:
            raw0, raw1, _ts0, _ts1, _paired = capture.next_pair()
            detected = rapidtag.detect_markers_batch([raw0, raw1], _APRILTAG_DICT)
            det0 = _detections(raw0, *detected[0], keep)
            det1 = _detections(raw1, *detected[1], keep)
            # Only frames both cameras can answer, or the three columns would
            # summarise different moments.
            if not det0 or not det1:
                continue

            frame = {}
            started = time.perf_counter()
            r, t = rig.mono_pose(det0, K0, D0, solver)
            elapsed0 = time.perf_counter() - started
            if r is None:
                continue
            frame["cam0"] = (rig.tip(r, t), elapsed0)

            started = time.perf_counter()
            r, t = rig.mono_pose(det1, K1, D1, solver)
            if r is None:
                continue
            r, t = rig.pose_in_cam1_frame(r, t, R_st, T_st)
            frame["cam1"] = (rig.tip(r, t), time.perf_counter() - started)

            started = time.perf_counter()
            r, t = rig.stereo_pose(det0, det1, K0, D0, K1, D1, R_st, T_st, solver)
            if r is None:
                continue
            frame["stereo"] = (rig.tip(r, t), time.perf_counter() - started)

            for name, (point, elapsed) in frame.items():
                paths[name].append(point)
                times[name].append(elapsed)
            tags0.append(len(det0))
            tags1.append(len(det1))

            # Score both mappings on this same frame. The streams do not move;
            # what changes is which intrinsics and which baseline direction each
            # is solved with.
            for order, (cal0, cal1, R, T) in candidates.items():
                a = rig.mono_pose(det0, cal0[0], cal0[1], solver)
                b = rig.mono_pose(det1, cal1[0], cal1[1], solver)
                if a[0] is None or b[0] is None:
                    continue
                b = rig.pose_in_cam1_frame(b[0], b[1], R, T)
                mapping_error[order].append(
                    float(np.linalg.norm(rig.tip(*a) - rig.tip(*b)) * 1000.0)
                )

            capture.maybe_resync()
    except KeyboardInterrupt:
        print("\n[CAM] Interrupted.")
    finally:
        capture.close()

    if len(paths["cam0"]) < 3:
        raise SystemExit("[CAM] Too few frames with both cameras seeing the device.")

    points = {name: np.asarray(p) for name, p in paths.items()}
    print(f"\nFrames with both cameras: {len(points['cam0'])}  "
          f"(tags: cam0 {np.mean(tags0):.1f}, cam1 {np.mean(tags1):.1f})")

    print(f"\n{'path':<8}{'noise':>8}{'nx':>7}{'ny':>7}{'nz':>7}{'ms':>8}")
    for name in ("cam0", "cam1", "stereo"):
        p = points[name]
        second = p[:-2] - 2.0 * p[1:-1] + p[2:]
        nx, ny, nz = np.sqrt(np.mean(second**2, axis=0) / 6.0) * 1000.0
        print(f"{name:<8}{_noise_mm(p):>8.2f}{nx:>7.2f}{ny:>7.2f}{nz:>7.2f}"
              f"{1000 * np.mean(times[name]):>8.2f}")
    print("noise = frame-to-frame estimator error in mm, with movement removed")

    print("\ncam0 vs cam1 at the same instant, under each candidate mapping:")
    scores = {}
    for order in candidates:
        errors = np.asarray(mapping_error[order])
        if len(errors) < 3:
            continue
        scores[order] = float(np.median(errors))
        mark = "  <- device.toml" if order == configured else ""
        print(f"  stream0={order[0]:<5} stream1={order[1]:<5} "
              f"median {np.median(errors):7.1f} mm  p95 {np.percentile(errors, 95):7.1f} mm{mark}")

    if not scores:
        print("  (not enough frames where both cameras solved)")
    else:
        best = min(scores, key=scores.get)
        if scores[configured] > MAPPING_LIMIT_MM:
            print(
                f"\n[CAM] The configured mapping is WRONG. The two cameras are "
                f"describing the same point at the same instant and disagree by "
                f"{scores[configured]:.0f} mm; the extrinsic is being applied "
                f"along the opposite baseline. Set device.toml [cameras] to:\n"
                f'    stream0 = "{best[0]}"\n    stream1 = "{best[1]}"'
            )
        elif best != configured:
            print(f"\n[CAM] Both mappings agree closely; {best} is marginally "
                  "better, which is not enough to act on.")
        else:
            print("\n[CAM] The configured mapping is the right one.")

    quietest = min(("cam0", "cam1", "stereo"), key=lambda n: _noise_mm(points[n]))
    print(f"\nQuietest path: {quietest}")
    if quietest != "stereo":
        print("  device.toml [cameras] stereo_pose = false would use cam0 alone.")


if __name__ == "__main__":
    main()
