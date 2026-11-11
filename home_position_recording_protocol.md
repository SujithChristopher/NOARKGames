# Home-position reach recording: protocol

Draft, 2026-11-11. Follow-up to the `reach_play` session (2026-11-09, analysis in
`docs/results/trunk_visibility_game_takes.md`). The game side is built in the game repo;
this document lists what the recording needs from it and how the takes will be analysed here.

## 1. Why this recording

`reach_play` showed four things that a recording with a fixed home pose can resolve:

| Finding on reach_play | Consequence | What fixes it |
|---|---|---|
| The subject never returns to a fixed pose. Only the start of the take can be the reference. | Slow drift shows up as 3-5 deg offsets in every method: the subject slides ~6 cm forward on the seat over the wtc take, and the sternum plate curls/tilts ~4-5 deg early in the game take. | Hold a home pose between reaches; re-zero on every hold. |
| All camera methods under-read flexion (gain 0.4-0.65 vs the sternum plate). | Re-zeroing cannot fix a gain. | Isolated calibration movements; pelvis + upper-back markers to tell hip lean from thoracic curl from plate tilt. |
| Student/teacher read sideways lean low (gain 0.70-0.79) and twist high (1.32-1.36) on wtc. A Kabsch check found no orientation-convention error, so this is a per-axis gain. | Working hypothesis: the networks follow the shoulder girdle, the plate follows the sternum. | Acromion markers: compare the shoulder line with the sternum. |
| The best-looking neutral pose (game frame 46) was 2.1 s before Motive started, so it had no mocap truth. A single-frame reference adds that frame's error to the whole take (student lateral bias +1.5 -> +3.7 deg). | References must sit inside the mocap window and be averaged over >= 1 s. | Start Motive first, then hold home; holds >= 1.5 s. |

Goals, in priority order:

1. **G1 drift vs gain**: re-zero at every home hold and measure how much of the error is drift.
2. **G2 what moved**: separate seat drift, pelvis tilt, thoracic curl and sternum-plate tilt.
3. **G3 shoulder girdle**: test whether student/teacher twist and sideways lean follow the shoulder line.
4. **G4 per-axis gain**: isolated forward lean, slump, side lean and twist, with the arms out of the picture.
5. **G5 (optional) board constraint**: targets beyond arm's reach, so that hand position forces trunk travel.

## 2. Setup

Unchanged from `reach_play` unless marked **NEW**.

- **Cameras**: rig v4 dual camera on the Radxa, 1280x800 at 30 fps, stereo calibration
  `calib_radxa_sep18_26`. Check `camera_order` in `metadata.json` per run: with
  `["cam1", "cam0"]`, file `cam0` is calibration cam1 (the left camera).
- **Rig**: do not touch the camera rig, the table or the Motive cameras within a session.
  Takes without board motion reuse the camera-to-mocap alignment of the game takes.
- **Skateboard**: AprilTag rigid body plus its 4 Motive markers (rigid body `skateboard`).
  Keep them; script 32 fits the camera-to-mocap alignment from them with no fitted S.
- **Motive**: 100 Hz, Y up from the ground-plane calibration (used as gravity), mm.
  Export rigid bodies, rigid-body markers and labelled markers for **every** take. The
  wtc export on 2026-11-09 lacked the trunk rigid body.
- **Sync**: GPIO pulse per take, with Motive start as the rising edge.
  Start the camera recording **before** Motive and stop it **after**.
- **Furniture**: same chair and table position, with chair-leg positions taped on the floor.
- **Clothing**: same kind of shirt and chest strap as on 2026-11-09 for comparability.
  Avoid loose clothing over the torso, which ICP and segmentation rely on.

### Markers

