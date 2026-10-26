extends Node2D

# Cannon Defense's playfield, drawn in code on a 1920x1080 canvas: a night sky,
# a town under a dome, the cannon, and meteors falling on it.
#
# Meteors come straight at the cannon, each along one line, so a meteor asks for
# one aim angle for its whole fall — the angle the patient must turn to and hold.
# (Falling straight down, its angle would keep widening as it dropped, and the
# low ones would end up past the patient's range.)
#
# Firing is aim-and-hold: the aim within AIM_TOL_DEG of a meteor for DWELL_S
# fires on its own, so no button is needed and the steadiness of the hold is
# part of the exercise. The shot follows its meteor, so a lock is a hit.
# A meteor reaching the dome is a miss.
#
# The level adapts: 5 hits in the last 6 meteors goes up one, 3 misses down one.

signal spawned(m: Dictionary)
signal fired(m: Dictionary)
signal resolved(m: Dictionary, outcome: String)   # "hit" or "miss"

const SIZE := Vector2(1920, 1080)
const PIVOT := Vector2(960, 985)       # the barrel's pivot
const BARREL_LEN := 150.0
const DOME_R := 235.0
const ARC_DEG := 65.0                   # the cannon turns +-this; the patient's range maps onto it
const AIM_TOL_DEG := 5.0
const DWELL_S := 0.4
const SHOT_SPEED := 2400.0
const METEOR_R := 46.0
const MIN_SEP_DEG := 20.0               # a new meteor this far from the last one, so the hand moves
const MAX_LEVEL := 8
const ADAPT_WINDOW := 6

const SKY_TOP := Color(0.03, 0.04, 0.12)
const SKY_LOW := Color(0.24, 0.12, 0.30)
const GOLD := Color(1.0, 0.82, 0.3)
const STEEL := Color(0.30, 0.34, 0.44)
const STEEL_DARK := Color(0.17, 0.19, 0.26)

var running := false          # meteors spawn, fall and can be shot
var aim_deg := 0.0            # set by the game every frame
var aim_live := true          # the aim is the hand's now (false: handle not seen, nothing locks)
var show_aim := true
var level := 1
var hold := -1.0              # calibration: a pose being held, 0..1 (ring round the cannon); <0 none
var arrow := 0                # calibration: the way to turn, -1 left, 1 right, 0 none

var _meteors: Array = []
var _shots: Array = []
var _particles: Array = []
var _rings: Array = []
var _popups: Array = []
var _recent: Array = []       # last outcomes, true = hit
var _next_id := 1
var _spawn_in := 1.0
var _last_angle := 0.0
var _recoil := 0.0
var _dome_flash := 0.0
var _t := 0.0

var _stars: Array = []
var _hills_back := PackedVector2Array()
var _hills_front := PackedVector2Array()
var _houses: Array = []
var _font: Font
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_font = load("res://Assets/Fonts/Bungee-Regular.ttf")
	var scenery := RandomNumberGenerator.new()
	scenery.seed = 2026
	for i in 140:
		_stars.append([Vector2(scenery.randf() * SIZE.x, scenery.randf() * SIZE.y * 0.75),
			scenery.randf_range(1.0, 2.6), scenery.randf() * TAU])
	_hills_back = _hills(scenery, 860.0, 70.0)
	_hills_front = _hills(scenery, 930.0, 45.0)
	var x := 40.0
	while x < SIZE.x - 40.0:
		var w := scenery.randf_range(50.0, 90.0)
		if absf(x + w * 0.5 - PIVOT.x) > 150.0:   # leave room for the cannon
			_houses.append([Rect2(x, SIZE.y - scenery.randf_range(60.0, 120.0), w, 200.0),
				scenery.randi_range(0, 3)])
		x += w + scenery.randf_range(6.0, 30.0)


static func _hills(rng: RandomNumberGenerator, base: float, height: float) -> PackedVector2Array:
	var pts := PackedVector2Array([Vector2(0, SIZE.y)])
	var a := rng.randf() * TAU
	var b := rng.randf() * TAU
	for i in 49:
		var x := SIZE.x * i / 48.0
		pts.append(Vector2(x, base - height * (0.6 * sin(x / 260.0 + a) + 0.4 * sin(x / 110.0 + b))))
	pts.append(Vector2(SIZE.x, SIZE.y))
	return pts


