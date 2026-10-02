extends Node2D

# One clinic visit (docs/clinic_study_interface.md §3-5; build plan §7.2,
# packages 1-3, and 5 for the look — night fireflies: forest_scene.gd,
# night_life.gd, game_art.gd, effects.gd, sounds.gd; since 2026-09-29 a bat
# that races the hand to each timed firefly, bat.gd):
#   reach scan -> warm-up -> calibration rounds -> calibration check -> play rounds.
# One target (a firefly; "apple" in the code and the files) at a time at one of
# the three fixed pairs; hold inside it for HOLD_S to catch it. The warm-up
# rewards speed with points (3 / 2 / 1, diamonds on the target) and waits up to
# the cap; its movement times start the calibration. Calibration is timed like
# play but kept encouraging: a staircase holds each pair at about 85 % caught;
# the day's lifetime per pair is the p-th percentile of the Kaplan–Meier
# movement-time curve from those fireflies (staircase.gd, since 2026-09-28).
# It is frozen and play gives each pair that lifetime.
#
#   - Targets are placed and hit-tested in table mm (§3.4, table_space.gd); the
#     screen only draws them. The whole circle must lie inside the reach
#     outline from the scan (reach_scan.gd) and on screen, always at the
#     pair's exact distance (_spawn).
#   - Holds are judged per tracker sample on the camera's capture clock, so at
#     100 Hz rather than at the frame rate.
#   - MT = hold start − spawn, which equals catch − spawn − hold (design.md §4.6).
#   - An apple's "window" is how long a hold may take to start: the cap in the
#     warm-up, the lifetime in calibration and play. At the end of the window
#     the apple goes unless a hold is under way, which then finishes (caught)
#     or breaks (missed). So it is caught exactly when MT <= lifetime (§3.3),
#     and an apple on screen can always still be caught.
#
# firefly_main.gd sets `config` before adding it (participant, day, level_index,
# order_id, quick, show_check, resume; optionally "boundary": a saved reach
# outline, [[x_mm, y_mm], ...], which skips the reach scan) and saves the score
# from `finished`; "scan_only": true runs just the reach scan and emits scan_done (also emitted after a normal scan). Keys: Enter / C / S on the calibration check, Enter on the
# last screen; Esc (firefly_main.gd) stops.

signal calibration_accepted(state: Dictionary)   # frozen calibration, for resuming
signal round_done(rounds_done: int)              # after each play round
signal finished                                  # the last play round ended
signal scan_done(boundary: Array)                  # scan_only: the reach outline, [[x_mm, y_mm], ...]
signal leave                                     # Enter on the last screen

const Tracker := preload("res://Games/firefly_reach/input_adapter.gd")
const Protocol := preload("res://Games/firefly_reach/protocol.gd")
const TableSpace := preload("res://Games/firefly_reach/table_space.gd")
const VisitLogger := preload("res://Games/firefly_reach/visit_logger.gd")
const ReachScan := preload("res://Games/firefly_reach/reach_scan.gd")
const Staircase := preload("res://Games/firefly_reach/staircase.gd")
const Art := preload("res://Games/firefly_reach/game_art.gd")
const Effects := preload("res://Games/firefly_reach/effects.gd")
const ForestScene := preload("res://Games/firefly_reach/forest_scene.gd")
const NightLife := preload("res://Games/firefly_reach/night_life.gd")
const Sounds := preload("res://Games/firefly_reach/sounds.gd")
const Bat := preload("res://Games/firefly_reach/bat.gd")

const TIMEOUT_GRACE_S := 0.15     # samples reach Godot ~20 ms after capture; wait for them
const MISS_PAUSE_S := 0.5         # after a timed miss, time to watch the bat take the firefly
const EDGE_MARGIN_PX := 12.0
const REPOSITION_W_MM := 60.0     # the uncounted apple that brings the hand where a pair fits
const SPOT_GRID_MM := 25.0        # grid for searching reposition spots
const FEW_SAMPLES := 20           # calibration check flags a pair with fewer apples

const GOLD := Color("FFE27A")
const AMBER := Color(1.0, 0.75, 0.4)
# The hand is a "wisp" (chosen 2026-09-28 in the Cursor Lab mockup over the red
# laser dot): ice-blue light, gold while inside a firefly.
const WISP := Color(0.59, 0.80, 1.0)
const WISP_GOLD := Color(1.0, 0.81, 0.38)
const TRAIL_MS := 320
const GAME_NAME := "FireflyReach"

enum Stage { SCAN, ROUND, REST, CHECK, DONE }

# {participant, day, level_index, order_id, quick, show_check, resume}.
# resume: {} for a fresh start, else the day record from study_db.gd
# (lifetimes, boundary, unfit, rounds_done, rounds_total).
var config: Dictionary = {}

var _ts: TableSpace
var _log: VisitLogger
var _scan: ReachScan
var _boundary := PackedVector2Array()   # reach outline, table mm; empty until the scan ends
var _rounds: Array = []          # [{phase, number}] in play order
var _round_idx: int = 0
var _stage: Stage = Stage.SCAN
var _stage_left: float = 0.0     # seconds left in the current round or rest
var _paused: bool = false        # tracker lost
var _quick: bool = false         # quick test: fewer rounds, short rests
var _scan_only: bool = false     # the assessment: the reach scan and nothing else
var _skip_scan: bool = false    # a saved reach outline came in the config
var _attempt: int = 1            # calibration attempt; C / S on the check screen add one

var _hand: Vector2 = Vector2.ZERO   # latest hand position, table mm
var _apple: Dictionary = {}         # the current apple; empty = none
var _apple_n: int = 0               # apples spawned this round
var _pair_bag: Array = []           # every block of 3 apples uses each pair once
var _unfit: Dictionary = {}         # pair -> true: not played (fits nowhere / no lifetime)
var _no_fit: bool = false           # no pair left to play
var _spots: Dictionary = {}         # pair -> reposition spots (_spots_for)
var _repositions: int = 0           # reposition apples during calibration rounds
var _round_points: int = 0
var _round_caught: int = 0          # play: pair apples caught / missed this round
var _round_missed: int = 0
var _round_hits: int = 0            # warm-up: apples that earned points this round
var _calib: Array = []              # per pair, this attempt's calibration: {caught, missed, mts}
var _stairs: Array = []             # per pair, this attempt's staircase (staircase.gd); built at calibration start
var _warm: Array = []               # per pair, warm-up movement times: where the staircases start
var _lifetimes: Array = []          # per pair, s; -1 = not played
var _play: Array = []               # per pair: {caught, missed}

var _fx: Effects                    # catch / miss feedback (visual only)
var _life: NightLife                # the moving backdrop
var _snd: Sounds
var _bat: Bat                       # races the hand to each timed firefly (visual and sound only)
var _stage_t: float = 0.0           # seconds since the stage began (card animations)
var _shown_stage: int = -1
var _float_t: float = 0.0
var _spawn_after: float = 0.0       # the next target waits for the catch's hitstop
var _trail: Array = []              # cursor tail: [{pos (px), t (ms)}]
var _sparks: Array = []             # accents on the tail: [{pos, vel (px/s), t (ms), life (s), gold}]
var _last_cur: Vector2 = Vector2.ZERO
var _rounds_before: int = 0         # play rounds done before this session (a resumed day)
var _test: bool = false             # test drive: endless, nothing saved


func _ready() -> void:
	var vp := get_viewport_rect().size
	_ts = TableSpace.new(vp)
	add_child(ForestScene.new())   # defaults: the game's forest, dimmed so targets stand out
	_life = NightLife.new()
	add_child(_life)
	_snd = Sounds.new()
	add_child(_snd)
	_fx = Effects.new(vp)
	_bat = Bat.new(vp)
	for k in Protocol.PAIRS.size():
		_play.append({"caught": 0, "missed": 0})
	_reset_calibration()
	_hand = _ts.screen_to_mm(vp * 0.5)
	_last_cur = vp * 0.5
	_scan = ReachScan.new(_ts, vp)
	_quick = bool(config.get("quick", false))
	_test = bool(config.get("test", false))
	_scan_only = bool(config.get("scan_only", false))
	var resume: Dictionary = config.get("resume", {})
	if _test:
		# Test drive (Settings -> Device): one endless warm-up round on the whole
		# screen, nothing saved.
		_rounds.append({"phase": "warmup", "number": 1})
		_start_round()
		_stage_left = INF
	elif resume.is_empty():
		var calib: int = Protocol.QUICK_CALIB_ROUNDS if _quick else Protocol.CALIB_ROUNDS
		var play: int = Protocol.QUICK_PLAY_ROUNDS if _quick else Protocol.PLAY_ROUNDS
		for i in Protocol.WARMUP_ROUNDS:
			_rounds.append({"phase": "warmup", "number": i + 1})
		for i in calib:
			_rounds.append({"phase": "calibration", "number": i + 1})
		for i in play:
			_rounds.append({"phase": "play", "number": i + 1})
		_stage = Stage.SCAN
	else:
		_restore(resume)
	var saved: Array = config.get("boundary", [])
	if resume.is_empty() and not _test and saved.size() >= 3:
		for pt in saved:
			_boundary.append(Vector2(pt[0], pt[1]))
		_bat_band()
		_skip_scan = true   # the assessment's reach outline is used as it is
	_log = VisitLogger.new()
	if not _test and not _scan_only:
		_log.open(GAME_NAME, String(config["participant"]), _header_lines())
	# The participant sees only the wisp; the system arrow is hidden (it
	# still moves, for the mouse fallback in development).
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN


# A stopped day resumes play with its frozen calibration (§4.8): the remaining
# play rounds, after a rest to get ready.
func _restore(r: Dictionary) -> void:
	_lifetimes = r["lifetimes"]
	for pt in r["boundary"]:
		_boundary.append(Vector2(pt[0], pt[1]))
	_bat_band()
	for k in r["unfit"]:
		_unfit[int(k)] = true
	_rounds_before = int(r["rounds_done"])
	for i in range(int(r["rounds_done"]), int(r["rounds_total"])):
		_rounds.append({"phase": "play", "number": i + 1})
	_stage = Stage.REST
	_stage_left = _rest_s()


