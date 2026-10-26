"""BLE peripheral smoke test: the tracker's GATT server without the cameras.

    uv run pyscripts/ble_test.py              # advertise, stream a fake hand circle
    uv run pyscripts/ble_test.py --hz 20 --seconds 60

Advertises as settings.json `ble_device_name` (default NOARK_Tracker) with the
same service and characteristics as the tracker, answers the app's HELLO and
commands like the tracker (link.py), and once connected notifies a POSITION
(docs/PROTOCOL.md) moving the tip round a 10 cm circle — or, after CONFIG
track=rotation, a ROTATION turning ±40° about the camera's z axis — so a central
(the GdAndroidBLE demo, or Godot in "ble" transport) can be checked end to end
without a patient. Every command the central sends is printed and accepted.
"""

import argparse
import math
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import protocol  # noqa: E402
from ble_streamer import BLEStreamer  # noqa: E402
from link import Link  # noqa: E402
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
    link = Link(ble)

    mode = {"track": "position"}

    def accept(kind, body):
        print(f"[BLE] command 0x{kind:02x} {body!r}", flush=True)
        if kind == protocol.CONFIG and body.startswith(b"track="):
            mode["track"] = body[6:].decode()
        return True, ""

    t0 = time.time()
    n = 0
    try:
        while not args.seconds or time.time() - t0 < args.seconds:
            t = time.time() - t0
            x, z = 0.1 * math.cos(t), 0.1 * math.sin(t)
            link.poll(accept)
            if link.connected and link.silent_for() > 3.0:
                print("[BLE] App went quiet; waiting for the next HELLO", flush=True)
                link.reset()
            if link.connected:
                if mode["track"] == "rotation":
                    link.send(protocol.encode_vec3(protocol.ROTATION, (0.0, 0.0, 0.7 * math.sin(t))))
                else:
                    link.send(protocol.encode_vec3(protocol.POSITION, (x, 0.0, 0.5 + z)))
                n += 1
            if n and n % int(args.hz * 5) == 0:
                print(f"[BLE] {n} packets, {n / t:.1f}/s", flush=True)
            time.sleep(1 / args.hz)
    except KeyboardInterrupt:
        pass
    finally:
        ble.stop()


if __name__ == "__main__":
    main()
