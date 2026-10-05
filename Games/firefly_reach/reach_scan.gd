extends RefCounted

# Reach scan (docs/clinic_study_interface.md §4.3), since 2026-09-28 "stretch
# the bubble" (before: a light gliding out along 8 spokes, ~48 s). Hold the
# cursor in the centre ring for HOME_HOLD_S; then a small polygon of light
# with VERTICES corners appears around it, and the participant pushes it out
# as far as they can reach, at their own pace, in any order. Vertex i points
# along u_i (every 360/30 = 12 degrees; 15 corners, 24°, until 2026-09-29) and
# grows only from hand positions in its own sector (within ±6 degrees of u_i):
#     r_i = max |p - home|  over samples p with angle(p - home) within ±6° of u_i
# (not the projection on u_i: with free movement a reach towards 30° would
# otherwise also push the 0° vertex, by cos 30° = 0.87). A vertex cannot go
# past the screen edge; one that got within SCREEN_LIMIT_MM of it is marked
# "screen" (fireflies cannot appear beyond it either).
# It ends when every vertex has grown (GROWN_MM past the start, or reached the
# screen edge) and nothing has grown for QUIET_S, or after MAX_S, or when the
# researcher presses Enter (round_runner.gd).
#
# Driven by round_runner.gd: on_sample() per tracker sample, update() per
# frame, draw() from its _draw. All positions are table mm.

const TableSpace := preload("res://Games/firefly_reach/table_space.gd")
const Art := preload("res://Games/firefly_reach/game_art.gd")

const VERTICES := 30
const HOME_R_MM := 30.0
const HOME_HOLD_S := 1.0
const START_R_MM := 45.0        # the polygon's size when it appears
const GROWN_MM := 40.0          # a vertex counts as stretched this far past the start
const GROWTH_STEP_MM := 2.0     # growth smaller than this does not reset the quiet timer
const QUIET_S := 3.0
const MAX_S := 60.0            # 45 s with 15 corners; half-width sectors take longer to fill
const EDGE_MARGIN_PX := 20.0
const SCREEN_LIMIT_MM := 10.0

enum Step { HOME, STRETCH, DONE }

var home: Vector2
var results: Array = []         # per vertex: {angle_deg, reach_mm, edge, light_mm (screen limit), limited_by}

var _ts: TableSpace
var _vp: Vector2
var _step: Step = Step.HOME
var _u: Array[Vector2] = []     # vertex directions
var _r: Array[float] = []       # vertex radii, mm
var _limit: Array[float] = []   # screen edge along each direction, mm
var _grew: bool = false
var _quiet: float = 0.0
var _elapsed: float = 0.0
var _home_hold: float = -1.0    # sample time the hand entered the ring; -1 = not inside
var _hand: Vector2 = Vector2.ZERO


func _init(ts: TableSpace, viewport_size: Vector2) -> void:
	_ts = ts
	_vp = viewport_size
	home = ts.screen_to_mm(viewport_size * 0.5)
	var rect := Rect2(Vector2.ZERO, _vp).grow(-EDGE_MARGIN_PX)
	for i in VERTICES:
		var u := Vector2.from_angle(TAU * float(i) / float(VERTICES))
		var lim := 0.0
		while rect.has_point(_ts.mm_to_screen(home + u * (lim + 5.0))):
			lim += 5.0
		_u.append(u)
		_limit.append(lim)
		_r.append(minf(START_R_MM, lim))


func is_done() -> bool:
	return _step == Step.DONE


# The polygon is out and being pushed (past the hold in the centre ring).
func is_stretching() -> bool:
	return _step == Step.STRETCH


func on_sample(t: float, hand: Vector2) -> void:
	_hand = hand
	match _step:
		Step.HOME:
			if hand.distance_to(home) > HOME_R_MM:
				_home_hold = -1.0
			elif _home_hold < 0.0:
				_home_hold = t
			elif t - _home_hold >= HOME_HOLD_S:
				_step = Step.STRETCH
		Step.STRETCH:
			var d := hand - home
			var i := posmod(roundi(d.angle() / (TAU / float(VERTICES))), VERTICES)
			var r := minf(d.length(), _limit[i])
			if r > _r[i]:
				if r - _r[i] >= GROWTH_STEP_MM:
					_grew = true
				_r[i] = r


func update(delta: float) -> void:
	if _step != Step.STRETCH:
		return
	_elapsed += delta
	if _grew:
		_quiet = 0.0
		_grew = false
	else:
		_quiet += delta
	if (_all_grown() and _quiet >= QUIET_S) or _elapsed >= MAX_S:
		finish()


# Tracker lost: the quiet timer waits for it to come back.
func pause() -> void:
	_quiet = 0.0


func _grown(i: int) -> bool:
	return _r[i] >= START_R_MM + GROWN_MM or _r[i] >= _limit[i] - SCREEN_LIMIT_MM


func _all_grown() -> bool:
	for i in VERTICES:
		if not _grown(i):
			return false
	return true


