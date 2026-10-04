"""Live test of the trunk pipeline on the tracker's cameras, without Godot.

    uv run pyscripts/trunk_live.py                 # Enter = capture neutral, q+Enter = quit
    uv run pyscripts/trunk_live.py --show          # window: mask overlay, n = neutral, q = quit
    uv run pyscripts/trunk_live.py --neutral-after 3 --seconds 30

Prints one line per trunk update: state, angles from neutral, per-axis level,
cloud size, ICP residual and the time each stage took. The tracker must not be
running — this opens the cameras itself.
"""

import argparse
import sys
import threading
import time
from pathlib import Path

import cv2
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from rigid_body import load_cameras, load_device, stereo_extrinsic  # noqa: E402
from stereo_capture import StereoCapture  # noqa: E402
from trunk import LEVEL_NAMES, TrunkThread  # noqa: E402
from tracker import DEFAULT_SETTINGS_PATH, _load_settings  # noqa: E402


def line(st):
    t = st.timing_ms
    tm = " ".join(f"{k} {v:4.0f}" for k, v in t.items())
    head = f"{st.state_name:<10} {st.hz:4.1f}Hz pts {st.npts:4d}"
    if st.state_name == "TRACKING":
        f, l, a = st.angles
        lv = "/".join(LEVEL_NAMES[x][0] for x in st.levels)
        return (f"{head}  flex {f:+6.1f} lat {l:+6.1f} axi {a:+6.1f}  [{lv}] "
                f"{LEVEL_NAMES[st.level]:<12} rms {st.rms_mm:4.1f}mm {st.how:<8} | {tm}")
    if st.state_name == "CAPTURING":
        return f"{head}  capturing neutral {st.progress * 100:3.0f}% | {tm}"
    return f"{head}  {st.reason or st.capture_result} | {tm}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--settings", type=Path, default=DEFAULT_SETTINGS_PATH)
    ap.add_argument("--show", action="store_true")
    ap.add_argument("--seconds", type=float, default=0)
    ap.add_argument("--neutral-after", type=float, default=None,
                    help="capture neutral automatically this many seconds in")
    args = ap.parse_args()

    settings = _load_settings(args.settings)
    calib = HERE / "calibration"
    device = load_device(calib / "device.toml")
    cams, size = load_cameras(calib / "sterio_calibration.toml", device["camera_order"])
    R, T = stereo_extrinsic(calib / "sterio_calibration.toml", device["camera_order"])
    (K0, D0), (K1, D1) = cams["cam0"], cams["cam1"]

    trunk = TrunkThread(K0, D0, K1, D1, R, T, size, settings).start()
    print(f"[TRUNK] reference camera: stream{1 if trunk.shell.swap else 0}, "
          f"SGBM {trunk.shell.size} x {trunk.shell.num_disp} disparities")
    cap = StereoCapture(frame_size=size, exposure_us=device["exposure_us"],
                        gain=device["gain"], isp=device["isp"])

    quit_flag = threading.Event()

    def stdin_loop():
        for raw in sys.stdin:
            if raw.strip().lower() == "q":
                quit_flag.set()
                return
            trunk.capture_neutral()
            print("[TRUNK] capturing neutral - sit upright and hold still")

    if not args.show:
        threading.Thread(target=stdin_loop, daemon=True).start()

    t0 = time.time()
    last_seq, frames = 0, 0
    auto_done = args.neutral_after is None
    try:
        while not quit_flag.is_set():
            raw0, raw1, *_ = cap.next_pair()
            frames += 1
            trunk.submit(raw0, raw1)
            el = time.time() - t0
            if not auto_done and el >= args.neutral_after:
                trunk.capture_neutral()
                print("[TRUNK] capturing neutral - sit upright and hold still")
                auto_done = True
            if args.seconds and el >= args.seconds:
                break
            st = trunk.status()
            if st.seq != last_seq:
                last_seq = st.seq
                print(line(st), flush=True)
            if args.show and trunk.last_view is not None:
                img, mask = trunk.last_view
                vis = cv2.cvtColor(img, cv2.COLOR_GRAY2BGR)
                if mask is not None:
                    vis[mask > 0] = (0.5 * vis[mask > 0] + (0, 90, 0)).astype(np.uint8)
                colour = {"OK": (0, 200, 0), "WARN": (0, 200, 255),
                          "COMPENSATING": (0, 0, 255)}.get(LEVEL_NAMES[st.level], (200, 200, 200))
                if st.state_name != "TRACKING":
                    colour = (160, 160, 160)
                cv2.putText(vis, line(st).split("|")[0], (8, 22), cv2.FONT_HERSHEY_SIMPLEX,
                            0.42, colour, 1, cv2.LINE_AA)
                cv2.imshow("trunk", vis)
                k = cv2.waitKey(1) & 0xFF
                if k == ord("q"):
                    break
                if k == ord("n"):
                    trunk.capture_neutral()
    except KeyboardInterrupt:
        pass
    finally:
        el = time.time() - t0
        print(f"[CAM] {frames / max(el, 1e-6):.1f} fps camera loop over {el:.0f}s")
        trunk.stop()
        cap.close()


if __name__ == "__main__":
    main()
