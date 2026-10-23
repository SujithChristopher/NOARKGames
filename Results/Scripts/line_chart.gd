class_name LineChart
extends Control
## A minimal line chart drawn with _draw(): one x label per point, any number of
## series, a legend, and the nearest point's values on hover.
## chart.plot(["01-10", "02-10"], [{"name": "Active area", "values": [1.0, 2.0], "color": Color.GREEN}])

const PAD_LEFT := 64.0
const PAD_RIGHT := 32.0
const PAD_TOP := 44.0
const PAD_BOTTOM := 52.0
const Y_TICKS := 5

@export var title := ""
@export var x_label := ""
@export var y_label := ""
@export var background := Color("#161a1d")
@export var grid_color := Color("#283442")
@export var text_color := Color.WHITE_SMOKE

var _x_labels: Array = []
var _series: Array = []
var _y_min := 0.0
var _y_max := 1.0
var _hover := -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	resized.connect(queue_redraw)


func plot(x_labels: Array, series: Array) -> void:
	_x_labels = x_labels
	_series = series
	var lo := INF
	var hi := -INF
	for s in series:
		for v in s.values:
			lo = minf(lo, v)
			hi = maxf(hi, v)
	if lo == INF:
		lo = 0.0
		hi = 1.0
	if is_equal_approx(lo, hi):
		hi = lo + 1.0
	var step := _nice_step((hi - lo) / Y_TICKS)
	_y_min = floorf(lo / step) * step
	_y_max = ceilf(hi / step) * step
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var i := _nearest_index(event.position.x)
		if i != _hover:
			_hover = i
			queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _hover != -1:
		_hover = -1
		queue_redraw()


func _plot_rect() -> Rect2:
	return Rect2(PAD_LEFT, PAD_TOP, size.x - PAD_LEFT - PAD_RIGHT, size.y - PAD_TOP - PAD_BOTTOM)


func _point(i: int, v: float) -> Vector2:
	var r := _plot_rect()
	var n := _x_labels.size()
	var x := r.position.x + (r.size.x * 0.5 if n <= 1 else r.size.x * i / (n - 1))
	var y := r.end.y - r.size.y * (v - _y_min) / (_y_max - _y_min)
	return Vector2(x, y)


func _nearest_index(mx: float) -> int:
	var n := _x_labels.size()
	if n == 0 or not _plot_rect().grow(8).has_point(Vector2(mx, _plot_rect().get_center().y)):
		return -1
	if n == 1:
		return 0
	var r := _plot_rect()
	return clampi(roundi((mx - r.position.x) / r.size.x * (n - 1)), 0, n - 1)


func _draw() -> void:
	var font := get_theme_default_font()
	var r := _plot_rect()
	draw_rect(Rect2(Vector2.ZERO, size), background)
	if title != "":
		draw_string(font, Vector2(0, 28), title, HORIZONTAL_ALIGNMENT_CENTER, size.x, 18, text_color)

	# Horizontal grid and y ticks
	for t in Y_TICKS + 1:
		var v := _y_min + (_y_max - _y_min) * t / Y_TICKS
		var y := r.end.y - r.size.y * t / Y_TICKS
		draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y), grid_color, 1.0)
		draw_string(font, Vector2(0, y + 5), _fmt(v), HORIZONTAL_ALIGNMENT_RIGHT, PAD_LEFT - 8, 13, text_color)

	# X labels, thinned so they never overlap
	var n := _x_labels.size()
	var every := maxi(1, ceili(n * 56.0 / maxf(r.size.x, 1.0)))
	for i in n:
		var p := _point(i, _y_min)
		draw_line(Vector2(p.x, r.position.y), Vector2(p.x, r.end.y), Color(grid_color, 0.5), 1.0)
		if i % every == 0:
			draw_string(font, Vector2(p.x - 40, r.end.y + 20), str(_x_labels[i]), HORIZONTAL_ALIGNMENT_CENTER, 80, 13, text_color)
	if x_label != "":
		draw_string(font, Vector2(r.position.x, size.y - 8), x_label, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 14, text_color)
	if y_label != "":
		draw_set_transform(Vector2(14, r.get_center().y), -PI / 2)
		draw_string(font, Vector2(-r.size.y / 2, 0), y_label, HORIZONTAL_ALIGNMENT_CENTER, r.size.y, 14, text_color)
		draw_set_transform(Vector2.ZERO)

	# Series
	for s in _series:
		var pts := PackedVector2Array()
		for i in mini(n, s.values.size()):
			pts.append(_point(i, s.values[i]))
		if pts.size() > 1:
			draw_polyline(pts, s.color, 2.5, true)
		for p in pts:
			draw_circle(p, 4.0, s.color)

	# Legend, top right
	var lx := r.end.x
	for s in range(_series.size() - 1, -1, -1):
		var name: String = _series[s].name
		var w := font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		lx -= w + 28
		draw_rect(Rect2(lx, r.position.y - 20, 12, 12), _series[s].color)
		draw_string(font, Vector2(lx + 16, r.position.y - 9), name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, text_color)

	if _hover >= 0:
		_draw_tooltip(font, _hover)


func _draw_tooltip(font: Font, i: int) -> void:
	var r := _plot_rect()
	var x := _point(i, _y_min).x
	draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(text_color, 0.4), 1.0)
	var lines: Array[String] = [str(_x_labels[i])]
	var colors: Array[Color] = [text_color]
	for s in _series:
		if i < s.values.size():
			lines.append("%s: %s" % [s.name, _fmt(s.values[i])])
			colors.append(s.color)
	var w := 0.0
	for l in lines:
		w = maxf(w, font.get_string_size(l, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x)
	var box := Rect2(x + 10, r.position.y + 6, w + 16, lines.size() * 18 + 8)
	if box.end.x > size.x:
		box.position.x = x - 10 - box.size.x
	draw_rect(box, Color(0, 0, 0, 0.8))
	for k in lines.size():
		draw_string(font, box.position + Vector2(8, 20 + k * 18), lines[k], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, colors[k])


static func _nice_step(raw: float) -> float:
	if raw <= 0.0:
		return 1.0
	var mag := pow(10.0, floorf(log(raw) / log(10.0)))
	for m in [1.0, 2.0, 5.0, 10.0]:
		if raw <= m * mag:
			return m * mag
	return 10.0 * mag


static func _fmt(v: float) -> String:
	return str(roundi(v)) if absf(v) >= 100.0 or is_equal_approx(v, roundf(v)) else "%.2f" % v
