"""Runs tests/smoke_test.tscn headless and fails on any error Godot prints.

GDScript cannot catch its own errors, so the scene only opens each game and the
verdict comes from Godot's output: any ERROR / SCRIPT ERROR line fails the run,
as does the scene not reaching its last line (a crash or a hang).

    python tests/smoke.py              # GODOT=<path> picks the binary
"""
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TIMEOUT_S = 300
ERROR = re.compile(r"^\s*(USER )?(SCRIPT )?ERROR:", re.M)
# Godot's own report at quit, not a game's error: autoloads still hold a few.
ALLOWED = ("resources still in use at exit",)


def godot() -> str:
    path = os.environ.get("GODOT") or shutil.which("godot") or shutil.which("godot4")
    if not path:
        sys.exit("Godot not found: put it on PATH or set GODOT=<path>")
    return path


def main() -> int:
    cmd = [godot(), "--headless", "--path", str(ROOT), "res://tests/smoke_test.tscn"]
    try:
        # One stream, so each error stays after the "SMOKE scene" line it belongs to.
        run = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                             encoding="utf-8", errors="replace", timeout=TIMEOUT_S)
    except subprocess.TimeoutExpired:
        print(f"FAIL: no result within {TIMEOUT_S} s")
        return 1
    output = run.stdout
    lines = output.splitlines()
    errors = [i for i, line in enumerate(lines)
              if ERROR.match(line) and not any(a in line for a in ALLOWED)]
    for i in errors:
        scene = next((l for l in reversed(lines[:i]) if l.startswith("SMOKE scene")), "")
        print(f"{scene}\n    " + "\n    ".join(lines[i:i + 3]))
    if "SMOKE DONE" not in output:
        print("\n".join(lines[-30:]))
        print("FAIL: the smoke scene did not finish")
        return 1
    if errors:
        print(f"FAIL: {len(errors)} errors")
        return 1
    print(output[output.index("SMOKE DONE"):].splitlines()[0] + " — no errors")
    return 0


if __name__ == "__main__":
    sys.exit(main())
