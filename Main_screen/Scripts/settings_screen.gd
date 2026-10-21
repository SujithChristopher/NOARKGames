extends Control
## The Settings scene (settings_screen.tscn), from the main menu's Settings
## button; Back (or Esc) returns to the main menu.
##
## Tracker tab: {DOCUMENTS}/NOARK_demo/settings.json, saved as it is edited.
## `debug` is not listed on purpose (file-only). The LIVE_KEYS are also sent to
## the tracker as a CONFIG and apply at once (recording from the next session);
## the rest need the tracker restarted (sudo systemctl restart noark-tracker).
## Storage tab: the board's camera recordings (storage_tab.gd).

const StorageTab := preload("res://Main_screen/Scripts/storage_tab.gd")
const TrunkMonitorScript := preload("res://Main_screen/Scripts/trunk_monitor.gd")

const LIVE_KEYS := {
	"tracker_solver": "solver", "tracker_refine": "refine",
	"tracker_camera": "camera", "corner_deadband_px": "deadband",
	"trunk_method": "trunk_method", "recording": "recording",
	"recording_fps": "recording_fps", "recording_scale": "recording_scale",
}

# [section title] or [key, label, kind, options, (shown names)]
# kind: "bool", "choice" (choices are compared as strings) or "status" (the link)
const FIELDS := [
	["Connection"],
	["stream_type", "Link to the tracker", "choice", ["ble", "udp"],
		{"ble": "BLE (app on a tablet)", "udp": "UDP (app on the board)"}],
	["", "Status", "status", []],
	["Recording"],
	["recording", "Record camera frames", "bool", []],
	["recording_fps", "Recording fps", "choice", ["15", "30", "60"]],
	["recording_scale", "Recording scale", "choice", ["0.25", "0.5", "1"]],
	["Trunk"],
	["trunk_enabled", "Trunk tracking", "bool", []],
	["trunk_method", "Trunk method", "choice", ["msam_r18", "msam_v3rot", "icp"], TrunkMonitorScript.METHOD_NAMES],
	["Hand tracker"],
	["tracker_solver", "Pose solver", "choice", ["joint", "ransac"]],
	["tracker_refine", "Corner refine", "choice", ["contour", "subpix", "crop", "none"]],
	["tracker_camera", "Cameras", "choice", ["both", "cam0", "cam1"]],
	["corner_deadband_px", "Corner deadband (px)", "choice", ["0", "0.5", "1", "2"]],
	["display", "Show tracker window", "bool", []],
]

const MUTED := Color(0.7, 0.72, 0.75)
const MENU := "res://Main_screen/Scenes/main.tscn"
const LinkProtocol := preload("res://Main_screen/Scripts/link_protocol.gd")
const LINK_STATUS_TEXT := {
	LinkProtocol.LinkStatus.IDLE: "Not started",
	LinkProtocol.LinkStatus.SCANNING: "Looking for the tracker...",
	LinkProtocol.LinkStatus.CONNECTING: "Waiting for the tracker...",
	LinkProtocol.LinkStatus.CONNECTED: "Connected",
}

var _tabs: TabContainer
var _storage: Control
var _status: Label
var _link_label: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var theme := Theme.new()
	theme.default_font_size = 20
	theme.set_constant("v_separation", "Tree", 10)
	theme.set_icon("unchecked", "Tree", _box_icon())   # the default vanishes on a dark background
	self.theme = theme

	var bg := ColorRect.new()
	bg.color = Color(0.11, 0.12, 0.14)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	margin.add_child(col)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 20)
	col.add_child(header)
	var back := Button.new()
	back.text = "  ⬅ Back  "
	back.focus_mode = Control.FOCUS_NONE
	back.custom_minimum_size.y = 48
	back.pressed.connect(_back)
	header.add_child(back)
	var title := Label.new()
	title.text = "Settings"
	title.add_theme_font_size_override("font_size", 30)
	header.add_child(title)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_tabs)
	_tabs.add_child(_tracker_tab())
	_storage = StorageTab.new()
	_storage.name = "Storage"
	_tabs.add_child(_storage)
	_tabs.tab_changed.connect(func(_i: int): _refresh_storage_if_shown())


func _back() -> void:
	get_tree().change_scene_to_file(MENU)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_back()


# An empty checkbox: a light 2 px outline, 16 px square, 4 px clear of the text.
static func _box_icon() -> Texture2D:
	var size := 16
	var img := Image.create(size + 4, size, false, Image.FORMAT_RGBA8)
	var edge := Color(0.85, 0.87, 0.9)
	for i in size:
		for w in 2:
			img.set_pixel(i, w, edge)
			img.set_pixel(i, size - 1 - w, edge)
			img.set_pixel(w, i, edge)
			img.set_pixel(size - 1 - w, i, edge)
	return ImageTexture.create_from_image(img)


