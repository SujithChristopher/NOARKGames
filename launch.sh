#!/usr/bin/env bash
# Launch the game pinned to the little cores from the first instruction.
#
# global_script.gd also pins itself in _ready(), but that is after engine
# startup. Starting under taskset covers that window, and every thread Godot
# spawns inherits the mask. The tracker is not affected: it sets its own mask
# (settings.json tracker_cpus) before doing any work.
#
# Usage: ./launch.sh [extra godot args]
#   GAME_CPUS=0-3 ./launch.sh      override the core list
#   GODOT=/path/to/godot ./launch.sh
set -euo pipefail

cd "$(dirname "$0")"

SETTINGS="${NOARK_SETTINGS:-$HOME/Documents/NOARK_demo/settings.json}"
# Binary: $GODOT, else godot on PATH, else the one in ~/Downloads.
GODOT="${GODOT:-$(command -v godot || echo "$HOME/Downloads/godot.arm64")}"

# Core list: env var, else settings.json game_cpus, else the little cores.
CPUS="${GAME_CPUS:-}"
if [[ -z "$CPUS" && -f "$SETTINGS" ]]; then
    CPUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("game_cpus",""))' "$SETTINGS" 2>/dev/null || true)"
fi
CPUS="${CPUS:-0-3}"

echo "[launch] game on cores $CPUS"
exec taskset -c "$CPUS" "$GODOT" --path . --main-scene res://Main_screen/Scenes/main.tscn "$@"
