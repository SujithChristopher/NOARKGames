"""Synthetic check that tags never co-visible with the reference still solve.

Tags wrapped around a device cannot all be seen at once: the far side is never
in the same frame as the reference. The solve has to reach those tags through
whichever neighbours bridge the gap, so this builds a ring where only adjacent
tags are ever co-visible and checks every tag still lands in the right place.
"""

import sys
from pathlib import Path

import cv2
import numpy as np
from scipy.spatial.transform import Rotation

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import rigidbody_calib as rb

rng = np.random.default_rng(11)

CALIB = str(Path(__file__).resolve().parents[1] / "calibration" / "sterio_calibration.toml")
cameras, _ = rb.load_cameras(CALIB)

REFERENCE = 1
RADIUS = 0.045
NOISE_PX = 0.15

# Eight tags evenly around a cylinder, each facing outward — tag 1 and tag 5 sit
# on opposite sides and can never appear in one frame.
TRUTH = {}
for i in range(8):
    angle = np.deg2rad(45.0 * i)
    R = Rotation.from_euler("y", 45.0 * i, degrees=True).as_matrix()
    t = np.array([RADIUS * np.sin(angle), 0.0, RADIUS * np.cos(angle) - RADIUS])
    TRUTH[i + 1] = (R, t)

rig_truth = {mid: {"R": R, "t": t} for mid, (R, t) in TRUTH.items()}


def corners_of(mid):
    R, t = TRUTH[mid]
    return rb._MARKER_PTS @ R.T + t


collector = rb.CornerCollector()
for _ in range(700):
    # Spin about the cylinder's axis so each face takes its turn, with a little
    # wobble so the views are not degenerate.
    yaw = rng.uniform(-180, 180)
    rvec = Rotation.from_euler(
        "yxz", [yaw, rng.uniform(-25, 25), rng.uniform(-15, 15)], degrees=True
    ).as_rotvec()
    tvec = np.array([rng.uniform(-.04, .04), rng.uniform(-.04, .04), rng.uniform(.30, .50)])
    R_board = cv2.Rodrigues(rvec)[0]

    for name in collector.camera_names:
        K, D = cameras[name]
        detections = {}
        for mid in TRUTH:
            pts = corners_of(mid)
            normal = R_board @ TRUTH[mid][0][:, 2]
            centre = R_board @ pts.mean(axis=0) + tvec
            # Only faces turned toward the camera are readable, which is what
            # makes opposite tags mutually exclusive.
            if float(normal @ (centre / np.linalg.norm(centre))) > -0.45:
                continue
            projected, _ = cv2.fisheye.projectPoints(
                pts.reshape(-1, 1, 3), rvec.reshape(3, 1), tvec.reshape(3, 1), K, D
            )
            detections[mid] = projected.reshape(4, 2) + rng.normal(0, NOISE_PX, (4, 2))
        collector.add(name, detections)

counts = collector.counts()
print("detections:", counts)

# Confirm the premise: the far side really never shares a frame with tag 1.
pairs = set()
for frames in collector.frames.values():
    for frame in frames:
        ids = sorted(frame)
        for i, a in enumerate(ids):
            for b in ids[i + 1:]:
                pairs.add((a, b))
direct = sorted(b for a, b in pairs if a == REFERENCE) + sorted(
    a for a, b in pairs if b == REFERENCE
)
print(f"co-visible with tag {REFERENCE}: {sorted(set(direct))}")
assert len(set(direct)) < 7, "premise broken: every tag sees the reference"

result = rb.solve(collector, cameras, REFERENCE)
transforms = result["transforms"]

print("\n=== recovery vs ground truth ===")
worst_t = worst_r = 0.0
for mid in sorted(TRUTH):
    assert mid in transforms, f"tag {mid} was never reached from the reference"
    item = transforms[mid]
    R_true, t_true = TRUTH[mid]
    dt = 1000.0 * np.linalg.norm(item["t"] - t_true)
    dr = np.degrees(Rotation.from_matrix(item["R"].T @ R_true).magnitude())
    worst_t, worst_r = max(worst_t, dt), max(worst_r, dr)
    hops = item.get("hops", 0)
    print(f"  tag {mid}: dt={dt:6.2f} mm  dr={dr:5.2f} deg  hops={hops}")

print(f"\nworst: {worst_t:.2f} mm, {worst_r:.2f} deg")
assert max(t.get("hops", 0) for t in transforms.values()) > 1, "nothing was chained"
assert worst_t < 3.0, f"chained translation too poor: {worst_t:.2f} mm"
assert worst_r < 2.0, f"chained rotation too poor: {worst_r:.2f} deg"
print("\nOK — every tag solved, including those never seen with the reference.")