func stretched() -> int:
	var n := 0
	for i in VERTICES:
		if _grown(i):
			n += 1
	return n


# End the scan now (the rule above, or the researcher's Enter).
func finish() -> void:
	if _step == Step.DONE:
		return
	results = []
	for i in VERTICES:
		results.append({
			"angle_deg": 360.0 * float(i) / float(VERTICES),
			"reach_mm": _r[i],
			"edge": home + _u[i] * _r[i],
			"light_mm": _limit[i],
			"limited_by": "screen" if _r[i] >= _limit[i] - SCREEN_LIMIT_MM else "hand",
		})
	_step = Step.DONE


# The reach outline in table mm, vertices in order (a star-shaped polygon around home).
func boundary() -> PackedVector2Array:
	var pts := PackedVector2Array()
	for r in results:
		pts.append(r["edge"])
	return pts


# Rows for reach.csv (visit_logger.gd REACH_COLUMNS).
func csv_rows() -> Array:
	var rows: Array = []
	for i in results.size():
		var r: Dictionary = results[i]
		var edge: Vector2 = r["edge"]
		rows.append([i + 1, "%.1f" % r["angle_deg"], "%.1f" % r["reach_mm"],
			"%.2f" % edge.x, "%.2f" % edge.y, "%.1f" % r["light_mm"], r["limited_by"]])
	return rows


# A bubble of light around the centre ring: brighter towards its middle, a
# bright edge; corners still to stretch pulse gold, stretched ones glow ice,
# ones at the screen edge are gold diamonds. A pill counts the stretched
# corners, and one line says what to do.
func draw(ci: CanvasItem, _font: Font) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var ring := _ts.circle_outline(home, HOME_R_MM, 48)
	var in_ring := _hand.distance_to(home) <= HOME_R_MM
	var c := _ts.mm_to_screen(home)
	var edge := PackedVector2Array()
	for i in VERTICES:
		edge.append(_ts.mm_to_screen(home + _u[i] * _r[i]))

	# The bubble: a fan of triangles, bright in the middle, fainter at the edge.
	var a_mid := 0.22 if _step == Step.STRETCH else 0.1
	for i in VERTICES:
		var j := (i + 1) % VERTICES
		ci.draw_polygon(PackedVector2Array([c, edge[i], edge[j]]),
			PackedColorArray([Color(Art.ICE, a_mid), Color(Art.ICE, 0.06), Color(Art.ICE, 0.06)]))
	var closed := edge.duplicate()
	closed.append(edge[0])
	ci.draw_polyline(closed, Color(Art.ICE_HI, 0.35), 8.0, true)
	ci.draw_polyline(closed, Color(Art.ICE_HI, 0.95), 2.5, true)
	for i in VERTICES:
		var p := edge[i]
		if _r[i] >= _limit[i] - SCREEN_LIMIT_MM:
			Art.draw_diamond(ci, p, 9.0, true)
		elif _grown(i):
			Art.blit(ci, Art.glow(), p, Vector2(34.0, 34.0), Color(Art.ICE, 0.8))
			ci.draw_circle(p, 5.0, Art.ICE_HI, true, -1.0, true)
		else:
			var pulse := 0.5 + 0.5 * sin(now * 4.0 + float(i) * 0.7)
			Art.blit(ci, Art.glow(), p, Vector2.ONE * (40.0 + 24.0 * pulse), Color(Art.FF_GLOW, 0.45 + 0.4 * pulse))
			ci.draw_circle(p, 5.5, Art.FF_CORE, true, -1.0, true)

	# The centre ring: where to start.
	if _step == Step.HOME and in_ring:
		ci.draw_colored_polygon(ring, Color(0.35, 0.85, 0.45, 0.35))
	var ring_a := 0.55 + 0.35 * sin(now * 2.6)
	for i in range(0, ring.size(), 2):   # dashed: every other segment
		ci.draw_line(ring[i], ring[(i + 1) % ring.size()], Color(1.0, 1.0, 1.0, ring_a), 3.0, true)

	# Progress pill and the instruction.
	var count := "%d / %d" % [stretched(), VERTICES]
	var cw := Art.text_width(count, 22) + 48.0
	var pill := Rect2(_vp.x * 0.5 - cw * 0.5, 24.0, cw, 42.0)
	Art.draw_glass(ci, pill, 21)
	Art.text(ci, pill.get_center(), count, 22, Art.GOLD if _all_grown() else Art.INK)
	var msg := "HOLD THE CURSOR IN THE RING TO START"
	if _step == Step.STRETCH:
		msg = "PUSH THE LIGHT OUT AS FAR AS YOU CAN REACH" if not _all_grown() else "GREAT — KEEP REACHING, OR HOLD STILL TO FINISH"
	var tw := Art.text_width(msg, 20) + 48.0
	var tp := Rect2(_vp.x * 0.5 - tw * 0.5, 76.0, tw, 44.0)
	Art.draw_glass(ci, tp, 22)
	Art.text(ci, tp.get_center(), msg, 20, Color.WHITE)
