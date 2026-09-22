# NOARK Tracker — pyscripts

ArUco marker tracking system that streams pose data to Godot over BLE or UDP.

## Running manually

```bash
# From project root
uv run pyscripts/tracker.py
```

## Systemd service (Raspberry Pi)

The tracker runs as a systemd service (`noark-tracker`) so it starts on boot.

### First-time setup

```bash
sudo cp noark-tracker.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable noark-tracker   # auto-start on boot
sudo systemctl start noark-tracker    # start now
```

### Start / stop / restart

```bash
sudo systemctl start noark-tracker
sudo systemctl stop noark-tracker
sudo systemctl restart noark-tracker
```

### Status and logs

```bash
systemctl status noark-tracker        # quick status
journalctl -u noark-tracker -f        # live logs
journalctl -u noark-tracker -n 100    # last 100 lines
```

### Disable autostart

```bash
sudo systemctl disable noark-tracker
```

## Frame synchronisation

The two OV9281s self-clock off separate 24 MHz crystals with no FSIN wiring, so
they free-run at an arbitrary phase — cold, that can be most of a frame period.
Triangulating a *moving* marker from a pair taken at two different instants puts
a position error into the track proportional to how fast the hand is moving, so
the tracker aligns them before it starts and keeps them aligned as it runs:

- **At startup** `rcam.FrameSync` walks cam1's phase onto cam0's by briefly
  stretching its vertical blanking, landing the pair inside ~100 µs. It then
  re-pairs the two capture queues: each camera buffers its own frames and hands
  back the oldest, and cam0 banks a few while cam1 is still being configured —
  cold, three, which is ~50 ms of skew that the old software timestamps could
  not see.
- **While running** the ~50 ppm the crystals differ by walks the phase apart
  again (~3 ms/minute), so it is re-measured from the frame timestamps every few
  seconds and nudged back when it exceeds the threshold. A pair that slips a
  frame (the driver drops frames the loop is too slow to consume) is caught up
  from the lagging camera's queue rather than triangulated.

```bash
uv run pyscripts/tracker.py --no-frame-sync        # let the sensors free-run
uv run pyscripts/tracker.py --resync-every 0       # align once, never top up
uv run pyscripts/tracker.py --resync-threshold 500 # nudge sooner (more often)
```

The `[SYNC]` status line reports the current phase, its jitter and drift, and
how many pairs had to be re-paired in the last interval:

```
[SYNC] phase: +86 µs  jitter: 79 µs  drift: +28 ppm  (0.52% of a frame)  re-paired: 50
```

Anything up to a few hundred µs of phase is normal. A phase that keeps climbing
between nudges means the threshold is set too high for the drift; a re-pair
count near the frame count means the sensors are producing far more frames than
the loop consumes, which `--fps` can cap.

## Rigid-body marker calibration