func _exit_tree() -> void:
	_log.close()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE   # back for the operator screens


# Tells the bat which screen rows fireflies can appear in (the reach outline's
# top and bottom), so it rests outside them.
func _bat_band() -> void:
	if _boundary.size() < 3:
		return
	var top := INF
	var bottom := -INF
	for p in _boundary:
		var s := _ts.mm_to_screen(p)
		top = minf(top, s.y)
		bottom = maxf(bottom, s.y)
	_bat.set_play_band(top, bottom)


# A labelled moment in the tracker's recording (tracker/marks.csv): the event,
# the phase, round and firefly number, e.g. "spawn calibration r2 a7". It ties
# targets.csv to the tracker's per-frame files even if the board's clock steps.
func _mark(_event: String, _n: int = 0) -> void:
	pass   # the clinic build sent these to the tracker's recorder; there is none here


# Fireflies caught in the play rounds so far: the score.
func play_caught() -> int:
	var n := 0
	for p in _play:
		n += int(p["caught"])
	return n


func _rest_s() -> float:
	return Protocol.QUICK_REST_S if _quick else Protocol.REST_S


func _rounds_of(phase: String) -> int:
	var n := 0
	for r in _rounds:
		if r["phase"] == phase:
			n += 1
	return n


func _header_lines() -> Array:
	var pairs := PackedStringArray()
	for p in Protocol.PAIRS:
		pairs.append("%d/%d" % [int(p["a_mm"]), int(p["w_mm"])])
	var ppm := _ts.px_per_mm()
	var resume: Dictionary = config.get("resume", {})
	return [
		"participant,%s" % config["participant"],
		"study_day,%d" % int(config["day"]),
		"order_id,%d" % int(config["order_id"]),
		"level_index,%d" % (int(config["level_index"]) + 1),
		"level_p,%.2f" % _level_p(),
		"resumed_after_round,%s" % (str(int(resume["rounds_done"])) if not resume.is_empty() else ""),
		"firefly_protocol,%s" % Protocol.VERSION,
		"quick_test,%s" % _quick,
		"pairs_a_w_mm,%s" % " ".join(pairs),
		"hold_s,%s" % Protocol.HOLD_S,
		"warmup_rounds,%d" % Protocol.WARMUP_ROUNDS,
		"reach_corners,%d" % ReachScan.VERTICES,
		"calibration,km (timed at >= %.2f catch rate; level = Kaplan-Meier percentile; staircase.gd)"
			% Staircase.calibration_rate(_level_p()),
		"point_cap_s,%s" % Protocol.POINT_CAP_S,
		"screen_mapped,%s" % _ts.mapped,
		"px_per_mm_x_y,%.3f %.3f" % [ppm.x, ppm.y],
		"timing,frame rate (one hand sample per frame)",
	]


func _level_p() -> float:
	return Protocol.LEVELS[int(config["level_index"])]


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var key: int = event.keycode
	if _stage == Stage.DONE:
		if key == KEY_ENTER or key == KEY_KP_ENTER:
			leave.emit()
	elif _stage == Stage.SCAN:
		if key == KEY_ENTER or key == KEY_KP_ENTER:
			_scan.finish()   # the researcher accepts the reach area as it is
	elif _stage == Stage.CHECK:
		if key == KEY_ENTER or key == KEY_KP_ENTER:
			_accept_calibration()
		elif key == KEY_C:
			_redo_calibration(false)
		elif key == KEY_S:
			_redo_calibration(true)


func _process(delta: float) -> void:
	_read_hand()
	_update_pause()
	if not _paused:
		match _stage:
			Stage.SCAN:
				_scan.update(delta)
				if _skip_scan:
					_skip_scan = false
					_start_round()
				elif _scan.is_done():
					var rows: Array = []
					for r in _scan.csv_rows():
						rows.append([_attempt] + r)
					_log.log_reach(rows)
					_boundary = _scan.boundary()
					var out: Array = []
					for pt in _boundary:
						out.append([pt.x, pt.y])
					scan_done.emit(out)
					if _scan_only:
						_stage = Stage.DONE
						return
					_bat_band()
					_start_round()
			Stage.ROUND:
				_stage_left -= delta
				if _apple.is_empty():
					if _now() >= _spawn_after:   # after the last catch's hitstop
						_spawn()
				elif _apple_expired():
					_finish_apple("timeout", _window_end())
				if _stage_left <= 0.0:
					_end_round()
			Stage.REST:
				_stage_left -= delta
				if _stage_left <= 0.0:
					_start_round()
	# Visuals and sound only from here.
	if int(_stage) != _shown_stage:
		_shown_stage = int(_stage)
		_stage_t = 0.0
	var before := _stage_t
	_stage_t += delta
	if _stage == Stage.REST:
		# A bell for each star as it pops in on the rest card.
		for i in _rest_stars():
			var at := 0.25 + 0.28 * float(i)
			if before < at and _stage_t >= at:
				_snd.star(i)
	_fx.update(delta)
	var now_ms := Time.get_ticks_msec()
	var cur := _ts.mm_to_screen(_hand)
	_bat.set_hand(cur)
	_bat.update(delta, _now())
	_snd.bat(_stage == Stage.ROUND and not _paused, _bat.click_rate, _bat.click_gain, _bat.wing_gain, _bat.pan)
	if _trail.is_empty() or cur.distance_to(_trail[-1]["pos"]) > 3.0:
		_trail.append({"pos": cur, "t": now_ms})
	while not _trail.is_empty() and now_ms - int(_trail[0]["t"]) > TRAIL_MS:
		_trail.pop_front()
	# A spark or two where the hand moved, drifting a little and fading.
	var moved := cur.distance_to(_last_cur)
	if moved > 1.0:
		for i in mini(2, ceili(moved / 16.0)):
			var f := float(i) / 2.0
			_sparks.append({"pos": _last_cur.lerp(cur, f) + Vector2(randf() - 0.5, randf() - 0.5) * 6.0,
				"vel": Vector2(randf() - 0.5, randf() - 0.5) * 40.0 + Vector2(0.0, 12.0),
				"t": now_ms, "life": 0.22 + randf() * 0.14, "gold": _hand_inside()})
	_last_cur = cur
	while not _sparks.is_empty() and now_ms - int(_sparks[0]["t"]) > 400:
		_sparks.pop_front()
	if _stage == Stage.DONE:
		_float_t += delta
		if _float_t > 0.2:
			_float_t = 0.0
			var vp := get_viewport_rect().size
			_fx.float_up(Vector2(randf() * vp.x, vp.y + 10.0))
	queue_redraw()


# ── Hand samples ──────────────────────────────────────────────────────────────

func _now() -> float:
	return Time.get_unix_time_from_system()


# Feeds every tracker sample since the last frame to the hold logic and the
# hand log. input_adapter.gd gives one per frame.
func _read_hand() -> void:
	var samples: Array = Tracker.take_samples()
	if not Tracker.connected():
		# Mouse fallback (development only): one sample per frame, not logged.
		_on_sample(_now(), _ts.screen_to_mm(get_global_mouse_position()))
		return
	var phase := _phase_name()
	var rnd := _round_number()
	var rows: Array = []
	for s in samples:
		# s = [arrival, screen_x, screen_y, tracker_x, tracker_y, tracker_z, capture]
		var mm := TableSpace.tracker_to_mm(s[3], s[5])
		rows.append(["%.6f" % s[0], "%.6f" % s[6], phase, rnd,
			"%.2f" % mm.x, "%.2f" % mm.y, s[3], s[4], s[5]])
		_on_sample(s[6], mm)
	_log.log_hand(rows)


func _on_sample(t: float, mm: Vector2) -> void:
	_hand = mm
	if _stage == Stage.SCAN and not _paused:
		_scan.on_sample(t, mm)
		return
	if _paused or _stage != Stage.ROUND or _apple.is_empty():
		return
	var spawn: float = _apple["spawn_time"]
	if t < spawn:
		return
	if not TableSpace.inside(mm, _apple["centre"], _apple["w_mm"]):
		if float(_apple["hold_start"]) >= 0.0:
			_mark("hold_break", int(_apple["n"]))
			# Still time left: the bat, which had turned away, hunts again.
			if _apple["timed"] and t - spawn <= float(_apple["window"]):
				_bat.hunt(_ts.mm_to_screen(_apple["centre"]), _target_size(float(_apple["w_mm"])).x * 0.5,
					spawn, float(_apple["window"]), _now(), true)
		_apple["hold_start"] = -1.0
		return
	var hold_start: float = _apple["hold_start"]
	if hold_start < 0.0:
		if t - spawn <= float(_apple["window"]):   # past the window no new hold may start
			_apple["hold_start"] = t
			_mark("hold", int(_apple["n"]))
			var was_hunting := _bat.is_hunting()
			_bat.give_up()   # the hand got there first: the bat turns away
			if was_hunting:
				_snd.bat_gives_up(_bat.pos)
	elif t - hold_start >= Protocol.HOLD_S:
		_finish_apple("caught", t)


# Tracker was streaming but packets stopped: freeze the round and drop the
# apple, or hold the reach scan's quiet timer.
func _update_pause() -> void:
	var lost: bool = Tracker.connected() and not Tracker.is_fresh()
	if lost == _paused:
		return
	_paused = lost
	SessionLog.set_paused(lost)
	if not lost:
		return
	if not _apple.is_empty():
		_finish_apple("aborted", _now())
	if _stage == Stage.SCAN:
		_scan.pause()


# ── Rounds ────────────────────────────────────────────────────────────────────

