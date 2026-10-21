# BLE Communication Status

## What Works

### Python test receiver → RPi peripheral (simplepyble + bless)
- **Library**: `simplepyble` (Windows central) ↔ `bless` (RPi peripheral)
- **Test script**: `pyscripts/test_ble_receiver.py`
- **Confirmed**: Full scan → connect → notify → receive pipeline working
- **Device**: `NOARK_Tracker` at `88:a2:9e:ad:d3:e5`
- **Data rate**: Continuous position packets at ~30 Hz
- **Message format**: see `docs/PROTOCOL.md` (one protocol for UDP and BLE)

### GATT layout (confirmed from live scan)
| Service / Char UUID | Caps | Role |
|---|---|---|
| `4e4f4152-4b00-0000-0000-000000000000` | — | NOARK service root |
| `4e4f4152-4b01-0000-0000-000000000000` | read, notify | Position stream (RPi → Godot) |
| `4e4f4152-4b02-0000-0000-000000000000` | write_request, write_command | Commands (Godot → RPi) |

### RPi peripheral (`pyscripts/ble_streamer.py` + `bless`)
- Advertises as `NOARK_Tracker`
- GATT server accepts connections from any central
- Sends position on notify channel at camera frame rate
- Accepts the app's commands (HELLO, SESSION, STOP, CONFIG, TRUNK; `docs/PROTOCOL.md`)

---

## What Does Not Work

### Rust/Godot GDExtension with btleplug
- **Status**: Replaced with `simplersble`
- **Root causes identified**:
  1. `scan()` called from GDScript Thread → gdext `single_threaded` binding panics (error code 40)
  2. `godot_print!`/`godot_error!` macros called from background thread → panic
  3. btleplug `scan_get_results()` on Windows returned 0 devices despite RPi advertising
  4. Double GDExtension init from `gdble_src/addons/` being scanned → fixed with `.gdignore`

---

## Architecture

```
RPi (tracker device)
  └─ pyscripts/main.py          ← camera → pose estimation → smoothing
       └─ pyscripts/ble_streamer.py  ← bless GATT peripheral server
            └─ characteristic 4b01: notify position packets
            └─ characteristic 4b02: receive commands

Windows PC (game device)
  └─ Godot game
       └─ addons/gdble/ (GDExtension, Rust)
            └─ simplersble (replaces btleplug)
            └─ gdble_src/src/gdble.rs      ← scan + adapter management
            └─ gdble_src/src/ble_device.rs ← per-device connect/notify/write
```

---

## Python Dependencies

| Package | Role | Platform |
|---|---|---|
| `bless >= 0.1.7` | BLE GATT **peripheral** server | RPi (Linux) only |
| `simplepyble` | BLE **central** scanner/client (test only) | Windows |
| `bleak` | BLE **central** (previous attempt, replaced) | Windows |

`bless` cannot be replaced by simplepyble — simplepyble is central-only.

---

## Running the Test

```bash
# On RPi: start the peripheral
uv run pyscripts/main.py

# On Windows PC: verify BLE communication without Godot
uv run pyscripts/test_ble_receiver.py
```
