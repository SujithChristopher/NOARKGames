"""Synthetic check of rigid_body.py's solvers against a known board pose."""
import sys
from pathlib import Path
import numpy as np, cv2, toml
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scipy.spatial.transform import Rotation
import rigidbody_calib as rbc
from rigid_body import RigidBody, MARKER_PTS

rng = np.random.default_rng(3)
cams, _ = rbc.load_cameras(str(Path(__file__).resolve().parents[1] / "calibration" / "sterio_calibration.toml"))
K0, D0 = cams["cam0"]; K1, D1 = cams["cam1"]
sc = toml.load(str(Path(__file__).resolve().parents[1] / "calibration" / "sterio_calibration.toml"))
R_st = np.array(sc["stereo"]["R"]); T_st = np.array(sc["stereo"]["T"]).reshape(3,1)/1000.0

TRUTH = {
    4:  (np.eye(3), np.zeros(3)),
    8:  (Rotation.from_euler("y",  72, degrees=True).as_matrix(), np.array([0.040, 0.0, -0.012])),
    12: (Rotation.from_euler("x", -35, degrees=True).as_matrix(), np.array([0.0, 0.035, -0.038])),
}
TIP = np.array([0.0, 0.01, -0.069])
rig = RigidBody(4, TRUTH, TIP, {})

def project(pts, rvec, tvec, K, D, noise=0.15):
    p, _ = cv2.fisheye.projectPoints(pts.reshape(-1,1,3), rvec.reshape(3,1), tvec.reshape(3,1), K, D)
    return p.reshape(-1,2) + rng.normal(0, noise, (len(pts),2))

mono_err, stereo_err = [], []
for _ in range(60):
    rvec = Rotation.random(random_state=int(rng.integers(0,2**31))).as_rotvec()
    tvec = np.array([rng.uniform(-.05,.05), rng.uniform(-.05,.05), rng.uniform(.35,.6)])
    rvec1, tvec1 = cv2.composeRT(rvec.reshape(3,1), tvec.reshape(3,1),
                                 cv2.Rodrigues(R_st)[0], T_st)[:2]
    det0, det1 = {}, {}
    for mid in TRUTH:
        pts = rig.corners_reference[mid]
        R_board = cv2.Rodrigues(rvec)[0]
        normal = R_board @ TRUTH[mid][0][:,2]
        centre = R_board @ pts.mean(axis=0) + tvec
        if float(normal @ (centre/np.linalg.norm(centre))) > -0.34:
            continue
        det0[mid] = project(pts, rvec, tvec, K0, D0)
        det1[mid] = project(pts, rvec1.ravel(), tvec1.ravel(), K1, D1)
    if len(det0) < 2:
        continue
    truth_tip = cv2.Rodrigues(rvec)[0] @ TIP + tvec

    r, t = rig.mono_pose(det0, K0, D0)
    if r is not None:
        mono_err.append(1000*np.linalg.norm(rig.tip(r,t) - truth_tip))
    r, t = rig.stereo_pose(det0, det1, K0, D0, K1, D1, R_st, T_st)
    if r is not None:
        stereo_err.append(1000*np.linalg.norm(rig.tip(r,t) - truth_tip))

for label, errs in (("mono_pose (cam0)", mono_err), ("stereo_pose (both)", stereo_err)):
    e = np.asarray(errs)
    print(f"  {label:20s} N={len(e):3d}  median {np.median(e):6.2f} mm  p95 {np.percentile(e,95):6.2f} mm")

assert np.median(mono_err) < 5.0, "mono_pose is wrong"
assert np.median(stereo_err) < 5.0, "stereo_pose is wrong"
assert np.median(stereo_err) <= np.median(mono_err) * 1.5, "stereo should not be worse than mono"
print("\nOK — both solvers recover the known pose; stereo is not worse than mono.")
