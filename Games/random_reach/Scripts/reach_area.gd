extends RefCounted
## Where Random Reach may put an apple: inside the patient's reach outline from the workspace
## scan (reach_scan.gd, kept by reach_store.gd; an experiment's own scan in reach_play_run.gd),
## the whole apple, not only its centre, and inside the game's usual box (clear of the HUD).
##
## The outline is in table mm, as the scan measured the hand: with a table defined, mm from its
## centre (GlobalScript.table_r * 1000); without one, the tracker's metres * 1000. Random Reach's
## screen is GlobalScript's mapping of the same hand: px = metres * table_k (or the scaler) plus
## the screen centre, minus the game's Zero offset. So an outline point lands where the hand
## would be drawn standing on it. 2D only: in 3D the screen's y is height, not the table.
##
## The game draws that workspace scaled to its apple area (`view_fit`): visual feedback only, so
## a small reach still moves the sheep across the screen. One scale for both axes (a circle stays a
## circle), GAIN_MIN..GAIN_MAX. Apples are placed and caught in the drawn space; everything logged
## is mapped back through the inverse, so the raw data stays in real units.

const TRIES := 300
const GAIN_MIN := 0.5
const GAIN_MAX := 4.0   # more and the tracker's jitter shows as the sheep shaking


## The outline in the game's pixels. Empty if it has fewer than 3 points.
static func outline_px(boundary_mm: Array, zero_offset: Vector2 = Vector2.ZERO) -> PackedVector2Array:
	var out := PackedVector2Array()
	if boundary_mm.size() < 3:
		return out
	var k := Vector2(GlobalScript.table_k, GlobalScript.table_k) if GlobalScript.table_set \
		else Vector2(GlobalScript.PLAYER_POS_SCALER_X, GlobalScript.PLAYER_POS_SCALER_Z)
	var centre := Vector2(GlobalScript.X_SCREEN_OFFSET, GlobalScript.Y_SCREEN_OFFSET)
	for p in boundary_mm:
		out.append(Vector2(float(p[0]), float(p[1])) / 1000.0 * k + centre - zero_offset)
	return out


## Real game pixels -> drawn pixels: the outline's bounding box, centred and scaled onto the box
## [lo, hi]. Identity without an outline.
static func view_fit(outline: PackedVector2Array, lo: Vector2i, hi: Vector2i) -> Transform2D:
	if outline.size() < 3:
		return Transform2D.IDENTITY
	var rect := Rect2(outline[0], Vector2.ZERO)
	for p in outline:
		rect = rect.expand(p)
	var box := Rect2(Vector2(lo), Vector2(hi - lo))
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return Transform2D.IDENTITY
	var gain := clampf(minf(box.size.x / rect.size.x, box.size.y / rect.size.y), GAIN_MIN, GAIN_MAX)
	return Transform2D(0.0, Vector2(gain, gain), 0.0, box.get_center() - rect.get_center() * gain)


## The whole circle (centre, radius r px) inside the outline.
static func fits(outline: PackedVector2Array, centre: Vector2, r: float) -> bool:
	if not Geometry2D.is_point_in_polygon(centre, outline):
		return false
	for i in outline.size():
		var a := outline[i]
		var b := outline[(i + 1) % outline.size()]
		if centre.distance_to(Geometry2D.get_closest_point_to_segment(centre, a, b)) < r:
			return false
	return true


## A random spot in the box [lo, hi] where an apple of radius r fits the outline, or null if
## none was found (an outline too small, or outside the box).
static func pick(outline: PackedVector2Array, r: float, lo: Vector2i, hi: Vector2i) -> Variant:
	if outline.size() < 3:
		return null
	# Only the part of the box the outline covers is worth trying.
	var rect := Rect2(outline[0], Vector2.ZERO)
	for p in outline:
		rect = rect.expand(p)
	var x0 := maxi(lo.x, ceili(rect.position.x + r))
	var x1 := mini(hi.x, floori(rect.end.x - r))
	var y0 := maxi(lo.y, ceili(rect.position.y + r))
	var y1 := mini(hi.y, floori(rect.end.y - r))
	if x0 > x1 or y0 > y1:
		return null
	for i in TRIES:
		var c := Vector2(randi_range(x0, x1), randi_range(y0, y1))
		if fits(outline, c, r):
			return c
	return null
