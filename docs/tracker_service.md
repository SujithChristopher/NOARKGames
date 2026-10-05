# Tracker service (BLE)

On the Radxa the tracker runs as a systemd service, `noark-tracker`, so it starts
on boot and is always advertising over BLE for the tablet. The unit file is
`noark-tracker.service` in the repo root (user `radxa`, runs
`uv run pyscripts/tracker.py`, restarts on failure after 5 s).

It needs `"stream_type": "ble"` in `~/Documents/NOARK_demo/settings.json`. With
`udp` (the default) Godot on the board starts the tracker itself instead; never
run both, since only one process can hold the cameras.

## Install (once)

```bash
sudo cp noark-tracker.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now noark-tracker   # start on boot, and start now
```

Advertising on this board goes through `sudo -n hcitool`, which needs
`/etc/sudoers.d/noark-ble` (`radxa ALL=(root) NOPASSWD: /usr/bin/hcitool`).

## Start / stop / restart

```bash
sudo systemctl start noark-tracker
sudo systemctl stop noark-tracker
sudo systemctl restart noark-tracker    # needed after editing settings.json
```

Stop it before running anything else that uses the cameras (`bench_cameras.py`,
`trunk_live.py`, `rigidbody_calib.py`, or `tracker.py` by hand).

## Autostart on boot

```bash
sudo systemctl enable noark-tracker     # on
sudo systemctl disable noark-tracker    # off (the running instance is not stopped)
systemctl is-enabled noark-tracker
```

## Monitor

```bash
systemctl status noark-tracker          # running? since when? last lines
journalctl -u noark-tracker -f          # live log
journalctl -u noark-tracker -n 100      # last 100 lines
journalctl -u noark-tracker -b          # everything since boot
```

Startup takes about a minute (cameras, phase alignment, trunk process on the
NPU). In the log, look for:

| Line | Meaning |
|------|---------|
| `[SYNC] Phase offset: ...` | the two cameras are aligned |
| `[TRUNK] Tracking from stream0 ...` | trunk tracking is up (otherwise hand tracking only) |
| `[BLE] Advertising as 'NOARK_Tracker'` | visible to the tablet |
| `[BLE] Central connected` | the app connected |
| `[BLE] Streaming position data` | position packets are going out |
| `[BLE] Waiting for reconnect — advertising continues` | the app left; the tracker stays up |

## Behaviour to know

- The tracker outlives the app. STOP from the app, or 3 s without a heartbeat,
  ends the session and it goes back to advertising; the service keeps running.
- `Restart=on-failure`: if the tracker crashes, systemd restarts it after 5 s.
  A restart takes the same ~1 minute to come up again.
- BLE advertising falling back to raw HCI shows as
  `[BLE] BlueZ advertising failed (...); advertising by raw HCI`. That is
  expected on this board.

## Troubleshooting

- **Not advertising / `Raw HCI advertising failed`**: check the sudoers file
  above and `systemctl status bluetooth`.
- **Camera errors / "device busy"**: something else holds the cameras. Find it with
  `pgrep -af "tracker.py|trunk_live|bench_"` and stop it.
- **Service keeps restarting**: `journalctl -u noark-tracker -n 50` shows why.
- **Edited the unit file**: `sudo systemctl daemon-reload` then restart.
