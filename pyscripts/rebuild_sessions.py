"""Rebuild each patient's sessions.csv from the raw game logs written before it existed.

Old raw files are GameData/{Game}_S{n}_T{n}_{date}.csv. Their S/T numbers come
from a global counter that went up on every game start, so they say nothing
about logins: a session here is a run of trials with no gap over --gap minutes.
Each file is renamed to the new raw-sessNN-trialNNN-{Game}-{Mode}.csv (Firefly
Reach's _hand/_reach/_calibration files go with it) and gets its row in
{patient}/sessions.csv, in the format Main_screen/Scripts/session_log.gd writes.

Only files that start with the 7-line Manager header are used; anything else is
listed and left alone. A patient that already has a sessions.csv is skipped.

Hits and misses are recovered where the log has them:
  FruitCatcher  last gems_caught / gems_missed
  FlyThrough    last score / missed_count
  PingPong      status turning to "player" / "ground"
  RandomReach   status turning to "captured" / "missed"
  FireflyReach  outcome caught / missed or timeout
  Jumpify       blank (no targets)

Dry run by default; --apply renames and writes.

    python pyscripts/rebuild_sessions.py                 # report only
    python pyscripts/rebuild_sessions.py --apply
    python pyscripts/rebuild_sessions.py --data /path/to/NOARK_demo/data --patient vvv
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path

# Keep in step with session_log.gd.
MOVEMENT = {
    "FruitCatcher": "ML", "PingPong": "ML",
    "FlyThrough": "AP",
    "RandomReach": "MLAP", "FireflyReach": "MLAP",
}
MODE_OVERRIDE = {"Jumpify": "3D"}
SESSION_COLUMNS = [
    "SessionNumber", "DateTime", "TrialNumberDay", "TrialNumberSession",
    "TrialStartTime", "TrialStopTime", "TrialRawDataFile", "Movement", "GameName", "Mode",
    "GameDuration", "SuccessRate", "MoveTime", "CurrentTargets", "CurrentHits", "CurrentMisses",
    "CummulativeTargets", "CummulativeHits", "CummulativeMisses", "RawDataFileName",
]
SIDE_SUFFIXES = ("_hand", "_reach", "_calibration")   # Firefly Reach's companion files
OLD_NAME = re.compile(r"^(?P<game>[A-Za-z0-9]+)_S\d+_T\d+_\d{4}-\d{2}-\d{2}$")
TIME_FMT = "%Y-%m-%d %H:%M:%S"
MAX_STEP_S = 1.0   # a longer gap between log rows is not play time


@dataclass
class Trial:
    path: Path
    game_name: str          # as logged, e.g. FlyThrough3D
    start: datetime
    stop: datetime
    move_time: float
    duration: str = ""
    hits: int | None = None
    misses: int | None = None
    game: str = ""
    mode: str = ""
    new_name: str = ""
    row: list = field(default_factory=list)

    def __post_init__(self):
        self.game = self.game_name.removesuffix("3D")
        self.mode = MODE_OVERRIDE.get(self.game_name, "3D" if self.game_name.endswith("3D") else "2D")


def default_data_dir() -> Path:
    return Path.home() / "Documents" / "NOARK_demo" / "data"


def _float(s: str) -> float | None:
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def read_trial(path: Path) -> Trial | None:
    """Parse one raw log; None if it lacks the Manager header or has no data rows."""
    with path.open(newline="", encoding="utf-8", errors="replace") as f:
        lines = list(csv.reader(f))
    if not lines or lines[0][:1] != ["headerrows"]:
        return None
    header = {r[0]: r[1] for r in lines[1:7] if len(r) >= 2}
    if "game_name" not in header or "start_time" not in header:
        return None
    columns = lines[7] if len(lines) > 7 else []
    # A file reopened for a retry repeats the header further down; only rows whose
    # first cell is a number are data. "Final Score: n" lines are dropped too.
    rows = [dict(zip(columns, r)) for r in lines[8:] if r and _float(r[0]) is not None]
    if not rows:
        return None
    start = datetime.fromisoformat(header["start_time"])
    epochs = [_float(r.get("epochtime")) for r in rows]
    epochs = [e for e in epochs if e is not None]
    stop = datetime.fromtimestamp(epochs[-1]) if epochs else start

    move = 0.0
    for prev, cur in zip(rows, rows[1:]):
        a, b = _float(prev.get("epochtime")), _float(cur.get("epochtime"))
        if a is None or b is None or cur.get("pause_state", "1") != "1":
            continue
        move += min(max(b - a, 0.0), MAX_STEP_S)

    t = Trial(path, header["game_name"], start, max(stop, start), move)
    _score(t, rows)
    return t


def _has_header(path: Path) -> bool:
    with path.open(encoding="utf-8", errors="replace") as f:
        return f.readline().startswith("headerrows")


def _transitions(rows: list[dict], key: str, value: str) -> int:
    n, prev = 0, None
    for r in rows:
        v = r.get(key)
        if v == value and prev != value:
            n += 1
        prev = v
    return n


def _last_int(rows: list[dict], key: str) -> int | None:
    v = _float(rows[-1].get(key))
    return int(v) if v is not None else None


def _score(t: Trial, rows: list[dict]) -> None:
    if t.game == "FruitCatcher":
        t.hits, t.misses = _last_int(rows, "gems_caught"), _last_int(rows, "gems_missed")
        first = _float(rows[0].get("countdown_time"))
        if first:
            t.duration = str(int(first))
    elif t.game == "FlyThrough":
        t.hits, t.misses = _last_int(rows, "score"), _last_int(rows, "missed_count")
    elif t.game == "PingPong":
        t.hits, t.misses = _transitions(rows, "status", "player"), _transitions(rows, "status", "ground")
    elif t.game == "RandomReach":
        t.hits, t.misses = _transitions(rows, "status", "captured"), _transitions(rows, "status", "missed")
    elif t.game == "FireflyReach":
        outcomes = [r.get("outcome") for r in rows]
        t.hits = outcomes.count("caught")
        t.misses = outcomes.count("missed") + outcomes.count("timeout")


def build_rows(patient: str, trials: list[Trial], gap: timedelta) -> None:
    """Number sessions and trials, fill each trial's new_name and sessions.csv row."""
    trials.sort(key=lambda t: t.start)
    session, session_start, last_stop = 0, None, None
    per_session: dict = defaultdict(int)
    per_day: dict = defaultdict(int)
    cum: dict = defaultdict(lambda: [0, 0, 0])
    for t in trials:
        if last_stop is None or t.start - last_stop > gap:
            session += 1
            session_start = t.start
        last_stop = max(last_stop or t.stop, t.stop)
        key = (t.game, t.mode)
        per_session[(session, key)] += 1
        per_day[(t.start.date(), key)] += 1
        n = per_session[(session, key)]
        t.new_name = f"raw-sess{session:02d}-trial{n:03d}-{t.game}-{t.mode}.csv"

        scored = t.game in MOVEMENT and t.hits is not None and t.misses is not None
        targets = (t.hits + t.misses) if scored else 0
        if scored:
            c = cum[key]
            c[0] += targets
            c[1] += t.hits
            c[2] += t.misses
        rate = str(round(100 * t.hits / targets)) if scored and targets else ""
        blank = ["", "", "", "", "", ""]
        counts = [targets, t.hits, t.misses, *cum[key]] if scored else blank
        t.row = [
            session, session_start.strftime(TIME_FMT), per_day[(t.start.date(), key)], n,
            t.start.strftime(TIME_FMT), t.stop.strftime(TIME_FMT), patient,
            MOVEMENT.get(t.game, ""), t.game, t.mode,
            t.duration, rate, f"{t.move_time:.1f}", *counts, t.new_name,
        ]