func _refresh_storage_if_shown() -> void:
	if _tabs.get_current_tab_control() == _storage:
		_storage.refresh()


# ── Tracker tab ───────────────────────────────────────────────────────────────

func _tracker_tab() -> Control:
	var tab := VBoxContainer.new()
	tab.name = "Tracker"
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tab.add_child(scroll)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 8)
	scroll.add_child(col)
	for f in FIELDS:
		if f.size() == 1:
			col.add_child(_section(f[0]))
		else:
			col.add_child(_row(f))

	_status = Label.new()
	_status.text = "Changes are saved automatically  (%s)" % Settings.path
	_status.add_theme_color_override("font_color", MUTED)
	_status.add_theme_font_size_override("font_size", 16)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tab.add_child(_status)
	return tab


func _section(text: String) -> Control:
	var box := VBoxContainer.new()
	var spacer := Control.new()
	spacer.custom_minimum_size.y = 6
	box.add_child(spacer)
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", MUTED)
	box.add_child(label)
	box.add_child(HSeparator.new())
	return box


func _row(f: Array) -> HBoxContainer:
	var key: String = f[0]
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = f[1]
	label.custom_minimum_size.x = 320
	row.add_child(label)
	if f[2] == "status":
		_link_label = Label.new()
		row.add_child(_link_label)
	elif f[2] == "bool":
		var box := CheckButton.new()
		box.focus_mode = Control.FOCUS_NONE
		box.button_pressed = bool(Settings.get_value(key, false))
		box.toggled.connect(func(on: bool): _changed(key, on))
		row.add_child(box)
	else:
		var options: Array = f[3].duplicate()
		var names: Dictionary = f[4] if f.size() > 4 else {}
		var pick := OptionButton.new()
		pick.focus_mode = Control.FOCUS_NONE
		pick.custom_minimum_size.x = 200
		for o in options:
			pick.add_item(names.get(o, o))
		var current := _as_text(Settings.get_value(key, options[0]))
		var idx := options.find(current)
		if idx < 0:   # a value edited into the file that the list doesn't offer
			options.append(current)
			pick.add_item(current)
			idx = pick.item_count - 1
		pick.select(idx)
		pick.item_selected.connect(func(i: int): _changed(key, _typed(key, options[i])))
		row.add_child(pick)
	return row


func _process(_delta: float) -> void:
	if _link_label:
		var over := "BLE" if Settings.get_value("stream_type", "ble") == "ble" else "UDP"
		_link_label.text = "%s  (%s)" % [LINK_STATUS_TEXT.get(GlobalScript.link_status, "?"), over]


func _changed(key: String, value: Variant) -> void:
	if key == "stream_type":
		Settings.set_value(key, value)
		if not Settings.save():
			_status.text = "Could not save settings!"
			return
		GlobalScript.restart_link()
		# The tracker picks its transport once, at start, from its own board's
		# settings.json — the same file when the app runs on the board.
		_status.text = "This app now connects over %s. The tracker on the board must match: " % value.to_upper() \
			+ "set it there and run  sudo systemctl restart noark-tracker"
		return
	if key == "trunk_enabled":
		TrunkMonitor.set_enabled(value)   # saves, and tells the tracker now
		_status.text = "Saved trunk_enabled = %s (applied now)" % value
		return
	Settings.set_value(key, value)
	if not Settings.save():
		_status.text = "Could not save settings!"
		return
	var live := " (restart the tracker to apply)"
	if LIVE_KEYS.has(key):
		var sent := ("on" if value else "off") if value is bool else _as_text(value)
		GlobalScript.send_tracker_config(LIVE_KEYS[key], sent)
		live = " (sent to the tracker)"
	_status.text = "Saved %s = %s%s" % [key, _as_text(value), live]


# 1.0 -> "1", 0.5 -> "0.5"; matches how the option lists are written.
static func _as_text(v: Variant) -> String:
	if v is float and is_equal_approx(v, round(v)):
		return str(int(v))
	return str(v)


# Keep numbers numeric in the file: the tracker int()/float()s them, but a string would be sloppy.
static func _typed(key: String, text: String) -> Variant:
	if key in ["stream_type", "tracker_solver", "tracker_refine", "tracker_camera", "trunk_method"]:
		return text
	return text.to_float() if "." in text else text.to_int()
