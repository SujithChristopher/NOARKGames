"""BLE peripheral smoke test: the tracker's GATT server without the cameras.

    uv run pyscripts/ble_test.py              # advertise, stream a fake hand circle
    uv run pyscripts/ble_test.py --hz 20 --seconds 60

Advertises as settings.json `ble_device_name` (default NOARK_Tracker) with the
same service and characteristics as the tracker, and notifies a 44-byte
position packet (11 float32) moving the tip round a 10 cm circle, so a central
(the GdAndroidBLE demo, or Godot in "ble" transport) can be checked end to end
without a patient. Every command the central writes is printed.
"""

import argparse
import math
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from ble_streamer import BLEStreamer  # noqa: E402
from tracker import DEFAULT_SETTINGS_PATH, _load_settings  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--settings", type=Path, default=DEFAULT_SETTINGS_PATH)
    ap.add_argument("--hz", type=float, default=30)
    ap.add_argument("--seconds", type=float, default=0, help="0 = until Ctrl+C")
    args = ap.parse_args()

    name = _load_settings(args.settings).get("ble_device_name", "NOARK_Tracker")
    ble = BLEStreamer(name)
    ble.start()

    t0 = time.time()
    n = 0
    try:
        while not args.seconds or time.time() - t0 < args.seconds:
            t = time.time() - t0
            x, z = 0.1 * math.cos(t), 0.1 * math.sin(t)
            ble.send([2.0, x, 0.0, 0.5 + z, 0, 0, 0, x, 0.0, 0.5 + z, 0.0])
            n += 1
            cmd = ble.get_command()
            if cmd:
                print(f"[BLE] command {cmd!r}", flush=True)
            if n % int(args.hz * 5) == 0:
                print(f"[BLE] {n} packets, {n / t:.1f}/s", flush=True)
            time.sleep(1 / args.hz)
    except KeyboardInterrupt:
        pass
    finally:
        ble.stop()


if __name__ == "__main__":
    main()
