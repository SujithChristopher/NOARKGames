# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**NOARKGames** is a Godot 4.5-based rehabilitation gaming platform for stroke patients. Mini-games track motor skill recovery through UDP-driven real-time position data and comprehensive CSV session logging.

**Engine**: Godot 4.5 with GDScript
**Primary Target**: Linux ARM64 (Raspberry Pi)
**Secondary Target**: Android

## Running and Building

```bash
# Open project in editor
godot project.godot

# Run from CLI
godot --path . --main-scene res://Main_screen/Scenes/main.tscn
```

**Export targets** (via Godot Editor → Project → Export):
- **Linux ARM64**: SSH remote deploy to Raspberry Pi, OpenGL compatibility renderer
- **Android**: Mobile platform

**Debug mode** — edit `settings.json` (a `debug.json` also exists but nothing reads it):
```json
{"debug": true}   // patient ID = 'vvv', skips authentication
{"debug": false}  // production mode
```

## Python Motion Capture System

The external input device uses ArUco marker tracking over UDP:

```bash
# Install dependencies (requires Python 3.11+)
python -m venv .venv
.venv\Scripts\activate          # Windows
pip install -e .                 # installs from pyproject.toml

# Run tracker (streams to localhost:8000)
python pyscripts/main.py
```

**Dependencies** (`pyproject.toml`): `opencv-contrib-python>=4.13`, `scipy>=1.17`

**Architecture**: `pyscripts/tracker.py` detects AprilTags on both cameras, solves one pose for the calibrated rigid body, and UDP-streams 11 float32s to `127.0.0.1:8000`. Godot's `GlobalScript` receives and scales these to screen coordinates.

There is **no temporal smoothing**: `ExponentialMovingAverageFilter3D` is constructed with `alpha=1`, which passes the input straight through. Smoothness comes from the geometry, not from a filter — so a jitter problem is a calibration or camera-mapping problem, and reaching for a filter would only hide it. `CornerStabilizer` freezes the pose when no contributing corner has moved, which saves the solve but measured no change to noise.

## Architecture

### Autoload System (Global Singletons)

Order in `project.godot` is critical — later autoloads can depend on earlier ones:

| # | Name | Script | Purpose |
|---|------|--------|---------|
| 1 | PatientDB | `Main_screen/Scripts/patient_db.gd` | Patient JSON database |
| 2 | Manager | `Main_screen/Scripts/manager.gd` | CSV session log creation |
| 3 | GlobalSignals | `Main_screen/Scripts/global_signals.gd` | Signal bus + shared state |
| 4 | GlobalScript | `Main_screen/Scripts/global_script.gd` | Session/trial IDs, UDP, screen scaling |
| 5 | SoundFx | `Main_screen/Scenes/SoundFx.tscn` | Audio management |
| 6 | GlobalTimer | `Main_screen/Scripts/global_timer.gd` | Session-wide timer |
| 7 | ScoreManager | `Main_screen/Scripts/score_db.gd` | High score persistence |
| 8 | DebugSettings | `Main_screen/Scripts/debug_settings.gd` | Debug config |
| 9 | AudioManager | `Games/Jumpify/…/AudioManager.gd` | Jumpify audio |
| 10 | SceneTransition | `Games/Jumpify/…/SceneTransition.gd` | Jumpify transitions |
| 11 | GlobalTimerManager | `Main_screen/Scripts/global_timer_manager.gd` | Countdown timer with signals |
| 12 | MusicManager | `Main_screen/Scripts/music_manager.gd` | Background music |
| 13 | ButtonSoundManager | `Main_screen/Scripts/button_sound_manager.gd` | Button SFX |
| 14 | CircularTimer | `Games/random_reach/…/circular_timer.gd` | Visual countdown |

### Data Flow

**Patient flow**: Registration UI → `PatientDB.add_patient()` → JSON at `{DOCUMENTS}/NOARK/records/patients.json`

**Session flow**: Game `_ready()` → `Manager.create_game_log_file(game_name, patient_id)` → CSV file handle → log rows every ~0.02s → close on game end

**Score flow**: Game end → `ScoreManager.update_top_score(patient_id, game_name, score)` → JSON at `{DOCUMENTS}/NOARK/records/scores.json`

**File paths**:
```
{DOCUMENTS}/NOARK/
  records/patients.json        # patient database
  records/scores.json          # high scores per patient per game
  data/{patient_id}/GameData/  # CSV session logs
```

**CSV filename format**: `{game}_S{session}_T{trial}_{date}.csv`
**CSV header**: 7 lines — `game_name, h_id, device_location, device_version, protocol_version, start_time, headerrows`

### Games

| Game | Path | Mode | Notes |
|------|------|------|-------|
| Flappy Bird | `Games/flappy_bird/` | 2D + 3D | Pipe obstacle avoidance |
| Ping Pong | `Games/ping_pong/` | 2D only | Physics-based paddle game |
| Fruit Catcher | `Games/fruit_catcher/` | 2D only | `fruit.gd` class is named `Gem` |
| Jumpify | `Games/Jumpify/` | 3D only | Platformer with level progression |
| Random Reach | `Games/random_reach/` | 2D + 3D | Most complex; uses shaders and `@onready` dicts |
| Assessment | `Games/assessment/` | 3D only | Workspace boundary testing (minimal) |

Games supporting both modes maintain **separate high scores** — `game_name` is set dynamically:
```gdscript
game_name = "GameName3D" if is_3d_mode else "GameName"
```

