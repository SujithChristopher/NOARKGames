extends RefCounted

# The bat (2026-09-29; approved mockup https://claude.ai/artifact/1mPYcyfaEBhEWWLEmStuwK).
# Always on screen, it races the hand to each timed firefly and so shows the
# deadline. Visual and sound only: the catch rule stays in round_runner.gd.
#   PATROL:  circles a perch far from the hand, OUTSIDE the play band (the
#            screen rows the reach area covers, set_play_band): in the strip
#            above it (or below), where no firefly can appear — so a new one
#            never lights up under a resting bat (2026-09-29);
#   HUNT:    a timed firefly appeared: flies a curve from wherever it is to the
#            edge of the catch circle, arriving exactly when the lifetime ends,
#            so its speed is (path length) / (time left): far = fast, near = slow;
#   RETREAT: the hand got there first (a hold started), or a firefly was caught:
#            it turns away to a new perch. A hold that breaks while there is
#            still time sends it hunting again (hunt() from where it is);
#   SWOOP:   a miss: the firefly stays where it was, still flashing (drawn
#            here, since the runner has already dropped it), and the bat flies
#            at it mouth first — fast from afar if it had turned away;
#   GRAB:    its mouth reaches the firefly: a flash of the lantern and a few
#            sparks, and the bat holds it, lit, for GRAB_S;
#   SNATCH:  then it flies off carrying it, the light fading over CARRY_S.
# (2026-09-29: the first version dropped the firefly at once and showed only a
# small one in the bat's mouth; on the board it looked as if it just vanished.)
# Warm-up fireflies: it hunts only during the last diamond (hunt's not_before),
# arriving as the cap ends. Reposition fireflies have no deadline: it patrols,
# and swoops from its perch if one reaches its cap uncaught.
# Warm brown with see-through reddish wings and a light edge, as if the moon
# were behind it (black did not show on the night sky).
# Screen pixels; times on the runner's clock (_now(), seconds).

const Art := preload("res://Games/firefly_reach/game_art.gd")

enum State { PATROL, HUNT, RETREAT, SWOOP, GRAB, SNATCH }

const SCALE := 1.9             # wingspan about 100 px
const RETREAT_PX_S := 900.0    # leaves fast after a catch or a miss
const STRIP_MIN_PX := 70.0     # a strip outside the play band this tall can hold a perch
const SWOOP_PX_S := 900.0
const SNATCH_PX_S := 520.0
const GRAB_S := 0.3
const SNATCH_S := 0.5
const CARRY_S := 1.1
const MOUTH := 11.0            # mouth ahead of the body centre, before SCALE
# Board feedback 2026-09-29: it never seemed to leave after a catch (the next
# firefly sent it straight back), and it sometimes crossed a firefly the hand
# was already holding. So:
const LEAVE_MIN_S := 0.6       # after a catch or a miss it flies away at least this long...
const LEAVE_MAX_FRAC := 0.5    # ...but joins the next hunt no later than half its lifetime
const STANDOFF_PX := 50.0      # a hunt ends this far outside the catch circle (half a wingspan)
const RESUME_DELAY_S := 0.15   # after a hold breaks, wait this long before hunting again
const AVOID_PX := 160.0        # when giving up, first get this far from the firefly
const FUR := Color("6B4A3A")
const FUR_DARK := Color("4A3228")
const MEMBRANE := Color(0.62, 0.36, 0.27, 0.78)
const BONE := Color(0.25, 0.15, 0.11, 0.9)
const RIM := Color(1.0, 0.86, 0.72, 0.85)

var pos := Vector2.ZERO
var heading := 0.0
# For sounds.gd: echolocation clicks per second and their loudness, wingbeat
# loudness (0..1), and left-right pan (-1..1). While hunting the click rate
# rises from about 8 to about 180 per second (a bat's "feeding buzz"):
#     rate(u) = 8 · (180 / 8)^(u²),  u = time used / lifetime.
var click_rate := 3.0
var click_gain := 0.0
var wing_gain := 0.0
var pan := 0.0

var _vp: Vector2
var _state: State = State.PATROL
var _perch := Vector2.ZERO
var _wobble := Vector2(46.0, 20.0)   # patrol circle around the perch, px
var _band_top := -1.0          # play band, screen y; -1 = not known (perches as before)
var _band_bottom := -1.0
var _hand := Vector2.ZERO
var _p0 := Vector2.ZERO        # hunt curve: start, control point, end
var _pc := Vector2.ZERO
var _pe := Vector2.ZERO
var _t0 := 0.0                 # hunt from _t0 to _t1 (= the lifetime's end)
var _t1 := 1.0
var _spawn := 0.0
var _window := 1.0
var _prey := {}                # the missed firefly: {pos, L (body length px), ang}
var _dir := Vector2.RIGHT      # snatch direction
var _s0 := 0.0
var _carry := INF              # when the carried light began to fade (flight start)
var _carrying := false
var _pending: Array = []       # a hunt waiting to start: [target, r, spawn, window, release time, not_before]
var _leave_t0 := -9.0          # when the bat last began to fly away
var _target := Vector2.ZERO    # the firefly it is (or was last) hunting
var _avoid := false            # giving up: move straight away from _target first
var _sparks: Array = []        # [{pos, vel, t}]
var _flap := randf() * TAU
var _now := 0.0


