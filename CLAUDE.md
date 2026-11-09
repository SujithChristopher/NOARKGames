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

**Settings** live at `{DOCUMENTS}/NOARK_demo/settings.json` (this `demo` branch uses `NOARK_demo` — `Settings.APP_DIR` — so the real `{DOCUMENTS}/NOARK` data is never touched), not in the repo — `res://` is read-only in an export. The `Settings` autoload (first in the list) loads/saves it and seeds it from defaults on first run; the main scene has a Settings panel for it. `location` (the site written to sessions.csv and raw logs) is set from the login dose dialog. The tracker reads the same file on the board (default path; `--settings` overrides).

**Debug mode** means the mouse instead of the tracker, in every game, and it is the only way to play without one. Settings > Tracker > Debug, or that file. Every script asks `Settings.is_debug()` at the time (no autoload keeps a copy), and a game gets its patient from `SessionLog.current_patient()` (vvv in debug). A game asks the tracker for nothing (`GlobalScript.tracking_mode()`), so a tracker that is running changes nothing and trunk never pauses play. A red banner (`debug_banner.gd`) stays on every screen, because a real patient's session played in debug is logged as vvv and never uploaded. Without debug and without a tracker, games wait for it.
```json
{"debug": true}   // patient ID = 'vvv', no upload, mouse instead of the tracker; Random Reach logs nothing
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

**Architecture**: `pyscripts/tracker.py` detects AprilTags on both cameras, solves one pose for the calibrated rigid body, and sends it to the app as POSITION messages over UDP or BLE (`docs/PROTOCOL.md`). Godot's `GlobalScript` receives and scales these to screen coordinates.

There is **no temporal smoothing**: `ExponentialMovingAverageFilter3D` is constructed with `alpha=1`, which passes the input straight through. Smoothness comes from the geometry, not from a filter — so a jitter problem is a calibration or camera-mapping problem, and reaching for a filter would only hide it. `CornerStabilizer` freezes the pose when no contributing corner has moved, which saves the solve but measured no change to noise.

## Architecture

### Autoload System (Global Singletons)

Order in `project.godot` is critical — later autoloads can depend on earlier ones:

| # | Name | Script | Purpose |
|---|------|--------|---------|
| 1 | Settings | `Main_screen/Scripts/settings.gd` | User settings file (must be first) |
| 2 | PatientDB | `Main_screen/Scripts/patient_db.gd` | Patient list from the server's patients.json, and the sync that fetches it |
| 3 | SessionLog | `Main_screen/Scripts/session_log.gd` | Per-patient sessions.csv, trial numbering, therapy dose |
| 4 | Manager | `Main_screen/Scripts/manager.gd` | Raw trial CSV creation |
| 5 | GlobalSignals | `Main_screen/Scripts/global_signals.gd` | Signal bus + shared state |
| 6 | GlobalScript | `Main_screen/Scripts/global_script.gd` | UDP, screen scaling |
| 7 | SoundFx | `Main_screen/Scenes/SoundFx.tscn` | Audio management |
| 8 | GlobalTimer | `Main_screen/Scripts/global_timer.gd` | Session-wide timer |
| 9 | ScoreManager | `Main_screen/Scripts/score_db.gd` | High score persistence |
| 10 | AudioManager | `Games/Jumpify/…/AudioManager.gd` | Jumpify audio |
| 11 | SceneTransition | `Games/Jumpify/…/SceneTransition.gd` | Jumpify transitions |
| 12 | GlobalTimerManager | `Main_screen/Scripts/GlobalTimerManager.gd` | Countdown timer with signals |
| 13 | MusicManager | `Main_screen/Scripts/MusicManager.gd` | Background music |
| 14 | ButtonSoundManager | `Main_screen/Scripts/btn_sound_manager.gd` | Button SFX |
| 15 | CircularTimer | `Games/random_reach/…/circular_timer.gd` | Visual countdown |
| 16 | TrunkMonitor | `Main_screen/Scripts/trunk_monitor.gd` | Trunk posture from the tracker (TRUNK_STATUS messages) |
| 17 | DeviceAgent | `Main_screen/Scripts/device_agent.gd` | Patient lock, through `agent.py` on 127.0.0.1:5055 |

### Data Flow

**Patient flow**: When the main screen opens it calls `PatientDB.sync()`, which runs `sender_raspberryPI.py --sync` on a thread (in the autoload, so leaving the screen never waits for it; only quitting does), which fetches `{DOCUMENTS}/NOARK_demo/patients.json` from the server (`{"version", "patients": [{"user_id", "status", "side", "devices"}]}`). `PatientDB` reads it (active patients whose `devices` include NOARK — `assessment_devices` alone does not count; `side` → `affected_hand`), the main screen fills its dropdown, and the id is the server's `user_id`. Offline, the last fetched file is used; connecting gives up after 3 s (`CONNECT_TIMEOUT_SECONDS`), while a connected server gets its full timeout to reply. The **Refresh** button beside the patient box syncs again without leaving the screen. The main screen's **New Patient** button (where Set Origin was — the origin comes from Define Table) creates a patient on the device with just an id and training hand (left/right/both): `PatientDB.add_local_patient()` writes `local_patients.json` beside patients.json in the same shape, so a sync never overwrites it; they are tagged "(this device)" in the list. Once the server lists the same id, the local entry is dropped from that file, so a later server removal removes the patient here too.

**Login flow**: patient id typed or picked from the suggestion list on the main screen → the dose screen (`Main_screen/Scenes/dose.tscn`, `dose_screen.gd`) confirms/enters the daily therapy dose (appends to `configdata.csv` if new or changed) → `DeviceAgent.start(pid)` claims the patient on the server, refused while another device is training them (a network fault never stops therapy: the login goes through without the lock) → `SessionLog.start_session(pid)` (SessionNumber = max in sessions.csv + 1) → 2D/3D mode screen. `agent.py` is started by the app if it is not running, stays up after it closes, and never runs in debug or on Android; a trial's end renews the claim, logging out or closing releases it.

**Trial flow**: game start → `Manager.create_game_log_file(game_name, patient_id)` → `SessionLog.begin_trial` names the raw file → log rows every ~0.02s → game calls `SessionLog.hit()` / `miss()` → `SessionLog.end_trial()` at game over appends the sessions.csv row. Leaving the scene, starting another trial, or closing the app also ends the trial. Every row written starts `sender_raspberryPI.py --upload {pid}` in the background (`SessionLog.upload`, one at a time, later ones queued); closing the app (window X or an Exit button) shows "Saving the session to the server..." and quits only when the upload is done. Games and Exit buttons must not call `get_tree().quit()` themselves — they call `GlobalScript.request_quit()` (what the window X does), which also releases the patient lock. MoveTime excludes pauses (`GlobalTimer.pause_timer` → `SessionLog.set_paused`).

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
Movement per game: FruitCatcher, PingPong = ML · FlyThrough = AP · RandomReach, FireflyReach = MLAP · CannonDefense = ROT (`SessionLog.MOVEMENT`). ROT is scored but is not one of the dose's movements (`SessionLog.MOVEMENTS`), so it counts towards no daily dose.

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
| Cannon Defense | `Games/cannon_defense/` | 2D only | Aim by **turning** the handle (orientation, not position); see below |
| ~~Assessment~~ | `Games/assessment/` | — | Old workspace assessment, unhooked (Results still uses `workspace.gd` for area maths) |

**Experiments** (main menu's Experiments button, no patient or login): `Experiments/experiment_menu.gd` lists them (`EXPERIMENTS`: a row and a scene per experiment). **Static grid** (`static_grid.gd`) lays a grid over the defined table (default 4 x 6, 50 mm margin, snaking from the top-left), highlights a point, and once the device has been inside it (15 mm) and still (within 5 mm) for 1 s the tracker saves 30 solved frames and the next lights up; all editable on its setup screen. A capture in which the device moved past that 5 mm is kept but not accepted, and the point is asked for again. The app decides where and when; the tracker writes everything, on the board (EXPERIMENT, `pyscripts/experiment.py`), to `{DOCUMENTS}/NOARK_demo/experiments/<experiment>/<label>_<date>_<time>/` (the label is the name or number that must be typed before Start): pose per frame, images per frame through `FrameRecorder` with every frame kept at full size (`recording_fps` / `recording_scale` do not apply), the mocap trigger's edges and a once-a-second camera phase log for the whole run (each capture's edge count, first rise and phase in targets.csv), a snapshot of the calibration; columns in `docs/DATA_FORMATS.md`. About 1.4 GB a run; Settings > Storage does not list them. It needs the tracker (no mouse in debug) and the table's corners, which `table.json` only keeps since this screen: a table defined earlier must be defined again. The expected points come from the tracker-measured corners, so this measures precision, not accuracy.
**Continuous raw capture** (`continuous_raw.gd`) is the two camera feeds and the trigger only: one Start | Stop button, each Start its own folder (metadata.json, recording/, calibration/; no poses.csv or targets.csv), no time limit (only Stop ends it, or the tracker when the disk is down to 5 GB, `MIN_FREE_BYTES`: reason `disk_full`), and a frame rate as Settings > Recording's (15/30/60/90/every frame, starting at `recording_fps`; kept on sensor time by `FrameRecorder`, `start ... raw <fps>`). It is a raw run (`start ... raw`): the tracker skips tag detection and the pose for its whole length (`Experiments.images_only`, early return in `process_frame`) so the cores go to writing frames, but still sends the Camera tab's preview (CONFIG `preview=on`, both feeds at 320x200 each, ~5 Hz; UDP only, over BLE the picture needs the hotspot that only Settings > Camera joins). ~12 GB a minute at 100 fps.
**Random Reach** (`reach_play.gd` setup → `reach_play_scan.gd` → Random Reach 2D with `reach_play_game.gd` beside its player; state shared in `reach_play_run.gd`'s static vars) asks for a name, the frame rate saved (as raw capture's), the image size saved (full / half / quarter of each side) and the game time; Start opens a `play` run (`start reach_play <frames> <label> play <fps> <scale>`), then the workspace scan (not recorded; its outline goes into the run's folder, not to a patient), then the game, at once for that time with no timer selector. `record` at play, `stop` at game over or on leaving (no restart). The tracker keeps tracking at full rate on full frames; only what is saved follows the choice, frames kept on sensor time. It writes images + poses.csv (one row per pair saved); the app writes `reach_boundary.json` and `random_reach.csv` into its own `experiments/reach_play/<run>/` (the same folder on the board). No patient, scores, sessions.csv or upload; in debug too the scan and game take the tracker (round_runner `config.tracker`). A full disk ends the game early. If the mocap trigger is HIGH when the time is up, play stays frozen but the recording goes on ("Waiting for the mocap to stop", with Stop without waiting) until it goes LOW plus 0.5 s (`SYNC_TAIL_S`), so the recording spans the mocap's whole take; `game_end` in metadata.json says how it ended. Load Random Reach on a background thread (`Run.warm_game`): loading it on the main thread at the scan's end stopped the heartbeat over 3 s and the tracker closed the run as `link_lost`.
**Every experiment screen shows the mocap trigger** (`sync_indicator.gd`, top centre: HIGH green / LOW grey, edge count, flashes amber on an edge): EXPERIMENT `watch on` makes the tracker open the sync line itself while no run holds it (a run's recorder has it then), and EXPERIMENT_STATUS carries `sync`. A new experiment screen adds one. If session recording holds the line it shows NO LINE.

**Daily assessment gate**: every game button goes through `AssessmentGate.play()` (`Main_screen/Scripts/assessment_gate.gd`). If `reach_boundary.json` (`data/{pid}/`, `ReachStore`) was not saved today, the reach scan runs first and then the chosen game starts (`GlobalSignals.pending_game`). The menus' Assessment button always runs a fresh scan; Esc in the scan returns to the menu without playing. Adapt ROM was removed from all games. Random Reach (2D) places each apple, the whole catch circle, inside that outline (`Games/random_reach/Scripts/reach_area.gd`: the outline turned into the game's pixels by the hand's own mapping, `table_k` or the scaler plus the screen centre, minus Zero), within its usual 200–900 x 200–600 box; with no room there it falls back to the box (`apples_outside_outline`). For the eye only, the game draws that workspace scaled onto the apple area (`ReachArea.view_fit`: the outline's bounding box centred on 200–900 x 200–600, one gain for both axes, 0.5–4x): the sheep at the scaled hand, apples placed and caught in the drawn space. Everything logged (`device_*`, `target_*`, `player_*` in the raw CSV; the tracker's poses) is real, taken back through `_view_inv`. Identity with no outline, and in 3D. The experiment uses its run's own scan. Firefly Reach uses the outline too; the other games do not.

**Cannon Defense** aims a cannon by the handle's rotation (`GlobalScript.hand_rotation()`; the game calls `GlobalScript.want_rotation(self)`, so the tracker sends ROTATION — the rvec — instead of POSITION while it runs). Each game start calibrates on two poses, each taken with Enter (keyboard only for now, so a tablet needs one): where the turn starts (initial) and as far as it goes (max) (`rotation_input.gd`). Both are usually extremes of what the arm allows — a right hand cannot turn further right than where it starts — so there is no middle: that one range is the whole ±65° arc, initial at the training hand's own end (right hand the right end, left hand the left, unknown as the right). The rotation axis is *measured* from initial to max, not assumed, so it works for forearm rotation, wrist deviation or a dial turn with any grip; the aim is the swing-twist angle about that axis, and `rot_deg` in the raw CSV is that angle from initial. Meteors fall straight at the cannon so each asks for one fixed angle; holding the aim on one for 0.4 s fires (no button). Play holds (meteors freeze, MoveTime and countdown pause) on pause, trunk compensation (as Random Reach) and the handle out of view. Raw CSV per frame plus `<raw name>_targets.csv` (one row per meteor, calibration in its header). In debug the mouse aims and there is no calibration.

**Look and feel** (Random Reach, FlyThrough, Ping Pong, Fruit Catcher): scenery and feedback are drawn in code and are decoration only — no collision shape, target position, speed or timing depends on them. `Main_screen/Scripts/game_fx.gd` (`GameFx`) holds the shared effects: particle burst, floating text, HUD pulse, outlined text, and `dim_behind` (pause/game-over backdrop; raises the panel to z 10, over the sprites). Random Reach: `meadow.gd` (grass shader, flowers, wooden frame over the hidden brick tiles, clouds in 3D) and `player_fx.gd` (shadow, jet smoke, lean); the apple draws its own time ring and gold eating ring. FlyThrough: `sky_scenery.gd` (parallax clouds and pines, scrolling ground; the old ground sprite is hidden, its collision kept); `pipe.gd` draws sandstone pillars and a gold hoop in the gap. Ping Pong: `table_court.gd` draws the table and adds `paddle_skin.gd` / `ball_skin.gd`. Fruit Catcher: `forest_scenery.gd` (sunbeams, drifting light, ground shadows; dresses the basket and squashes it on a catch). Every fruit is drawn at one size in game units (`Gem.SIZE`, 64 of the 1152 width) and its hit circle is the fruit's body — it once scaled by the screen's DPI, so fruit size and catch tolerance changed from screen to screen. `GameFx.shrink` trims a big sprite and shrinks it with mipmaps, so it does not shimmer when drawn small. Ping Pong's predicted ball path (`show_trajectory` in `ball.gd`) now shows — before, its Line2D was added while the scene was still setting up and never appeared.

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

`Results/` contains `parse_files.gd` and `user_progress.gd/.tscn` for visualizing CSV session data. Charts are drawn by `Results/Scripts/line_chart.gd` (`LineChart`, a plain `_draw()` Control: `plot(x_labels, [{name, values, color}])`) — no chart addon.

## Critical Implementation Details

### Adding a New Game
0. Launch it from the menu with `AssessmentGate.play(get_tree(), scene)`, never `change_scene_*` directly; give it a tile in the menu's .tscn and a row in its `_game_tiles()` (colour + picture)
1. Add a `GameSession` (`Main_screen/Scripts/game_session.gd`) last in `_ready`:
   `GameSession.new(game_name, COLUMNS, _log_row, $CircularTimer)`, connect `started` (begin play) and
   `time_up` (game over). It shows the timer selector, runs the countdown, writes the raw CSV at 50 Hz
   (`epochtime` + your columns, a `Final Score:` line at the end), and ends the trial however the scene
   is left. The game adds to `session.score` and calls `pause()` / `resume()` (MoveTime and the
   countdown together), `finish()` at game over (returns the best score), `retry()` and `to_menu()`.
   FruitCatcher, PingPong and FlyThrough use it; Random Reach, Jumpify and Cannon Defense still carry
   their own copy of this.
2. Call `SessionLog.hit()` / `SessionLog.miss()` per target
3. For 2D/3D support: set `game_name` dynamically via an `is_3d_mode` flag (`"…3D"` suffix → Mode 3D)
4. Add the game to `SessionLog.MOVEMENT` (and `MOVEMENT` in `pyscripts/rebuild_sessions.py`)
5. Add its scene to `SCENES` in `tests/smoke_test.gd`; a scene with a `GameSession` also gets a short
   trial run through it (raw header, row widths, Final Score, sessions.csv row, retry)

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
  uncalibrated rig still starts. GDScript no longer carries a copy — the tracked
  point arrives as POSITION.
- Stereo refinement is off unless the calibration carries a self-calibrated
  extrinsic: with a multi-tag board it measured no better than one camera
  (1.19 mm vs 1.02 mm jitter) at four times the cost.
- The two choices that change tracking live in `settings.json`, because the
  `noark-tracker` service starts `tracker.py` with no arguments — a flag cannot
  affect a real session. `tracker_solver` is `joint` (fit every visible corner)
  or `ransac` (rapidtag's consensus fit, dropping corners that disagree);
  `tracker_camera` is `both`, `cam0` or `cam1`. `device.toml` describes the rig;
  settings.json says how to use it and wins where both speak.
- The stereo calibration's cam0/cam1 labels need not match rcam's enumeration;
  `device.toml [cameras]` maps them. rcam sorts by CSI-PHY id, yet the right mapping has
  changed with no cable touched, apparently at a reboot: an open bug, see
  `docs/camera_stream_swap.md`. A wrong mapping costs ~150 mm of camera-to-camera
  disagreement and tens of mm of stereo jitter, so re-run the bench if tracking looks wrong
  after a reboot.
  `pyscripts/bench_cameras.py` scores both mappings on one take;
  `pyscripts/bench_solvers.py` does the same for the two solvers.

**Frame rate:** the cameras run as fast as the exposure allows unless `tracker.py --fps` caps them
(`fastest_blanking` in `stereo_capture.py`): frame length = exposure + 25 lines, at least 910 lines. So 10 ms gives about
98 fps, and changing exposure live moves the frame period. It has to be set: the sensor's own default is about 60 fps. What a
recording saves is separate, `recording_fps` in settings.json (0 = every frame), kept by the sensor timestamp.

**Following the body (`tracker_refine` = `multistage`, `pyscripts/body_search.py`):** instead of
searching the whole frame, each camera searches one window around the whole rigid body: every tag projected
through the last pose, joined with the corners that camera last saw, moved on by the window's last step. Then
rapidtag's `MultiStageRefiner` (0.1.12) sharpens the corners and re-finds a missed tag from its track. A camera
gets a full search every 60 frames; with nothing to follow, both search in full every frame. A calibration take
always searches in full. `[SEARCH]` in the journal says how much of the frame was searched. Not per-tag crops, by choice.
Tested on recordings and synthetic tags, not yet live on this rig. Calibrate in the same mode you track in.

**From the app (Settings > Calibration, `calibration_tab.gd`):** after a tag is moved, swapped or
added, no terminal needed. **One tag stays fixed** (`[tip] tag` in device.toml, tag 1 unless changed): the tracked point's
offset is measured from it and is kept, and "moved" means relative to it. The tab's Tracked point card picks that tag and
its x, y, z offset (mm on screen, BODY `tip` in metres, saved in device.toml's `[tip]`, so it works from a tablet); it applies
at once if the calibration in use has the tag, otherwise with the first take that includes it. The tracker takes the
take from its own frames while tracking continues (`pyscripts/body_take.py`: corners only, 10 pairs a
second, 60 s, same exposure, ISP and refine as tracking; no pose is solved meanwhile), runs the solve as
its own niced process (`body_solve.py`, about 2 minutes; the cameras go off meanwhile), and the app shows
each tag as same place / moved / new / gone / left out. Nothing changes until Save, which backs up
`rigidbody.toml` under `calibration/takes/` (git-ignored, with the take and the log) and swaps the body
in with no restart; "Put the previous one back" undoes it. Any tag id is accepted, unlike
`rigidbody_calib.py`, which filters by `tag_ids`; Save adds new ids to that list. A tag that does not move
with the device (`_moves_together`: over 20 mm or 10° of spread) is left out before the slow stage: one
fixed in the room took the solve past 8 minutes. A take is refused if the device barely turned (under 15°,
`MIN_TURN_DEG`), which otherwise passes every other check. If every other tag moved it warns that tag 1
itself may have. Not handled: a different printed tag size (device.toml).

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
  a number or `{"flexion", "lateral", "axial"}`); `trunk_enabled` turns it off — one switch: `TrunkMonitor.enabled()` gates `available()`, which every panel, cue, pause and CSV column asks. Flip it in the main Settings panel or the in-game Tune panel (F2) via `TrunkMonitor.set_enabled()`: saved, and sent as CONFIG `trunk=on|off` so the tracker stops/starts trunk work live (first `on` after a disabled start loads the model).
  No NPU / model → the tracker carries on with hand tracking only.
- **Two ways to measure the rotation**, `trunk_method` in settings.json (main Settings
  panel, Tune panel, live as CONFIG `trunk_method=…`; a switch clears the neutral):
  `icp` (above) or minisam3d (`trunk/pose.py`): `msam_r18` / `msam_v3rot`, the
  upper-body pose student from `E:/NOARK_CV/minisam3d` (W8A16 QDQ on the NPU, AI Hub
  jobs `j56ojzy65` / `j5wy9o3jg`), one camera, no SGBM. It crops from the trunk_seg
  subject box (then from its own keypoints), predicts the c_spine3 segment rotation,
  and the angles are that rotation relative to neutral, through the same
  `trunk_angles` and state machine — TRUNK_STATUS is the same either way. r18 is the
  better one (0.5–0.6° frame-to-frame jitter vs ~1°); ~10 ms a frame on the NPU.
  `trunk_reference` (`neutral` | `model`; Settings, the Trunk angles screen's "Model frame"
  switch, Tune panel, live as CONFIG): `model` measures the minisam3d angles from the model's own
  frame instead of a captured neutral — its rotations are MHR global joint rotations in camera axes,
  which carry c_spine3's bind orientation: upright, squarely facing a level camera reads as the axis
  permutation `MODEL_REST`, not identity (measured from the model's own joints; `model_frame()` in
  trunk/tracker.py). With identity every frame sat ~126° off and was gated. No
  capture, no NO_NEUTRAL, no re-neutral after occlusion; camera tilt reads as a constant offset
  (not corrected, by choice). Games, warnings and CSVs use these angles as they would neutral ones,
  with their own thresholds `trunk_model_warn_deg` 15 / `trunk_model_comp_deg` 25. "Set zero" (the
  capture button in the model frame, TRUNK `neutral`) makes a held-still pose read 0 on the
  model frame's (camera) axes; "Clear zero" (TRUNK `zero_clear`) goes back to the model's rest pose.
  icp ignores it. TRUNK_STATUS's last field says which is in use.
  Re-quantize after any retrain (minisam3d `scripts/npu_quantize.py`) and copy
  `model.onnx` + `model.data` into `trunk/models/minisam3d_*_w8a16/`.
- `trunk_rot180` (`auto`): trunk_seg and the student only work upright, and the rig
  is mounted both ways (the Oct-10 sessions are upside down, the Oct-14 bench
  upright). Auto tries the other way when no torso is found; masks are rotated back,
  so the stereo geometry never sees the rotation.
- Godot → tracker TRUNK `neutral` (the game menus' "Capture neutral posture");
  tracker → Godot TRUNK_STATUS `state,level,lf,ll,la,flex,lat,axi,progress,has_neutral,reason,capture_result,people,locked,q_how,q_rms_mm,q_frac,raw_pts,mask_px,held,hz,method,doubt`.
  The last six are *this frame's* quality (how it fit or why it did not, ICP residual, matched
  share, shell points, mask area, whether the angles are held from the last good frame). Random
  Reach writes them to its raw CSV (`trunk_how` … `trunk_held`) and the tracker prints a journal
  line on every state / level / outcome change, for working out why a reading paused the game.
- **Several people in view:** the subject is the centre-most torso unless picked.
  TRUNK `snapshot` → the tracker sends a ~160 px JPEG with one outline per person as
  one SNAPSHOT message (`trunk/snapshot_packet.py`, chunked by the link over either transport;
  `TrunkMonitor.on_snapshot` → `snapshot_ready`); TRUNK `select=<n>` (-1 = centre-most)
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
- **Scoring a method against ground truth:** `"trunk_debug": true` in settings.json (read at
  tracker start) logs every trunk update next to the rigid body's pose to
  `{DOCUMENTS}/NOARK_demo/trunk_debug/trunk_*.csv`, plus a `[TRUNK-DBG]` journal line a second
  and the neutral frame's offset from the camera at capture. Strap the hand device to the
  sternum, capture neutral, lean / twist each way; `uv run pyscripts/trunk_score.py` prints
  each method's cross-talk matrix (diagonal = gain per axis, off-diagonal = leak). Measured
  2026-10-21 (v3rot): the flexion / lateral / axial split matches the camera-axes rotation
  1:1 (neutral frame 8–11° off the camera) — axis leaks seen live come from the model.
- **Occlusion (minisam3d):** an arm or object in front of the chest bends the student's rotation
  5–10° while its neck/shoulder heatmap confidence drops. Per model, `trunk_msam_min_conf`
  (r18 2.5) drops the frame (held, then OCCLUDED) and `trunk_msam_doubt_conf` (r18 2.9) or a
  wrist/elbow inside the chest outline (`pose.arm_over_chest`) marks it `doubt`: shown, but no
  warning/pause and kept out of a neutral capture. TRUNK_STATUS carries it; the Trunk angles graph
  shades those stretches light yellow; Random Reach logs `trunk_doubt`. OCCLUDED for
  `trunk_reneutral_s` (10 s) drops the neutral (`capture_result` "away"): people rarely sit back
  down the same way.

### App ↔ tracker link (UDP or BLE)

`docs/PROTOCOL.md` is the spec. One protocol over both transports: a type byte
per message, commands with a sequence number acknowledged by the tracker, chunks
for big messages, heartbeats both ways.

- The tracker is the `noark-tracker` systemd service on the board over **both**
  transports; Godot never starts it, it connects (HELLO) and the session ends on
  STOP or 3 s of silence, the tracker running on.
- **Idle unless a game runs:** the cameras, tag detection and trunk tracking are off
  until Godot sends CONFIG `track=position`. `GlobalScript._update_tracking` sends it while
  the current scene is under `res://Games/` (not in debug) or a node called
  `GlobalScript.hold_tracking(self)` (trunk panel in the game menus when trunk is on and not in debug,
  Trunk angles, Define Table, Settings > Camera and > Calibration); `track=rotation` while a node that called
  `GlobalScript.want_rotation(self)` is in the tree (Cannon Defense) — the tracker then
  sends ROTATION (the rvec) instead of POSITION, never both; everywhere else `track=off`. The cameras take 2–5 s to
  come up (own thread; the link keeps answering) and go off `camera_idle_off_s` (20 s)
  after. Recordings cover only tracked stretches. Idle measured ~98% CPU free, 71 °C
  falling (tracking: ~170% CPU, 85–87 °C). The tracker's state rides on
  TRACKER_HEARTBEAT; the main menu's status dot shows it (cameras off / starting / tracking).
  A new screen that needs the hand outside `res://Games/` must call `hold_tracking`.