func _start_round() -> void:
	_stage = Stage.ROUND
	_stage_left = Protocol.ROUND_S
	if _phase_name() == "calibration" and _stairs.is_empty():
		_build_stairs()   # the first calibration round of this attempt
	_mark("round_start")
	_snd.round_started()   # the jar keeps its fireflies across rounds (effects.gd)
	_round_points = 0
	_round_caught = 0
	_round_missed = 0
	_round_hits = 0
	_apple_n = 0
	_pair_bag = []


func _end_round() -> void:
	if not _apple.is_empty():
		_finish_apple("aborted", _now())
	_mark("round_end")
	var ended: Dictionary = _rounds[_round_idx]
	_round_idx += 1
	if ended["phase"] == "play":
		round_done.emit(int(ended["number"]))
	if _round_idx >= _rounds.size():
		_stage = Stage.DONE
		_log.close()
		finished.emit()
	elif ended["phase"] == "calibration" and _rounds[_round_idx]["phase"] == "play":
		_enter_check()
	else:
		_stage = Stage.REST
		_stage_left = _rest_s()


func _phase_name() -> String:
	match _stage:
		Stage.ROUND:
			return _rounds[_round_idx]["phase"]
		Stage.REST:
			return "rest"
		Stage.SCAN:
			return "reach_scan"
		Stage.CHECK:
			return "check"
	return "done"


# The round being played; during a rest, the round just finished (0 before the
# first round of a resumed day).
func _round_number() -> int:
	match _stage:
		Stage.ROUND:
			return _rounds[_round_idx]["number"]
		Stage.REST:
			return _prev_round().get("number", 0)
	return 0


# The round before the current one; {} at the start of a resumed day.
func _prev_round() -> Dictionary:
	return _rounds[_round_idx - 1] if _round_idx > 0 else {}


# ── Calibration -> play ───────────────────────────────────────────────────────

func _reset_calibration() -> void:
	_calib = []
	for k in Protocol.PAIRS.size():
		_calib.append({"caught": 0, "missed": 0, "mts": []})
	_stairs = []
	_repositions = 0
	if _warm.is_empty():
		for k in Protocol.PAIRS.size():
			_warm.append([])


# One staircase per pair, starting at the pair's warm-up median movement time
# (1 s if the warm-up caught none of that pair).
func _build_stairs() -> void:
	_stairs = []
	for k in Protocol.PAIRS.size():
		var v: Array = _warm[k].duplicate()
		v.sort()
		var start: float = v[v.size() / 2] if not v.is_empty() else 1.0
		_stairs.append(Staircase.new(start, Staircase.calibration_rate(_level_p())))


# Play's lifetime per pair: the day's percentile p of the pair's Kaplan–Meier
# movement-time curve from the timed calibration (staircase.gd).
func _enter_check() -> void:
	_lifetimes = []
	for k in Protocol.PAIRS.size():
		_lifetimes.append(Staircase.level_lifetime(_stairs[k].trials, _level_p()) if k < _stairs.size() else -1.0)
	if bool(config.get("show_check", true)):
		_stage = Stage.CHECK
	else:
		_accept_calibration()


# The model is frozen from here on (§3.3): these lifetimes hold for all of play.
func _accept_calibration() -> void:
	var rows: Array = []
	for k in Protocol.PAIRS.size():
		var c: Dictionary = _calib[k]
		var lt: float = _lifetimes[k]
		if lt < 0.0:
			_unfit[k] = true
		var st: Staircase = _stairs[k] if k < _stairs.size() else null
		var has := st != null and not st.trials.is_empty()
		rows.append([_attempt, k + 1, _pair_a(k), _pair_w(k), c["caught"], c["missed"],
			("%.2f" % st.rate) if st else "", ("%.4f" % st.trials[0][0]) if has else "",
			("%.3f" % Staircase.km_reach(st.trials)) if has else "",
			"%.2f" % _level_p(), ("%.4f" % lt) if lt >= 0.0 else ""])
	_log.log_calibration(rows)
	var boundary: Array = []
	for pt in _boundary:
		boundary.append([pt.x, pt.y])
	calibration_accepted.emit({
		"lifetimes": _lifetimes.duplicate(), "boundary": boundary, "unfit": _unfit.keys(),
		"rounds_total": _rounds_of("play"),
	})
	_no_fit = false
	_stage = Stage.REST
	_stage_left = _rest_s()


# C: play the calibration rounds again. S: the reach scan first, then them.
func _redo_calibration(rescan: bool) -> void:
	_attempt += 1
	_reset_calibration()
	_round_idx = Protocol.WARMUP_ROUNDS
	_no_fit = false
	if rescan:
		_boundary = PackedVector2Array()
		_spots = {}
		_unfit = {}
		_scan = ReachScan.new(_ts, get_viewport_rect().size)
		_stage = Stage.SCAN
	else:
		_start_round()


# ── Apples ────────────────────────────────────────────────────────────────────

# Every counted apple sits at its pair's exact distance A from the hand — never
# shortened. When the hand is somewhere the pairs still due in this block do not
# fit from:
#   1. try the other pairs still due in the block;
#   2. else put an uncounted "reposition" apple (big, easy) at the nearest spot
#      from which a due pair does fit, so the next apple can go at full distance;
#   3. a pair that fits from nowhere in the reach area is skipped for the visit
#      (the summary says so: the pair values are too big for this reach).
func _spawn() -> void:
	if _no_fit:
		return
	if _pair_bag.is_empty():
		for k in Protocol.PAIRS.size():
			if not _unfit.has(k):
				_pair_bag.append(k)
		if _pair_bag.is_empty():
			_no_fit = true
			return
		_pair_bag.shuffle()
	for i in range(_pair_bag.size() - 1, -1, -1):
		var k: int = _pair_bag[i]
		var angles := _fit_angles(_hand, _pair_a(k), _pair_w(k) * 0.5, 36)
		if not angles.is_empty():
			_pair_bag.remove_at(i)
			var ang: float = angles.pick_random()
			_new_apple("pair", k, _hand + Vector2.from_angle(ang) * _pair_a(k), _pair_w(k))
			return
	for i in range(_pair_bag.size() - 1, -1, -1):
		var k: int = _pair_bag[i]
		var spot = _reposition_spot(k)
		if spot != null:
			_new_apple("reposition", -1, spot, REPOSITION_W_MM)
			return
		_pair_bag.remove_at(i)
		_unfit[k] = true


func _new_apple(kind: String, k: int, centre: Vector2, w: float) -> void:
	var t := _now()
	var dist := _hand.distance_to(centre)
	# Timed (a lifetime, a draining rim, caught or missed): play at the frozen
	# lifetime, calibration at the pair's staircase lifetime. Warm-up and
	# reposition apples wait up to the cap and earn speed points.
	var phase := _phase_name()
	var in_play := phase == "play" and kind == "pair"
	var timed := (phase == "play" or phase == "calibration") and kind == "pair"
	var window: float = Protocol.POINT_CAP_S
	if in_play:
		window = _lifetimes[k]
	elif timed:
		window = (_stairs[k] as Staircase).lifetime
	_apple_n += 1
	_apple = {
		"kind": kind, "pair": k, "a_mm": _pair_a(k) if k >= 0 else dist, "w_mm": w,
		"n": _apple_n, "start": _hand, "centre": centre,
		"angle": (centre - _hand).angle(), "a_actual": dist,
		"spawn_time": t, "hold_start": -1.0, "play": in_play, "timed": timed, "window": window,
		"look": randf() * TAU, "ph": randf(),   # the firefly's heading and blink phase (drawing only)
	}
	_mark("spawn" if kind == "pair" else "spawn_reposition", _apple_n)
	var pos := _ts.mm_to_screen(centre)
	_snd.firefly_appears(pos)
	if timed:
		_bat.hunt(pos, _target_size(w).x * 0.5, t, window, t)


func _window_end() -> float:
	return float(_apple["spawn_time"]) + float(_apple["window"])


# Past its window with no hold under way. The grace lets the last tracker
# samples of the window arrive (they reach Godot ~20 ms after capture).
func _apple_expired() -> bool:
	return float(_apple["hold_start"]) < 0.0 and _now() > _window_end() + TIMEOUT_GRACE_S


func _pair_a(k: int) -> float:
	return Protocol.PAIRS[k]["a_mm"]


func _pair_w(k: int) -> float:
	return Protocol.PAIRS[k]["w_mm"]


# Directions (radians) in which a circle of radius r at distance a from start fits.
func _fit_angles(start: Vector2, a: float, r: float, n: int) -> Array:
	var out: Array = []
	var offset := randf() * TAU
	for i in n:
		var ang := offset + TAU * float(i) / float(n)
		if _fits(start + Vector2.from_angle(ang) * a, r):
			out.append(ang)
	return out


# Nearest spot to the hand from which pair k fits in plenty of directions
# (at least half as many as the best spot), so where the hand ends up inside
# the reposition circle does not matter. null when the pair fits from nowhere.
func _reposition_spot(k: int) -> Variant:
	var spots := _spots_for(k)
	if spots.is_empty():
		return null
	var most := 0
	for s in spots:
		most = maxi(most, s["n"])
	var pick = null
	var nearest := INF
	for s in spots:
		var d := _hand.distance_to(s["pos"])
		if int(s["n"]) * 2 >= most and d < nearest:
			nearest = d
			pick = s["pos"]
	return pick


