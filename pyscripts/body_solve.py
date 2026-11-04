"""The slow half of measuring the device's tags from the app (body_take.py): a take in,
a candidate calibration and a report out. Its own process, because the solve takes
minutes and the tracker has a link to answer.

    body_solve.py --take corners.npz --out candidate.toml --report candidate.json \
        --device device.toml --stereo sterio_calibration.toml --previous rigidbody.toml \
        --refine contour --isp pisp

Differences from rigidbody_calib.py's own take:

- Every tag seen is a candidate, not only those in device.toml, so a new tag works. A
  tag that does not move with the device is left out by the solve.
- The frames are split into the half that solves and the half that checks alternately,
  not first half and second half. Someone turning a device shows it in order, and the
  list on the screen counts the whole take: split in time, a tag shown only near the end
  would read as fine and then be missing. Neighbouring frames are a tenth of a second
  apart, so the check is a little kinder than on frames from later in the take.
- The fixed tag ([tip] tag) is the reference, so the tracked point keeps its numbers.
"""

import argparse
import json
import math
import os
import time
from pathlib import Path

import numpy as np

import rigidbody_calib as calib
from rigid_body import TAG_SIZE_M, CornerCollector, RigidBody, load_cameras, load_device, tag_corners

# Further than this between calibrations counts as moved. Two measurements of a tag that
# stayed differ by a millimetre or two.
MOVED_MM = 5.0


def alternate_frames(collector: CornerCollector) -> None:
    """Even frames first: solve() uses the first half and checks on the second."""
    for name in collector.camera_names:
        frames = collector.frames[name]
        collector.frames[name] = frames[::2] + frames[1::2]
    collector.paired = collector.paired[::2] + collector.paired[1::2]


def compare(previous: dict, new: dict, anchor: int, square: np.ndarray) -> dict:
    """Where each tag of `new` went since `previous`, relative to the fixed tag.
    Both are {tag id: (R, t)}. -> {tag id: {"state": same|moved|new, "moved_mm"}}"""
    def corners(transforms, mid):
        R_anchor, t_anchor = transforms[anchor]
        R, t = transforms[mid]
        return (square @ R.T + t - t_anchor) @ R_anchor

    tags = {}
    for mid in sorted(new):
        if mid not in previous or anchor not in previous:
            tags[mid] = {"state": "new", "moved_mm": None}
            continue
        moved = 1000.0 * float(np.linalg.norm(corners(previous, mid) - corners(new, mid), axis=1).max())
        tags[mid] = {"state": "same" if moved <= MOVED_MM else "moved", "moved_mm": round(moved, 1)}
    return tags


def report_on(result: dict, previous: dict, anchor: int, seen: dict, square: np.ndarray, started: float) -> dict:
    transforms = result["transforms"]
    solved = {mid: (item["R"], item["t"]) for mid, item in transforms.items()}
    places = compare(previous, solved, anchor, square)
    warnings = []
    others = [places[mid]["state"] for mid in places if mid != anchor and places[mid]["state"] != "new"]
    if len(others) >= 2 and all(state == "moved" for state in others):
        warnings.append(f"Tag {anchor} may have moved: every other tag shifted relative to it, and "
                        "the hand position is measured from it. If it did, put it back and take again.")
    problems = calib.take_problems(result)
    return {
        "ok": not problems,
        "problems": problems,
        "warnings": warnings,
        "tags": [{"id": mid, **places[mid], "seen": seen.get(mid, 0),
                  "spread_mm": round(transforms[mid]["translation_spread_mm"], 1)} for mid in sorted(solved)],
        "gone": sorted(set(previous) - set(solved)),
        "dropped": sorted(mid for mid, count in seen.items()
                          if count >= calib.MIN_SAMPLES_PER_MARKER and mid not in solved),
        "agreement_mm": [_number(result["agreement"]["median_mm"]), _number(result["agreement"]["p95_mm"])],
        "reprojection_px": [_number(result["validation"]["median_px"]), _number(result["validation"]["p95_px"])],
        "turned_deg": _number(result["bundle"]["turned_deg"]),
        "solve_s": round(time.time() - started),
    }


def _number(value: float):
    return None if math.isnan(value) else round(value, 2)


def _write_report(path: Path, report: dict) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(report, allow_nan=False), encoding="utf-8")
    os.replace(temporary, path)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    for name in ("take", "out", "report", "device", "stereo", "previous"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    parser.add_argument("--refine", required=True)
    parser.add_argument("--isp", required=True)
    args = parser.parse_args()

    # The tracker is pinned to its own cores, and a child inherits that. This is niced, so
    # it takes what the tracker and the app leave, wherever that is.
    os.sched_setaffinity(0, range(os.cpu_count()))

    started = time.time()
    device = load_device(args.device)
    anchor = device["tip_tag"] if device["tip_tag"] is not None else (device["reference_id"] or 1)
    if abs(device["tag_size_m"] - TAG_SIZE_M) > 1e-9:
        calib._MARKER_PTS = tag_corners(device["tag_size_m"])
    cameras, _size = load_cameras(args.stereo, device["camera_order"])
    previous = RigidBody.load(args.previous)
    previous = previous.transforms if previous is not None else {}

    collector = CornerCollector.load(args.take)
    seen = collector.counts()
    alternate_frames(collector)
    try:
        result = calib.solve(collector, cameras, anchor)
    except RuntimeError as exc:   # no usable pairs, nothing to check against
        _write_report(args.report, {"ok": False, "problems": [str(exc)], "warnings": [], "tags": [],
                                    "gone": sorted(previous), "dropped": sorted(seen)})
        return
    report = report_on(result, previous, anchor, seen, tag_corners(device["tag_size_m"]), started)
    if report["ok"]:
        tip = calib.tip_in_reference(result["transforms"], anchor, device["tip"])
        frames = min(len(collector.frames[name]) for name in collector.camera_names)
        calib.write_toml(args.out, result, anchor, tip, args.stereo, frames,
                         None if args.isp == "raw" else args.isp, args.refine)
    _write_report(args.report, report)


if __name__ == "__main__":
    main()
