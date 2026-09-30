# NOARK Data Formats

Reference for every file produced by the NOARK rehabilitation platform:
root-level session CSVs, per-game `GameData` CSVs, and workspace JSON files.

All patient identifiers in this document are placeholders (`PATIENT_ID1`,
`PATIENT_ID2`). In real data the identifier is the hospital ID assigned at
registration.

---

## 1. Directory layout

```text
NOARK/
  records/patients.json                # patient database
  records/scores.json                  # best score per patient per game
  data/PATIENT_ID1/
      Session-{YYYY-MM-DD}/MovementData/
          {YYYY_MM_DD_HH_MM_SS}_data.csv     # raw tracker stream   (§2)
          recordings/rec_{HH-MM-SS}/...      # optional raw camera frames
      GameData/
          {Game}_S{session}_T{trial}_{YYYY-MM-DD}.csv   # per-game log  (§3)
      workspace-{YYYY-MM-DD}.json                       # workspace     (§4)
```

The root `NOARK` folder sits in the user's Documents directory on desktop and
Raspberry Pi deployments, and in app-private storage on Android tablets.

There are two independent producers of data:

| Producer | Produces |
|---|---|
| Motion-tracking system (camera + marker tracker) | root-level `*_data.csv` |
| Game application | `GameData/*.csv`, `workspace-*.json`, `records/*.json` |

When the platform runs in debug/testing mode, all files are written under a
fixed dummy patient folder instead of a real hospital ID, so that folder
contains test data only.

---

## 2. Root-level session CSV — `2025_05_28_11_56_53_data.csv`

### Purpose

Raw motion-capture stream straight from the marker tracker, independent of any
game. It is the ground-truth movement record for the whole time a patient is
logged in; the GameData CSVs are the game-side view of the same motion.

### When it is generated

One file is opened at patient login (or when the operator switches to a
different patient) and written continuously until the tracking session ends.
One file per tracking session — **not** one per game.

### Naming convention

`{YYYY}_{MM}_{DD}_{HH}_{MM}_{SS}_data.csv`

The timestamp is local wall-clock time at the moment the file was opened, i.e.
patient login time. The filename carries no patient or game component; those
come from the folder path (`data/PATIENT_ID1/Session-{date}/MovementData/`).

### Columns

| Column | Meaning | Unit | Type |
|---|---|---|---|
| `Time` | Local timestamp of the sample, formatted `DD/MM/YYYY HH:MM:SS` | — | text, 1 second resolution |
| `X` | Marker-cluster centroid, horizontal (left–right) | metres | decimal |
| `Y` | Centroid, vertical (up–down) | metres | decimal |
| `Z` | Centroid, depth (toward/away from camera) | metres | decimal |

The centroid is the averaged position of all markers visible in that frame,
after each marker's fixed offset from the cluster centre is applied, and after
smoothing. Values are expressed in the **camera's own coordinate frame** — they
are not yet relative to the patient-specific origin. The origin correction is
applied downstream, inside the game application, which is why the same instant
has different numbers here and in a GameData file (§5).

### Sampling rate

One row per camera frame in which at least one marker is visible — therefore
frame-rate bound, typically **30–100 Hz** depending on camera configuration.
Frames where all markers are occluded produce no row, so rows are **not**
uniformly spaced in time. Never assume a fixed interval; use the row order and
the `Time` column, and treat gaps as marker occlusion.

Because `Time` has only 1 second resolution, many consecutive rows share the
same timestamp. For sub-second alignment, use the GameData timestamps instead.

### Variants found in older archives

- **Late 2024.** No header row at all; each line is a bare bracketed triplet of
  X, Y, Z in metres separated by spaces, with no timestamp.
- **Early/mid 2025.** The `Time,X,Y,Z` header is present, but each row is a
  single quoted list containing the timestamp and three numeric values wrapped
  in a type annotation. The field order is identical to the table above; the
  quoting and wrappers have to be stripped before the values can be read.
- **Older folder layout.** The file was written directly under
  `data/PATIENT_ID1/` rather than inside `Session-{date}/MovementData/`.