# Grid points (every SPOT_GRID_MM) where a reposition apple fits and from which
# pair k fits in some direction: [{pos, n = how many of 24 directions}].
# Computed once per pair, the first time it is needed.
func _spots_for(k: int) -> Array:
	if _spots.has(k):
		return _spots[k]
	var area := Rect2(_boundary[0], Vector2.ZERO) if _boundary.size() >= 3 \
		else Rect2(_ts.screen_to_mm(Vector2.ZERO), Vector2.ZERO)
	for b in _boundary:
		area = area.expand(b)
	if _boundary.size() < 3:
		area = area.expand(_ts.screen_to_mm(get_viewport_rect().size))
	var list: Array = []
	var x := area.position.x
	while x <= area.end.x:
		var y := area.position.y
		while y <= area.end.y:
			var p := Vector2(x, y)
			if _fits(p, REPOSITION_W_MM * 0.5):
				var n := _fit_angles(p, _pair_a(k), _pair_w(k) * 0.5, 24).size()
				if n > 0:
					list.append({"pos": p, "n": n})
			y += SPOT_GRID_MM
		x += SPOT_GRID_MM
	_spots[k] = list
	return list


# The whole circle is on screen and inside the reach outline.
func _fits(centre: Vector2, r: float) -> bool:
	if not _ts.fits_on_screen(centre, r, get_viewport_rect().size, EDGE_MARGIN_PX):
		return false
	if _boundary.size() < 3:
		return true
	for i in 16:
		var p := centre + Vector2.from_angle(TAU * float(i) / 16.0) * r
		if not Geometry2D.is_point_in_polygon(p, _boundary):
			return false
	return true


func _finish_apple(outcome: String, t: float) -> void:
	var a: Dictionary = _apple
	_apple = {}
	var k: int = a["pair"]
	var reposition: bool = a["kind"] == "reposition"
	var in_play: bool = a["play"]
	var timed: bool = a["timed"]
	var phase := _phase_name()
	var in_calib := phase == "calibration" and not reposition
	if outcome == "timeout" and timed:
		outcome = "missed"
	_mark(outcome, int(a["n"]))
	var caught := outcome == "caught"
	if caught:
		SessionLog.hit()
	elif outcome == "missed" or outcome == "timeout":
		SessionLog.miss()
	var mt := -1.0
	var pts := 0
	if caught:
		mt = float(a["hold_start"]) - float(a["spawn_time"])
	if reposition and phase == "calibration":
		_repositions += 1
	if timed:
		# Calibration and play: caught or missed against the lifetime.
		if caught:
			_round_caught += 1
		elif outcome == "missed":
			_round_missed += 1
		if in_play and (caught or outcome == "missed"):
			_play[k]["caught" if caught else "missed"] += 1
		if in_calib and (caught or outcome == "missed"):
			_calib[k]["caught" if caught else "missed"] += 1
			if caught:
				_calib[k]["mts"].append(mt)
			(_stairs[k] as Staircase).update(caught, mt)
	elif caught:
		# Warm-up and reposition apples: speed points; the warm-up's movement
		# times start the staircases.
		pts = Protocol.points_for(mt)
		_round_points += pts
		_round_hits += 1
		if phase == "warmup" and not reposition:
			_warm[k].append(mt)
	var start: Vector2 = a["start"]
	var centre: Vector2 = a["centre"]
	# Reposition apples: phase "reposition", pair 0, so a filter on the phase
	# leaves them out.
	_log.log_target([
		"reposition" if reposition else _phase_name(), _attempt, _round_number(), a["n"],
		k + 1, "%.1f" % a["a_mm"], a["w_mm"],
		"%.1f" % a["a_actual"], "%.1f" % rad_to_deg(a["angle"]),
		"%.2f" % start.x, "%.2f" % start.y, "%.2f" % centre.x, "%.2f" % centre.y,
		"%.6f" % a["spawn_time"], ("%.4f" % a["window"]) if timed else "",
		("%.6f" % a["hold_start"]) if caught else "",
		outcome, "%.6f" % t, ("%.4f" % mt) if caught else "", pts,
	])
	# Feedback only (already logged): a catch holds still for a moment (hitstop,
	# longer for a better grade), bursts with its grade and sound, and flies to
	# the jar; a miss dims and sinks; an aborted one just goes.
	var pos := _ts.mm_to_screen(centre)
	var size := _target_size(float(a["w_mm"]))
	if caught:
		var grade := 0 if timed else pts
		_spawn_after = _now() + _fx.catch_at(pos, size, grade)
		_snd.caught(grade)
		_bat.caught()
	elif outcome == "missed":
		# Timed: the bat takes it (bat.gd keeps drawing the firefly until then).
		# The next firefly waits MISS_PAUSE_S so the eye stays on the catch.
		_snd.missed(pos)
		_bat.missed(pos, _fly_len(size), float(a["look"]), _now())
		_spawn_after = _now() + MISS_PAUSE_S
	elif outcome == "timeout":
		_fx.miss_at(pos, size)
		_snd.missed()
	else:
		_bat.caught()   # aborted: the bat just goes back


# ── Drawing ───────────────────────────────────────────────────────────────────

func _draw() -> void:
	var vp := get_viewport_rect().size
	# The night backdrop is two children drawn behind this node (forest_scene.gd, night_life.gd).
	if _stage == Stage.ROUND:
		_fx.draw_jar(self)   # the rest screen draws it large, as its hero
	if _stage == Stage.ROUND and not _paused and not _apple.is_empty():
		_draw_apple()
	_fx.draw(self)
	if _stage == Stage.ROUND and not _paused:
		_bat.draw(self)
	if _stage == Stage.SCAN:
		_scan.draw(self, Art.font())
	_draw_cursor()
	_draw_hud(vp)
	if _stage == Stage.ROUND and _no_fit:
		_label(vp * 0.5, "None of the pairs fits this reach area", 24, AMBER)
	if _stage == Stage.ROUND and _phase_name() == "play" and bool(config.get("show_check", false)):
		_draw_overlay(vp)
	match _stage:
		Stage.REST:
			_draw_rest(vp)
		Stage.CHECK:
			_draw_check(vp)
		Stage.DONE:
			_draw_complete(vp)
	if _paused:
		_draw_pause(vp)
	if not _ts.mapped:
		draw_string(Art.font(), Vector2(16.0, vp.y - 12.0),
			"Screen mapping not set: drawing at 3 px/mm. Run the 4-corner mapping in the installer.",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, AMBER)


# Text with a soft dark halo, readable anywhere on the night sky.
func _label(pos: Vector2, s: String, size: int, col: Color) -> void:
	Art.text(self, pos, s, size, col, Color(0.02, 0.03, 0.08, 0.6))


# The catch circle on screen: W mm across, which may be a slight ellipse when
# the screen mapping scales x and y differently (§3.4).
func _target_size(w_mm: float) -> Vector2:
	var ppm := _ts.px_per_mm()
	return Vector2(w_mm * ppm.x, w_mm * ppm.y)


# Points it is worth right now (calibration): 3, 2, 1 as the limits pass.
func _worth(now: float) -> int:
	return Protocol.points_for(now - float(_apple["spawn_time"]))


# The firefly's body length on screen, px, from the catch circle's size.
func _fly_len(size: Vector2) -> float:
	return clampf(size.x * 0.4, 22.0, 40.0)


# The lantern's light now, 0..1: a flash of about 0.3 s once a period, the
# period shortening from 1.0 s to 0.45 s as a timed firefly's lifetime runs out
# (period = 1 - 0.55·u², u = time used / lifetime); steady while held.
func _lamp_level(now: float, holding: bool) -> float:
	if holding:
		return 0.95
	var u := 0.0
	if _apple["timed"]:
		u = clampf((now - float(_apple["spawn_time"])) / float(_apple["window"]), 0.0, 1.0)
	var period := 1.0 - 0.55 * u * u
	var ph := fmod(now + float(_apple["ph"]), period) / period
	return 0.18 + 0.82 * exp(-pow((ph - 0.2) / 0.12, 2.0))


# The target: a firefly (since 2026-09-29 a real-looking beetle, Art.draw_firefly,
# before a glowing disc) inside a thin ring that marks the catch circle, W.
#   its lantern flashes about 0.3 s each second, faster as the lifetime runs out;
#   warm-up:     three diamonds above it, one going out at each point limit (3 -> 2 -> 1);
#   holding:     it folds its wings, its light stays on and a bright ring closes
#                around it — full = caught;
#   calibration and play: the ring drains over the lifetime (and the bat comes, bat.gd).
func _draw_apple() -> void:
	var centre: Vector2 = _apple["centre"]
	var w: float = _apple["w_mm"]
	var now := _now()
	var c := _ts.mm_to_screen(centre)
	var size := _target_size(w)
	var inside := TableSpace.inside(_hand, centre, w)
	var hold_start: float = _apple["hold_start"]
	var holding := hold_start >= 0.0
	var L := _fly_len(size)
	var ang: float = _apple["look"]
	var lamp := _lamp_level(now, holding)
	var body := c + Vector2(0.0, sin(now * 3.0 + float(_apple["ph"]) * 6.0) * 1.2)
	var lp := Art.lamp_pos(body, L, ang)
	Art.blit(self, Art.glow(), lp, Vector2.ONE * L * (2.4 + 6.4 * lamp), Color(Art.LAMP_GLOW, 0.12 + 0.6 * lamp))
	Art.draw_firefly(self, body, L, ang, lamp, now, not holding)
	Art.blit(self, Art.glow(), lp, Vector2.ONE * L * 0.9, Color(Art.LAMP_CORE, 0.7 * lamp))
	var frac := 0.0
	if holding:
		frac = clampf((now - hold_start) / Protocol.HOLD_S, 0.0, 1.0)
	var rim := Color(1.0, 0.97, 0.86, 0.98) if inside else Color(Art.LAMP, 0.85)
	var rim_w := 3.0
	if _apple["timed"]:
		# Calibration and play: the rim itself drains over the lifetime.
		var window: float = _apple["window"]
		var left := clampf((_window_end() - now) / window, 0.0, 1.0)
		_arc(centre, w * 0.5, 1.0, Color(rim, 0.18), rim_w)
		_arc(centre, w * 0.5, left, rim, rim_w + 1.0)
	else:
		_arc(centre, w * 0.5, 1.0, rim, rim_w)
	# Holding: a bright ring fills around the firefly, full = caught.
	if frac > 0.0:
		var r := maxf(size.x, size.y) * 0.5 + 9.0
		Art.blit(self, Art.glow(), c, Vector2.ONE * (r * 2.6), Color(Art.LAMP_GLOW, 0.16 * frac))
		draw_arc(c, r, -PI * 0.5, -PI * 0.5 + TAU * frac, 64, Art.LAMP_CORE, 6.0, true)
	# Warm-up: three diamonds above it, the points still to be had (3 -> 2 -> 1).
	if not _apple["timed"] and _apple["kind"] == "pair":
		var worth := _worth(now) if hold_start < 0.0 else Protocol.points_for(hold_start - float(_apple["spawn_time"]))
		for i in 3:
			Art.draw_diamond(self, c + Vector2((float(i) - 1.0) * 24.0, -size.y * 0.5 - 28.0), 7.5, i < worth)