func _init(vp: Vector2) -> void:
	_vp = vp
	_perch = Vector2(vp.x * 0.88, vp.y * 0.18)
	pos = _perch


func set_hand(px: Vector2) -> void:
	_hand = px


# The screen rows fireflies can appear in (the reach area's top and bottom).
func set_play_band(top: float, bottom: float) -> void:
	_band_top = top
	_band_bottom = bottom
	if _state == State.PATROL:
		_retreat()


# Go for the firefly at target (catch radius r px), whose lifetime ends at spawn + window.
# It may start later — while it is still taking a missed firefly (SWOOP, GRAB),
# while it is still flying away (LEAVE_MIN_S), or RESUME_DELAY_S after a hold
# broke (resume = true) — but never later than half the lifetime; it still
# arrives at spawn + window, just faster. not_before holds it back further
# (the warm-up's last diamond), past that half-lifetime limit.
func hunt(target: Vector2, r: float, spawn: float, window: float, now: float, resume: bool = false,
		not_before: float = 0.0) -> void:
	_target = target
	var release := now + (RESUME_DELAY_S if resume else 0.0)
	if _state == State.SNATCH or _state == State.RETREAT:
		release = maxf(release, _leave_t0 + LEAVE_MIN_S)
	release = minf(release, spawn + LEAVE_MAX_FRAC * window)
	release = maxf(release, not_before)
	if _state == State.SWOOP or _state == State.GRAB:
		release = INF   # set when the grab ends
	if release > now:
		_pending = [target, r, spawn, window, release, not_before]
		return
	_start_hunt(target, r, spawn, window, now)


func _start_hunt(target: Vector2, r: float, spawn: float, window: float, now: float) -> void:
	_pending = []
	_avoid = false
	_target = target
	_spawn = spawn
	_window = window
	_t0 = now
	_t1 = spawn + window
	var d := pos - target
	var dist := maxf(d.length(), 1.0)
	var u := d / dist
	_p0 = pos
	_pe = target + u * (r + STANDOFF_PX)
	var side := -1.0 if randf() < 0.5 else 1.0
	_pc = (pos + _pe) * 0.5 + Vector2(-u.y, u.x) * dist * 0.25 * side
	_state = State.HUNT


# The hand reached the firefly first: turn away, first straight away from it.
func give_up() -> void:
	_pending = []
	if _state == State.HUNT:
		_retreat()
		_avoid = true


# Caught (or aborted): back to a perch.
func caught() -> void:
	_pending = []
	if _state == State.HUNT or _state == State.PATROL:
		_retreat()


# A miss: the firefly at target (body length L px, heading ang) stays until
# the bat takes it.
func missed(target: Vector2, L: float, ang: float, _now_s: float) -> void:
	_prey = {"pos": target, "L": L, "ang": ang}
	_carrying = false
	_state = State.SWOOP


func is_hunting() -> bool:
	return _state == State.HUNT


# Still flying at, or holding, a missed firefly: the next one waits for this.
func is_taking() -> bool:
	return _state == State.SWOOP or _state == State.GRAB


func _mouth() -> Vector2:
	return pos + Vector2.from_angle(heading) * MOUTH * SCALE


func _retreat() -> void:
	if _state != State.RETREAT:
		_leave_t0 = _now
	_state = State.RETREAT
	_perch = _pick_perch()


# A perch far from the hand (usually the farthest, sometimes the next): left,
# centre or right in the strip above the play band, else the strip below;
# without room outside the band, one of five spots on the screen as before.
func _pick_perch() -> Vector2:
	var spots: Array[Vector2] = []
	var above := _band_top
	var below := _vp.y - _band_bottom
	if _band_top >= 0.0 and (above >= STRIP_MIN_PX or below >= STRIP_MIN_PX):
		var y := above * 0.5 if above >= STRIP_MIN_PX else _band_bottom + below * 0.5
		var h := above if above >= STRIP_MIN_PX else below
		for fx in [0.12, 0.5, 0.88]:
			spots.append(Vector2(float(fx) * _vp.x, y))
		_wobble = Vector2(46.0, maxf(0.0, minf(20.0, h * 0.5 - 30.0)))
	else:
		for f in [Vector2(0.12, 0.18), Vector2(0.88, 0.18), Vector2(0.5, 0.12), Vector2(0.1, 0.52), Vector2(0.9, 0.52)]:
			spots.append(f * _vp)
		_wobble = Vector2(46.0, 20.0)
	spots.sort_custom(func(p: Vector2, q: Vector2) -> bool: return p.distance_to(_hand) > q.distance_to(_hand))
	return spots[0] if randf() < 0.7 else spots[1]