---

## 3. GameData CSVs — `FlyThrough_S11_T1_2025-05-28.csv`

### Purpose

Per-game, per-trial log that ties patient movement to what happened inside the
game: score, game state, target position, and the on-screen player position.
This is the file to use for outcome and performance analysis.

### When it is generated

Created when a game starts, one file per game run. Rows are appended at a fixed
interval until the game ends or the application closes.

### Naming convention

`{game}_S{session_id}_T{trial_id}_{YYYY-MM-DD}.csv`

| Component | Meaning |
|---|---|
| `{game}` | Game name: `FlyThrough` (obstacle avoidance), `PingPong`, `RandomReach`, `Jumpify`. A `3D` suffix (`FlyThrough3D`, `RandomReach3D`) denotes the 3D variant of that game, which is scored and tracked separately from the 2D variant. |
| `S{n}` | Session ID — incremented once per application session and reset to 1 at the start of each new calendar day. All games played back to back share one session number. |
| `T{n}` | Trial number **within that session, for that game**: the first `FlyThrough` run of a session is `T1`, the second `T2`. Counters are per game, and reset when the session changes. |
| `{YYYY-MM-DD}` | Local date the file was created. |

Example set from one sitting:

```text
FlyThrough_S11_T1_2025-05-28.csv     first FlyThrough run of session 11
FlyThrough_S11_T2_2025-05-28.csv     second run, same session
PingPong_S11_T1_2025-05-28.csv       first PingPong run of the same session
```

Caveat: session and trial counters are stored on the device, so they are
device-local and can restart after a reinstall. The `start_time` metadata
field inside the file is the authoritative way to order runs.

Older archives (before roughly May 2025) use `{game}-{YYYY-MM-DD}.csv` with no
session or trial component: one file per game per day, overwritten if the game
was replayed the same day.

### File structure

Current files begin with a 7-line metadata block, followed by the column header
row, followed by the data rows:

```text
headerrows,7
game_name,FlyThrough
h_id,PATIENT_ID1
device_location,PMR
device_version,NOARK-0.1.0
protocol_version,0.1.0
start_time,2025-05-28T11:58:12
epochtime,score,status,...            <- column header (line 8)
1748413092.317,0,moving,...           <- data begins on line 9
```

| Metadata key | Meaning |
|---|---|
| `headerrows` | Number of metadata lines to skip; always 7. The column header is therefore line 8 and the data starts on line 9. |
| `game_name` | Game and mode; matches the filename prefix. |
| `h_id` | Hospital/patient ID. In debug runs this field can hold a leftover identifier that does not match the folder — the folder name is authoritative. |
| `device_location` | Deployment site tag; currently a fixed value (`PMR`). |
| `device_version` | Hardware/build tag of the platform that produced the file. |
| `protocol_version` | Version of the log schema itself. Increment this whenever columns change. |
| `start_time` | Local date and time the file was created, `YYYY-MM-DDTHH:MM:SS`. |

After the last data row the file carries two trailing summary lines, which are
**not** CSV data rows and must be skipped when reading the table:

```text
Final Score: 14
Total Missed: 3        (FlyThrough only)
```

Archived files from before the metadata block was introduced start directly
with the column header on line 1. The presence of `headerrows` on the first
line distinguishes the two.

### Common columns

Shared by `RandomReach`, `RandomReach3D`, `FlyThrough`, `FlyThrough3D`,
`Jumpify` and `PingPong`.

| Column | Meaning | Unit | Type |
|---|---|---|---|
| `epochtime` | Timestamp of the sample, seconds since the Unix epoch (UTC) | seconds | decimal, millisecond precision |
| `score` | Running game score at this instant | points | integer |
| `status` | Game event / state at this instant (§3.4) | — | text |
| `error_status` | Reserved slot for fault reporting; currently always `null` | — | text |
| `packets` | Reserved slot for stream diagnostics; currently always `null` | — | text |
| `device_x` | Patient hand/marker position, horizontal, relative to the session origin | metres | decimal |
| `device_y` | Marker position, vertical | metres | decimal |
| `device_z` | Marker position, depth | metres | decimal |
| `target_x` | Position of the current target, horizontal | metres | decimal |
| `target_y` | Target position, vertical — meaningful in 3D mode only | metres | decimal |
| `target_z` | Target position, depth — meaningful in 2D mode only | metres | decimal |
| `player_x` | Position of the on-screen avatar the patient controls, horizontal | metres | decimal |
| `player_y` | Avatar position, vertical — meaningful in 3D mode only | metres | decimal |
| `player_z` | Avatar position, depth — meaningful in 2D mode only | metres | decimal |
| `pause_state` | `1` = game running, `0` = paused | — | integer |