# Part of a table-space ring, from the top, clockwise.
func _arc(centre: Vector2, r_mm: float, frac: float, col: Color, width: float) -> void:
	var n := int(clampf(frac, 0.0, 1.0) * 64.0)
	if n < 1:
		return
	var pts := PackedVector2Array()
	for i in n + 1:
		var a := -PI * 0.5 + TAU * float(i) / 64.0
		pts.append(_ts.mm_to_screen(centre + Vector2(cos(a), sin(a)) * r_mm))
	draw_polyline(pts, col, width, true)


# True while the hand is inside the current firefly (the wisp turns gold).
func _hand_inside() -> bool:
	if _stage != Stage.ROUND or _paused or _apple.is_empty():
		return false
	return TableSpace.inside(_hand, _apple["centre"], _apple["w_mm"])


# The hand: the "wisp" from the Cursor Lab mockup (2026-09-28). A small bright
# core, a thin ring and a see-through glow, so a small firefly stays visible
# underneath; ice-blue, gold while inside a firefly, pulsing while holding.
# Tail: a soft glow stamped every 4 px along the last TRAIL_MS of movement,
# shrinking and fading with age, a thin bright line down its middle, and a
# few sparks as accents.
func _draw_cursor() -> void:
	var now := Time.get_ticks_msec()
	var inside := _hand_inside()
	var hold := 0.0
	if inside and float(_apple["hold_start"]) >= 0.0:
		hold = clampf((_now() - float(_apple["hold_start"])) / Protocol.HOLD_S, 0.0, 1.0)
	var col := WISP_GOLD if inside else WISP
	var glow := Art.glow()
	for i in range(1, _trail.size()):
		var p0: Vector2 = _trail[i - 1]["pos"]
		var p1: Vector2 = _trail[i]["pos"]
		var t0 := float(_trail[i - 1]["t"])
		var t1 := float(_trail[i]["t"])
		var steps := maxi(1, ceili(p0.distance_to(p1) / 4.0))
		for s in steps:
			var f := float(s) / float(steps)
			var age := (float(now) - lerpf(t0, t1, f)) / float(TRAIL_MS)
			if age < 1.0:
				Art.blit(self, glow, p0.lerp(p1, f), Vector2.ONE * (62.0 - 46.0 * age), Color(col, 0.2 * (1.0 - age)))
	var core_line := Color(1.0, 0.94, 0.77) if inside else Color(0.89, 0.96, 1.0)
	for i in range(1, _trail.size()):
		var age := float(now - int(_trail[i]["t"])) / float(TRAIL_MS)
		draw_line(_trail[i - 1]["pos"], _trail[i]["pos"], Color(core_line, 0.85 * (1.0 - age)),
			lerpf(10.0, 2.0, age), true)
	for sp in _sparks:
		var dt := float(now - int(sp["t"])) / 1000.0
		var age: float = dt / float(sp["life"])
		if age < 1.0:
			var pos: Vector2 = sp["pos"] + sp["vel"] * dt
			Art.blit(self, glow, pos, Vector2.ONE * 18.0 * (1.0 - age),
				Color(WISP_GOLD if sp["gold"] else WISP, 0.7 * (1.0 - age)))
	var c := _ts.mm_to_screen(_hand)
	var pulse := 1.0 + 0.08 * sin(_now() * 18.0) if hold > 0.0 else 1.0
	Art.blit(self, glow, c, Vector2.ONE * (104.0 if inside else 86.0) * pulse, Color(col, 0.42 + 0.35 * hold))
	draw_arc(c, (17.0 if inside else 20.0) * pulse, 0.0, TAU, 48,
		Color(1.0, 0.89, 0.55, 0.95) if inside else Color(0.78, 0.91, 1.0, 0.85), 2.6 if inside else 2.0, true)
	Art.blit(self, glow, c, Vector2(30.0, 30.0), Color(col, 0.9))
	Art.blit(self, Art.disc(), c, Vector2(12.0, 12.0), Color(1.0, 0.96, 0.82) if inside else Color(0.93, 0.97, 1.0))


# Phase names as the participant sees them.
func _phase_title(phase: String) -> String:
	match phase:
		"play":
			return "ROUND"
		"warmup":
			return "WARM-UP"
	return "CALIBRATION"


# In-round HUD (Night Forest mockup): top left the round — its name, number of
# total and a draining time bar; top right the score — points (warm-up) or
# fireflies caught (calibration, play). The rest screen shows its own.
func _draw_hud(vp: Vector2) -> void:
	if _stage != Stage.ROUND:
		return
	var phase := _phase_name()
	var play := phase == "play"
	var total := _rounds_of(phase) + (_rounds_before if play else 0)
	var box := Rect2(44.0, 36.0, 360.0, 124.0)
	Art.draw_glass(self, box, 18)
	Art.text_left(self, box.position + Vector2(30.0, 30.0), _phase_title(phase), 15, Art.ICE_HI)
	var num := str(_round_number())
	Art.text_left(self, box.position + Vector2(30.0, 72.0), num, 50, Art.INK)
	Art.text_left(self, box.position + Vector2(38.0 + Art.text_width(num, 50), 78.0), "/%d" % total, 24, Art.MUTED)
	if not is_inf(_stage_left):
		var left := maxi(ceili(_stage_left), 0)
		Art.text_right(self, Vector2(box.end.x - 30.0, box.position.y + 78.0), "%d:%02d" % [left / 60, left % 60],
			20, Art.ICE_HI)
		Art.draw_bar(self, Rect2(box.position.x + 30.0, box.end.y - 24.0, box.size.x - 60.0, 9.0),
			_stage_left / Protocol.ROUND_S, Art.ICE)
	var timed := phase != "warmup"   # calibration and play: caught against a lifetime
	var score := str(_round_caught) if timed else str(_round_points)
	var sw := maxf(230.0, Art.text_width(score, 56) + 120.0)
	var plate := Rect2(vp.x - 44.0 - sw, 36.0, sw, 124.0)
	Art.draw_glass(self, plate, 18)
	Art.text_right(self, Vector2(plate.end.x - 30.0, plate.position.y + 30.0), "CAUGHT" if timed else "POINTS",
		15, Art.GOLD)
	Art.text_right(self, Vector2(plate.end.x - 30.0, plate.position.y + 78.0), score, 56, Art.GOLD,
		Color(1.0, 0.72, 0.25, 0.22))
	var fly := Vector2(plate.end.x - 52.0 - Art.text_width(score, 56), plate.position.y + 80.0)
	Art.blit(self, Art.glow(), fly, Vector2(44.0, 44.0), Color(Art.LAMP_GLOW, 0.85))
	Art.blit(self, Art.disc(), fly, Vector2(11.0, 11.0), Art.LAMP_CORE)


func _dim(vp: Vector2, a: float = 0.45) -> void:
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0.02, 0.03, 0.08, a))


# The rest countdown: a draining ring with the seconds in it, and a caption.
func _countdown(pos: Vector2, caption: String, title: String) -> void:
	var rc := pos + Vector2(52.0, 0.0)
	draw_circle(rc, 46.0, Color(0.03, 0.07, 0.16, 0.6), true, -1.0, true)
	draw_arc(rc, 46.0, 0.0, TAU, 64, Color(0.55, 0.75, 1.0, 0.18), 5.0, true)
	var left := clampf(_stage_left / _rest_s(), 0.0, 1.0)
	if left > 0.0:
		Art.blit(self, Art.glow(), rc, Vector2(150.0, 150.0), Color(Art.ICE, 0.12))
		draw_arc(rc, 46.0, -PI * 0.5, -PI * 0.5 + TAU * left, 64, Color("9FDBFF"), 5.0, true)
	Art.text(self, rc, str(maxi(ceili(_stage_left), 0)), 44, Art.INK)
	Art.text_left(self, pos + Vector2(126.0, -16.0), caption, 14, Art.MUTED)
	Art.text_left(self, pos + Vector2(126.0, 16.0), title, 30, Art.INK)


# How many stars the rest card shows (for the star bells in _process).
func _rest_stars() -> int:
	var prev := _prev_round()
	if prev.is_empty():
		return 0
	if prev["phase"] != "warmup":
		return roundi(5.0 * float(_round_caught) / float(maxi(_round_caught + _round_missed, 1)))
	return roundi(5.0 * float(_round_points) / float(maxi(3 * _round_hits, 1)))


# Five stars that pop in one by one, the first `filled` gold.
func _stars(centre: Vector2, filled: int, big: float) -> void:
	for i in 5:
		var p := centre + Vector2(float(i - 2) * big * 2.3, -6.0 if i == 2 else 0.0)
		var rr := big * (1.2 if i == 2 else 1.0)
		Art.draw_star(self, p, rr, false)
		if i < filled:
			var st := clampf((_stage_t - 0.25 - 0.28 * float(i)) / 0.3, 0.0, 1.0)
			if st > 0.0:
				var sc := st * 1.25 if st < 0.7 else lerpf(1.25, 1.0, (st - 0.7) / 0.3)
				Art.draw_star(self, p, rr * sc, true)


