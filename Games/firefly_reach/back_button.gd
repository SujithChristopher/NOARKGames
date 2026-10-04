extends CanvasLayer

# The Back button of the firefly scenes (top right; the Tune button is top left).
# The round runner hides the cursor, since the patient plays with the tracker,
# so moving the mouse shows it for a few seconds to let the operator click.

signal pressed

const CURSOR_SHOW_S := 3.0

var _hide_at: float = 0.0


func _ready() -> void:
	layer = 50
	process_mode = Node.PROCESS_MODE_ALWAYS
	var b := Button.new()
	b.text = "Back"
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(150, 60)
	b.add_theme_font_size_override("font_size", 28)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.1, 0.22, 0.75)
	style.border_color = Color(1, 1, 1, 0.35)
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	b.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate()
	hover.bg_color = Color(0.12, 0.2, 0.38, 0.9)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
	b.pressed.connect(pressed.emit)
	add_child(b)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_hide_at = Time.get_ticks_msec() / 1000.0 + CURSOR_SHOW_S


func _process(_delta: float) -> void:
	if _hide_at > 0.0 and Time.get_ticks_msec() / 1000.0 >= _hide_at:
		_hide_at = 0.0
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
