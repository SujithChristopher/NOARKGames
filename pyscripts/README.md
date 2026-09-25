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

### Camera settings

All three live in `calibration/device.toml` under `[cameras]`, shared by the
calibration and the tracker, with `--exposure`, `--gain` and `--isp` to override
for one run.

```toml
[cameras]
exposure_us = 10000   # a whole number of the mains half-period
gain        = 3.0     # analogue, 1.0-16.0
isp         = "pisp"  # Pi 5 gamma curve, "vc4", or "" for raw
```

**Exposure** must be a multiple of the mains half-period — 10000 µs at 50 Hz,
8333 µs at 60 Hz — or each frame integrates a different slice of the light's
sine and the image pulses. Measured here: 44% peak-to-peak brightness at
5000 µs, 0.3% at 10000 µs. It also cannot exceed the frame period (~16.6 ms),
and it costs motion blur on a moving device.

**Gain** is free but amplifies the sensor noise that corner accuracy rests on,
so raise exposure first where the motion allows.

**ISP** is rcam's port of the Pi's mono pipeline — black level, digital gain and
the `ov9281_mono` gamma curve. Measured against raw at the same exposure:

| | raw | pisp |
|---|---|---|
| image level | 58/255 | 113/255 |
| frame rate | ~30 fps | ~19.5 fps |
| jitter | no difference repeated runs could separate |
| depth | — | consistent +0.8 mm |

The cost is ~16 ms per pair. It hides inside the wait for the next sensor frame
if you measure capture alone, and becomes additive once the loop is doing real
work — so measure it end to end, not in isolation.

> The depth offset means **the rigid body must be calibrated in the mode it is
> tracked in**. The mode is stamped into `rigidbody.toml` as `meta.isp` so a
> take cannot be silently reused under a different pipeline.

### While recording

The preview window is on by default (`--no-display` for headless) and carries a
readout that answers what you can still act on: exposure level with a verdict,
apparent tag size, and each tag's state — paired up, seen but still needing a
neighbour, or never seen. Pairs are what the geometry is built from, so a tag
seen thousands of times alone still contributes nothing.

Takes are kept automatically under `calibration/takes/`, so any take can be
re-solved offline without going back to the cameras.

### When a calibration is rejected

Two checks run before anything is written, and a failure leaves the previous
calibration in place:

```
[CALIB] NOT WRITING the calibration:
  - the bundle did not converge within N evaluations
  - the tags disagree about the tracked point by 81.2 mm (limit 10 mm)
```

**Tag agreement** is the one that matters. Each visible tag places the body
origin on its own, and the spread between those answers is the geometry
disagreeing with itself. Reprojection error cannot see a rarely-visible tag that
is badly placed — one that was 29 mm out still *improved* the held-out median,
while tracking jitter went from 1.57 mm to 38 mm. Good takes measure under 2 mm.

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

### What the game actually uses

`global_script.gd` launches `tracker.py` with **no arguments**, so a command-line
flag cannot affect a real session. The two choices that change tracking live in
`settings.json`, which is the only configuration the running game reads:

```json
"tracker_solver": "joint",   // or "ransac"
"tracker_camera": "both"     // or "cam0", "cam1"
```

`device.toml` still describes the *rig* — its tags, its tip, which stereo
section maps to which stream, exposure and ISP. These two are choices about how
to use it, and settings.json wins over device.toml when both say something.
Flags (`--solver`, `--camera`) override both, for bench runs.

`cam0`/`cam1` are rcam's enumeration order, not the stereo calibration's labels.

### Which camera mapping is right

`device.toml [cameras] stream0/stream1` says which section of
`sterio_calibration.toml` describes which stream. **On this rig the calibration's
labelling is the reverse of rcam's order.** Getting it wrong does not degrade
gracefully — the extrinsic is then applied along the opposite baseline:

```bash
uv run pyscripts/bench_cameras.py --seconds 20
```

It scores both mappings on the same frames and needs no ground truth, only that
both cameras must agree about where the device is at a given instant. Measured
on this rig:

| mapping | cam0 vs cam1, same instant | stereo noise |
|---|---|---|
| `stream0="cam1", stream1="cam0"` | **2.8 mm** | **0.21 mm** |
| `stream0="cam0", stream1="cam1"` | 140.7 mm | 1.00 mm |

