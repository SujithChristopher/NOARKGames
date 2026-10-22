extends RefCounted

# Stretches the patient's reach outline (the daily reach scan, ReachStore) over
# the play area, so targets spread over the whole screen while staying inside
# what the patient can reach. Each axis is scaled on its own: the outline's
# bounding box fills the play rect, so a narrow reach is widened on screen.
#
# The hand is read in the units the scan recorded it in (firefly_reach
# input_adapter.gd): metres from the table centre when a table is defined,
# otherwise the origin-lock metres, times 1000.

const ReachStore := preload("res://Games/firefly_reach/reach_store.gd")

const MIN_SPAN_MM := 50.0   # a smaller outline is a failed scan: don't blow it up

var valid := false
var _mm_rect: Rect2          # outline bounding box, table mm
var _rect: Rect2             # play rect, screen px
var _poly := PackedVector2Array()   # outline on screen


func _init(patient_id: String, play_rect: Rect2) -> void:
	_rect = play_rect
	var mm := PackedVector2Array()
	for p in ReachStore.load_boundary(patient_id):
		mm.append(Vector2(p[0], p[1]))
	if mm.size() < 3:
		return
	_mm_rect = Rect2(mm[0], Vector2.ZERO)
	for p in mm:
		_mm_rect = _mm_rect.expand(p)
	if _mm_rect.size.x < MIN_SPAN_MM or _mm_rect.size.y < MIN_SPAN_MM:
		return
	for p in mm:
		_poly.append(mm_to_screen(p))
	valid = true


static func hand_mm() -> Vector2:
	if GlobalScript.table_set:
		return GlobalScript.table_r * 1000.0
	return Vector2(GlobalScript.raw_x, GlobalScript.raw_z) * 1000.0


# Hand mm -> raw tracker units, as GlobalScript.raw_x / raw_z hold them (for the CSV).
static func mm_to_raw(mm: Vector2) -> Vector2:
	var m := mm / 1000.0
	if GlobalScript.table_set:
		return Vector2(m.x * GlobalScript.table_k / GlobalScript.PLAYER_POS_SCALER_X,
			m.y * GlobalScript.table_k / GlobalScript.PLAYER_POS_SCALER_Z)
	return m


func mm_to_screen(mm: Vector2) -> Vector2:
	return _rect.position + (mm - _mm_rect.position) / _mm_rect.size * _rect.size


func screen_to_mm(px: Vector2) -> Vector2:
	return _mm_rect.position + (px - _rect.position) / _rect.size * _mm_rect.size


# A random screen point inside the outline, at least margin_px from its edge.
# Falls back to the outline's centre if the inset outline is too thin to hit.
func random_point(margin_px: float) -> Vector2:
	var inset := Geometry2D.offset_polygon(_poly, -margin_px)
	if inset.is_empty():
		return mm_to_screen(_mm_rect.get_center())
	# offset_polygon can split a concave outline: sample the largest piece.
	var poly: PackedVector2Array = inset[0]
	for piece in inset:
		if _area(piece) > _area(poly):
			poly = piece
	var box := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		box = box.expand(p)
	for i in 200:
		var p := Vector2(randf_range(box.position.x, box.end.x), randf_range(box.position.y, box.end.y))
		if Geometry2D.is_point_in_polygon(p, poly):
			return p
	return box.get_center()


static func _area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		a += poly[i].cross(poly[(i + 1) % poly.size()])
	return absf(a) * 0.5