### Node Organization Pattern

Complex games (e.g., Random Reach) group `@onready` nodes into typed dictionaries:
```gdscript
@onready var _audio_nodes = { "apple_sound": $"../apple_sound" }
@onready var _ui_nodes = { "score_board": $"...", "timer": $"..." }
```

### Results and Progress Visualization

`Results/` contains `parse_files.gd` and `user_progress.gd/.tscn` for visualizing CSV session data using the **EasyCharts** addon (`addons/easy_charts/`). Supports line, bar, area, scatter, and pie charts.

## Critical Implementation Details

### Adding a New Game
1. Call `Manager.create_game_log_file(game_name, patient_id)` in `_ready()` and store the returned handle
2. Use `GlobalScript.session_id` and `GlobalScript.get_next_trial_id(game_name)`
3. Log rows via the handle at ~0.02s intervals using a Timer node
4. Check `if debug: p_id = 'vvv'` before constructing any file paths
5. Close the file handle on game end
6. For 2D/3D support: set `game_name` dynamically via an `is_3d_mode` flag

### Marker Geometry (Rigid Body)

The device's tags are **measured, not hand-entered**. `pyscripts/rigidbody_calib.py`
solves every tag's pose relative to a reference tag from live detections and
writes `pyscripts/calibration/rigidbody.toml`; `tracker.py` loads it and solves
one joint PnP over every visible corner, rather than averaging a pose per tag.

- `pyscripts/calibration/device.toml` describes the rig — tag ids, reference
  tag, the tip offset, and which stereo-calibration section maps to which camera
  stream. That last one is not cosmetic: the calibration tool's cam0/cam1 need
  not match rcam's enumeration order, and on this rig they do not.
- `MARKER_OFFSETS` in `tracker.py` is the previous 5-tag bracket, kept only so an
  uncalibrated rig still starts. GDScript no longer carries a copy — `set_origin()`
  uses the tracked point from the packet.
- Stereo refinement is off unless the calibration carries a self-calibrated
  extrinsic: with a multi-tag board it measured no better than one camera
  (1.19 mm vs 1.02 mm jitter) at four times the cost.
- The two choices that change tracking live in `settings.json`, because
  `global_script.gd` launches `tracker.py` with no arguments — a flag cannot
  affect a real session. `tracker_solver` is `joint` (fit every visible corner)
  or `ransac` (rapidtag's consensus fit, dropping corners that disagree);
  `tracker_camera` is `both`, `cam0` or `cam1`. `device.toml` describes the rig;
  settings.json says how to use it and wins where both speak.
- The stereo calibration's cam0/cam1 labelling is the **reverse** of rcam's
  enumeration on this rig, which `device.toml [cameras]` corrects. rcam's order
  is stable across boots (sorted by CSI-PHY id), so it never drifts on its own —
  but a wrong mapping costs 141 mm of camera-to-camera disagreement, not a few.
  `pyscripts/bench_cameras.py` scores both mappings on one take;
  `pyscripts/bench_solvers.py` does the same for the two solvers.

See `pyscripts/README.md` for the calibration workflow.

### Network Position (UDP Input)
- `GlobalScript` listens on `127.0.0.1:8000`, receives `net_x, net_y, net_z, net_a`
- 2D scalers: `PLAYER_POS_SCALER_X`, `PLAYER_POS_SCALER_Z`
- 3D scalers: `PLAYER3D_POS_SCALER_X`, `PLAYER3D_POS_SCALER_Y`
- Positions are clamped to `MIN_X/MAX_X/MIN_Y/MAX_Y` screen bounds

### Modifying Autoloads
- Order in `project.godot` matters — `PatientDB`, `Manager`, `GlobalSignals` must initialize before any game scene
- Debug mode is read from `settings.json` in `_ready()` of both `Manager` and `GlobalScript`

### Patient Data Access
```gdscript
PatientDB.add_patient(data)
PatientDB.get_patient(hospital_id)
PatientDB.list_all_patients()   # returns Array of Dicts
PatientDB.current_patient_id

GlobalSignals.current_patient_id  # mirrors PatientDB
GlobalSignals.data_path           # {DOCUMENTS}/NOARK/data
GlobalSignals.selected_game_mode  # "2D" or "3D"
```

### Score System
```gdscript
ScoreManager.get_top_score(patient_id, game_name)
ScoreManager.update_top_score(patient_id, game_name, new_score)  # only updates if higher
ScoreManager.get_all_scores_for_patient(patient_id)
```

## Display Configuration

- **Mode**: Fullscreen (`window/size/mode=2`)
- **Stretch**: Canvas items, ignore aspect ratio
- **Renderer**: OpenGL Compatibility (`gl_compatibility`) for Raspberry Pi support

## Android GDExtension Gotchas

- **Headless export vs GUI export**: Headless (`--export-debug`) may not package GDExtensions correctly for Android — the `.so` may not load at runtime even if present in the APK. Prefer GUI export for Android APKs.
- **APK structure**: GDExtension `.so` files go in `lib/arm64-v8a/`, config goes in `assets/.godot/extension_list.cfg`
- **BLE permissions**: Android 12+ requires runtime permission requests before BLE operations — see `_init_ble()` in `global_script.gd`
- **extension_list.cfg**: If duplicate `.gdextension` files exist (e.g., from submodules), Godot may register both — use `.gdignore` in submodule dirs

## No Test Infrastructure

There are no automated tests in this project.
