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

**Settings** live at `{DOCUMENTS}/NOARK_demo/settings.json` (this `demo` branch uses `NOARK_demo` — `Settings.APP_DIR` — so the real `{DOCUMENTS}/NOARK` data is never touched), not in the repo — `res://` is read-only in an export. The `Settings` autoload (first in the list) loads/saves it and seeds it from defaults on first run; the main scene has a Settings panel for everything except `debug`, which is file-only (it skips authentication). `location` (the site written to sessions.csv and raw logs) is set from the login dose dialog. Godot passes the path to `tracker.py` with `--settings`.

**Debug mode** — edit that file (a `debug.json` also exists but nothing reads it):
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
| 1 | Settings | `Main_screen/Scripts/settings.gd` | User settings file (must be first) |
| 2 | PatientDB | `Main_screen/Scripts/patient_db.gd` | Read-only patient list from the server's patients.json |
| 3 | SessionLog | `Main_screen/Scripts/session_log.gd` | Per-patient sessions.csv, trial numbering, therapy dose |
| 4 | Manager | `Main_screen/Scripts/manager.gd` | Raw trial CSV creation |
| 5 | GlobalSignals | `Main_screen/Scripts/global_signals.gd` | Signal bus + shared state |
| 6 | GlobalScript | `Main_screen/Scripts/global_script.gd` | UDP, screen scaling |
| 7 | SoundFx | `Main_screen/Scenes/SoundFx.tscn` | Audio management |
| 8 | GlobalTimer | `Main_screen/Scripts/global_timer.gd` | Session-wide timer |
| 9 | ScoreManager | `Main_screen/Scripts/score_db.gd` | High score persistence |
| 10 | DebugSettings | `Main_screen/Scripts/debug_settings.gd` | Debug config |
| 11 | AudioManager | `Games/Jumpify/…/AudioManager.gd` | Jumpify audio |
| 12 | SceneTransition | `Games/Jumpify/…/SceneTransition.gd` | Jumpify transitions |
| 13 | GlobalTimerManager | `Main_screen/Scripts/GlobalTimerManager.gd` | Countdown timer with signals |
| 14 | MusicManager | `Main_screen/Scripts/music_manager.gd` | Background music |
| 15 | ButtonSoundManager | `Main_screen/Scripts/button_sound_manager.gd` | Button SFX |
| 16 | CircularTimer | `Games/random_reach/…/circular_timer.gd` | Visual countdown |
| 17 | TrunkMonitor | `Main_screen/Scripts/trunk_monitor.gd` | Trunk posture from the tracker (`TRK:` packets) |

### Data Flow

**Patient flow**: no registry in NOARK. When the main screen opens it runs `sender_raspberryPI.py --sync` on a thread, which fetches `{DOCUMENTS}/NOARK_demo/patients.json` from the server (`{"version", "patients": [{"user_id", "status", "side", "devices"}]}`). `PatientDB` reads it (active patients only; `side` → `affected_hand`), the main screen fills its dropdown, and the id is the server's `user_id`. Offline, the last fetched file is used.

**Login flow**: patient id typed or picked from the suggestion list on the main screen → the dose screen (`Main_screen/Scenes/dose.tscn`, `dose_screen.gd`) confirms/enters the daily therapy dose (appends to `configdata.csv` if new or changed) → `SessionLog.start_session(pid)` (SessionNumber = max in sessions.csv + 1) → 2D/3D mode screen

**Trial flow**: game start → `Manager.create_game_log_file(game_name, patient_id)` → `SessionLog.begin_trial` names the raw file → log rows every ~0.02s → game calls `SessionLog.hit()` / `miss()` → `SessionLog.end_trial()` at game over appends the sessions.csv row. Leaving the scene, starting another trial, or closing the app also ends the trial. Every row written starts `sender_raspberryPI.py --upload {pid}` in the background (`SessionLog.upload`, one at a time, later ones queued); closing the app (window X or an Exit button) shows "Saving the session to the server..." and quits only when the upload is done. Games must not call `get_tree().quit()` on close themselves — `GlobalScript` does it. MoveTime excludes pauses (`GlobalTimer.pause_timer` → `SessionLog.set_paused`).

**Score flow**: Game end → `ScoreManager.update_top_score(patient_id, game_name, score)` → JSON at `{DOCUMENTS}/NOARK_demo/records/scores.json`

**File paths**:
```
{DOCUMENTS}/NOARK_demo/
  patients.json                # from the server (sender_raspberryPI.py --sync); NOARK never writes it
  records/scores.json          # high scores per patient per game
  data/{patient_id}/sessions.csv     # one row per trial (same name/format as the other robots)
  data/{patient_id}/configdata.csv  # therapy dose history; last row is active
  data/{patient_id}/GameData/       # raw trial CSVs
```