## Clears the sky for a new trial. The level carries over: Play again starts
## where the patient left off.
func reset() -> void:
	_meteors.clear()
	_shots.clear()
	_recent.clear()
	_spawn_in = 1.0


func meteor_count() -> int:
	return _meteors.size()


## The meteor being locked onto ({} if none) and how far the lock is, 0..1.
func lock_state() -> Array:
	for m in _meteors:
		if m["lock"] > 0.0 and not m["claimed"]:
			return [m, minf(m["lock"] / DWELL_S, 1.0)]
	return [{}, 0.0]


func speed() -> float:
	return 55.0 + 15.0 * (level - 1)


func _max_active() -> int:
	return 1 if level <= 3 else 2


func _gap() -> float:
	return lerpf(2.2, 1.0, (level - 1) / float(MAX_LEVEL - 1))


static func dir(angle_deg: float) -> Vector2:
	var a := deg_to_rad(angle_deg)
	return Vector2(sin(a), -cos(a))


static func meteor_pos(m: Dictionary) -> Vector2:
	return PIVOT + dir(m["angle"]) * m["dist"]


func barrel_tip() -> Vector2:
	return PIVOT + dir(aim_deg) * BARREL_LEN


# ── simulation ────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	_t += delta
	_recoil = maxf(0.0, _recoil - delta * 120.0)
	_dome_flash = maxf(0.0, _dome_flash - delta * 2.0)
	if running:
		_spawn_in -= delta
		if _spawn_in <= 0.0 and _active() < _max_active():
			_spawn()
			_spawn_in = _gap()
		_move_meteors(delta)
		_lock(delta)
		_move_shots(delta)
	_animate_effects(delta)
	queue_redraw()


func _active() -> int:
	var n := 0
	for m in _meteors:
		if not m["claimed"]:
			n += 1
	return n


func _spawn() -> void:
	var angle := 0.0
	for _attempt in 12:
		angle = _rng.randf_range(-ARC_DEG + 3.0, ARC_DEG - 3.0)
		if absf(angle - _last_angle) >= MIN_SEP_DEG:
			break
	_last_angle = angle
	var d := dir(angle)
	# Where the line leaves the screen: the top, or a side for the wide angles.
	var edge := PIVOT.y / maxf(-d.y, 0.001)
	if absf(d.x) > 0.001:
		edge = minf(edge, PIVOT.x / absf(d.x))
	var craters := []
	for i in 4:
		craters.append(Vector3(_rng.randf_range(-0.5, 0.5), _rng.randf_range(-0.5, 0.5),
			_rng.randf_range(0.12, 0.24)))
	var m := {
		"id": _next_id, "angle": angle, "dist": edge + METEOR_R + 10.0, "edge": edge,
		"speed": speed(), "level": level, "rot": _rng.randf() * TAU,
		"spin": _rng.randf_range(-1.5, 1.5), "craters": craters,
		"lock": 0.0, "claimed": false,
		"spawn_t": Time.get_unix_time_from_system(), "lock_t": -1.0, "fire_t": -1.0,
	}
	_next_id += 1
	_meteors.append(m)
	spawned.emit(m)


func _move_meteors(delta: float) -> void:
	for m in _meteors.duplicate():
		m["dist"] -= m["speed"] * delta
		m["rot"] += m["spin"] * delta
		if m["dist"] <= DOME_R + METEOR_R * 0.4:
			# A claimed meteor is the shot's: it still counts as hit.
			_resolve(m, "hit" if m["claimed"] else "miss")


# The aim near a visible meteor builds its lock; one past DWELL_S fires. The
# nearest meteor in the aim wins; the others' locks drain twice as fast as they fill.
func _lock(delta: float) -> void:
	var target = null
	if aim_live:
		for m in _meteors:
			if m["claimed"] or m["dist"] > m["edge"] - METEOR_R:
				continue
			if absf(m["angle"] - aim_deg) <= AIM_TOL_DEG and (target == null or m["dist"] < target["dist"]):
				target = m
	for m in _meteors:
		if is_same(m, target):
			if m["lock_t"] < 0.0:
				m["lock_t"] = Time.get_unix_time_from_system()
			m["lock"] += delta
			if m["lock"] >= DWELL_S:
				_fire(m)
		else:
			m["lock"] = maxf(0.0, m["lock"] - delta * 2.0)


