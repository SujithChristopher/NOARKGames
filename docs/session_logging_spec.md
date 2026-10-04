# Session log + therapy dose — design

Modelled on the MARS robot's `sessions.csv` / `configdata.csv`
(`external/references/`), trimmed to what NOARK has.

## Files per patient

```
{DOCUMENTS}/NOARK/data/{pid}/
  sessions.csv          one row per trial, all games
  configdata.csv       therapy dose history (append-only)
  GameData/raw-sess{SS}-trial{TTT}-{Game}-{Mode}.csv   (+ _hand/_reach/_calibration for Firefly)
```

## sessions.csv

```
:Location: <settings location>
:Device: NOARK
:User: <pid>
SessionNumber,DateTime,TrialNumberDay,TrialNumberSession,TrialStartTime,TrialStopTime,TrialRawDataFile,Movement,GameName,Mode,GameDuration,SuccessRate,MoveTime,CurrentTargets,CurrentHits,CurrentMisses,CummulativeTargets,CummulativeHits,CummulativeMisses,RawDataFileName
```

| Column | Meaning |
|---|---|
| SessionNumber | Per patient, +1 on each login (registry login or quick Hosp-ID login). Next = max in file + 1. |
| DateTime | Session start (login time). |
| TrialNumberDay / TrialNumberSession | nth trial of this GameName+Mode today / this session. |
| TrialStartTime / TrialStopTime | Trial wall-clock bounds. |
| TrialRawDataFile | Patient id (as MARS). |
| Movement | FruitCatcher, PingPong = ML · FlyThrough = AP · RandomReach, FireflyReach = MLAP · Jumpify = blank (Assessment writes no trial log) |
| GameName / Mode | Base name (`FlyThrough`) / `2D` or `3D`. |
| GameDuration | Configured trial length, s. |
| MoveTime | Active play time excl. pauses, s. Feeds dose progress. |
| Current* | Targets / hits / misses this trial (definitions below). |
| Cummulative* | Same, summed over all sessions for this GameName+Mode. |
| SuccessRate | round(100 · hits / targets); blank if no targets. |
| RawDataFileName | Filename in `GameData/`. |

Hits/misses: FruitCatcher fruit spawned/caught/dropped · PingPong balls to
player/returned/lost · FlyThrough pipes/passed/crashed · RandomReach,
FireflyReach targets spawned/reached/timed-out (all phases) · Jumpify blank.

A row is appended when a trial ends, including early quit.

Dropped from MARS: TrainingPlaneAngle, ReachSpeed, GameParameter, currentStar,
CummulativeStars.

## configdata.csv

```
HomerID,DateTime,TotalTime,ML,AP,MLAP,Location
```

- Minutes per day, not game specific. TotalTime = ML + AP + MLAP (auto).
- DateTime = when the dose was set; last row is the active dose.
- Location also updates `settings.json` `location`, which the `:Location:` line
  and the raw logs' `device_location` read.
- Start/End dates, arm lengths, Group and TrainingSide dropped (the side is the
  patient's affected hand in patients.json).

## Login flow

After a patient is selected/created and logged in (registry or quick Hosp-ID
login), a shared **dose dialog** opens before mode/game select:
- dose exists → fields pre-filled with it; edit any to change, *Confirm*;
- none → fields at 0; *Confirm* stays disabled until the total is above 0.
Cancel stays on the login screen.
A changed/new dose appends a row. Then the new session starts.

## Progress

Game-select (2D and 3D) shows today's minutes per movement vs dose,
summed from today's `MoveTime` in sessions.csv. Display only, never blocks.

## Code shape

- New autoload `SessionLog` (after PatientDB): start_session(pid),
  begin_trial(game, mode) → raw file handle, end_trial(stats), today_minutes().
- New `Dose` helpers (in SessionLog or separate): load/save configdata.csv.
- `Manager.create_game_log_file` keeps its 7-line header, gets new filename
  from SessionLog. Global `user://session.json` counter and
  `start_new_session_if_needed()` removed.
- Each game reports targets/hits/misses/move time at trial end.

## Rebuild of old data

`pyscripts/rebuild_sessions.py` (stdlib only), per patient:
- Use only files with the 7-line header (`{Game}_S*_T*_{date}.csv`); list the
  skipped legacy files.
- Sort by `start_time`; gap > 30 min from previous trial → new session.
- Stop time = last row epochtime. Metrics best-effort from columns
  (`gems_caught/missed`, `missed_count`, status transitions); else blank.
- Rename raw files (and Firefly side files) to the new pattern; write
  sessions.csv. Dry-run by default, `--apply` to write.