See `docs/session_logging_spec.md` for the sessions.csv / configdata.csv columns.
Movement per game: FruitCatcher, PingPong = ML · FlyThrough = AP · RandomReach, FireflyReach = MLAP (`SessionLog.MOVEMENT`).

**Raw filename format**: `raw-sess{NN}-trial{NNN}-{Game}-{Mode}.csv` (trial = nth of that game+mode in the session)
**Raw CSV header**: 7 lines — `headerrows, game_name, h_id, device_location, device_version, protocol_version, start_time`

`pyscripts/rebuild_sessions.py` converts pre-sessions.csv data (old `{game}_S*_T*_{date}.csv` files): dry run by default, `--apply` renames and writes.

### Games

| Game | Path | Mode | Notes |
|------|------|------|-------|
| Flappy Bird | `Games/flappy_bird/` | 2D + 3D | Pipe obstacle avoidance |
| Ping Pong | `Games/ping_pong/` | 2D only | Physics-based paddle game |
| Fruit Catcher | `Games/fruit_catcher/` | 2D only | `fruit.gd` class is named `Gem` |
| Jumpify | `Games/Jumpify/` | 3D only | Platformer with level progression |
| Random Reach | `Games/random_reach/` | 2D + 3D | Most complex; uses shaders and `@onready` dicts |
| Reach Scan | `Games/firefly_reach/reach_assessment.tscn` | — | The workspace assessment; required once a day before any game |
| ~~Assessment~~ | `Games/assessment/` | — | Old workspace assessment, unhooked (Results still uses `workspace.gd` for area maths) |

**Daily assessment gate**: every game button goes through `AssessmentGate.play()` (`Main_screen/Scripts/assessment_gate.gd`). If `reach_boundary.json` (`data/{pid}/`, `ReachStore`) was not saved today, the reach scan runs first and then the chosen game starts (`GlobalSignals.pending_game`). The menus' Assessment button always runs a fresh scan; Esc in the scan returns to the menu without playing. Adapt ROM was removed from all games.

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
0. Launch it from the menu with `AssessmentGate.play(get_tree(), scene)`, never `change_scene_*` directly
1. Call `Manager.create_game_log_file(game_name, patient_id)` when play starts and store the returned handle (session/trial numbering and the debug `vvv` id are handled by `SessionLog`)
2. Log rows via the handle at ~0.02s intervals using a Timer node
3. Call `SessionLog.hit()` / `SessionLog.miss()` per target, and `SessionLog.end_trial()` at game over
4. Pause through `GlobalTimer.pause_timer()` / `resume_timer()` so MoveTime leaves pauses out
5. Close the file handle on game end
6. For 2D/3D support: set `game_name` dynamically via an `is_3d_mode` flag (`"…3D"` suffix → Mode 3D)
7. Add the game to `SessionLog.MOVEMENT` (and `MOVEMENT` in `pyscripts/rebuild_sessions.py`)

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
- The stereo calibration's cam0/cam1 labels need not match rcam's enumeration;
  `device.toml [cameras]` maps them. rcam's order is stable across boots (sorted
  by CSI-PHY id), but it flipped on this rig between 2026-09 and 2026-10-08
  (cables reseated?) — a wrong mapping costs ~140 mm of camera-to-camera
  disagreement and tens of mm of stereo jitter, so re-run the bench after any
  hardware handling.
  `pyscripts/bench_cameras.py` scores both mappings on one take;
  `pyscripts/bench_solvers.py` does the same for the two solvers.

See `pyscripts/README.md` for the calibration workflow.

### Trunk Tracking

The same camera pair sees the patient's torso. `pyscripts/trunk/` turns it into
trunk angles from a captured neutral pose — the realtime port of
`NOARK_backbone/trunkpose/dual_notebooks/07_icp_trunk.py`:
trunk_seg W8A8 on the NPU (torso mask, arms removed) → half-resolution fisheye
SGBM over the torso's box → front-shell cloud → point-to-plane ICP to the
neutral cloud → flexion / lateral / axial and a state machine
(NO_NEUTRAL, CAPTURING, TRACKING, OCCLUDED; per axis OK / WARN / COMPENSATING).

- It runs in **its own process** (`TrunkProcess`), pinned to `trunk_cpus` (core 7).
  A thread was not enough: ICP holds the GIL and took hand tracking from 31 to
  25 fps. As a process it costs hand tracking 1-3 fps at ~11 Hz of trunk updates.
- ICP registers about the neutral centroid, not the camera origin — about the
  origin a 15° lean converged to 64°.
