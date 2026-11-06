# Known issue: the two camera streams swap

**Status: open, cause not found.** Written 2026-11-06. Debugging is deferred.

## Symptom

After a fresh start of the board, tracking with both cameras can behave as if the two cameras
have changed places: the hand position jumps or jitters in the games. The operator reports it
appearing after a reboot, not during tracking, and with no camera or cable being touched.

## What it does to the data

`[cameras]` in `pyscripts/calibration/device.toml` says which calibration section belongs to
which stream. When that is wrong, each camera is solved with the other's lens parameters and the
stereo offset points the wrong way. The two cameras then disagree by about twice the 77 mm
baseline.

Sessions played in that state have wrong positions in their logs, and nothing flags them.

## Evidence

| Date | Order that fits | Source |
|---|---|---|
| until 2026-09 | `cam1, cam0` | note in `device.toml` |
| 2026-10-08 | `cam0, cam1` | note in `device.toml` |
| 2026-10-14 | `cam1, cam0` | note in `device.toml` (offline, from a recording) |
| 2026-10-29 | `cam0, cam1` | note in `device.toml` |
| 2026-11-04 17:09 | `cam1, cam0` | re-scored from the saved take, see below |
| 2026-11-05 | `cam1, cam0` | note in `device.toml` |

The 2026-11-04 row comes from `calibration/takes/corners_20261104_170942.npz`, scored the way
`bench_cameras.py` scores live frames, using all 269 paired frames:

| Order | Median disagreement | p95 |
|---|---|---|
| `cam0, cam1` (what `device.toml` said at the time) | 150.1 mm | 155.6 mm |
| `cam1, cam0` | 5.2 mm | 6.6 mm |

The board rebooted on 10-29, 10-30 and 11-02 between the last two changes of order. That fits the
reboot report but does not prove it: no check ran on each boot, so the exact moment is unknown.

## Ruled out

- **Cables or cameras moved:** the operator says they were not touched.
- **Device wiring:** the device tree ties `i2c-bus@0` to CSIPHY port 2 and `i2c-bus@1` to port 3.
  On the boot checked, the media graph matched: `18-0060` to `msm_csiphy2` to `msm_csid0`, and
  `20-0060` to `msm_csiphy3` to `msm_csid1`. Only that one boot has been read, so a graph that
  differs on another boot is not excluded.
- **rcam's ordering:** `topology.py` sorts sensors by CSI-PHY id, and the tracker runs that code
  (editable install of `external/rcam`). The only source change between the older pin `56840de` and
  the current `9c23784` is one line in `__init__.py`.
- **The inverse transform:** `stereo_extrinsic` inverts the offset correctly for the reversed order.

## Not ruled out

- **The kernel's camera path (`qcom_camss`):** the leading suspect, by elimination, and not
  observed. On the boot checked, the sensors registered out of bus order (`20-0060` before
  `18-0060`). rcam's sort should make that harmless, and whether the order varies is unknown.
- **Whether a reboot is required:** a tracker restart or camera restart has not been tested as a
  trigger.

Kernel logs for past boots were not readable without root, so they have not been checked.

## How to debug it

1. Log the order that fits at every camera start, with the boot ID, sensor registration order and
   media graph. A few reboots should then show when it changes and what changes with it.
2. Change the exposure on one sensor and see which stream gets brighter. If the stream tied to the
   other sensor changes, the driver's routing is the problem rather than our code.
3. Check `sudo journalctl -k` on a boot where the order changed.

## Fix to consider once the cause is known

Choose the order that fits at camera start, and warn in the app if neither does. Positions must
stay tied to one physical camera, or the origin moves by 77 mm and `table.json` goes wrong.

## Workaround

If tracking looks wrong after a reboot, hold the device where both cameras see it and run:

```bash
sudo systemctl stop noark-tracker
uv run pyscripts/bench_cameras.py --seconds 20
sudo systemctl start noark-tracker
```

If it reports the other order as correct, swap `stream0` and `stream1` in `device.toml`, restart
the tracker, and redo Define Table, because the origin moves with the first camera.

## Calibration affected

`rigidbody.toml` (2026-11-04) was solved while `device.toml` had the wrong order, so it used each
camera's lens parameters on the wrong camera. It still scores 5.2 mm under the right order, so it
is usable and has been kept. Redo it in Settings > Calibration once this is fixed.