func _fire(m: Dictionary) -> void:
	m["claimed"] = true
	m["fire_t"] = Time.get_unix_time_from_system()
	_shots.append({"pos": barrel_tip(), "id": m["id"], "trail": []})
	_recoil = 22.0
	for i in 8:
		_particles.append(_particle(barrel_tip(), dir(aim_deg).rotated(_rng.randf_range(-0.5, 0.5))
			* _rng.randf_range(120.0, 320.0), Color(1.0, 0.75, 0.35), 0.35, 7.0))
	fired.emit(m)


func _move_shots(delta: float) -> void:
	for s in _shots.duplicate():
		var m = _find(s["id"])
		if m == null:
			_shots.erase(s)
			continue
		var to: Vector2 = meteor_pos(m) - s["pos"]
		var step := SHOT_SPEED * delta
		s["trail"].push_front(s["pos"])
		if s["trail"].size() > 6:
			s["trail"].pop_back()
		if to.length() <= step + METEOR_R * 0.5:
			_shots.erase(s)
			_resolve(m, "hit")
		else:
			s["pos"] += to.normalized() * step


func _find(id: int):
	for m in _meteors:
		if m["id"] == id:
			return m
	return null


func _resolve(m: Dictionary, outcome: String) -> void:
	_meteors.erase(m)
	var pos := meteor_pos(m)
	if outcome == "hit":
		_burst(pos, [Color(1.0, 0.85, 0.4), Color(1.0, 0.5, 0.2), Color(0.9, 0.9, 1.0)], 34)
		_rings.append({"pos": pos, "r": METEOR_R, "life": 0.5, "color": GOLD})
		_popups.append({"pos": pos, "text": "+1", "life": 1.0})
	else:
		_burst(pos, [Color(1.0, 0.35, 0.25), Color(0.6, 0.55, 0.5)], 22)
		_dome_flash = 1.0
	_recent.append(outcome == "hit")
	_adapt()
	_spawn_in = maxf(_spawn_in, _gap() * 0.6)
	resolved.emit(m, outcome)


func _adapt() -> void:
	if _recent.size() < ADAPT_WINDOW:
		return
	var hits := _recent.count(true)
	if hits >= ADAPT_WINDOW - 1 and level < MAX_LEVEL:
		level += 1
		_recent.clear()
	elif hits * 2 <= ADAPT_WINDOW and level > 1:
		level -= 1
		_recent.clear()
	else:
		_recent.pop_front()


# ── effects ───────────────────────────────────────────────────────────────────

func _particle(pos: Vector2, vel: Vector2, color: Color, life: float, size: float) -> Dictionary:
	return {"pos": pos, "vel": vel, "color": color, "life": life, "max": life, "size": size}


func _burst(pos: Vector2, colors: Array, n: int) -> void:
	for i in n:
		var v := Vector2.from_angle(_rng.randf() * TAU) * _rng.randf_range(80.0, 420.0)
		_particles.append(_particle(pos, v, colors[i % colors.size()], _rng.randf_range(0.4, 0.9),
			_rng.randf_range(4.0, 11.0)))


func _animate_effects(delta: float) -> void:
	for p in _particles:
		p["life"] -= delta
		p["pos"] += p["vel"] * delta
		p["vel"] *= 1.0 - minf(delta * 2.5, 1.0)
		p["vel"].y += 260.0 * delta
	for r in _rings:
		r["life"] -= delta
		r["r"] += 260.0 * delta
	for p in _popups:
		p["life"] -= delta
		p["pos"].y -= 70.0 * delta
	var alive := func(e): return e["life"] > 0.0
	_particles = _particles.filter(alive)
	_rings = _rings.filter(alive)
	_popups = _popups.filter(alive)


# ── drawing ───────────────────────────────────────────────────────────────────