- **Restart tracker** (main menu): RESTART over the link (the tracker exits 75,
  systemd restarts it); if the tracker does not answer and the app is on the board,
  `sudo -n systemctl --no-block restart noark-tracker`, which needs
  `/etc/sudoers.d/noark-tracker` (`radxa ALL=(root) NOPASSWD: /usr/bin/systemctl --no-block restart noark-tracker`).
  Main-menu buttons are styled in code by `Main_screen/Scripts/game_button.gd`
  (`GameButton.apply(button, colour, size)`), layout stays in the .tscn.
  The 2D/3D game menus (`select_game.tscn`, `3d_games.tscn`) both extend `game_menu.gd`:
  header (patient, 2D/3D switch, training hand), a Games card kept apart from the
  Progress card (Assessment, Results, Trunk Angles), Log out / Exit, the hand question.
  Each menu's `_game_tiles()` gives `[button, colour, picture]`; pictures come from
  `menu_icons.gd` — `MenuIcons.art()` shrinks a game's own sprite, `MenuIcons.svg()`
  rasterises an SVG kept there (the games drawn in code, and the tools), no import step.
  `stream_type` in settings.json picks `ble` (the default; Godot on a tablet)
  or `udp` (Godot on the board), also in the Settings screen; the tracker and Godot each read it, in one place each.
