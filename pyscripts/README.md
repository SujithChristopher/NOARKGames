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
