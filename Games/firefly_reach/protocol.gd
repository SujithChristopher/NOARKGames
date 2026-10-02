# Firefly Reach protocol (from the clinic study's protocol.gd, persistence and
# lock removed: these are fixed defaults here).
# DRAFT: pairs, levels and point limits are placeholders until the pilot.
# Consumers use:  const Protocol := preload("res://Games/firefly_reach/protocol.gd")

const VERSION := "firefly-1"   # written to every session header

# The three levels: the catch rate p each pair's calibration staircase settles
# at (staircase.gd) — i.e. the p-th percentile of movement times with the
# deadline in view — the same for everyone; each participant plays them in
# their own order (spec §1).
static var LEVELS: Array = [0.60, 0.75, 0.90]

# The three target pairs, fixed for everyone, in table millimetres (spec §3.1).
static var PAIRS: Array = [
	{"a_mm": 150.0, "w_mm": 60.0},
	{"a_mm": 300.0, "w_mm": 40.0},
	{"a_mm": 450.0, "w_mm": 25.0},
]

static var HOLD_S: float = 1.0       # unbroken time inside the circle that counts as a catch
static var ROUND_S: float = 60.0
static var REST_S: float = 15.0
static var WARMUP_ROUNDS: int = 1   # played before calibration, not counted (0-5; editable since 2026-09-29)
static var CALIB_ROUNDS: int = 5
static var PLAY_ROUNDS: int = 15

# Warm-up speed points (spec §4.4; calibration used them until 2026-09-28).
# POINT_CAP_S is the staircase's longest lifetime and how long a reposition
# firefly waits. A warm-up hold must start within WARMUP_CAP_S of the spawn
# (round_runner.gd): the three diamonds go out at equal steps, 1 s each, and
# the bat takes the firefly as the last one goes (2026-10-02; before, the last
# diamond stayed lit up to POINT_CAP_S).
static var POINT_CAP_S: float = 8.0
static var POINT_LIMITS_S: Array = [1.0, 2.0]   # MT < 1.0 s -> 3 points, < 2.0 s -> 2, else 1
static var WARMUP_CAP_S: float = 3.0            # ...and 1 point up to here

# Reach scan (spec §4.3): fixed in reach_scan.gd (30-corner polygon the
# participant stretches; since 2026-09-28 — the spoke speed and wait are gone).

# Fixed, not in Settings.

# Quick test (Settings -> Mode): a short visit for checking the app. It still
# counts as a study day; the visit header says quick_test,true.
const QUICK_CALIB_ROUNDS := 2
const QUICK_PLAY_ROUNDS := 3
const QUICK_REST_S := 5.0


static func points_for(mt: float) -> int:
	if mt < float(POINT_LIMITS_S[0]):
		return 3
	if mt < float(POINT_LIMITS_S[1]):
		return 2
	return 1


static func id_bits(a_mm: float, w_mm: float) -> float:
	return log(a_mm / w_mm + 1.0) / log(2.0)
