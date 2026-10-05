extends CanvasLayer
## Subject picker: the tracker's snapshot with each person outlined; tap one to
## follow them. Opened by trunk_panel. The tracker numbers the people when it
## sends the image, so a tap means the person you saw even if they have moved.

signal closed

const FONT_SIZE := 22
const COLORS := [Color(0.3, 0.8, 1.0), Color(1.0, 0.7, 0.2), Color(0.5, 1.0, 0.5), Color(1.0, 0.5, 0.8)]

var _view: View
var _info: Label


class View extends Control:
	signal picked(index: int)
	var texture: ImageTexture
	var people := []
	var locked := -1

	func _frame() -> Rect2:
		if texture == null:
			return Rect2()
		var img := Vector2(texture.get_size())
		var s := minf(size.x / img.x, size.y / img.y)
		return Rect2((size - img * s) / 2.0, img * s)

	func _draw() -> void:
		var fr := _frame()
		if texture == null:
			return
		draw_texture_rect(texture, fr, false)
		var s := fr.size.x / texture.get_size().x
		for i in people.size():
			var pts := PackedVector2Array()
			for p in people[i]:
				pts.append(fr.position + p * s)
			if pts.size() < 3:
				continue
			var col: Color = COLORS[i % COLORS.size()]
			draw_colored_polygon(pts, Color(col, 0.35 if i != locked else 0.55))
			pts.append(pts[0])
			draw_polyline(pts, col, 4.0 if i == locked else 2.0)
			var c := Vector2.ZERO
			for p in people[i]:
				c += p
			c = fr.position + c / people[i].size() * s
			draw_string(get_theme_default_font(), c - Vector2(8, -8), str(i + 1),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 32, Color.WHITE)

	func _gui_input(event: InputEvent) -> void:
		if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
			return
		var fr := _frame()
		if fr.size.x <= 0.0:
			return
		var at: Vector2 = (event.position - fr.position) / (fr.size.x / texture.get_size().x)
		for i in people.size():
			if people[i].size() >= 3 and Geometry2D.is_point_in_polygon(at, people[i]):
				picked.emit(i)
				return


func _ready() -> void:
	layer = 50
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.8)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 40
	box.offset_right = -40
	box.offset_top = 30
	box.offset_bottom = -30
	add_child(box)

	var title := Label.new()
	title.text = "Who should be tracked?"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", FONT_SIZE + 6)
	box.add_child(title)

	_view = View.new()
	_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view.picked.connect(_on_picked)
	box.add_child(_view)

	_info = Label.new()
	_info.text = "Waiting for the camera image..."
	_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_info.add_theme_font_size_override("font_size", FONT_SIZE)
	box.add_child(_info)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)
	row.add_child(_button("Refresh", TrunkMonitor.request_snapshot))
	row.add_child(_button("Closest to centre", func(): _on_picked(-1)))
	row.add_child(_button("Close", _close))

	TrunkMonitor.snapshot_ready.connect(_on_snapshot)
	TrunkMonitor.request_snapshot()


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", FONT_SIZE)
	b.pressed.connect(cb)
	return b


func _on_snapshot(texture: ImageTexture, people: Array, locked: int) -> void:
	_view.texture = texture
	_view.people = people
	_view.locked = locked
	_view.queue_redraw()
	_info.text = "Tap a person to track them" if people.size() > 1 else \
			("Tap the person" if people.size() == 1 else "Nobody found: sit in view and refresh")


func _on_picked(index: int) -> void:
	TrunkMonitor.select_person(index)
	_close()


func _close() -> void:
	closed.emit()
	queue_free()