The device carries several AprilTags on different faces. The tracker needs each
one's offset to the device tip, and those offsets used to be hand measured
(`tracker.py`'s `MARKER_OFFSETS`) — which is why each tag reported the tip in a
slightly different place and the reported position stepped as the visible set
changed.

`rigidbody_calib.py` measures the body instead. Every frame in which two tags
appear in the same camera constrains their relative pose; enough of those solve
the whole cluster as one rigid body in a reference tag's frame. Only the tip
offset stays hand measured, and only in the reference tag's frame — every other
tag's offset follows from the solved geometry.

Nothing but corners is stored: a 60 s take is ~1.2 MB, not gigabytes of frames.

The rig is described once in `calibration/device.toml` — its tag ids, its
reference tag, and where the tracked point sits on it — so the same description
is shared with the repo instead of retyped on each command line. Every CLI flag
below just overrides that file.

```toml
[device]
tag_ids = [1, 2, 3, 4, 5, 6, 7, 8]
reference_id = 1

[tip]
tag = 1                      # the tag the measurement is taken against
offset_m = [0.0, 0.0, 0.0]   # all zeros = the centre of that tag
```

Tags outside `tag_ids` are discarded, so another rig in the room or the
occasional false positive never reaches the solve.

```bash
# Close the Godot app first — it owns both cameras while it runs.

# 1. Which tags can the cameras actually see?
.venv/bin/python pyscripts/rigidbody_calib.py --list

# 2. Calibrate, rotating the device throughout. No arguments needed —
#    everything about the rig comes from device.toml.
.venv/bin/python pyscripts/rigidbody_calib.py --seconds 60 \
    --save-corners /tmp/corners.npz

# 3. Once the hand position has been measured, apply it. No recapture and no
#    re-solve: it is saved to device.toml *and* applied to rigidbody.toml.
.venv/bin/python pyscripts/rigidbody_calib.py --set-tip 0 0.01 -0.069

# 4. Re-solve a saved take without recapturing (e.g. a different reference)
.venv/bin/python pyscripts/rigidbody_calib.py --from /tmp/corners.npz --reference 3
```

**The tip is not part of the geometry.** The capture measures where the tags sit
relative to each other; the tip only converts that into the per-tag offsets the
tracker consumes. So calibrate first and set the hand position whenever it is
measured — `--set-tip` records it in `device.toml` and rewrites the offsets of
the finished calibration in place.

Measure it in metres against `[tip] tag`, in that tag's own frame: **X** right
along the tag's top edge, **Y** up its left edge, **Z** out of the printed face,
so the tracked point is normally negative Z. Its accuracy sets the rig's
absolute accuracy; the geometry *between* tags never depends on it.

The tip tag and the reference tag are deliberately separate. The reference is
just the frame the geometry is expressed in, while the tip is a physical
measurement against whichever tag was convenient — keeping them apart means
re-solving against a different reference cannot silently invalidate the
measurement.

### Tags that never share a view

On a body whose tags wrap around it, the far side is never in the same frame as
the reference. The solve measures *every* co-visible pair and chains back to the
reference through whichever tags bridge the gap, choosing routes by how tightly
each pair was measured rather than how often. The printed route shows the path:

```
tag 3 -> tag 1: t=[45. 0. -44.9] mm, hop spread 0.65 mm / 0.68°  (via 2->3)
tag 6 -> tag 1: t=[-31.5 0.3 -77.2] mm, hop spread 0.44 mm / 0.26°  (via 2->3->5->4->6)
```

So rotate the device steadily through a full revolution rather than showing
faces one at a time: each *neighbouring* pair needs time in view together.
Anything unreachable is named rather than silently dropped.

**Rotate the device slowly through a wide range of angles during the take.** The
solve needs each tag seen *together with the reference tag* from many
orientations; a take from one viewpoint produces a poorly conditioned fit, which
shows up as a high bundle RMSE and a large held-out reprojection error.

Output is `pyscripts/calibration/rigidbody.toml`: each tag's transform into the
reference frame, plus an `[offsets]` table giving the tip in every tag's own
frame — the same shape the hand-measured `MARKER_OFFSETS` had.

> `MARKER_OFFSETS` in `tracker.py` describes the **previous** 5-tag bracket
> (ids 4, 8, 12, 14, 20), not the current 1-8 body. Ids 4 and 8 appear in both,
> so without a calibration the tracker supplies stale offsets for those two tags
> and nothing for the rest. It says so loudly at startup. Calibrate before use.

### How the tracker uses it

With a calibration present, `tracker.py` solves **one pose for the whole cluster**
from every visible corner, instead of a pose per tag whose tip offsets are then
averaged. Up to 40 corners across two cameras condition a pose far better than
any one tag's four. Without a calibration it falls back to `MARKER_OFFSETS` and
says so at startup.

```bash
.venv/bin/python pyscripts/tracker.py --no-stereo-refine   # cam0-only board PnP
```

`--stereo-refine` (the default) additionally fits the pose across both cameras,
which is the better estimator but runs in Python. Measured on this board:

| | pose stage | loop rate |
|---|---|---|
| per-marker averaging (old) | 7.1 ms | ~32 fps |
| joint board PnP, cam0 only | 5.3 ms | ~30 fps |
| joint board PnP + stereo refine | 26 ms | ~17 fps |

A useful health check: if the cam0-only and stereo poses disagree by more than a
few mm, either the rigid body or the stereo extrinsics are wrong — on a good
calibration they agree closely.
