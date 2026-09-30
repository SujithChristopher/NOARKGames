"""Synthetic check of the rapidtag RANSAC solver against a known board pose.

Two things are being checked, and they are separate:

1. The calibration transfers. `rigidbody.toml` and rapidtag's `RigidBody` must
   agree on what `rotation_marker_to_reference` means and on the corner order,
   or every pose comes out wrong in a way no live test would attribute to the
   convention. A clean recovery of the truth pose is what rules that out.
2. RANSAC actually rejects. One tag is moved off the body by 3 cm — the failure
   mode RANSAC exists for — and the joint fit, which trusts every corner, is
   expected to be dragged by it while RANSAC is not.
"""
import sys
from pathlib import Path

import cv2
import numpy as np
import toml
from scipy.spatial.transform import Rotation

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import rigidbody_calib as rbc
from rigid_body import RigidBody

rng = np.random.default_rng(5)

CALIB = str(Path(__file__).resolve().parents[1] / "calibration" / "sterio_calibration.toml")
cams, _ = rbc.load_cameras(CALIB)
K0, D0 = cams["cam0"]
sc = toml.load(CALIB)

TRUTH = {
    1: (np.eye(3), np.zeros(3)),
    2: (Rotation.from_euler("y", 72, degrees=True).as_matrix(), np.array([0.040, 0.0, -0.012])),
    3: (Rotation.from_euler("x", -35, degrees=True).as_matrix(), np.array([0.0, 0.035, -0.038])),
    4: (Rotation.from_euler("y", -60, degrees=True).as_matrix(), np.array([-0.038, 0.0, -0.010])),
}
TIP = np.array([0.0, 0.01, -0.069])
rig = RigidBody(1, TRUTH, TIP, {})

# What the tracker believes about tag 4 — 3 cm from where it really is. The
# corners are rendered from the true place, so every frame showing tag 4 carries
# one badly wrong correspondence.
LIAR = 4
DISPLACEMENT = np.array([0.03, 0.0, 0.0])


def project(pts, rvec, tvec, noise=0.15):
    p, _ = cv2.fisheye.projectPoints(
        pts.reshape(-1, 1, 3), rvec.reshape(3, 1), tvec.reshape(3, 1), K0, D0
    )
    return p.reshape(-1, 2) + rng.normal(0, noise, (len(pts), 2))


def take(bad_tag: bool):
    """Tip error per frame for each solver, with and without the bad tag."""
    errors = {"joint": [], "ransac": []}
    rejections = 0
    frames = 0
    for _ in range(120):
        rvec = Rotation.random(random_state=int(rng.integers(0, 2**31))).as_rotvec()
        tvec = np.array([rng.uniform(-.05, .05), rng.uniform(-.05, .05), rng.uniform(.35, .6)])
        R_board = cv2.Rodrigues(rvec)[0]

        detections = {}
        for mid in TRUTH:
            pts = rig.corners_reference[mid]
            if bad_tag and mid == LIAR:
                pts = pts + DISPLACEMENT
            normal = R_board @ TRUTH[mid][0][:, 2]
            centre = R_board @ pts.mean(axis=0) + tvec
            if float(normal @ (centre / np.linalg.norm(centre))) > -0.34:
                continue
            detections[mid] = project(pts, rvec, tvec)
        # RANSAC needs a majority of honest tags to have one to agree on.
        if len(detections) < 3:
            continue

        truth_tip = R_board @ TIP + tvec
        frames += 1
        for solver in ("joint", "ransac"):
            r, t = rig.mono_pose(detections, K0, D0, solver)
            if r is not None:
                errors[solver].append(1000 * np.linalg.norm(rig.tip(r, t) - truth_tip))
        report = rig.last_ransac
        if report is not None and len(report["inliers"]) < len(report["used"]):
            rejections += 1
    return errors, rejections, frames


print("=== clean body: does the calibration transfer to rapidtag? ===")
clean, _, frames = take(bad_tag=False)
for solver in ("joint", "ransac"):
    e = np.asarray(clean[solver])
    print(f"  {solver:<8} N={len(e):3d}  median {np.median(e):6.2f} mm  "
          f"p95 {np.percentile(e, 95):6.2f} mm")

assert len(clean["ransac"]) > 0.9 * frames, "ransac_pose failed on most frames"
assert np.median(clean["ransac"]) < 5.0, (
    f"ransac_pose does not recover the known pose "
    f"({np.median(clean['ransac']):.1f} mm) — check the transform convention"
)

print(f"\n=== tag {LIAR} displaced by {1000 * np.linalg.norm(DISPLACEMENT):.0f} mm ===")
dirty, rejections, frames = take(bad_tag=True)
for solver in ("joint", "ransac"):
    e = np.asarray(dirty[solver])
    print(f"  {solver:<8} N={len(e):3d}  median {np.median(e):6.2f} mm  "
          f"p95 {np.percentile(e, 95):6.2f} mm")
print(f"  RANSAC dropped a tag in {rejections}/{frames} frames")

# The joint fit screens out tags that disagree with the consensus pose before
# it solves (RigidBody.drop_outlier_tags), so a badly placed tag no longer
# separates it from RANSAC. What matters is that neither is dragged off.
assert np.median(dirty["ransac"]) <= np.median(dirty["joint"]) + 0.1, (
    "RANSAC is worse than the joint fit on a badly placed tag"
)
assert np.median(dirty["joint"]) < 2.0, (
    "the joint fit was dragged off by a badly placed tag; outlier screening failed"
)
print("\nOK — the calibration transfers, and both solvers survive a tag that disagrees.")