**rcam's enumeration order is stable across boots** — `rcam/topology.py` sorts
sensors by CSI-PHY id, so stream 0 is always the CAM2 connector and stream 1
always CAM3, independent of probe order or `/dev/video*` numbering. Only
physically moving a cable changes it. So if tracking is suddenly noisy, the
mapping is not something that drifted on its own; run the check to find out what
did.

The same run reports each path's noise, which is how the camera choice gets
decided:

| path | noise | pose stage |
|---|---|---|
| cam0 alone | 0.53 mm | 1.5 ms |
| cam1 alone | 0.21 mm | 1.2 ms |
| both | 0.21 mm | 5.2 ms |

### Choosing the estimator

Which fit turns the corners into a pose is selectable, because the corners are
not all equally trustworthy and it is not obvious in advance whether throwing
some away helps:

| | |
|---|---|
| `joint` | seed from the best single tag, then one OpenCV `ITERATIVE` PnP over every visible corner. All corners trusted equally. |
| `ransac` | rapidtag's `estimate_rigid_body_pose`: RANSAC over the same corners, drop the ones the consensus disagrees with, refit on the rest. Rust, not Python. |

Set it in `device.toml` under `[tracking]`, or override per run:

```bash
.venv/bin/python pyscripts/tracker.py --solver ransac
```

Measure before switching — both solvers run on identical frames, so the
comparison is exact:

```bash
uv run pyscripts/bench_solvers.py --seconds 20            # as configured
uv run pyscripts/bench_solvers.py --seconds 20 --no-stereo
```

The bench reports noise as the frame-to-frame residual after removing constant
velocity, not as spread about the take's mean, so a device that drifts during
the take does not read as estimator error. It also reports the two solvers'
**per-frame disagreement**, which is immune to movement entirely: the same
corners went into both.

Measured on this rig, 8 tags, 20 s takes:

| | joint | ransac |
|---|---|---|
| cam0 only — noise | 1.40 mm | 1.30 mm |
| cam0 only — pose stage | 4.94 ms | 2.05 ms |
| stereo — noise | 5.70 mm | 5.70 mm |
| stereo — pose stage | 17.48 ms | 12.62 ms |

Two things to read out of that. RANSAC is consistently the cheaper of the two —
the Python seed loop it replaces runs an IPPE solve and a fisheye projection per
visible tag. And with stereo refinement on it makes no difference to the answer
at all (median disagreement 0.016 mm): the cross-camera least-squares fit
converges to the same pose whichever seed it starts from, so there the solver
choice buys time and nothing else.

Where it does change the answer is cam0-only, and only modestly: it dropped a
tag in 40 of 484 frames and came out 7% quieter. That is a smaller effect than
it sounds, because the calibration's own per-tag agreement is ~7 mm — RANSAC has
plenty to reject and rejecting *moves* the solution, which is why an earlier
hand-rolled rejection experiment in this pipeline made jitter worse rather than
better. RANSAC earns its keep against a tag that is genuinely misplaced, which
`pyscripts/tests/test_ransac_synth.py` confirms: displace one tag by 30 mm and
the joint fit's tip error goes to 41 mm while RANSAC stays at 0.5 mm.

## Session recording

With `"recording": true` in `settings.json` the tracker also writes both
cameras' frames for the session, in the same format as NOARK_backbone's
`dual_recorder_rcam.py`:

```
{DOCUMENTS}/NOARK/data/{patient}/Session-{date}/Video/rec_HH-MM-SS/
  cam{0,1}_frame.msgpack      raw HxW uint8, msgpack-numpy packed
  cam{0,1}_timestamp.msgpack  [sync, wall_iso, monotonic_ns, sensor_ns, sequence]
  sync_events.msgpack         [timestamp_ns, value, line_seqno] per GPIO edge
  metadata.json
```

**Pair frames across cameras on `sensor_ns`, never on frame index.** It is
CLOCK_MONOTONIC as stamped by CAMSS in its frame-done interrupt, and the GPIO
edges carry the same clock, so a trigger pulse and a frame exposure sit on one
timeline with no clock fitting. Measured cross-camera skew on a recording:
median 125 µs, max 388 µs.

### Why raw rather than encoded

FFV1 compresses these frames 2.18x but costs ~26 ms of CPU per pair, and the
tracking loop is already what competes for the big cores. Packing raw costs
1.2 ms and the writes release the GIL. The cost lands on disk instead:

| | |
|---|---|
| raw, 30 Hz, both cameras | 61 MB/s, **37 GB per 10 min** |
| encoding instead | ~10-25x the CPU, ~17 GB per 10 min |

