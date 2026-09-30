extends Control

# "Define Table": the hand is put on the four corners of the table (top-left,
# top-right, bottom-left, bottom-right, as seen on screen) and each is recorded.
# GlobalScript.set_table() turns them into the screen mapping, so the origin
# does not need setting. Enter records / saves, Esc cancels.

signal table_done

const CORNER_LABELS: Array = ["top-left", "top-right", "bottom-left", "bottom-right"]

var _corners: Array = []      # Vector2(camera x, z) per recorded corner
var _ys: Array = []
var _screen_pts: Array = []   # where the cursor was, for feedback only
var _btn: Button
var _instruction: Label
var _status: Label
var _live: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var vp := get_viewport_rect().size

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.04, 0.12, 0.88)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	_instruction = _label(26, Color(0.95, 0.95, 1.0), Vector2(0.0, vp.y * 0.30), vp.x)
	_status = _label(16, Color(0.65, 0.90, 0.65), Vector2(0.0, vp.y * 0.30 + 50.0), vp.x)
	_live = _label(15, Color(0.9, 0.9, 0.9), Vector2(0.0, vp.y * 0.88), vp.x)

	_btn = _button("", Vector2(240.0, 52.0), Vector2(vp.x * 0.5 - 120.0, vp.y * 0.48))
	_btn.pressed.connect(_on_btn)
	var redo := _button("Start over", Vector2(130.0, 34.0), Vector2(vp.x * 0.5 - 135.0, vp.y * 0.48 + 62.0))
	redo.pressed.connect(func():
		_corners.clear(); _ys.clear(); _screen_pts.clear(); _refresh())
	var cancel := _button("Cancel", Vector2(130.0, 34.0), Vector2(vp.x * 0.5 + 5.0, vp.y * 0.48 + 62.0))
	cancel.pressed.connect(queue_free)
	var clear := _button("Clear saved table", Vector2(200.0, 34.0), Vector2(vp.x * 0.5 - 100.0, vp.y * 0.48 + 106.0))
	clear.visible = GlobalScript.table_set
	clear.pressed.connect(func():
		GlobalScript.clear_table(); table_done.emit(); queue_free())
	_refresh()


func _label(size: int, col: Color, pos: Vector2, width: float) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.custom_minimum_size = Vector2(width, 30.0)
	l.position = pos
	add_child(l)
	return l


func _button(text: String, size: Vector2, pos: Vector2) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = size
	b.size = size
	b.position = pos
	b.add_theme_font_size_override("font_size", 16)
	add_child(b)
	return b


func _hand_live() -> bool:
	return GlobalScript.last_packet_ms > 0 and Time.get_ticks_msec() - GlobalScript.last_packet_ms <= 1000


func _process(_dt: float) -> void:
	var c := GlobalScript.hand_camera()
	if _hand_live():
		_live.add_theme_color_override("font_color", Color(0.4, 0.9, 0.5))
		_live.text = "Tracker live — x %.3f  z %.3f m" % [c.x, c.z]
	else:
		_live.add_theme_color_override("font_color", Color(0.9, 0.65, 0.2))
		_live.text = "No tracker data"
	_btn.disabled = not _hand_live() and _corners.size() < 4
	queue_redraw()


func _draw() -> void:
	for p in _screen_pts:
		draw_circle(p, 9.0, Color(0.2, 0.88, 0.3, 0.85))
	if _screen_pts.size() >= 2:
		var r := Rect2(_screen_pts[0], Vector2.ZERO)
		for p in _screen_pts:
			r = r.expand(p)
		draw_rect(r, Color(0.25, 0.8, 0.3, 0.18), true)
		draw_rect(r, Color(0.25, 0.8, 0.3, 0.65), false, 2.0)
	if _hand_live():
		var p := GlobalScript.network_position
		draw_arc(p, 15.0, 0.0, TAU, 48, Color(1.0, 0.88, 0.18, 0.92), 2.5)
		draw_circle(p, 3.5, Color(1.0, 0.88, 0.18, 0.92))


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ENTER or event.physical_keycode == KEY_KP_ENTER:
			_on_btn()
			get_viewport().set_input_as_handled()
		elif event.physical_keycode == KEY_ESCAPE:
			queue_free()
			get_viewport().set_input_as_handled()


func _on_btn() -> void:
	if _corners.size() < 4:
		if not _hand_live():
			return
		var c := GlobalScript.hand_camera()
		_corners.append(Vector2(c.x, c.z))
		_ys.append(c.y)
		_screen_pts.append(GlobalScript.network_position)
		_refresh()
		return
	var y0 := 0.0
	for y in _ys:
		y0 += y
	if GlobalScript.set_table(_corners, y0 / _ys.size()):
		table_done.emit()
		queue_free()
	else:
		_status.text = "Corners do not span a table — start over"
		_status.add_theme_color_override("font_color", Color(0.95, 0.5, 0.4))


func _refresh() -> void:
	var n := _corners.size()
	_status.add_theme_color_override("font_color", Color(0.65, 0.9, 0.65))
	if n < 4:
		_instruction.text = "Put the hand on the %s corner of the table, then press Enter" % CORNER_LABELS[n]
		_btn.text = "Record %s   [Enter]" % CORNER_LABELS[n]
		_status.text = "%d / 4 corners recorded" % n
	else:
		_instruction.text = "All 4 corners recorded"
		_btn.text = "Save table   [Enter]"
		_status.text = "Corners are as seen on the screen: top-left first, bottom-right last"
