extends Control
## Live trunk angles from the 2D menu's "Trunk Angles" button: a scrolling graph
## of flexion / lateral / axial over the last GRAPH_S seconds, with the warn and
## compensation thresholds from settings.json. View only, nothing is logged.

const MENU := "res://Main_screen/Scenes/select_game.tscn"
const GRAPH_S := 30.0
const MIN_RANGE_DEG := 30.0
const COLORS := [Color(0.35, 0.75, 1.0), Color(1.0, 0.55, 0.3), Color(0.6, 1.0, 0.45)]
const NAMES := ["Forward / back", "Side lean", "Twist"]
const LEVEL_COLORS := [Color.WHITE, Color(1.0, 0.85, 0.3), Color(1.0, 0.35, 0.3)]

# [time_s, Vector3 or null]; null = no angle (not tracking), a gap in the lines.
var _samples: Array = []
var _warn := Vector3.ZERO
var _comp := Vector3.ZERO
var _graph: Control
var _values: Array[Label] = []
var _status: Label
var _result: Label
var _capture: Button


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_warn = _threshold("trunk_warn_deg", 8.0)
	_comp = _threshold("trunk_comp_deg", 15.0)
	_build()
	TrunkMonitor.updated.connect(_on_updated)


func _threshold(key: String, fallback: float) -> Vector3:
	var v = Settings.get_value(key, fallback)
	if v is Dictionary:
		return Vector3(float(v.get("flexion", fallback)), float(v.get("lateral", fallback)),
			float(v.get("axial", fallback)))
	return Vector3.ONE * float(v)


func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.08, 0.14)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 16)
	root.add_theme_constant_override("separation", 10)
	add_child(root)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 24)
	root.add_child(top)
	var title := _label("Trunk angles", 30)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	for i in 3:
		var l := _label("", 24)
		_values.append(l)
		var swatch := ColorRect.new()
		swatch.color = COLORS[i]
		swatch.custom_minimum_size = Vector2(18, 18)
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		top.add_child(swatch)
		top.add_child(l)

	_graph = Control.new()
	_graph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_graph.clip_contents = true
	_graph.draw.connect(_draw_graph)
	root.add_child(_graph)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 16)
	root.add_child(bottom)
	var back := _button("⬅ Back")
	back.pressed.connect(func(): get_tree().change_scene_to_file(MENU))
	bottom.add_child(back)
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(text)
	_status = _label("", 20)
	text.add_child(_status)
	_result = _label("", 18)
	text.add_child(_result)
	_capture = _button("Capture neutral posture")
	_capture.pressed.connect(_on_capture_pressed)
	bottom.add_child(_capture)
	_refresh_text()


func _label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	return l


func _button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(150, 60)
	b.add_theme_font_size_override("font_size", 22)
	return b


func _on_capture_pressed() -> void:
	TrunkMonitor.capture_neutral()
	_result.text = "Sit upright and hold still..."
	_result.modulate = Color.WHITE


func _on_updated() -> void:
	var tracking := TrunkMonitor.state == TrunkMonitor.TRACKING
	_samples.append([_now(), TrunkMonitor.angles if tracking else null])