Coordinate notes:

- `device_*` is the patient's measured position **after** the origin
  correction: the origin is set once at the start of a sitting, and all values
  are expressed relative to it and rotated into its frame. If the origin was
  never set, `device_*` is simply the camera-frame position.
- `target_*` and `player_*` are on-screen positions converted back into the
  same metric space as `device_*`, so all three can be compared or subtracted
  directly. Workspace-adaptive scaling (§4) is removed during that conversion,
  which keeps values comparable across patients with different workspace sizes.
- **2D mode** uses the horizontal/depth plane, so the `*_y` fields stay at 0.
  **3D mode** uses the horizontal/vertical plane, so the `*_z` fields stay at 0.
  Which one applies is indicated by the `3D` suffix in `game_name`.
- `player_*` is not identical to `device_*` even though both describe the same
  hand: the avatar position is clamped to the screen boundary and smoothed
  frame to frame. `device_*` is the unfiltered measurement; `player_*` is what
  the patient actually saw. The difference between the two is a useful measure
  of how often the patient pushed beyond the usable workspace.

Game-specific additional columns:

| Game | Extra columns | Meaning |
|---|---|---|
| `FlyThrough`, `FlyThrough3D` | `missed_count` (placed after `score`) | Cumulative count of obstacles missed (integer) |
| `PingPong` | `ball_x`, `ball_y`, `ball_z` (placed after `player_z`) | Ball position in the same metric space. Currently duplicates `target_*` |

Full column orders:

```text
RandomReach, RandomReach3D, Jumpify:
epochtime, score, status, error_status, packets,
device_x, device_y, device_z, target_x, target_y, target_z,
player_x, player_y, player_z, pause_state

FlyThrough, FlyThrough3D:
epochtime, score, missed_count, status, error_status, packets,
device_x, device_y, device_z, target_x, target_y, target_z,
player_x, player_y, player_z, pause_state

PingPong:
epochtime, score, status, error_status, packets,
device_x, device_y, device_z, target_x, target_y, target_z,
player_x, player_y, player_z, ball_x, ball_y, ball_z, pause_state
```

### 3.4 Game events and states (`status`)

`status` carries the most recent game event. The value is **latched**: it is
written on every row until the next event replaces it, so an event that lasted
one instant can appear on dozens of consecutive rows. For counting, look for
*transitions into* a value, not for the number of rows carrying it.

| Game | Value | Meaning | What it is useful for |
|---|---|---|---|
| RandomReach | `""` (blank) | Idle — no target active yet | Marks warm-up rows to exclude from analysis |
| | `moving` | Target is on screen, patient is reaching for it | Defines the reach interval: from `moving` to the next `captured`/`missed` |
| | `captured` | Patient reached the target successfully | Success count; reach time = time from `moving` to `captured` |
| | `missed` | Target expired before it was reached | Failure count; compare against `captured` for a hit rate |
| FlyThrough | `idle` | Game loaded, not yet flying | Trim the pre-play segment |
| | `moving` | Active flight between obstacles | Main analysis window for smoothness and path length |
| | `reached` | Obstacle gap successfully passed | Success events; spacing between them gives pace |
| | `restarting` | Run ended, game resetting | Marks the boundary between attempts inside one file |
| Jumpify | `moving` | Platform traversal in progress | Continuous movement segment |
| | `collected` | Coin/target collected | Success events; count and time between them |
| | `missed` | Target passed without collection | Failure events; ratio with `collected` gives accuracy |
| PingPong | (blank) | Not currently populated | Use `score` changes and ball position to detect rallies |

