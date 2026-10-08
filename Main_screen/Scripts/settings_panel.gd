extends CanvasLayer
## Settings screen for the main scene: a button opens a panel over {DOCUMENTS}/NOARK/settings.json.
## Edits are saved as they are made. `debug` is not listed on purpose (file-only).
## Solver / refine / camera / deadband are also sent to the running tracker; the
## rest are read when the tracker starts, so they apply next launch.

const LIVE_KEYS := {
	"tracker_solver": "solver", "tracker_refine": "refine",
	"tracker_camera": "camera", "corner_deadband_px": "deadband",
}

# [key, label, kind, options]   kind: "bool" or "choice" (choices are compared as strings)
const FIELDS := [
	["recording", "Record camera frames", "bool", []],
	["recording_fps", "Recording fps", "choice", ["15", "30", "60"]],
	["recording_scale", "Recording scale", "choice", ["0.25", "0.5", "1"]],
	["trunk_enabled", "Trunk tracking", "bool", []],
	["display", "Show tracker window", "bool", []],
	["tracker_solver", "Pose solver", "choice", ["joint", "ransac"]],
	["tracker_refine", "Corner refine", "choice", ["contour", "subpix", "crop", "none"]],
	["tracker_camera", "Cameras", "choice", ["both", "cam0", "cam1"]],
	["corner_deadband_px", "Corner deadband (px)", "choice", ["0", "0.5", "1", "2"]],
]

var _panel: PanelContainer
var _status: Label


func _ready() -> void:
	layer = 40
	var open := Button.new()
	open.text = "Settings"
	open.focus_mode = Control.FOCUS_NONE
	open.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	open.position = Vector2(12, 12)
	open.pressed.connect(func(): _panel.visible = not _panel.visible)
	add_child(open)

	_panel = PanelContainer.new()
	_panel.visible = false
	_panel.position = Vector2(12, 52)
	add_child(_panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	_panel.add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	margin.add_child(col)

	var title := Label.new()
	title.text = "Settings  (%s)" % Settings.path
	col.add_child(title)
	for f in FIELDS:
		col.add_child(_row(f))
	_status = Label.new()
	_status.text = "Changes are saved automatically."
	col.add_child(_status)


func _row(f: Array) -> HBoxContainer:
	var key: String = f[0]
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = f[1]
	label.custom_minimum_size.x = 240
	row.add_child(label)
	if f[2] == "bool":
		var box := CheckButton.new()
		box.focus_mode = Control.FOCUS_NONE
		box.button_pressed = bool(Settings.get_value(key, false))
		box.toggled.connect(func(on: bool): _changed(key, on))
		row.add_child(box)
	else:
		var options: Array = f[3]
		var pick := OptionButton.new()
		pick.focus_mode = Control.FOCUS_NONE
		for o in options:
			pick.add_item(o)
		var current := _as_text(Settings.get_value(key, options[0]))
		var idx := options.find(current)
		if idx < 0:   # a value edited into the file that the list doesn't offer
			pick.add_item(current)
			idx = pick.item_count - 1
		pick.select(idx)
		pick.item_selected.connect(func(i: int): _changed(key, _typed(key, pick.get_item_text(i))))
		row.add_child(pick)
	return row


func _changed(key: String, value: Variant) -> void:
	if key == "trunk_enabled":
		TrunkMonitor.set_enabled(value)   # saves, and tells the tracker now
		_status.text = "Saved trunk_enabled = %s (applied now)" % value
		return
	Settings.set_value(key, value)
	var ok := Settings.save()
	var live := ""
	if LIVE_KEYS.has(key):
		GlobalScript.send_tracker_config(LIVE_KEYS[key], _as_text(value))
		live = " (sent to the tracker)"
	elif not ok:
		live = ""
	else:
		live = " (applies next launch)"
	_status.text = ("Saved %s = %s%s" % [key, _as_text(value), live]) if ok else "Could not save settings!"


# 1.0 -> "1", 0.5 -> "0.5"; matches how the option lists are written.
static func _as_text(v: Variant) -> String:
	if v is float and is_equal_approx(v, round(v)):
		return str(int(v))
	return str(v)


# Keep numbers numeric in the file: the tracker int()/float()s them, but a string would be sloppy.
static func _typed(key: String, text: String) -> Variant:
	if key in ["tracker_solver", "tracker_refine", "tracker_camera"]:
		return text
	return text.to_float() if "." in text else text.to_int()
