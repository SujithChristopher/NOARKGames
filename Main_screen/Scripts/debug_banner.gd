extends CanvasLayer
## On every screen while debug is on. It is one switch away in Settings, and a real
## patient's session played in it would be logged as vvv and never uploaded, so it
## must not go unnoticed.


func _init() -> void:
	name = "DebugBanner"
	layer = 128
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	var back := StyleBoxFlat.new()
	back.bg_color = Color(0.7, 0.1, 0.1, 0.85)
	back.content_margin_left = 8
	back.content_margin_right = 8
	var label := Label.new()
	label.text = "DEBUG:  mouse, not the tracker  ·  logged as vvv, not uploaded"
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_stylebox_override("normal", back)
	add_child(label)
	# The bottom edge: the top is where the menus and games keep their scores.
	label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	label.grow_vertical = Control.GROW_DIRECTION_BEGIN


func _process(_delta: float) -> void:
	visible = Settings.is_debug()