func update(dt: float, now: float) -> void:
	_now = now
	var prev := pos
	match _state:
		State.HUNT:
			var u := clampf((now - _t0) / maxf(0.05, _t1 - _t0), 0.0, 1.0)
			var a := 1.0 - u
			pos = _p0 * (a * a) + _pc * (2.0 * a * u) + _pe * (u * u)
		State.SWOOP:
			# Head for the spot where the mouth is on the firefly.
			var target: Vector2 = _prey["pos"]
			var to := target - pos
			var dir := to.normalized() if to.length() > 0.1 else Vector2.from_angle(heading)
			var goal := target - dir * MOUTH * SCALE
			var d := goal - pos
			if d.length() < 4.0:
				pos = goal
				heading = dir.angle()
				_dir = dir
				_state = State.GRAB
				_s0 = now
				_carrying = true
				_carry = INF
				for i in 12:
					_sparks.append({"pos": target, "vel": Vector2.from_angle(randf() * TAU) * randf_range(40.0, 140.0), "t": 0.0})
			else:
				pos += d.normalized() * minf(d.length(), SWOOP_PX_S * dt)
		State.GRAB:
			pos += Vector2(0.0, sin(now * 30.0) * 0.6)
			if now - _s0 > GRAB_S:
				_carry = now
				_state = State.SNATCH
				_s0 = now
				_leave_t0 = now
				if not _pending.is_empty():   # a hunt that came during the grab: after the leave
					_pending[4] = maxf(minf(now + LEAVE_MIN_S, float(_pending[2]) + LEAVE_MAX_FRAC * float(_pending[3])),
						float(_pending[5]))
		State.SNATCH:
			pos += (_dir * SNATCH_PX_S + Vector2(0.0, -120.0)) * dt
			if now - _s0 > SNATCH_S:
				_retreat()
		State.RETREAT:
			var d := _perch - pos
			if d.length() < 20.0:
				_state = State.PATROL
			else:
				var way := d.normalized()
				if _avoid:
					var away := pos - _target
					if away.length() < AVOID_PX:
						way = (away.normalized() + way * 0.3).normalized()
					else:
						_avoid = false
				pos += way * minf(d.length(), RETREAT_PX_S * dt) + Vector2(0.0, sin(now * 4.0) * 40.0 * dt)
		State.PATROL:
			var goal := _perch + Vector2(_wobble.x * sin(now * 0.8), _wobble.y * sin(now * 1.7))
			pos += (goal - pos) * minf(1.0, dt * 1.8)
	# A waiting hunt starts when its time comes (not during a swoop or grab).
	if not _pending.is_empty() and _state != State.SWOOP and _state != State.GRAB \
			and now >= float(_pending[4]):
		var p := _pending
		_start_hunt(p[0], p[1], p[2], p[3], now)
	var v := pos - prev
	if v.length() > 0.3 and _state != State.GRAB:
		heading = v.angle()
	if _carrying and now - _carry > CARRY_S:
		_carrying = false
	var keep: Array = []
	for s in _sparks:
		s["t"] += dt
		s["pos"] += s["vel"] * dt
		if float(s["t"]) < 0.6:
			keep.append(s)
	_sparks = keep
	var hunting := _state == State.HUNT
	var u2 := clampf((now - _spawn) / maxf(0.05, _window), 0.0, 1.0) if hunting else 0.0
	click_rate = 8.0 * pow(180.0 / 8.0, u2 * u2) if hunting else (60.0 if _state == State.SWOOP else 3.0)
	click_gain = 0.25 + 0.75 * u2 if hunting else (0.8 if _state == State.SWOOP else 0.12)
	wing_gain = 0.2 + 0.8 * u2 if hunting or _state == State.SWOOP else 0.12
	pan = clampf(pos.x / _vp.x * 2.0 - 1.0, -1.0, 1.0)