- Python: `protocol.py` (wire format), `link.py` (acks, chunks, heartbeat,
  liveness), `udp_streamer.py` / `ble_streamer.py` (bytes only). Godot:
  `link_protocol.gd`, `tracker_link.gd`, `udp_transport.gd` / `ble_transport.gd`;
  `GlobalScript.link` is the link, `link_status` drives the status dot.
- The main menu's **Settings** button opens its own scene (`Main_screen/Scenes/settings_screen.tscn`,
  `settings_screen.gd`). Its look is one Theme in `settings_style.gd` (`Style`), modelled on a bedside monitor rather than the
  games: a tab names what a thing is (`"Card"`, `"Helper"`, `"PrimaryButton"`) and takes colours from `Style`; blue is something
  to press, green / amber / red how a reading stands; the typeface is Atkinson Hyperlegible Next (no µ: it falls back to Godot's font).
  A rail on the left picks the tab (`_tabs` is a TabContainer with its own tabs hidden) and shows the link's state. Tabs: a Tracker tab (settings.json, incl. the UDP/BLE choice, applied live), a Camera tab (`camera_tab.gd`), a Calibration tab (`calibration_tab.gd`, under Marker Geometry) and a Storage tab (`storage_tab.gd`) that lists and deletes
  the board's camera recordings through the tracker (STORAGE command,
  `pyscripts/storage.py`), so it works from a tablet too. Only recordings —
  never game data, sessions.csv or position CSVs — and never the one in progress.