| Rigid body / markers | Placement | Purpose |
|---|---|---|
| `trunk` (existing) | Sternum plate, 4 markers; origin 4, x 3, z 2 as in `reach_play/session.toml` | Current truth; keeps the new data comparable |
| `skateboard` (existing) | Board, 4 markers | Camera-to-mocap alignment |
| **NEW** `C7`, `T8` | Single markers on the spinous processes | With IJ/PX: ISB thorax frame; separates thoracic curl from plate tilt (G2) |
| **NEW** `IJ`, `PX` | Jugular notch and xiphoid, if the plate and strap leave room | ISB thorax frame; skip if covered by the plate |
| **NEW** `LASI`, `RASI`, `SACR` (or a rigid pelvis cluster on a belt) | Pelvis | Hip lean vs thoracic flexion; pivot for the pendulum model (G2) |
| **NEW** `chair` | 3 markers on the chair frame | Seat drift = pelvis relative to chair; chair sliding |
| **NEW** `LSHO`, `RSHO` | Acromions | Shoulder line vs sternum (G3) |
| Optional `ELB`, `WRA` | Lateral epicondyle and wrist of the reaching arm | Arm segment lengths for a closed-chain board-arm-trunk model (G5) |

Before recording, do a test reach to each side and a full forward lean, and confirm Motive keeps
every marker. Watch especially C7/T8 and SACR on the back, and the ASIS markers at full lean.

## 3. Home position

- Seated upright, feet flat, back **off** the backrest (keeps T8/SACR visible and makes the
  lean real).
- Reaching hand on the skateboard; board centred on a taped home mark, pointing straight ahead.
- Other hand resting on a taped spot on the table, the same every time.
- Eyes on the screen.

**Game definition**: the board tip is within `R_home` of the home point and the board is still
(speed below a threshold) for `hold_s`. Proposed: `R_home` = 2 cm, still = 10 mm/s,
`hold_s` = 1.5 s. Analysis averages 1 s; the extra 0.5 s covers settling.

## 4. Session sequence (per subject)

Every take starts and ends the same way:

1. Start the camera recording.
2. Start Motive (GPIO rise).
3. Wait 2 s.
4. Subject holds home for 3 s.
5. Run the take content.
6. Subject holds home for 3 s.
7. Stop Motive.
8. Stop the camera.

The home holds therefore always fall inside the mocap window.

| # | Take label | Length | Content |
|---|---|---|---|
| 0 | n/a | n/a | Motive calibration + ground plane (Y up). Marker check (section 2). |
| 1 | `<subj>_<date>_static` | ~20 s | 5 s home, then 5 s with arms relaxed at the sides and hands off the table (upper body unoccluded: body and arm-length fit), then home again. |
| 2 | `<subj>_<date>_moves` | ~3 min | Arms crossed on the chest, board left at the home mark. Each movement 5 times, back to upright with a 2 s still hold between repetitions: (a) forward lean from the hips, back straight, ~20 deg; (b) slump/curl of the upper back with the pelvis still; (c) side lean left; (d) side lean right; (e) twist left; (f) twist right. Separates hip lean from curl and gives per-axis gain without the arm-posture confound (G2, G4). |
| 3 | `<subj>_<date>_game` | ~5 min | Reach game with home holds enforced (section 5). |
| 4 | `<subj>_<date>_<cond2>` | ~5 min | Same as 3 in the second condition used on 2026-11-09 (`wtc`), if it is still wanted. |
| 5 | `<subj>_<date>_beyond` (optional) | ~3 min | Game with ~25% of targets beyond the reach boundary (e.g. `reach_boundary.json` scaled x1.2), so that the hand on the board forces trunk travel (G5). |
| 6 | n/a | ~10 s | Final home hold. This can be the end of the last take. |

## 5. What the game needs (game repo)

The current game logs `random_reach.csv` with `status` in {`moving`, `captured`, `missed`,
`waiting_sync`}. It has no home concept. Needed:

1. **Home state machine**. Loop through these states:
   - `home_wait`: show the home marker, hide the target.
   - `hold`: board in the zone and still; show progress.
   - `reach`: target shown. The target appears only after a complete hold.
   - `captured` or `missed`.
   - `return`: prompt "back to home".
   - Then `home_wait` again.

   If the board leaves the zone during `hold`, the hold restarts.
2. **Configurable parameters**: home point in table mm (same frame as `table_x_mm`/`table_y_mm`
   in `poses.csv`), `R_home`, still threshold, `hold_s`, target seed, beyond-reach fraction.
   Write all of them to `metadata.json` under a `home` block.
