extends RefCounted

# Table-space geometry. Targets are placed and hit-tested in table millimetres;
# the screen only draws.
#
# GlobalScript receives the grip position in metres in the origin-lock frame,
# the table plane is x-z, so
#     hand (mm) = 1000 * (raw_x, raw_z)
# and GlobalScript's own mapping to the screen is
#     px = metres * PLAYER_POS_SCALER_{X,Z} + screen centre.
# This class uses the same mapping so the firefly game's cursor lines up with
# every other game, but with ONE scale (the smaller of the two scalers) so a
# table circle is a circle on screen. (The clinic build used the 4-corner
# affine of WorkspaceConfig; here the main screen's "Define Table" plays that
# role, see GlobalScript.set_table.)

var mapped: bool = true
var _m: Transform2D     # table mm -> screen px
var _inv: Transform2D   # screen px -> table mm


func _init(viewport_size: Vector2) -> void:
	# GlobalScript's scalers are in pixels of its own screen_size; scale to this viewport.
	var ref: Vector2 = GlobalScript.screen_size if GlobalScript.screen_size.x > 0.0 else viewport_size
	var s: Vector2 = viewport_size / ref
	var k := minf(float(GlobalScript.PLAYER_POS_SCALER_X) * s.x,
		float(GlobalScript.PLAYER_POS_SCALER_Z) * s.y) / 1000.0
	if GlobalScript.table_set:
		# The defined table fixes the real scale (px per metre), and the hand
		# arrives in real metres from its centre (input_adapter.gd).
		k = GlobalScript.table_k * minf(s.x, s.y) / 1000.0
	_m = Transform2D(Vector2(k, 0.0), Vector2(0.0, k), viewport_size * 0.5)
	_inv = _m.affine_inverse()


static func tracker_to_mm(raw_x: float, raw_z: float) -> Vector2:
	return Vector2(raw_x, raw_z) * 1000.0


func mm_to_screen(p: Vector2) -> Vector2:
	return _m * p


func screen_to_mm(s: Vector2) -> Vector2:
	return _inv * s


# Screen pixels per table mm along the table's x and y (the affine's column lengths).
func px_per_mm() -> Vector2:
	return Vector2(_m.x.length(), _m.y.length())


static func inside(hand: Vector2, centre: Vector2, w_mm: float) -> bool:
	return hand.distance_to(centre) <= w_mm * 0.5


# n screen points around a table circle (not closed: append [0] for a polyline).
func circle_outline(centre: Vector2, r_mm: float, n: int = 64) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in n:
		var t := TAU * float(i) / float(n)
		pts.append(mm_to_screen(centre + Vector2(cos(t), sin(t)) * r_mm))
	return pts


# True when the whole table circle lands on screen, margin_px in from the edges.
func fits_on_screen(centre: Vector2, r_mm: float, viewport_size: Vector2, margin_px: float) -> bool:
	var rect := Rect2(Vector2.ZERO, viewport_size).grow(-margin_px)
	for p in circle_outline(centre, r_mm, 16):
		if not rect.has_point(p):
			return false
	return true