def write_session_csv(path: Path, patient: str, location: str, trials: list[Trial]) -> None:
    with path.open("w", newline="", encoding="utf-8") as f:
        f.write(f":Location: {location}\n:Device: NOARK\n:User: {patient}\n")
        w = csv.writer(f, lineterminator="\n")
        w.writerow(SESSION_COLUMNS)
        for t in trials:
            w.writerow(t.row)


def rebuild_patient(folder: Path, gap: timedelta, location: str, apply: bool) -> None:
    patient = folder.name
    game_dir = folder / "GameData"
    session_csv = folder / "sessions.csv"
    if not game_dir.is_dir():
        return
    print(f"\n== {patient}")
    if session_csv.exists():
        print(f"   sessions.csv already exists - skipped (delete it to rebuild)")
        return

    trials, skipped = [], []
    for p in sorted(game_dir.glob("*.csv")):
        stem = p.stem
        if stem.endswith(SIDE_SUFFIXES):
            continue                      # moves with its main file
        if stem.startswith("raw-sess"):
            skipped.append((p.name, "already new format"))
            continue
        if not OLD_NAME.match(stem):
            skipped.append((p.name, "legacy name"))
            continue
        t = read_trial(p)
        if t is None:
            skipped.append((p.name, "no Manager header" if not _has_header(p) else "no data rows"))
            continue
        trials.append(t)

    for name, why in skipped:
        print(f"   skip  {name}  ({why})")
    if not trials:
        print("   no trials to rebuild")
        return
    build_rows(patient, trials, gap)

    renames = []
    for t in trials:
        renames.append((t.path, game_dir / t.new_name))
        for suffix in SIDE_SUFFIXES:
            side = t.path.with_name(t.path.stem + suffix + ".csv")
            if side.exists():
                renames.append((side, game_dir / (Path(t.new_name).stem + suffix + ".csv")))
    clash = [dst for _, dst in renames if dst.exists()]
    if clash:
        print(f"   ABORT: targets already exist: {[c.name for c in clash]}")
        return

    sessions = trials[-1].row[0]
    print(f"   {len(trials)} trials in {sessions} sessions")
    for src, dst in renames:
        print(f"   {src.name}  ->  {dst.name}")
    if apply:
        for src, dst in renames:
            src.rename(dst)
        write_session_csv(session_csv, patient, location, trials)
        print(f"   wrote {session_csv}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", type=Path, default=default_data_dir(), help="NOARK data folder")
    ap.add_argument("--patient", help="only this patient folder")
    ap.add_argument("--gap", type=float, default=30.0, help="minutes between trials that start a new session")
    ap.add_argument("--location", default="PMR", help=":Location: line of sessions.csv")
    ap.add_argument("--apply", action="store_true", help="rename files and write sessions.csv (default: dry run)")
    args = ap.parse_args(argv)

    if not args.data.is_dir():
        print(f"no such folder: {args.data}", file=sys.stderr)
        return 1
    folders = [args.data / args.patient] if args.patient else sorted(p for p in args.data.iterdir() if p.is_dir())
    for folder in folders:
        rebuild_patient(folder, timedelta(minutes=args.gap), args.location, args.apply)
    if not args.apply:
        print("\nDry run - nothing changed. Re-run with --apply to rename and write.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