- Thresholds live in `settings.json` (`trunk_warn_deg` 8, `trunk_comp_deg` 15;
  a number or `{"flexion", "lateral", "axial"}`); `trunk_enabled` turns it off — one switch: `TrunkMonitor.enabled()` gates `available()`, which every panel, cue, pause and CSV column asks. Flip it in the main Settings panel or the in-game Tune panel (F2) via `TrunkMonitor.set_enabled()`: saved, and sent as `CFG:trunk=on|off` so the tracker stops/starts trunk work live (first `on` after a disabled start loads the model).
  No NPU / model → the tracker carries on with hand tracking only.
- Godot → tracker `TRUNK:neutral` (the game menus' "Capture neutral posture");
  tracker → Godot `TRK:state,level,lf,ll,la,flex,lat,axi,progress,has_neutral,reason,capture_result,people,locked,q_how,q_rms_mm,q_frac,raw_pts,mask_px,held`.
  The last six are *this frame's* quality (how it fit or why it did not, ICP residual, matched
  share, shell points, mask area, whether the angles are held from the last good frame). Random
  Reach writes them to its raw CSV (`trunk_how` … `trunk_held`) and the tracker prints a journal
  line on every state / level / outcome change, for working out why a reading paused the game.
- **Several people in view:** the subject is the centre-most torso unless picked.
  `TRUNK:snapshot` → the tracker sends a ~160 px JPEG with one outline per person as
  chunked `IMG:` packets (`trunk/snapshot_packet.py`, same over UDP and BLE;
  `TrunkMonitor` reassembles → `snapshot_ready`); `TRUNK:select=<n>` (-1 = centre-most)
  locks onto person n. The lock follows them by mask overlap (IoU ≥ `trunk_lock_iou`
  0.3 with their last mask), not by class, which can flip; if nobody overlaps that much (a fast move, a short occlusion) the lock
  moves to the person nearest its last position, within `trunk_lock_dist` (0.3 of the image
  width); only if nobody is that close are they `lost_subject`. Picking a different person clears the neutral — pick, then capture
  neutral. `person_picker.gd` is the tap-a-mask UI; `trunk_panel.gd` opens it
  by itself when `people > 1` and nobody is picked.
- Random Reach: WARN shows a cue; COMPENSATING beeps, pauses play (and the
  target) and a hit does not score; play resumes after 0.5 s back under WARN.
  Occluded never pauses. Trunk state/level/angles are appended to its raw CSV.
  `Main_screen/Scripts/trunk_feedback.gd` is the overlay any game can add.
- `uv run pyscripts/trunk_live.py --show` tests it without Godot (stop the tracker first).

### BLE transport

`stream_type` in settings.json is `udp` (Godot on the board spawns `tracker.py`)
or `ble` (Godot on an Android tablet; `tracker.py` runs on the board and is a
GATT peripheral). Never both; the tracker and Godot each read the key.

- One notify characteristic carries everything the UDP socket does: the 44-byte
  position packet and the text `TRK:` / `CFG:` packets, told apart by size and
  prefix (`global_script.gd` `_handle_text_packet`). Commands (heartbeat,
  `TRUNK:neutral`, `USER:`, `STOP`) are writes to the command characteristic.
- Over BLE the tracker outlives the app: STOP or 3 s without a heartbeat closes
  the session and it waits for the next connection instead of exiting.
- **Advertising on the Radxa:** the AIC8800's BlueZ advertising fails — the
  kernel rejects the advertising data (MGMT Add Extended Advertising Data →
  Invalid Parameters, on 7.0.11-6/-7-qcom) though the controller accepts it.
  `ble_streamer.py` falls back to `RawAdvertiser`, which sends the HCI commands
  itself through `sudo -n hcitool`; that needs `/etc/sudoers.d/noark-ble`
  (`radxa ALL=(root) NOPASSWD: /usr/bin/hcitool`), set up per board.
- `uv run pyscripts/ble_test.py` advertises the same service with a fake hand
  circle, no cameras. `external/GdAndroidBLE/` (submodule) is the Android plugin; its
  `plugin/demo` is a test app for the tracker over BLE. Build with
  `./gradlew assemble` there (Java 17 + Android SDK — not on the Radxa).

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
PatientDB.load_database()       # re-read patients.json after a sync
PatientDB.get_patient(hospital_id)
PatientDB.list_all_patients()   # Array of {hospital_id, name, affected_hand}
PatientDB.current_patient_id

GlobalSignals.current_patient_id  # mirrors PatientDB
GlobalSignals.data_path           # {DOCUMENTS}/NOARK_demo/data
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