func _process(_delta: float) -> void:
	var cutoff := _now() - GRAPH_S
	while _samples.size() > 0 and _samples[0][0] < cutoff:
		_samples.pop_front()
	# Tracker gone: stop drawing the last angles as if they were live.
	if not TrunkMonitor.available() and _samples.size() > 0 and _samples.back()[1] != null:
		_samples.append([_now(), null])
	_refresh_text()
	_graph.queue_redraw()


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _refresh_text() -> void:
	var tracking := TrunkMonitor.available() and TrunkMonitor.state == TrunkMonitor.TRACKING
	for i in 3:
		_values[i].text = "%s %s" % [NAMES[i], "%+.1f°" % TrunkMonitor.angles[i] if tracking else "--"]
		_values[i].modulate = LEVEL_COLORS[TrunkMonitor.levels[i]] if tracking else Color(1, 1, 1, 0.5)
	_status.text = TrunkMonitor.status_text()
	_capture.disabled = not TrunkMonitor.available() or TrunkMonitor.state == TrunkMonitor.CAPTURING
	if TrunkMonitor.state == TrunkMonitor.CAPTURING:
		return
	match TrunkMonitor.capture_result:
		"ok":
			_result.text = "Neutral captured ✓"
			_result.modulate = Color(0.5, 1.0, 0.5)
		"moving":
			_result.text = "Capture failed: please hold still and try again"
			_result.modulate = Color(1.0, 0.6, 0.4)
		"not_visible":
			_result.text = "Capture failed: the trunk is not visible to the cameras"
			_result.modulate = Color(1.0, 0.6, 0.4)


func _draw_graph() -> void:
	var w := _graph.size.x
	var h := _graph.size.y
	var font := get_theme_default_font()
	_graph.draw_rect(Rect2(Vector2.ZERO, _graph.size), Color(0, 0, 0, 0.35))

	# Symmetric range: at least ±MIN_RANGE_DEG and the compensation line, wider if
	# an angle in view goes past it.
	var span := maxf(MIN_RANGE_DEG, maxf(_comp.x, maxf(_comp.y, _comp.z)) * 1.5)
	for s in _samples:
		if s[1] != null:
			var a: Vector3 = s[1]
			span = maxf(span, maxf(absf(a.x), maxf(absf(a.y), absf(a.z))) * 1.1)
	var y_of := func(deg: float) -> float: return h * 0.5 - deg / span * h * 0.5
	var x_of := func(t: float) -> float: return w - (_now() - t) / GRAPH_S * w

	# Grid every 10 s and every 10°.
	for sec in range(0, int(GRAPH_S) + 1, 10):
		var x: float = w - sec / GRAPH_S * w
		_graph.draw_line(Vector2(x, 0), Vector2(x, h), Color(1, 1, 1, 0.08))
		_graph.draw_string(font, Vector2(x + 4, h - 6), "-%ds" % sec, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1, 0.4))
	var step := 10 if span <= 60 else 20
	for deg in range(-int(span) / step * step, int(span) + 1, step):
		var y: float = y_of.call(deg)
		_graph.draw_line(Vector2(0, y), Vector2(w, y), Color(1, 1, 1, 0.25 if deg == 0 else 0.08))
		_graph.draw_string(font, Vector2(4, y - 3), "%+d°" % deg if deg != 0 else "0°", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1, 0.45))

	# Thresholds: the smallest per-axis value, so no axis crosses a line unseen.
	var warn := minf(_warn.x, minf(_warn.y, _warn.z))
	var comp := minf(_comp.x, minf(_comp.y, _comp.z))
	for pair in [[warn, LEVEL_COLORS[1]], [comp, LEVEL_COLORS[2]]]:
		for sgn in [-1.0, 1.0]:
			var y: float = y_of.call(sgn * pair[0])
			_graph.draw_dashed_line(Vector2(0, y), Vector2(w, y), Color(pair[1], 0.6), 2.0, 10.0)

	for i in 3:
		var line := PackedVector2Array()
		for s in _samples:
			if s[1] == null:
				if line.size() > 1:
					_graph.draw_polyline(line, COLORS[i], 3.0, true)
				line.clear()
				continue
			line.append(Vector2(x_of.call(s[0]), y_of.call(s[1][i])))
		if line.size() > 1:
			_graph.draw_polyline(line, COLORS[i], 3.0, true)

	if not TrunkMonitor.available() or TrunkMonitor.state != TrunkMonitor.TRACKING:
		_graph.draw_string(font, Vector2(0, h * 0.5 - 40), TrunkMonitor.status_text(),
			HORIZONTAL_ALIGNMENT_CENTER, w, 28, Color(1, 1, 1, 0.7))