# Rest screen (Night Forest mockup, §4.6): the jar of this round's fireflies,
# large, on the left; on the right the round badge and progress, the round's
# result counting up (TypingClub style), stars, catch rate by reach so far
# today, and the countdown.
func _draw_rest(vp: Vector2) -> void:
	# Darken towards the right so the column reads over the forest.
	var navy := Color(0.016, 0.035, 0.094)
	var x_a := vp.x * 0.38
	var x_b := vp.x * 0.56
	draw_polygon(PackedVector2Array([Vector2(x_a, 0), Vector2(x_b, 0), Vector2(x_b, vp.y), Vector2(x_a, vp.y)]),
		PackedColorArray([Color(navy, 0.0), Color(navy, 0.78), Color(navy, 0.78), Color(navy, 0.0)]))
	draw_polygon(PackedVector2Array([Vector2(x_b, 0), Vector2(vp.x, 0), Vector2(vp.x, vp.y), Vector2(x_b, vp.y)]),
		PackedColorArray([Color(navy, 0.78), Color(navy, 0.93), Color(navy, 0.93), Color(navy, 0.78)]))
	# The jar, the hero of this screen, with the warm light it throws.
	var jar := Rect2(vp.x * 0.29 - 142.0, vp.y * 0.815 - 350.0, 285.0, 350.0)
	Art.blit(self, Art.glow(), jar.get_center(), Vector2(760.0, 640.0), Color(Art.LAMP_GLOW, 0.16))
	_fx.draw_jar(self, jar)

	var x0 := vp.x * 0.526
	var x1 := vp.x - 90.0
	var halo := Color(0.0, 0.01, 0.06, 0.6)
	var prev := _prev_round()
	if prev.is_empty():   # a resumed day
		Art.text_left(self, Vector2(x0, vp.y * 0.36), "WELCOME BACK", 60, Art.INK, halo)
		Art.text_left(self, Vector2(x0, vp.y * 0.36 + 62.0), "Session continues", 26,
			Art.INK_SOFT)
		_countdown(Vector2(x0, vp.y - 130.0), "FIRST ROUND IN", "GET READY")
		return
	var phase: String = prev["phase"]
	var play := phase == "play"
	var timed := phase != "warmup"   # calibration and play: caught against a lifetime
	var frac := 0.0
	if timed:
		frac = float(_round_caught) / float(maxi(_round_caught + _round_missed, 1))
	else:
		frac = float(_round_points) / float(maxi(3 * _round_hits, 1))
	var grow := 1.0 - pow(1.0 - clampf((_stage_t - 0.3) / 1.1, 0.0, 1.0), 3.0)   # ease out

	# Header: the round badge, a word for the result, progress through the phase.
	var y := 150.0
	var num: int = prev["number"]
	var total := _rounds_of(phase) + (_rounds_before if play else 0)
	var badge := Vector2(x0 + 76.0, y + 80.0)
	Art.draw_hex(self, badge, 80.0)
	Art.text(self, badge + Vector2(0.0, -10.0), str(num), 62, Art.INK)
	Art.text(self, badge + Vector2(0.0, 36.0), _phase_title(phase), 12, Art.ICE_HI)
	var word := "EXCELLENT" if frac >= 0.9 else ("NICELY DONE" if frac >= 0.7 else "KEEP GOING")
	Art.text_left(self, Vector2(x0 + 196.0, y + 58.0), word, 58, Art.INK, halo)
	Art.draw_bar(self, Rect2(x0 + 196.0, y + 110.0, x1 - x0 - 300.0, 13.0), float(num) / float(maxi(total, 1)),
		Art.VIOLET)
	Art.text_right(self, Vector2(x1, y + 116.0), "%d/%d" % [num, total], 22, Art.INK_SOFT)

	# This round: the result ring counting up, and the plain count.
	y += 250.0
	var rc := Vector2(x0 + 43.0, y)
	var col := Art.LAMP_GLOW if timed else Art.GOLD
	draw_arc(rc, 38.0, 0.0, TAU, 48, Color(0.55, 0.75, 1.0, 0.15), 6.0, true)
	if frac * grow > 0.0:
		Art.blit(self, Art.glow(), rc, Vector2(150.0, 150.0), Color(col, 0.2))
		draw_arc(rc, 38.0, -PI * 0.5, -PI * 0.5 + TAU * frac * grow, 48, col, 6.0, true)
	Art.blit(self, Art.glow(), rc, Vector2(36.0, 36.0), Color(Art.LAMP_GLOW, 0.9))
	Art.blit(self, Art.disc(), rc, Vector2(9.0, 9.0), Art.LAMP_CORE)
	Art.text_left(self, Vector2(x0 + 110.0, y - 30.0), "CAUGHT THIS ROUND" if timed else "SPEED POINTS", 14,
		Art.MUTED)
	var big := str(roundi(100.0 * frac * grow)) if timed else str(roundi(float(_round_points) * grow))
	Art.text_left(self, Vector2(x0 + 110.0, y + 18.0), big, 84, Art.INK, halo)
	Art.text_left(self, Vector2(x0 + 122.0 + Art.text_width(big, 84), y + 30.0), "%" if timed else "PTS", 30,
		Art.MUTED)
	var x2 := x0 + 470.0
	draw_line(Vector2(x2 - 40.0, y - 44.0), Vector2(x2 - 40.0, y + 44.0), Color(0.55, 0.75, 1.0, 0.32), 1.0)
	Art.text_left(self, Vector2(x2, y - 30.0), "FIREFLIES", 14, Art.MUTED)
	var got := _round_caught if timed else _round_hits
	Art.text_left(self, Vector2(x2, y + 18.0), str(got), 84, Art.INK, halo)
	if timed:
		Art.text_left(self, Vector2(x2 + 12.0 + Art.text_width(str(got), 84), y + 30.0),
			"/%d" % (_round_caught + _round_missed), 30, Art.MUTED)

	# Stars, as the round's result.
	y += 130.0
	_stars(Vector2(x0 + 150.0, y), _rest_stars(), 26.0)

	# Reach: caught so far today at each distance, nearest first.
	y += 90.0
	Art.text_left(self, Vector2(x0, y + 10.0), "REACH", 30, Art.INK)
	Art.text_left(self, Vector2(x0, y + 44.0), "CAUGHT TODAY", 13, Art.MUTED)
	var order: Array = []
	for k in Protocol.PAIRS.size():
		if not _unfit.has(k):
			order.append(k)
	order.sort_custom(func(a, b): return _pair_a(a) < _pair_a(b))
	var names: Array = ["SHORT", "MIDDLE", "LONG"] if order.size() == 3 else ["SHORT", "LONG"]
	for i in order.size():
		var k: int = order[i]
		var c := int(_play[k]["caught"]) if play else int(_calib[k]["caught"])
		var n := c + (int(_play[k]["missed"]) if play else int(_calib[k]["missed"]))
		var ry := y + float(i) * 60.0
		var rx := x0 + 230.0
		Art.draw_diamond(self, Vector2(rx, ry + 16.0), 13.0, true, Art.ICE)
		Art.text_left(self, Vector2(rx + 34.0, ry + 4.0), names[i] if i < names.size() else "PAIR %d" % (k + 1), 17,
			Art.INK)
		var rate := float(c) / float(n) if n > 0 else 0.0
		Art.text_right(self, Vector2(x1, ry + 4.0), "%d%%" % roundi(100.0 * rate) if n > 0 else "—", 20, Art.ICE_HI)
		Art.draw_bar(self, Rect2(rx + 34.0, ry + 24.0, x1 - rx - 34.0, 11.0), rate, Art.ICE)

	_countdown(Vector2(x0, vp.y - 110.0), "NEXT ROUND IN", "GET READY")


# Closing card (§4.7): stars and the whole session's result; Enter returns to Home.
func _draw_complete(vp: Vector2) -> void:
	_dim(vp, 0.32)
	var card := Rect2(vp.x * 0.5 - 300.0, vp.y * 0.5 - 235.0, 600.0, 460.0)
	Art.draw_card(self, card)
	var cx := card.get_center().x
	var y0 := card.position.y
	var c := 0
	var n := 0
	for k in Protocol.PAIRS.size():
		c += int(_play[k]["caught"])
		n += int(_play[k]["caught"]) + int(_play[k]["missed"])
	var frac := float(c) / float(maxi(n, 1))
	Art.text(self, Vector2(cx, y0 + 62.0), "Session complete", 38, Art.INK)
	Art.text(self, Vector2(cx, y0 + 104.0), "Thank you — well played", 18, Art.INK_SOFT)
	_stars(Vector2(cx, y0 + 165.0), roundi(5.0 * frac), 26.0)
	var tiles: Array = [["%d%%" % roundi(100.0 * frac), "fireflies caught"],
		[str(_rounds_of("play") + _rounds_before), "rounds played"]]
	for i in 2:
		var tile := Rect2(cx - 185.0 + float(i) * 200.0, y0 + 222.0, 170.0, 84.0)
		Art.draw_glass(self, tile, 18)
		Art.text(self, tile.get_center() + Vector2(0.0, -12.0), tiles[i][0], 32, Art.INK)
		Art.text(self, tile.get_center() + Vector2(0.0, 22.0), tiles[i][1], 14, Art.INK_SOFT)
	var btn := Rect2(cx - 100.0, y0 + 336.0, 200.0, 54.0)
	Art.blit(self, Art.glow(), btn.get_center(), Vector2(320.0, 150.0), Color(Art.FF_GLOW, 0.18))
	draw_style_box(Art._box(Color("FFC94A"), 27), btn)
	Art.text(self, btn.get_center(), "DONE  (ENTER)", 20, Color("2B1C00"))
	Art.text(self, Vector2(cx, y0 + 425.0), "✓ Saved", 14, Art.INK_SOFT)


