"""Score the trunk measurement against the rigid body strapped to the sternum.

With `"trunk_debug": true` in settings.json the tracker writes
~/Documents/NOARK_demo/trunk_debug/trunk_<start>.csv: every trunk update, its
rotation from neutral in camera axes, and the rigid body's latest pose. Strap
the hand device flat on the sternum, capture neutral, then lean forward / back,
left / right and twist both ways, a few seconds each.

    uv run pyscripts/trunk_score.py [csv]      (default: the newest log)

Per method it prints the cross-talk matrix: each trunk axis (camera x =
flexion, y = axial, z = lateral, as minisam3d's eval_trunk_zeroed.py) as a
least-squares mix of the marker's three. The diagonal is the gain (1 = right
size); the off-diagonal is leakage, e.g. row axial / column lateral = how much
of a side lean reads as twist. Both rotations are taken relative to their own
mean over the block, so the neutral and the marker's mounting drop out.

The marker's pose is in the hand tracker's camera frame. If that is not the
camera the trunk is measured from, pass --align to rotate it onto the trunk's
by the best-fit rotation; without it, the fitted angle is printed as a hint.
--align soaks up part of any leak (a rotation is a mix of axes), so leave it
off when the two share a camera.
"""

import argparse
import csv
import sys
from pathlib import Path

import numpy as np
from scipy.spatial.transform import Rotation

LOG_DIR = Path.home() / "Documents" / "NOARK_demo" / "trunk_debug"
AXES = ("flex (x)", "axial (y)", "lat (z)")
MAX_MARKER_AGE_S = 0.1
MIN_ROWS = 50
MIN_REACH_DEG = 5.0   # less marker movement than this cannot separate the axes


def load(path):
    rows = []
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            if r["held"] != "0" or r["has_neutral"] != "1" or r["marker_rx"] == "":
                continue
            if float(r["marker_age_s"]) > MAX_MARKER_AGE_S or r["cam_rx"] == "nan":
                continue
            rows.append(r)
    return rows


def zeroed(R):
    """Each rotation relative to the set's mean, as rotation vectors (deg)."""
    mean = R.mean()
    return (R * mean.inv()).as_rotvec(degrees=True)


def score(rows, align_frames):
    trunk = Rotation.from_rotvec([[float(r[k]) for k in ("cam_rx", "cam_ry", "cam_rz")] for r in rows],
                                 degrees=True)
    marker = Rotation.from_rotvec([[float(r[k]) for k in ("marker_rx", "marker_ry", "marker_rz")] for r in rows])
    vt = zeroed(trunk)
    vm = zeroed(marker)
    if rows[0]["flip"] == "1":     # tags found in mirrored frames: a mirror in x flips y and z of a rotation
        vm = vm * np.array([1.0, -1.0, -1.0])
    align, _ = Rotation.align_vectors(vt, vm)
    if align_frames:
        vm = align.apply(vm)
    M, *_ = np.linalg.lstsq(vm, vt, rcond=None)
    M = M.T                        # vt ≈ M @ vm
    resid = vt - vm @ M.T
    return M, align.magnitude(), np.abs(vm).max(0), np.sqrt((resid ** 2).mean(0))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv", nargs="?", help="a trunk_debug CSV (default: the newest)")
    ap.add_argument("--align", action="store_true",
                    help="rotate the marker's camera frame onto the trunk's (different cameras)")
    a = ap.parse_args()
    path = Path(a.csv) if a.csv else max(LOG_DIR.glob("trunk_*.csv"), key=lambda p: p.stat().st_mtime, default=None)
    if path is None:
        sys.exit(f"no trunk_debug CSV in {LOG_DIR}")
    rows = load(path)
    print(f"{path}: {len(rows)} usable rows (tracking, not held, marker seen within {MAX_MARKER_AGE_S} s)\n")
    for method in dict.fromkeys(r["method"] for r in rows):
        block = [r for r in rows if r["method"] == method]
        if len(block) < MIN_ROWS:
            print(f"{method}: only {len(block)} rows, skipped\n")
            continue
        M, align_rad, reach, rms = score(block, a.align)
        if reach.max() < MIN_REACH_DEG:
            print(f"{method}: the marker turned at most {reach.max():.1f} deg - it was not on the "
                  "chest, or nobody moved. Nothing to score.\n")
            continue
        how = "aligned by" if a.align else "not aligned; best-fit rotation between the frames"
        print(f"{method}: {len(block)} rows; marker camera {how} {np.degrees(align_rad):.0f} deg")
        print("  movement range (marker, deg): " + "  ".join(f"{n} {v:.0f}" for n, v in zip(AXES, reach)))
        print(f"  {'trunk reads':<12}" + "".join(f"{'per ' + n:>14}" for n in AXES) + f"{'rms deg':>10}")
        for i, n in enumerate(AXES):
            print(f"  {n:<12}" + "".join(f"{M[i, j]:>14.2f}" for j in range(3)) + f"{rms[i]:>10.1f}")
        print("  (diagonal = gain, 1 is right; off-diagonal = leak from that marker axis)\n")


if __name__ == "__main__":
    main()