Worked examples of how the states are meant to be used:

- **Reach time (RandomReach).** For each row where `status` changes to
  `moving`, find the next row where it changes to `captured`; the difference in
  `epochtime` is that reach's duration. Rows changing to `missed` instead are
  timeouts and should be counted separately, not averaged into reach time.
- **Excluding non-play time.** Rows where `pause_state` is `0`, or where
  `status` is `idle`, are not active play. Dropping them
  before computing movement distance or time-on-task avoids counting the
  patient resting between attempts.
- **Segmenting repeated attempts.** In FlyThrough a single file can contain
  several attempts; each `restarting` transition marks a boundary, so score and
  movement metrics should be computed per segment rather than per file.

### 3.5 Sampling rate

Rows are written on a fixed timer of 0.02 s — a **nominal 50 Hz**. The real
spacing follows the `epochtime` column and drifts with display frame rate; on
slower hardware the effective rate falls below 50 Hz. Always derive the actual
interval from `epochtime` rather than assuming 50 Hz.

The underlying position only refreshes when a new tracker sample arrives
(30–100 Hz, §2), so consecutive rows can repeat the same position values. That
is expected and is not a stall in the recording.

### 3.6 Column sets in older archives

Files predating the metadata block use these column names:

```text
FlyThrough (around May 2025):
Score, Epochtime, position_x, position_y,
network_position_x, network_position_y,
scaled_network_position_x, scaled_network_position_y

RandomReach (around May 2025):
score, epoch, position_x, position_y,
network_position_x, network_position_y,
scaled_network_position_x, scaled_network_position_y,
pause, time_played

RandomReach (earlier, May 2025):
time, ball_x, ball_y, position_x, position_y,
network_position_x, network_position_y,
scaled_network_position_x, scaled_network_position_y
```

In those files:

- `position_*` is the on-screen sprite position, in screen pixels.
- `network_position_*` is the tracker position mapped to the screen without
  workspace-adaptive scaling, in screen pixels.
- `scaled_network_position_*` is the same position after workspace-adaptive
  scaling, in screen pixels.
- `pause` is the same flag as today's `pause_state`; `time_played` is elapsed
  seconds within the run.

These files contain no metric (metre) columns at all, and some rows carry fewer
values than there are column names, so field counts must be checked per row.

---

## 4. Workspace JSON — `workspace-2025-05-28.json`

### Purpose

Output of the assessment step: the patient's reachable area, traced by having
them move the marker through their full comfortable range. It defines the
usable play area and the on-screen scaling that every subsequent game uses, so
that a patient with a small range still gets a full-screen game.

### When it is generated

Written once when the assessment is confirmed by the operator. One file per
patient per day; repeating the assessment on the same day **overwrites** that
day's file.

### Naming convention

`workspace-{YYYY-MM-DD}.json`, local date, stored directly in the patient
folder (`data/PATIENT_ID1/workspace-2025-05-28.json`).

### Structure

A flat JSON object with six keys. The two polygons are stored as **text
strings** in the form `"[(x, y), (x, y), …]"`, not as JSON arrays, so they must
be parsed out of the string.

| Key | Meaning | Unit | Type |
|---|---|---|---|
| `active_workspace` | Convex outline of the traced movement path — the patient's measured reachable area | screen pixels, point-list string | text |
| `inflated_workspace` | The same outline shrunk inward by a fixed safety margin and re-hulled — the conservative training area actually used during gameplay | screen pixels, point-list string | text |
| `axdir` | Width of the active workspace (bounding-box extent, horizontal) | centimetres | decimal |
| `azdir` | Depth of the active workspace (bounding-box extent, depth axis) — 2D assessments only | centimetres | decimal |
| `txdir` | Width of the training (inflated) workspace | centimetres | decimal |
| `tzdir` | Depth of the training workspace — 2D assessments only | centimetres | decimal |

Interpretation:

- `active_workspace` answers "how far can this patient reach"; `inflated_workspace`
  answers "where is it safe to place targets". Games place targets inside the
  inflated area only.