# Tracker lost (§4.8): the handle settling onto its spot on the table.
func _draw_pause(vp: Vector2) -> void:
	_dim(vp, 0.5)
	var card := Rect2(vp.x * 0.5 - 240.0, vp.y * 0.5 - 190.0, 480.0, 370.0)
	Art.draw_card(self, card)
	var cx := card.get_center().x
	var y0 := card.position.y
	var t := fmod(_stage_t + float(Time.get_ticks_msec()) / 1000.0, 2.4) / 2.4
	var drop := clampf((t - 0.15) / 0.4, 0.0, 1.0) if t < 0.85 else 1.0 - (t - 0.85) / 0.15
	var table_y := y0 + 150.0
	draw_polygon(PackedVector2Array([Vector2(cx - 130, table_y), Vector2(cx + 130, table_y),
		Vector2(cx + 112, table_y + 40), Vector2(cx - 112, table_y + 40)]),
		PackedColorArray([Color("3A4A63"), Color("3A4A63"), Color("222D40"), Color("222D40")]))
	draw_rect(Rect2(cx - 130, table_y - 6, 260, 9), Color("4A5B76"))
	var spot_a := 0.35 + 0.65 * drop
	Art.blit(self, Art.glow(), Vector2(cx, table_y - 2), Vector2(170.0, 40.0), Color(Art.FF_GLOW, 0.35 * spot_a))
	for i in 12:
		var a0 := TAU * float(i) / 12.0
		var p0 := Vector2(cx, table_y - 2) + Vector2(cos(a0) * 64.0, sin(a0) * 8.0)
		var p1 := Vector2(cx, table_y - 2) + Vector2(cos(a0 + 0.3) * 64.0, sin(a0 + 0.3) * 8.0)
		draw_line(p0, p1, Color(Art.FF_BODY, spot_a), 3.0, true)
	var dy := -34.0 * (1.0 - drop)
	var body := Rect2(cx - 56, table_y - 50 + dy, 112, 46)
	draw_style_box(Art._box(Color("65727E"), 12), body)
	draw_rect(Rect2(cx - 46, table_y - 40 + dy, 18, 18), Color("F2F2F2"))
	draw_rect(Rect2(cx + 28, table_y - 40 + dy, 18, 18), Color("F2F2F2"))
	draw_style_box(Art._box(Color("3E4852"), 10), Rect2(cx - 14, table_y - 88 + dy, 28, 42))
	draw_style_box(Art._box(Color("5B6773"), 6), Rect2(cx - 20, table_y - 94 + dy, 40, 12))
	Art.text(self, Vector2(cx, y0 + 238.0), "Place the handle", 30, Art.INK)
	Art.text(self, Vector2(cx, y0 + 274.0), "back on the table", 30, Art.INK)
	Art.text(self, Vector2(cx, y0 + 312.0), "The game continues by itself", 17, Art.INK_SOFT)
	for i in 3:
		var bob := sin(float(Time.get_ticks_msec()) / 1000.0 * 5.0 - float(i) * 0.9)
		draw_circle(Vector2(cx - 18.0 + 18.0 * float(i), y0 + 342.0 - 3.0 * bob), 5.0,
			Color(Art.FF_BODY, 0.45 + 0.4 * bob))