# Warm brown, see-through reddish wings with darker finger bones, a light edge
# and a faint halo so it reads on the night sky; wings beat about 11 times a
# second (fast and small while it holds a firefly).
func draw(ci: CanvasItem) -> void:
	# The missed firefly, still there and flashing fast until the bat reaches it.
	if _state == State.SWOOP:
		var target: Vector2 = _prey["pos"]
		var L: float = _prey["L"]
		var lamp := 0.5 + 0.5 * sin(_now * 40.0)
		Art.blit(ci, Art.glow(), Art.lamp_pos(target, L, _prey["ang"]), Vector2.ONE * L * (2.4 + 5.0 * lamp),
			Color(Art.LAMP_GLOW, 0.2 + 0.5 * lamp))
		Art.draw_firefly(ci, target, L, _prey["ang"], lamp, _now, true)
	Art.blit(ci, Art.glow(), pos, Vector2.ONE * 130.0, Color(1.0, 0.85, 0.7, 0.13))
	var grabbing := _state == State.GRAB
	var f := sin(_now * (110.0 if grabbing else 69.0) + _flap) * (0.4 if grabbing else 1.0)
	var xf := Transform2D(heading + PI * 0.5, pos) * Transform2D(0.0, Vector2.ONE * SCALE, 0.0, Vector2.ZERO)
	for s: float in [-1.0, 1.0]:
		var shoulder := Vector2(s * 3.0, -3.0)
		var wrist := Vector2(s * 12.0, -9.0 + f * 9.0)
		var tip := Vector2(s * 27.0, -4.0 + f * 15.0)
		var local := PackedVector2Array([shoulder, wrist, tip])
		local = _quad(local, Vector2(s * 23.0, 2.0 + f * 9.0), Vector2(s * 21.0, 7.0 + f * 7.0))
		local = _quad(local, Vector2(s * 17.0, 3.0 + f * 5.0), Vector2(s * 13.0, 8.0 + f * 4.0))
		local = _quad(local, Vector2(s * 9.0, 5.0 + f * 2.0), Vector2(s * 5.0, 8.0))
		var pts := PackedVector2Array()
		for p in local:
			pts.append(xf * p)
		ci.draw_colored_polygon(pts, MEMBRANE)
		for bone_end in [tip, Vector2(s * 21.0, 7.0 + f * 7.0), Vector2(s * 13.0, 8.0 + f * 4.0)]:
			ci.draw_line(xf * wrist, xf * bone_end, BONE, 1.3, true)
		ci.draw_line(xf * shoulder, xf * wrist, BONE, 2.0, true)
		pts.append(pts[0])
		ci.draw_polyline(pts, RIM, 1.3, true)
	Art._ellipse(ci, xf, Vector2(0.0, 1.0), Vector2(4.2, 8.2), FUR)
	Art._ellipse(ci, xf, Vector2(0.0, 3.0), Vector2(2.4, 4.5), FUR_DARK)
	Art._ellipse(ci, xf, Vector2(0.0, -8.0), Vector2(3.5, 3.5), FUR)
	for s: float in [-1.0, 1.0]:   # ears
		ci.draw_colored_polygon(PackedVector2Array([xf * Vector2(s * 3.0, -9.0), xf * Vector2(s * 2.2, -14.5),
			xf * Vector2(s * 0.6, -10.0)]), FUR)
	# The taken firefly, the same size as on the table, in its mouth: lit while
	# the bat holds it (a flash as it is taken), then its light fades as the bat
	# flies off.
	if _carrying and not _prey.is_empty():
		var k := 1.0 if grabbing else clampf(1.0 - (_now - _carry) / CARRY_S, 0.0, 1.0)
		var flash := maxf(0.0, 1.0 - (_now - _s0) / 0.2) if grabbing else 0.0
		var mouth := _mouth()
		var L: float = _prey["L"]
		var lp := Art.lamp_pos(mouth, L, heading)
		Art.blit(ci, Art.glow(), lp, Vector2.ONE * (L * (2.4 + 5.0 * k) + 120.0 * flash),
			Color(Art.LAMP_GLOW, 0.85 * k + 0.15 * flash))
		Art.draw_firefly(ci, mouth, L, heading, k, _now, false)
	for s in _sparks:
		var a := 1.0 - float(s["t"]) / 0.6
		Art.blit(ci, Art.glow(), s["pos"], Vector2.ONE * 14.0 * a, Color(Art.LAMP_GLOW, a))


# pts plus a quadratic curve from its last point through ctrl to end (6 steps).
# Returned, since packed arrays are copied on write.
static func _quad(pts: PackedVector2Array, ctrl: Vector2, end: Vector2) -> PackedVector2Array:
	var out := pts
	var start := pts[pts.size() - 1]
	for i in range(1, 7):
		var u := float(i) / 6.0
		out.append(start.lerp(ctrl, u).lerp(ctrl.lerp(end, u), u))
	return out