- The `a*` values describe measured ability and are the ones to track over time
  as a recovery outcome. The `t*` values describe how the game was configured
  on that day and are context, not outcome.
- Pixel-to-centimetre conversion is a fixed ratio of the mapping in use
  (approximately 20 pixels per centimetre at default settings), which is how
  the centimetre fields are derived from the pixel polygons.
- Area of either polygon can be computed from its point list and is a compact
  single-number summary of reachable workspace.

### Known gaps

- **3D assessments.** The vertical extents measured during a 3D assessment are
  shown on screen but are not among the six saved keys; the depth-axis keys
  (`azdir`, `tzdir`) then hold a value that does not describe the vertical
  range. Treat the depth fields as trustworthy for 2D assessments only.
- The file records no mode flag (2D vs 3D), no origin position, and no patient
  identifier. Mode has to be inferred from the session context; the patient
  comes from the folder.
- Polygons are in the screen pixel space of the display used on the day, so
  files recorded on different screen resolutions are not directly comparable.
  Compare the centimetre extents instead.
- The adaptive scaling factors derived from the workspace at assessment time
  are held only for that sitting and are never written to disk. They are baked
  into the `scaled_network_position_*` columns of older CSVs and removed from
  the `player_*` columns of current ones, so exact scaling cannot be recovered
  from an archive alone — it has to be recomputed from `inflated_workspace`
  together with the known screen resolution.

---

## 5. Relationship between the files

A typical day for one patient:

```text
data/PATIENT_ID1/
  Session-2025-05-28/MovementData/2025_05_28_11_56_53_data.csv   one per login
  GameData/FlyThrough_S11_T1_2025-05-28.csv                      one per game run
  GameData/PingPong_S11_T1_2025-05-28.csv                        same session S11
  workspace-2025-05-28.json                                      one per day
```

- **Session CSV ↔ GameData CSV.** The same physical movement, recorded twice
  from different points in the chain. The session CSV is one continuous stream
  for the whole login; each GameData file covers a sub-interval of it. There is
  no shared identifier column — align them on time: GameData `epochtime` is UTC
  with millisecond precision, session CSV `Time` is local with 1 second
  precision. Convert using the device's timezone and use the GameData
  `start_time` metadata to bracket the interval. Expect several GameData files
  inside the span of one session CSV.
- **Coordinates between the two.** Session CSV `X/Y/Z` are camera-frame metres;
  GameData `device_x/y/z` are the same quantity after the origin correction, so
  the two differ by a fixed rotation and translation for the whole sitting. If
  no origin was set that day, the two match directly.
- **Workspace JSON ↔ GameData CSV.** The workspace file carrying the same date
  as a game file defines the play area and the pixel-to-centimetre scaling that
  was in force for that run. Use it to normalise positions and to compute
  reachable-area metrics. A game file holds no pointer back to the workspace
  file, so match by patient and date, taking the nearest workspace file at or
  before the game date.
- **Session number as a grouping key.** `S{n}` is shared by all GameData files
  from one application session, which makes it the natural way to group games
  played back to back. It appears in neither the session CSV nor the workspace
  file.
- **Scores.** The scores database holds only the best score per patient per
  game. Per-run scores come from the `score` column and from the trailing
  `Final Score:` line of each GameData file.

---

## 6. Reading the files — practical notes

- Detect the format of a GameData file from its first line: if it begins with
  `headerrows`, skip that many lines to reach the column header; otherwise the
  column header is line 1 and the file is an older archive (§3.6).
- Drop the trailing `Final Score:` / `Total Missed:` lines before treating the
  file as a table.
- Do not assume fixed sampling intervals in any file. Derive intervals from
  `epochtime` (GameData) or from row order plus `Time` (session CSV).
- Treat `error_status` and `packets` as unused; they carry `null` in every
  current file.
- Workspace polygons need string parsing before use: split the point list, then
  read each pair of numbers.
- Files under the fixed dummy-patient folder used in debug/testing mode are not
  clinical data and should be excluded from analysis.