- The **Camera tab** sets exposure and gain live: CONFIG `exposure` / `gain`, saved on
  letting go as `camera_exposure_us` / `camera_gain` in settings.json (until then `device.toml`'s
  apply; calibration always uses `device.toml`). A tablet cannot reach the board's file, so over
  BLE the tracker saves what changed when the tab closes. While it is shown it holds tracking and sends
  `preview=on`, and the tracker sends CAMERA_STATUS (2 Hz: what the sensors report, image level,
  % blown out, tags per camera, fps) and PREVIEW (5 Hz: both cameras, 640×200 JPEG, tags outlined;
  `pyscripts/camera_view.py`). An ACK only says the value was accepted: with the ISP on, rcam writes
  the sensor on the next frame, so the read-back is in the status. The sensor caps exposure at the
  frame period (~16.4 ms); short exposures can pulse under 50 Hz lights (`device.toml` has the numbers).
  **Over BLE** the numbers stay on BLE and the picture goes over the board's own hotspot, as Quick
  Share does: `preview=on` starts it (`pyscripts/hotspot.py`, root helper `setup/noark-hotspot`,
  installed once with `sudo pyscripts/setup/setup_board.sh [COUNTRY]`), the status's `wifi` field
  says when it is up, the tablet joins (`android_wifi.gd`, GdAndroidBLE `wifi_join`, Android's
  `WifiNetworkSpecifier`, password typed once per board, never sent over BLE) and pictures come over
  UDP (`picture_link.py` / `picture_link.gd`, docs/PROTOCOL.md). The AIC8800 runs the hotspot beside its
  normal Wi-Fi on a second interface; udev renames that interface and renaming it back breaks
  wpa_supplicant. Without the hotspot the tab still works on the numbers.