func _draw() -> void:
	draw_polygon(PackedVector2Array([Vector2.ZERO, Vector2(SIZE.x, 0), SIZE, Vector2(0, SIZE.y)]),
		PackedColorArray([SKY_TOP, SKY_TOP, SKY_LOW, SKY_LOW]))
	for s in _stars:
		draw_circle(s[0], s[1], Color(1, 1, 1, 0.35 + 0.3 * sin(_t * 1.7 + s[2])))
	_draw_moon(Vector2(1660, 160))
	draw_colored_polygon(_hills_back, Color(0.13, 0.08, 0.20))
	draw_colored_polygon(_hills_front, Color(0.08, 0.05, 0.13))
	_draw_town()
	_draw_dome()
	if show_aim:
		_draw_aim()
	for m in _meteors:
		_draw_meteor(m)
	for s in _shots:
		for i in s["trail"].size():
			draw_circle(s["trail"][i], 10.0 - i, Color(1.0, 0.8, 0.4, 0.5 - i * 0.07))
		draw_circle(s["pos"], 22.0, Color(1.0, 0.8, 0.4, 0.3))
		draw_circle(s["pos"], 11.0, Color(1.0, 0.97, 0.85))
	_draw_cannon()
	_draw_calibration()
	for p in _particles:
		var c: Color = p["color"]
		c.a = p["life"] / p["max"]
		draw_circle(p["pos"], p["size"] * (0.5 + 0.5 * c.a), c)
	for r in _rings:
		var c: Color = r["color"]
		c.a = r["life"] * 1.6
		draw_arc(r["pos"], r["r"], 0.0, TAU, 40, c, 5.0)
	for p in _popups:
		draw_string(_font, p["pos"] + Vector2(-100, 0), p["text"], HORIZONTAL_ALIGNMENT_CENTER, 200, 44,
			Color(1.0, 0.9, 0.5, minf(p["life"] * 2.0, 1.0)))


func _draw_moon(c: Vector2) -> void:
	for i in 4:
		draw_circle(c, 70.0 + i * 22.0, Color(1.0, 0.95, 0.8, 0.04))
	draw_circle(c, 62.0, Color(0.98, 0.94, 0.82))
	draw_circle(c + Vector2(-18, -10), 12.0, Color(0.88, 0.84, 0.72))
	draw_circle(c + Vector2(20, 18), 8.0, Color(0.88, 0.84, 0.72))


func _draw_town() -> void:
	for h in _houses:
		var r: Rect2 = h[0]
		draw_rect(r, Color(0.10, 0.07, 0.15))
		draw_colored_polygon(PackedVector2Array([r.position + Vector2(-6, 0),
			r.position + Vector2(r.size.x * 0.5, -r.size.x * 0.45), r.position + Vector2(r.size.x + 6, 0)]),
			Color(0.14, 0.09, 0.19))
		for w in h[1]:
			var pos := r.position + Vector2(10 + w * 22, 18)
			if pos.x + 12 < r.end.x:
				draw_rect(Rect2(pos, Vector2(12, 14)), Color(1.0, 0.8, 0.4, 0.8))


func _draw_dome() -> void:
	var a := 0.10 + 0.35 * _dome_flash
	var colour := Color(0.5, 0.8, 1.0).lerp(Color(1.0, 0.3, 0.25), _dome_flash)
	var pts := PackedVector2Array()
	for i in 41:
		pts.append(PIVOT + Vector2.from_angle(PI + PI * i / 40.0) * DOME_R)
	draw_colored_polygon(pts, Color(colour, a * 0.4))
	draw_arc(PIVOT, DOME_R, PI, TAU, 64, Color(colour, a + 0.25), 4.0)
	# The cannon's reach: the arc the patient's range is mapped onto.
	draw_arc(PIVOT, DOME_R + 26.0, deg_to_rad(-90.0 - ARC_DEG), deg_to_rad(-90.0 + ARC_DEG), 48,
		Color(1, 1, 1, 0.12), 6.0)


