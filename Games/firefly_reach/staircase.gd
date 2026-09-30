extends RefCounted

# One pair's calibration (2026-09-28). Two ideas:
#
# 1. Calibrate WITH the deadline in view, at an ENCOURAGING catch rate.
#    Untimed calibration (the percentile rule before) measured relaxed
#    movements: the first pilot, at p = 0.25, caught ~50 % in early play
#    because the draining rim made movements faster. A staircase AT p fixed
#    that but made a p = 0.25 day open with 3 misses in 4 — demotivating. So
#    calibration fireflies have a lifetime and a draining rim exactly as in
#    play, but a weighted up-down staircase (Kaernbach, 1991) keeps each
#    pair's lifetime where about CAL_RATE of them are caught:
#        caught -> shorter by exp(-down),  missed -> longer by exp(+up),
#        rate * down = (1 - rate) * up
#    The larger step is 0.25 in log units until the 2nd reversal, 0.12 until
#    the 4th, then 0.06. It starts at the pair's warm-up median.
#
# 2. Take the day's level from the whole distribution (Kaplan–Meier).
#    A catch gives its exact movement time; a miss says only "slower than
#    its lifetime" (right-censored). The Kaplan–Meier survival curve turns
#    that into the movement-time distribution with the deadline in view:
#        S(t) = prod over catch times t_i <= t of (1 - d_i / n_i),  F = 1 - S
#    (d_i catches at t_i; n_i fireflies still uncaught just before t_i — a
#    miss drops out once its lifetime has passed). Play's lifetime is the
#    p-th percentile, F^-1(p), for any p the curve reaches.
# Consumers use:  const Staircase := preload("res://Games/firefly_reach/staircase.gd")

const Protocol := preload("res://Games/firefly_reach/protocol.gd")

const MIN_S := 0.15                 # never shorter than this
const CAL_RATE := 0.85              # calibration's catch rate, at least

var rate: float                     # the catch rate this staircase keeps
var lifetime: float                 # the next firefly's lifetime, s
var trials: Array = []              # [lifetime s, caught, mt s (caught only, else -1)]
var reversals: int = 0


# The catch rate calibration keeps for a day at level p: at least CAL_RATE,
# and a bit above p so that the Kaplan–Meier curve reaches p.
static func calibration_rate(p: float) -> float:
	return clampf(maxf(CAL_RATE, p + 0.05), CAL_RATE, 0.95)


# start_s: where it begins (the pair's warm-up median movement time).
func _init(start_s: float, keep_rate: float) -> void:
	rate = keep_rate
	lifetime = clampf(start_s, MIN_S, Protocol.POINT_CAP_S)


func _step() -> float:
	if reversals < 2:
		return 0.25
	if reversals < 4:
		return 0.12
	return 0.06


# A firefly at `lifetime` was caught (after mt s) or missed; aborted ones do not count.
func update(caught: bool, mt: float) -> void:
	if not trials.is_empty() and bool(trials[-1][1]) != caught:
		reversals += 1
	trials.append([lifetime, caught, mt if caught else -1.0])
	var s := _step()
	var down := s if rate <= 0.5 else s * (1.0 - rate) / rate
	var up := s * rate / (1.0 - rate) if rate <= 0.5 else s
	lifetime = clampf(lifetime * exp(-down if caught else up), MIN_S, Protocol.POINT_CAP_S)


# Kaplan–Meier points: [[t, F(t)], ...] at each catch time, in order.
static func km_curve(trials: Array) -> Array:
	var obs: Array = []   # [time, caught]: a catch at its movement time, a miss at its lifetime
	for tr in trials:
		obs.append([float(tr[2]) if bool(tr[1]) else float(tr[0]), bool(tr[1])])
	# At equal times catches go first (a miss at t was still uncaught at t).
	obs.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] and not b[1]))
	var out: Array = []
	var at_risk := obs.size()
	var surv := 1.0
	var i := 0
	while i < obs.size():
		var t: float = obs[i][0]
		var d := 0
		var gone := 0
		while i < obs.size() and float(obs[i][0]) == t:
			if obs[i][1]:
				d += 1
			gone += 1
			i += 1
		if d > 0:
			surv *= 1.0 - float(d) / float(at_risk)
			out.append([t, 1.0 - surv])
		at_risk -= gone
	return out


# Play's lifetime for level p: the first catch time where F reaches p. If the
# curve never reaches p (too few catches), the longest lifetime calibration
# used — play is then at least as long as anything calibration asked for.
# -1 without any trials.
static func level_lifetime(trials: Array, p: float) -> float:
	if trials.is_empty():
		return -1.0
	for pt in km_curve(trials):
		if float(pt[1]) >= p:
			return float(pt[0])
	var longest := 0.0
	for tr in trials:
		longest = maxf(longest, float(tr[0]))
	return longest


# How far the curve got (its last F), to flag a level beyond calibration.
static func km_reach(trials: Array) -> float:
	var c := km_curve(trials)
	return float(c[-1][1]) if not c.is_empty() else 0.0