3. **Per-frame phase**: add a `phase` column to `random_reach.csv` (and preferably to
   `poses.csv`) with the state above.
4. **Event log**: `home_events.csv` with `monotonic_ns, event, target, attempt`. Events:
   `hold_start`, `hold_ok`, `hold_break`, `target_show`, `captured`, `missed`, `return_start`.
   Use the same monotonic clock as the camera timestamps and `sync_events.msgpack`, so hold
   windows map to camera frames and mocap time without guessing.
5. **Reproducible targets**: seeded target order, with the seed logged, so that subjects get
   the same sequence.
6. **Unchanged**: `poses.csv` columns (frame, sensor_ns, tip, rvec/tvec, table, tags),
   `random_reach.csv` existing columns, `reach_boundary.json`, recording layout and
   `chunks.json`.

## 6. Data layout

Same as `reach_play`, new session folder:

```
data/experiments/reach_home/            # name to confirm
  session.toml                          # camera, calibration, [mocap] rigid bodies + marker numbering, exports
  mocap/<label>.csv                     # Motive exports
  <run>/recording/                      # cam*_frame_*.msgpack, timestamps, sync_events, chunks.json
  <run>/poses.csv  random_reach.csv  reach_boundary.json  metadata.json
  <run>/home_events.csv                 # NEW
```

`session.toml` needs the new rigid bodies and marker names under `[mocap]`. Write down the
marker numbering per rigid body on the day.

## 7. Quality checks during the session

Check after each take, before the next one:

- [ ] `sync_events.msgpack` has one rise and one fall.
- [ ] The Motive take covers the opening and closing home holds.
- [ ] Every rigid body and single marker tracked through the take. Look at the back markers at full reach.
- [ ] Skateboard tags detected across the reach area (`tags_cam0/1` in `poses.csv`).
- [ ] No frame gaps in `poses.csv`.
- [ ] Holds logged in `home_events.csv`. The number of `hold_ok` events should roughly equal the number of targets.
- [ ] `camera_order` recorded in `metadata.json`.

## 8. Analysis plan (this repo)

1. **Alignment**: script 32 (skateboard) per take. The `static` and `moves` takes reuse the game-take alignment.
2. **Methods**: ICP, student, teacher and fused as in script 33, on stride-6 frames inside the take.
3. **Re-zero per hold**: average the 1 s of every `hold_ok` window, for mocap and for each method. Score each reach against its own hold.
   - Compare with a single start reference. The difference is the drift share of the error (G1).
4. **Thorax truth**:
   - Build the ISB thorax frame (IJ, PX, C7, T8) and compare it with the sternum plate. This separates plate tilt from thoracic curl.
   - Score methods against both (G2).
5. **Pelvis and chair**:
   - Seat drift = pelvis translation relative to the chair.
   - Pelvis tilt vs thorax angle separates hip lean from curl.
   - This gives the pivot and lever for the sternum-travel pendulum model (G2).
6. **Shoulder line**: twist and tilt of LSHO-RSHO vs the sternum plate, and vs student/teacher axial and lateral (G3).
7. **Moves take**: per-axis gain and cross-talk of each method on isolated movements (G4).
8. **Beyond-reach take**: board distance minus arm length gives a lower bound on trunk travel. It is the test case for the closed-chain model (G5).

## 9. Open decisions (fill in before recording)

- [ ] Session name and subjects (how many; same subject first?).
- [ ] `R_home`, still threshold and `hold_s` (proposed 2 cm, 10 mm/s, 1.5 s).
- [ ] Backrest contact allowed? (proposed: no)
- [ ] Marker set: ISB thorax (IJ/PX/C7/T8), pelvis (LASI/RASI/SACR or a cluster), chair, acromions; elbow/wrist optional.
- [ ] Which conditions to repeat (`game`, `wtc`), and whether to add the `beyond` take.
- [ ] Clinical target, which decides the primary truth: trunk displacement (cm) or thorax angle (ISB thorax or sternum plate).
