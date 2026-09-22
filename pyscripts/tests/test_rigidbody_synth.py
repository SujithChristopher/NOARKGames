"""Synthetic check: build a known rigid body, project it, see if solve() recovers it."""
import sys
from pathlib import Path
import numpy as np
import cv2

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scipy.spatial.transform import Rotation

import rigidbody_calib as rb

rng = np.random.default_rng(7)

cameras, _ = rb.load_cameras(
    str(Path(__file__).resolve().parents[1] / "calibration" / "sterio_calibration.toml")
)

REFERENCE = 4
# Ground-truth body: each tag's pose in tag 4's frame.
TRUTH = {
    4:  (np.eye(3), np.zeros(3)),
    8:  (Rotation.from_euler("y",  72, degrees=True).as_matrix(), np.array([0.040, 0.000, -0.012])),
    12: (Rotation.from_euler("x", -35, degrees=True).as_matrix(), np.array([0.000, 0.035, -0.038])),
    14: (Rotation.from_euler("y", -72, degrees=True).as_matrix(), np.array([-0.040, 0.000, -0.012])),
    20: (Rotation.from_euler("z",  20, degrees=True).as_matrix(), np.array([0.010, -0.045, -0.005])),
}
TIP = np.array([0.00, 0.01, -0.069])
NOISE_PX = 0.15

def board_corners(mid):
    R, t = TRUTH[mid]
    return rb._MARKER_PTS @ R.T + t

collector = rb.CornerCollector()
n_frames = 260
for i in range(n_frames):
    # A board pose in front of the camera, tilted so IPPE is well conditioned.
    # Full random orientation: the device is turned over during a real take,
    # which is what gives every face its share of views.
    rvec = Rotation.random(random_state=int(rng.integers(0, 2**31))).as_rotvec()
    tvec = np.array([rng.uniform(-0.06, 0.06), rng.uniform(-0.06, 0.06), rng.uniform(0.35, 0.65)])
    for name in collector.camera_names:
        K, D = cameras[name]
        detections = {}
        for mid in TRUTH:
            pts = board_corners(mid)
            projected, _ = cv2.fisheye.projectPoints(
                pts.reshape(-1, 1, 3), rvec.reshape(3, 1), tvec.reshape(3, 1), K, D
            )
            c = projected.reshape(4, 2) + rng.normal(0, NOISE_PX, (4, 2))
            # Only keep tags facing the camera, as a real take would.
            R_board = cv2.Rodrigues(rvec)[0]
            normal_cam = R_board @ TRUTH[mid][0][:, 2]
            centre_cam = R_board @ pts.mean(axis=0) + tvec
            viewing = centre_cam / np.linalg.norm(centre_cam)
            # A tag is readable only when its face turns toward the camera.
            if float(normal_cam @ viewing) > -0.34:   # ~70 deg incidence
                continue
            detections[mid] = c
        collector.add(name, detections)

print("detections:", collector.counts())
result = rb.solve(collector, cameras, REFERENCE)

print("\n=== recovery vs ground truth ===")
worst_t, worst_r = 0.0, 0.0
for mid, item in sorted(result["transforms"].items()):
    R_true, t_true = TRUTH[mid]
    dt = 1000.0 * np.linalg.norm(item["t"] - t_true)
    dr = np.degrees(
        Rotation.from_matrix(item["R"].T @ R_true).magnitude()
    )
    worst_t, worst_r = max(worst_t, dt), max(worst_r, dr)
    print(f"  tag {mid:2d}: dt={dt:6.2f} mm  dr={dr:5.2f} deg")

print(f"\nworst: {worst_t:.2f} mm, {worst_r:.2f} deg")

# The offsets table is what the tracker consumes.
offsets = rb.tip_offsets(result["transforms"], TIP)
print("\n=== tip offsets (should all map to the same physical point) ===")
for mid, off in sorted(offsets.items()):
    R_true, t_true = TRUTH[mid]
    # Map the solved per-tag offset back into the reference frame.
    back = R_true @ off + t_true
    print(f"  tag {mid:2d}: offset {np.round(1000*off,1)} mm -> tip_ref {np.round(1000*back,2)} mm")

assert worst_t < 2.0, f"translation recovery too poor: {worst_t:.2f} mm"
assert worst_r < 1.0, f"rotation recovery too poor: {worst_r:.2f} deg"
print("\nOK")