Storage is the thing to plan around here, not CPU. Budget accordingly.

### Rate

The sensor is left free-running so tracking gets every frame it can. The
recorder decimates to `recording_fps` (default 30) on **elapsed sensor time**,
not by counting frames — so the rate does not depend on the capture rate
dividing evenly. At ~57 Hz in, keeping every other pair measures 29.9 Hz.

A consequence worth knowing when reading the data: the `sequence` column jumps,
because the skipped sensor frames are genuinely absent. That is how you tell
which frames were kept.

### Chunking

An hour at 30 Hz is 110 GB per camera in one file — awkward to copy, painful to
resume, unopenable by anything that wants to seek. Output rotates every
`recording_chunk_frames` (default 900 = 30 s ≈ 0.9 GB per camera; 0 disables):

```
cam0_frame_0000.msgpack      cam0_timestamp_0000.msgpack
cam0_frame_0001.msgpack      cam0_timestamp_0001.msgpack
chunks.json
```

Frames and their timestamps rotate on the same boundary, so **each chunk stands
alone** and can be copied or processed by itself. `chunks.json` records each
chunk's frame count and `sensor_ns` span, so the chunk holding a given moment is
found without opening any of them:

```json
{"cam0": [{"chunk": 0, "frames": 900,
           "first_sensor_ns": 19201358090000, "last_sensor_ns": 19203326449000,
           "frame_file": "cam0_frame_0000.msgpack",
           "timestamp_file": "cam0_timestamp_0000.msgpack"}]}
```

Reading chunks in order reconstructs the timeline exactly — measured across a
boundary, the interval was 33.26 ms, indistinguishable from any other frame.

### Resolution

`recording_scale` (default 1.0) downscales **what is written to disk, and only
that**. Detection and tracking always run on the sensor's full 1280x800 — the
resize happens on the writer thread, after the frame has already been handed to
the tracking loop, so live accuracy is identical at any scale.

0.5 gives 640x400 and quarters the storage. Unlike the chunking or any
compression, **it is irreversible**: not a smaller encoding of the same data,
but less data.

What it costs is re-running detection on the recordings *afterwards*. Measured
on 300 real frames, the same frames at both resolutions:

| | tags/frame | tag size |
|---|---|---|
| 1280x800 | 3.81 | 71.4 px |
| 640x400 | 2.40 | 44.0 px |

Half resolution detects **37% fewer tags**, and the pose from those frames
differs from the full-resolution pose by 8.45 mm median — largely because a
different tag subset is a different answer.

So the question is only what the archive is for: full resolution if it must be
able to reproduce what the live tracker saw, half if it is for review. Either
way the live tracking is the same.

The scale is written into `metadata.json`, since a reader needs it to scale the
camera matrix and cannot infer it from the frames.

Storage per hour, both cameras at 30 Hz: **110 GB** at 1.0, **27.5 GB** at 0.5.

### Sync line

The mocap trigger is read from the 40-pin header — `gpiochip4`, `PIN_11`
(TLMM line 29), the same physical hole the Pi used for GPIO17, configurable via
`sync_chip` / `sync_pin`. Header pin N is *not* TLMM line N; names come from the
device tree.

Two things are recorded. The per-frame `sync` column is a level sampled once per
frame, so a pulse shorter than the frame period is usually missed and one that
is caught is located only to within a frame. A latch thread therefore also
records every transition with the kernel's own CLOCK_MONOTONIC timestamp, giving
pulse edges at interrupt accuracy and keeping edges that fall between
recordings.

Missing `gpiod`, a claimed line, or a kernel that refuses edge detection each
degrade a step rather than failing, ending at a constant 0 so a session without
the trigger box still records. Startup says which you got:

```
[SYNC] GPIO on gpiochip4 line 29 (PIN_11) (level + edge timestamps), idle level 0
```

### Backpressure

Each camera has a bounded queue feeding a writer thread. If a flush stalls, the
pair is dropped and counted rather than blocking capture — capture also feeds
tracking, and a stutter in the game is worse than a gap in the recording. The
status line reports it:

```
[REC] 90 pairs at 29.9 Hz (skipped 81), written [90, 90], dropped [0, 0],
      backlog [0, 0], sync edges 0
```

`skipped` is deliberate decimation; `dropped` is the queue overflowing and
should stay at zero.