- Changing a setting: the Settings panel sends it live as a CONFIG; at every HELLO
  the tracker also re-applies the live keys from its own settings.json. Anything
  else (camera hardware such as `isp`, `stream_type`, trunk thresholds, `display`) is read when
  the tracker starts, so the Settings screen restarts it after saving (RESTART over the link, no
  password). Nothing holds the board's password: what needs root has its own sudoers line, from
  `sudo pyscripts/setup/setup_board.sh`, once per board.
- Godot and the tracker must speak the same `VERSION` (protocol.py /
  link_protocol.gd): a tablet APK built before a protocol change will not
  connect — rebuild it with the board's code.
- **Advertising on the Radxa:** the AIC8800's BlueZ advertising fails — the
  kernel rejects the advertising data (MGMT Add Extended Advertising Data →
  Invalid Parameters, on 7.0.11-6/-7-qcom) though the controller accepts it.
  `ble_streamer.py` falls back to `RawAdvertiser`, which sends the HCI commands
  itself through `sudo -n hcitool`; that needs `/etc/sudoers.d/noark-ble`
  (`radxa ALL=(root) NOPASSWD: /usr/bin/hcitool`), set up per board.
- `uv run pyscripts/ble_test.py` advertises the same service and link with a fake
  hand circle, no cameras. `external/GdAndroidBLE/` (submodule) is the Android
  plugin; its `plugin/demo` is a test app (still on the old wire format). Build with
  `./gradlew assemble` there (Java 17 + Android SDK — not on the Radxa).