func _draw_aim() -> void:
	var u := dir(aim_deg)
	var locking: bool = lock_state()[1] > 0.0
	var colour := Color(GOLD, 0.6) if locking else Color(1, 1, 1, 0.28 if aim_live else 0.1)
	var d := BARREL_LEN + 20.0
	while d < 1500.0:
		draw_line(PIVOT + u * d, PIVOT + u * (d + 16.0), colour, 4.0)
		d += 34.0
	# Where the aim is on the reach arc.
	draw_arc(PIVOT, DOME_R + 26.0, deg_to_rad(-90.0 + aim_deg - 2.0), deg_to_rad(-90.0 + aim_deg + 2.0), 6,
		Color(GOLD, 0.9), 10.0)


func _draw_meteor(m: Dictionary) -> void:
	var pos := meteor_pos(m)
	var back := dir(m["angle"])          # the trail streams out behind, away from the cannon
	for i in range(8, 0, -1):
		draw_circle(pos + back * (METEOR_R * 0.55 * i), METEOR_R * (1.0 - i * 0.09),
			Color(1.0, 0.55 - i * 0.03, 0.2, 0.22 - i * 0.025))
	draw_circle(pos, METEOR_R * 1.3, Color(1.0, 0.6, 0.25, 0.22))
	draw_circle(pos, METEOR_R, Color(0.46, 0.37, 0.33))
	draw_circle(pos + Vector2(-0.22, -0.22) * METEOR_R, METEOR_R * 0.62, Color(0.62, 0.52, 0.45, 0.6))
	for c in m["craters"]:
		var off := Vector2(c.x, c.y).rotated(m["rot"]) * METEOR_R
		draw_circle(pos + off, c.z * METEOR_R, Color(0.30, 0.23, 0.21))
	if m["claimed"]:
		draw_arc(pos, METEOR_R + 14.0, 0.0, TAU, 40, Color(1.0, 0.45, 0.3, 0.9), 5.0)
	elif m["lock"] > 0.0:
		draw_arc(pos, METEOR_R + 14.0, 0.0, TAU, 40, Color(GOLD, 0.25), 5.0)
		draw_arc(pos, METEOR_R + 14.0, -PI / 2.0, -PI / 2.0 + TAU * minf(m["lock"] / DWELL_S, 1.0), 40,
			GOLD, 7.0)


func _draw_calibration() -> void:
	if hold >= 0.0:
		draw_arc(PIVOT, 84.0, 0.0, TAU, 48, Color(GOLD, 0.2), 10.0)
		if hold > 0.0:
			draw_arc(PIVOT, 84.0, -PI / 2.0, -PI / 2.0 + TAU * hold, 48, GOLD, 10.0)
	if arrow != 0:
		# A curved arrow over the cannon, the way to turn.
		var r := 330.0
		var start := -PI / 2.0
		var end := start + arrow * deg_to_rad(50.0)
		draw_arc(PIVOT, r, minf(start, end), maxf(start, end), 32, Color(GOLD, 0.85), 14.0)
		var tip := PIVOT + Vector2.from_angle(end) * r
		var along := Vector2.from_angle(end + arrow * PI / 2.0)
		var out := Vector2.from_angle(end)
		draw_colored_polygon(PackedVector2Array([tip + along * 44.0, tip + out * 30.0, tip - out * 30.0]),
			Color(GOLD, 0.85))


func _draw_cannon() -> void:
	draw_colored_polygon(PackedVector2Array([PIVOT + Vector2(-120, 100), PIVOT + Vector2(120, 100),
		PIVOT + Vector2(80, 20), PIVOT + Vector2(-80, 20)]), STEEL_DARK)
	draw_set_transform(PIVOT, deg_to_rad(aim_deg), Vector2.ONE)
	var l := BARREL_LEN - _recoil
	draw_colored_polygon(PackedVector2Array([Vector2(-24, 0), Vector2(24, 0), Vector2(18, -l),
		Vector2(-18, -l)]), STEEL)
	draw_rect(Rect2(-24, -l - 6, 48, 18), STEEL_DARK)
	draw_rect(Rect2(-6, -l + 14, 6, l - 30), Color(1, 1, 1, 0.12))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	draw_circle(PIVOT, 60.0, STEEL)
	draw_circle(PIVOT, 60.0 * 0.55, STEEL_DARK)
	draw_circle(PIVOT + Vector2(-14, -16), 14.0, Color(1, 1, 1, 0.15))
