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

```bash
# Close the Godot app first — it owns both cameras while it runs.
.venv/bin/python pyscripts/rigidbody_calib.py --seconds 60 --reference 4 \
    --save-corners /tmp/corners.npz

# Re-solve a saved take without recapturing (e.g. with a different reference)
.venv/bin/python pyscripts/rigidbody_calib.py --from /tmp/corners.npz --reference 8
```

**Rotate the device slowly through a wide range of angles during the take.** The
solve needs each tag seen *together with the reference tag* from many
orientations; a take from one viewpoint produces a poorly conditioned fit, which
shows up as a high bundle RMSE and a large held-out reprojection error.

Output is `pyscripts/calibration/rigidbody.toml`: each tag's transform into the
reference frame, plus an `[offsets]` table giving the tip in every tag's own
frame — the same shape the hand-measured `MARKER_OFFSETS` had. The script prints
the two side by side so the disagreement being corrected is visible.

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