### Network Position
- `GlobalScript._apply_position` turns each POSITION into `net_x, net_y, net_z, net_a`
- 2D scalers: `PLAYER_POS_SCALER_X`, `PLAYER_POS_SCALER_Z`
- 3D scalers: `PLAYER3D_POS_SCALER_X`, `PLAYER3D_POS_SCALER_Y`
- Positions are clamped to `MIN_X/MAX_X/MIN_Y/MAX_Y` screen bounds

### Modifying Autoloads
- Order in `project.godot` matters — `PatientDB`, `Manager`, `GlobalSignals` must initialize before any game scene
- Debug mode is `Settings.is_debug()`, read when needed; do not cache it in another autoload

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

## Tests

```bash
python tests/smoke.py                     # every game scene headless (~1 min); GODOT=<path> if not on PATH
python pyscripts/tests/test_parity.py     # constants GDScript and Python both keep
```

- **Stop `noark-tracker` before running `smoke.py` on the board.** Its Settings checks can reach a live tracker over UDP: on 2026-11-06 a run sent a real `tip 3` and rewrote `device.toml` and `rigidbody.toml`.
- `tests/smoke_test.tscn` opens each game (both modes where it has two), the menus, Trunk angles and
  Results for 120 frames; `smoke.py` fails on any `ERROR` / `SCRIPT ERROR` Godot prints and names the
  scene. It runs in debug in memory only, with the data folder in Godot's user dir — never patient
  data, never an upload; it also fails if `agent.py` gets started. A new game scene goes in its
  `SCENES` list. The login screens (`main.tscn`, `dose.tscn`) are only loaded, because opening them
  talks to the server; the main screen is also opened with a stand-in for the sender (`PatientDB.sync_command`).
- `test_parity.py` checks the protocol `VERSION`, `MOVEMENT` and the app folder (`Settings.APP_DIR`)
  agree between the GDScript and Python copies.
- `pyscripts/tests/` also holds the tracker's synthetic tests; each runs as `python <file>`.
  `test_experiment.py` is a run with made-up frames through the real `FrameRecorder`.
  `test_camera_live.py` and `test_body_live.py` need the board: a client against the running tracker
  and real cameras. `test_body_take.py` needs the board's venv: takes with a known answer through the
  real solve, no cameras.
