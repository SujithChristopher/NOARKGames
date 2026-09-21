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