# Researcher overlay during play (§4.9): diagnostics only — never p, the
# lifetimes or the level, since the participant can see the screen.
func _draw_overlay(vp: Vector2) -> void:
	var box := Rect2(16.0, vp.y - 164.0, 290.0, 148.0)
	draw_style_box(Art._box(Color(0.08, 0.09, 0.07, 0.78), 12), box)
	var f: Font = ThemeDB.fallback_font
	var y := box.position.y + 26.0
	draw_circle(Vector2(box.position.x + 18.0, y - 5.0), 4.0, Color("E4553F"))
	draw_string(Art.font(), Vector2(box.position.x + 30.0, y), "RESEARCHER OVERLAY", HORIZONTAL_ALIGNMENT_LEFT,
		-1, 12, Color("F3B6AC"))
	var left := maxi(ceili(_stage_left), 0)
	var pair := "—"
	if not _apple.is_empty() and int(_apple["pair"]) >= 0:
		var k: int = _apple["pair"]
		pair = "pair %d (A %d · W %d)" % [k + 1, int(_pair_a(k)), int(_pair_w(k))]
	var rows: Array = [
		["Tracker", "%d Hz" % Tracker.packets_per_sec()],
		["Round", "%d of %d · %d:%02d left" % [_round_number(), _rounds_of("play") + _rounds_before,
			left / 60, left % 60]],
		["Apple", pair],
		["This round", "%d caught · %d missed" % [_round_caught, _round_missed]],
	]
	for row in rows:
		y += 26.0
		draw_string(f, Vector2(box.position.x + 16.0, y), row[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
			Color("C9C5BB"))
		draw_string(f, Vector2(box.position.x + 110.0, y), row[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
			Color("F4F2EC"))


# Researcher's calibration check (§4.4), in the operator screens' dark style.
# For each pair, the distribution of its calibration movement times (timed, at
# about 85 % caught — staircase.gd): a smooth density curve (Gaussian kernel
# density estimate), a dot per firefly below it, the median as a line, and the misses as a
# separate grey bar past the end of the axis (a miss has no movement time,
# only "slower than its lifetime"). All pairs share one time axis. Also the
# reach outline. Never shows p, the lifetimes or the level (no percentile
# cut-off is marked): the participant may be watching.
func _draw_check(vp: Vector2) -> void:
	_dim(vp, 0.6)
	var panel := Rect2(vp.x * 0.5 - 720.0, vp.y * 0.5 - 390.0, 1440.0, 780.0)
	draw_style_box(Art._box(Color("0F1F3F"), 18, Color(0.55, 0.75, 1.0, 0.3), 1, 34.0), panel)
	var f: Font = ThemeDB.fallback_font
	var b := Art.font()
	var ink := Color("EAF3FF")
	var muted := Color("8EA4C6")
	var warn := Color("FFCB7A")
	var faint := Color(0.55, 0.75, 1.0, 0.14)
	var x0 := panel.position.x + 44.0
	var y := panel.position.y + 50.0
	draw_circle(Vector2(x0 + 5.0, y - 5.0), 5.0, Color("FF7A70"), true, -1.0, true)
	draw_string(b, Vector2(x0 + 18.0, y), "RESEARCHER OVERLAY", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, muted)
	draw_string(b, Vector2(x0, y + 42.0), "CALIBRATION CHECK", HORIZONTAL_ALIGNMENT_LEFT, -1, 30, ink)
	var total := 0
	for k in Protocol.PAIRS.size():
		total += int(_calib[k]["caught"]) + int(_calib[k]["missed"])
	draw_string(f, Vector2(x0, y + 74.0), "%d calibration fireflies, %d reposition. Movement time = hold start − appear. Play waits for you." % [
		total, _repositions], HORIZONTAL_ALIGNMENT_LEFT, -1, 16, muted)

	# One time axis for all pairs: 0 to just past the slowest movement time.
	var span := 1.0
	for k in Protocol.PAIRS.size():
		for mt in _calib[k]["mts"]:
			span = maxf(span, float(mt) * 1.05)
	var bin := 0.1 if span <= 4.0 else 0.2
	var n_bins := ceili(span / bin)
	span = float(n_bins) * bin
	var px := x0 + 300.0          # plot left edge
	var pw := 640.0               # plot width
	var row_h := 160.0
	var hist_h := 72.0
	var top := panel.position.y + 170.0
	var bottom := top + row_h * float(Protocol.PAIRS.size())
	# Grid: a faint line every second (every half second on a short axis).
	var step := 0.5 if span <= 3.0 else 1.0
	var s := 0.0
	while s <= span + 0.001:
		var gx := px + pw * s / span
		draw_line(Vector2(gx, top - 10.0), Vector2(gx, bottom - 40.0), faint, 1.0)
		var tick := ("%d s" % roundi(s)) if is_equal_approx(s, roundf(s)) else ("%.1f s" % s)
		draw_string(f, Vector2(gx - 12.0, bottom - 18.0), tick, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, muted)
		s += step

	for k in Protocol.PAIRS.size():
		var c: Dictionary = _calib[k]
		var ry := top + row_h * float(k)
		if k > 0:
			draw_line(Vector2(x0, ry - 22.0), Vector2(px + pw + 90.0, ry - 22.0), faint, 1.0)
		draw_string(b, Vector2(x0, ry + 8.0), "PAIR %d · %.2f BITS" % [k + 1, Protocol.id_bits(_pair_a(k), _pair_w(k))],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 18, ink)
		draw_string(f, Vector2(x0, ry + 32.0), "A %d · W %d mm" % [int(_pair_a(k)), int(_pair_w(k))],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, muted)
		if _unfit.has(k):
			draw_string(f, Vector2(x0, ry + 60.0), "does not fit this reach area", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, warn)
			continue
		var mts: Array = c["mts"].duplicate()
		mts.sort()
		var caught: int = c["caught"]
		var missed: int = c["missed"]
		draw_string(f, Vector2(x0, ry + 60.0), "%d / %d caught" % [caught, caught + missed],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, ink)
		# Amber: too few fireflies, or the day's level lies beyond what this
		# calibration's curve reached (play then uses the longest lifetime tried).
		var st: Staircase = _stairs[k] if k < _stairs.size() else null
		var beyond := st != null and not st.trials.is_empty() and Staircase.km_reach(st.trials) < _level_p()
		var note := "%d missed" % missed
		if caught + missed < FEW_SAMPLES:
			note += " · few fireflies"
		if beyond:
			note += " · level beyond this calibration"
		draw_string(f, Vector2(x0, ry + 84.0), note, HORIZONTAL_ALIGNMENT_LEFT, -1, 15,
			warn if beyond or caught + missed < FEW_SAMPLES else muted)
		if not mts.is_empty():
			draw_string(f, Vector2(x0, ry + 108.0), "median %.2f s" % _median(mts),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 15, ink)

		# A smooth density curve (Gaussian kernel density estimate), scaled to
		# this pair's peak, as a filled area.
		var base := ry + hist_h
		draw_line(Vector2(px, base), Vector2(px + pw, base), Color(0.55, 0.75, 1.0, 0.35), 1.0)
		var dens := _density(mts, span, 160)
		if not dens.is_empty():
			var peak := 0.0
			for d in dens:
				peak = maxf(peak, d)
			var curve := PackedVector2Array()
			for i in dens.size():
				curve.append(Vector2(px + pw * float(i) / float(dens.size() - 1), base - maxf(0.6, hist_h * dens[i] / peak)))
			var area := curve.duplicate()
			area.append(Vector2(px + pw, base))
			area.append(Vector2(px, base))
			var cols := PackedColorArray()
			for p in area:   # brighter where it is taller
				cols.append(Color(0.49, 0.77, 1.0, 0.12 + 0.45 * clampf((base - p.y) / hist_h, 0.0, 1.0)))
			draw_polygon(area, cols)
			draw_polyline(curve, Color(0.62, 0.84, 1.0, 0.95), 2.0, true)
		# A dot per firefly, spread a little up and down so equal times stay visible.
		for i in mts.size():
			var dx := px + pw * float(mts[i]) / span
			draw_circle(Vector2(dx, base + 16.0 + 5.0 * sin(float(i) * 2.4)), 3.0, Color(1.0, 0.79, 0.29, 0.9), true, -1.0, true)
		if not mts.is_empty():
			var mx := px + pw * _median(mts) / span
			draw_line(Vector2(mx, ry - 6.0), Vector2(mx, base + 26.0), Color.WHITE, 2.0)
		# Misses: past the axis, as a share of this pair's fireflies.
		var tx := px + pw + 36.0
		if missed > 0:
			var th := maxf(3.0, hist_h * float(missed) / float(maxi(caught + missed, 1)))
			draw_rect(Rect2(tx, base - th, 28.0, th), Color(0.62, 0.67, 0.78, 0.7))
			draw_string(f, Vector2(tx + 6.0, base - th - 6.0), str(missed), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, muted)
		draw_string(f, Vector2(tx - 8.0, base + 22.0), "missed", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, muted)

	# Reach outline, the screen as the frame.
	var map := Rect2(panel.end.x - 330.0, top - 10.0, 286.0, 200.0)
	draw_string(b, Vector2(map.position.x, map.position.y - 14.0), "REACH", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, muted)
	draw_style_box(Art._box(Color(0.02, 0.05, 0.12, 0.6), 10, faint, 1), map)
	if _boundary.size() >= 3:
		var k2 := minf(map.size.x / vp.x, map.size.y / vp.y)
		var off := map.position + (map.size - vp * k2) * 0.5
		var poly := PackedVector2Array()
		for p in _boundary:
			poly.append(off + _ts.mm_to_screen(p) * k2)
		draw_colored_polygon(poly, Color(1.0, 0.79, 0.29, 0.15))
		var closed := poly.duplicate()
		closed.append(poly[0])
		draw_polyline(closed, Color("FFC94A"), 2.0, true)
		draw_circle(off + _ts.mm_to_screen(_scan.home) * k2, 3.5, ink, true, -1.0, true)
	var reach_lines := _reach_text().split("\n")
	for i in reach_lines.size():
		draw_string(f, Vector2(map.position.x, map.end.y + 24.0 + 18.0 * float(i)), reach_lines[i],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, muted)

	# Fitts' law: each pair's median movement time against its ID, with the
	# least-squares line MT = a + b·ID. The medians and the quartile whiskers
	# come from the Kaplan–Meier curve, so the misses count too.
	var fit := Rect2(map.position.x, top + 280.0, 286.0, 170.0)
	draw_string(b, Vector2(fit.position.x, fit.position.y - 14.0), "FITTS' LAW", HORIZONTAL_ALIGNMENT_LEFT, -1, 14,
		muted)
	draw_style_box(Art._box(Color(0.02, 0.05, 0.12, 0.6), 10, faint, 1), fit)
	var pts: Array = []   # [ID bits, q25, median, q75]
	for k in Protocol.PAIRS.size():
		if _unfit.has(k) or k >= _stairs.size():
			continue
		var tr: Array = (_stairs[k] as Staircase).trials
		var md := _km_q(tr, 0.5)
		if md > 0.0:
			pts.append([Protocol.id_bits(_pair_a(k), _pair_w(k)), _km_q(tr, 0.25), md, _km_q(tr, 0.75)])
	if pts.size() < 2:
		draw_string(f, fit.position + Vector2(16.0, 90.0), "needs 2 pairs with catches", HORIZONTAL_ALIGNMENT_LEFT,
			-1, 14, muted)
	else:
		var mx := 0.0
		var my := 0.0
		for q in pts:
			mx += float(q[0])
			my += float(q[2])
		mx /= float(pts.size())
		my /= float(pts.size())
		var sxx := 0.0
		var sxy := 0.0
		var syy := 0.0
		var x_lo := INF
		var x_hi := -INF
		var y_hi := 0.0
		for q in pts:
			sxx += (float(q[0]) - mx) * (float(q[0]) - mx)
			sxy += (float(q[0]) - mx) * (float(q[2]) - my)
			syy += (float(q[2]) - my) * (float(q[2]) - my)
			x_lo = minf(x_lo, float(q[0]))
			x_hi = maxf(x_hi, float(q[0]))
			y_hi = maxf(y_hi, maxf(float(q[3]), float(q[2])))
		var slope := sxy / sxx if sxx > 0.0 else 0.0
		var icpt := my - slope * mx
		var r2 := sxy * sxy / (sxx * syy) if sxx > 0.0 and syy > 0.0 else 1.0
		x_lo -= 0.5
		x_hi += 0.5
		y_hi *= 1.15
		var inner := fit.grow(-16.0)
		var to_px := func(id: float, t: float) -> Vector2:
			return Vector2(inner.position.x + inner.size.x * (id - x_lo) / (x_hi - x_lo),
				inner.end.y - inner.size.y * clampf(t / y_hi, 0.0, 1.0))
		draw_line(to_px.call(x_lo, icpt + slope * x_lo), to_px.call(x_hi, icpt + slope * x_hi),
			Color("FFC94A"), 2.0, true)
		for q in pts:
			var lo_q: float = q[1] if float(q[1]) > 0.0 else float(q[2])
			var hi_q: float = q[3] if float(q[3]) > 0.0 else y_hi
			draw_line(to_px.call(float(q[0]), lo_q), to_px.call(float(q[0]), hi_q), Color(0.62, 0.84, 1.0, 0.7), 2.0)
			draw_circle(to_px.call(float(q[0]), float(q[2])), 5.0, Color("EAF3FF"), true, -1.0, true)
		draw_string(f, Vector2(fit.position.x, fit.end.y + 24.0),
			"MT = %.2f + %.2f·ID s   R² %.2f" % [icpt, slope, r2], HORIZONTAL_ALIGNMENT_LEFT, -1, 15, ink)
		draw_string(f, Vector2(fit.position.x, fit.end.y + 44.0), "median per pair (whiskers: quartiles) vs ID bits",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, muted)

	var foot_y := panel.end.y - 36.0
	draw_line(Vector2(x0, foot_y - 30.0), Vector2(panel.end.x - 44.0, foot_y - 30.0), faint, 1.0)
	draw_string(f, Vector2(x0, foot_y), "Lifetimes and the level are never shown here.",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, muted)
	draw_string(b, Vector2(panel.end.x - 720.0, foot_y),
		"ENTER: START PLAY    C: REDO CALIBRATION    S: REDO FROM REACH SCAN",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color("FFC94A"))


# Gaussian kernel density of the values at n points from 0 to span; empty with
# fewer than 2 values. Bandwidth by Silverman's rule of thumb:
#     h = 0.9 * min(sd, IQR / 1.34) * n^(-1/5)
func _density(sorted: Array, span: float, n: int) -> Array:
	var m := sorted.size()
	if m < 2:
		return []
	var mean := 0.0
	for v in sorted:
		mean += float(v)
	mean /= float(m)
	var sq := 0.0
	for v in sorted:
		sq += (float(v) - mean) * (float(v) - mean)
	var sd := sqrt(sq / float(m - 1))
	var iqr := float(sorted[(3 * m) / 4]) - float(sorted[m / 4])
	var spread := minf(sd, iqr / 1.34) if iqr > 0.0 else sd
	var h := maxf(0.9 * spread * pow(float(m), -0.2), 0.02)
	var out: Array = []
	for i in n:
		var x := span * float(i) / float(n - 1)
		var d := 0.0
		for v in sorted:
			var z := (x - float(v)) / h
			d += exp(-0.5 * z * z)
		out.append(d)
	return out


# The q-th quantile of a pair's movement times from its Kaplan–Meier curve
# (staircase.gd): the first catch time where F >= q; -1 if F never gets there.
func _km_q(trials: Array, q: float) -> float:
	for pt in Staircase.km_curve(trials):
		if float(pt[1]) >= q:
			return float(pt[0])
	return -1.0


# Median of an ascending list.
func _median(sorted: Array) -> float:
	var m: int = sorted.size() / 2
	return float(sorted[m]) if sorted.size() % 2 == 1 else (float(sorted[m - 1]) + float(sorted[m])) * 0.5


func _reach_text() -> String:
	if _scan.results.is_empty():
		return "Reach: not measured"
	var lo := INF
	var hi := 0.0
	var by_screen := 0
	for r in _scan.results:
		lo = minf(lo, r["reach_mm"])
		hi = maxf(hi, r["reach_mm"])
		if r["limited_by"] == "screen":
			by_screen += 1
	return "Reach %d–%d mm\n%d of %d directions stopped by the screen edge" % [
		int(lo), int(hi), by_screen, _scan.results.size()]
