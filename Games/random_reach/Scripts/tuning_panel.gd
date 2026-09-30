extends CanvasLayer
## Live tracker tuning overlay. F2 or the "Tune" button toggles it.
## Each change is sent to tracker.py as `CFG:<key>=<value>` and applies on the next frame.

const OPTIONS := {
	"solver": ["joint", "ransac"],
	"refine": ["crop", "subpix", "none"],
	"camera": ["both", "cam0", "cam1"],
	"deadband": ["0", "0.5", "1", "2"],
}
const SETTINGS_KEYS := {"solver": "tracker_solver", "camera": "tracker_camera"}

var _box: VBoxContainer
var _toggle: Button
var _status: Label


func _ready() -> void:
	layer = 50
	var settings = JSON.parse_string(FileAccess.get_file_as_string("res://settings.json"))
	if settings == null:
		settings = {}

	_toggle = Button.new()
	_toggle.text = "Tune"
	_toggle.position = Vector2(8, 8)
	_toggle.focus_mode = Control.FOCUS_NONE
	_toggle.pressed.connect(func(): _box.visible = not _box.visible)
	add_child(_toggle)

	_box = VBoxContainer.new()
	_box.position = Vector2(8, 44)
	_box.visible = false
	add_child(_box)

	_status = Label.new()
	_status.text = "ready"
	_status.add_theme_font_size_override("font_size", 18)
	_set_status("ready", Color.WHITE)
	_box.add_child(_status)
	GlobalScript.tracker_config_applied.connect(func(t): _set_status("APPLIED: " + t, Color.LIME_GREEN))

	for key in OPTIONS:
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = key
		label.custom_minimum_size.x = 80
		row.add_child(label)
		var pick := OptionButton.new()
		pick.focus_mode = Control.FOCUS_NONE
		for v in OPTIONS[key]:
			pick.add_item(v)
		# Show what the tracker started with (settings.json); crop/0 are its defaults.
		var start = str(settings.get(SETTINGS_KEYS.get(key, ""), ""))
		var idx = OPTIONS[key].find(start)
		pick.select(max(idx, 0))
		pick.item_selected.connect(func(i):
			_set_status("sending %s=%s ..." % [key, OPTIONS[key][i]], Color.ORANGE)
			GlobalScript.send_tracker_config(key, OPTIONS[key][i]))
		row.add_child(pick)
		_box.add_child(row)


func _set_status(text: String, color: Color) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", color)
	_status.add_theme_color_override("font_outline_color", Color.BLACK)
	_status.add_theme_constant_override("outline_size", 4)


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F2:
		_box.visible = not _box.visible
