extends Control
## The Settings scene (settings_screen.tscn), from the main menu's Settings
## button; Back (or Esc) returns to the main menu. A rail on the left picks the tab and
## says how the link stands; settings_style.gd is how all of it looks.
##
## Tracker tab: {DOCUMENTS}/NOARK_demo/settings.json, saved as it is edited.
## The LIVE_KEYS are also sent to the tracker as a CONFIG and apply at once
## (recording from the next session); the rest restart the tracker, over the link,
## so nobody has to do it by hand. `debug` is the app's own: the tracker is not told.
## Camera tab: exposure and gain, with a live preview (camera_tab.gd).
## Calibration tab: a new measurement of the device's tags (calibration_tab.gd).
## Storage tab: the board's camera recordings (storage_tab.gd).

const Style := preload("res://Main_screen/Scripts/settings_style.gd")
const CameraTab := preload("res://Main_screen/Scripts/camera_tab.gd")
const CalibrationTab := preload("res://Main_screen/Scripts/calibration_tab.gd")
const StorageTab := preload("res://Main_screen/Scripts/storage_tab.gd")
const TrunkMonitorScript := preload("res://Main_screen/Scripts/trunk_monitor.gd")

const LIVE_KEYS := {
	"tracker_solver": "solver", "tracker_refine": "refine",
	"tracker_camera": "camera", "corner_deadband_px": "deadband",
	"trunk_method": "trunk_method", "trunk_reference": "trunk_reference", "recording": "recording",
	"recording_fps": "recording_fps", "recording_scale": "recording_scale",
}

# [section title] or [key, label, kind, options, (shown names)]
# kind: "bool" or "choice" (choices are compared as strings)
const FIELDS := [
	["Connection"],
	["stream_type", "Link to the tracker", "choice", ["ble", "udp"],
		{"ble": "BLE (app on a tablet)", "udp": "UDP (app on the board)"}],
	["Recording"],
	["recording", "Record camera frames", "bool", []],
	["recording_fps", "Frame rate", "choice", ["15", "30", "60", "90", "0"],
		{"15": "15 fps", "30": "30 fps", "60": "60 fps", "90": "90 fps", "0": "Every frame"}],
	["recording_scale", "Picture size", "choice", ["0.25", "0.5", "1"],
		{"0.25": "Quarter", "0.5": "Half", "1": "Full"}],
	["Trunk"],
	["trunk_enabled", "Trunk tracking", "bool", []],
	["trunk_method", "Method", "choice", ["msam_r18", "msam_v3rot", "icp"], TrunkMonitorScript.METHOD_NAMES],
	["trunk_reference", "Angles measured from", "choice", ["neutral", "model"],
		{"neutral": "Captured neutral", "model": "Model frame"}],
	["Hand tracker"],
	["tracker_solver", "Pose solver", "choice", ["joint", "ransac"],
		{"joint": "Joint", "ransac": "RANSAC"}],
	["tracker_refine", "Corner refinement", "choice", ["contour", "subpix", "crop", "multistage", "none"],
		{"contour": "Contour", "subpix": "Sub-pixel", "crop": "Crop", "multistage": "Multistage", "none": "None"}],
	["tracker_camera", "Cameras", "choice", ["both", "cam0", "cam1"],
		{"both": "Both", "cam0": "Camera 0", "cam1": "Camera 1"}],
	["corner_deadband_px", "Corner deadband", "choice", ["0", "0.5", "1", "2"],
		{"0": "Off", "0.5": "0.5 px", "1": "1 px", "2": "2 px"}],
	["display", "Show tracker window", "bool", []],
	["Debug"],
	["debug", "Play with the mouse, not the tracker", "bool", []],
]
const HELP := {
	"stream_type": "How this app reaches the tracker.",
	"recording": "Saves the cameras' video on the board from the next session. Storage lists what is kept.",
	"recording_fps": "How many frames a second are saved. Tracking runs as fast as it can whatever this says.",
	"recording_scale": "Shrinks only what is written to disk. Tracking is unaffected, and the detail is gone for good.",
	"trunk_enabled": "Watches the patient's posture, so games can react to leaning.",
	"trunk_method": "How trunk rotation is worked out. Changing it clears the neutral posture.",
	"trunk_reference": "Model frame needs no capture, and works with the minisam3d methods only.",
	"tracker_solver": "Joint fits every visible tag corner. RANSAC drops the corners that disagree.",
	"tracker_refine": "How tag corners are sharpened after they are found.",
	"tracker_camera": "Which cameras the hand position is worked out from.",
	"corner_deadband_px": "Holds the last pose until a tag corner has moved this far.",
	"display": "Opens the tracker's own view on the board's screen. Restarts the tracker.",
	"debug": "Sessions are logged as patient vvv and are never uploaded.",
}
const TABS := [["Tracker", "tracker"], ["Camera", "camera"], ["Calibration", "calibration"], ["Storage", "storage"]]
const RAIL_WIDTH := 196
const PICKER_WIDTH := 272

const MENU := "res://Main_screen/Scenes/main.tscn"
const LinkProtocol := preload("res://Main_screen/Scripts/link_protocol.gd")
const RESTART_ACK_WAIT_S := 2.0
const LINK_STATUS_TEXT := {
	LinkProtocol.LinkStatus.IDLE: "Not started",
	LinkProtocol.LinkStatus.SCANNING: "Looking for the tracker...",
	LinkProtocol.LinkStatus.CONNECTING: "Waiting for the tracker...",
	LinkProtocol.LinkStatus.CONNECTED: "Connected",
}

var _tabs: TabContainer
var _nav: Array[Button] = []
var _camera: Control
var _calibration: Control
var _storage: Control
var _status: Label
var _link_dot: Panel
var _link_label: Label
var _link_over: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = Style.make_theme()
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS   # the icons, on a small screen

	var bg := ColorRect.new()
	bg.color = Style.GROUND
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var body := HBoxContainer.new()
	body.set_anchors_preset(Control.PRESET_FULL_RECT)
	body.add_theme_constant_override("separation", 0)
	add_child(body)
	body.add_child(_rail())

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 22)
	body.add_child(margin)

	_tabs = TabContainer.new()
	_tabs.tabs_visible = false   # the rail picks
	margin.add_child(_tabs)
	_tabs.add_child(_tracker_tab())
	_camera = CameraTab.new()
	_camera.name = "Camera"
	_tabs.add_child(_camera)
	_calibration = CalibrationTab.new()
	_calibration.name = "Calibration"
	_tabs.add_child(_calibration)
	_storage = StorageTab.new()
	_storage.name = "Storage"
	_tabs.add_child(_storage)
	_tabs.tab_changed.connect(func(_i: int): _on_tab_changed())
	_show_link()


func _back() -> void:
	get_tree().change_scene_to_file(MENU)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_back()


# The tab leaving goes first: Camera and Calibration both ask for the preview, and the
# one coming into view must have the last word.
func _on_tab_changed() -> void:
	for i in _nav.size():
		_nav[i].set_pressed_no_signal(i == _tabs.current_tab)
	var shown := _tabs.get_current_tab_control()
	for tab in [_camera, _calibration]:
		if tab != shown:
			tab.set_active(false)
	if shown == _camera or shown == _calibration:
		shown.set_active(true)
	if shown == _storage:
		_storage.refresh()


# ── The rail ──────────────────────────────────────────────────────────────────

func _rail() -> Control:
	var rail := PanelContainer.new()
	rail.theme_type_variation = "Rail"
	rail.custom_minimum_size.x = RAIL_WIDTH
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	rail.add_child(col)

	var back := Button.new()
	back.text = "Back"
	back.icon = Style.icon("back")
	back.theme_type_variation = "QuietButton"
	back.alignment = HORIZONTAL_ALIGNMENT_LEFT
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(_back)
	col.add_child(back)

	var title := MarginContainer.new()
	title.add_theme_constant_override("margin_left", 12)
	title.add_theme_constant_override("margin_top", 10)
	title.add_theme_constant_override("margin_bottom", 14)
	title.add_child(Style.label("Settings", "Title"))
	col.add_child(title)

	var group := ButtonGroup.new()
	for i in TABS.size():
		var item := Button.new()
		item.text = TABS[i][0]
		item.icon = Style.icon(TABS[i][1])
		item.theme_type_variation = "NavButton"
		item.alignment = HORIZONTAL_ALIGNMENT_LEFT
		item.toggle_mode = true
		item.button_group = group
		item.focus_mode = Control.FOCUS_NONE
		item.button_pressed = i == 0
		item.pressed.connect(func(): _tabs.current_tab = i)
		col.add_child(item)
		_nav.append(item)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(spacer)
	col.add_child(_link_box())
	return rail


# How the link stands, in view on every tab: all but the Tracker tab need it.
func _link_box() -> Control:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 4)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)
	margin.add_child(line)
	_link_dot = Style.dot()
	_link_dot.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var nudge := MarginContainer.new()   # level with the first line of the words
	nudge.add_theme_constant_override("margin_top", 5)
	nudge.add_child(_link_dot)
	line.add_child(nudge)
	var words := VBoxContainer.new()
	words.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	words.add_theme_constant_override("separation", 0)
	line.add_child(words)
	_link_label = Style.wrapped("", "Helper")
	_link_label.add_theme_color_override("font_color", Style.TEXT)
	words.add_child(_link_label)
	_link_over = Style.label("", "Helper")
	words.add_child(_link_over)
	return margin


# ── Tracker tab ───────────────────────────────────────────────────────────────

func _tracker_tab() -> Control:
	var tab := VBoxContainer.new()
	tab.name = "Tracker"
	tab.add_theme_constant_override("separation", 10)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tab.add_child(scroll)
	var clear_of_bar := MarginContainer.new()
	clear_of_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear_of_bar.add_theme_constant_override("margin_right", 14)
	scroll.add_child(clear_of_bar)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 20)
	clear_of_bar.add_child(col)
	var rows: VBoxContainer
	for f in FIELDS:
		if f.size() == 1:
			rows = _section(col, f[0])
		else:
			Style.add_row(rows, _row(f))

	_status = Style.wrapped("Changes save automatically to %s" % Settings.path, "Helper")
	tab.add_child(_status)
	return tab


# A title and its card; returns where the card's rows go.
func _section(parent: VBoxContainer, text: String) -> VBoxContainer:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", 8)
	parent.add_child(section)
	section.add_child(Style.label(text, "SectionTitle"))
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 0)
	section.add_child(Style.card(rows, false))
	return rows


func _row(f: Array) -> Control:
	var key: String = f[0]
	var row := MarginContainer.new()
	row.add_theme_constant_override("margin_left", 16)
	row.add_theme_constant_override("margin_right", 16)
	row.add_theme_constant_override("margin_top", 10)
	row.add_theme_constant_override("margin_bottom", 10)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 24)
	row.add_child(line)
	var words := VBoxContainer.new()
	words.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	words.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	words.add_theme_constant_override("separation", 1)
	line.add_child(words)
	words.add_child(Style.label(f[1]))
	if HELP.has(key):
		words.add_child(Style.wrapped(HELP[key], "Helper"))
	var control := _switch(key) if f[2] == "bool" else _picker(f)
	control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(control)
	return row


func _switch(key: String) -> Control:
	var box := CheckButton.new()
	box.focus_mode = Control.FOCUS_NONE
	box.button_pressed = bool(Settings.get_value(key, false))
	box.toggled.connect(func(on: bool): _changed(key, on))
	return box


func _picker(f: Array) -> Control:
	var key: String = f[0]
	var options: Array = f[3].duplicate()
	var names: Dictionary = f[4] if f.size() > 4 else {}
	var pick := OptionButton.new()
	pick.focus_mode = Control.FOCUS_NONE
	pick.custom_minimum_size.x = PICKER_WIDTH
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
	return pick


func _process(_delta: float) -> void:
	_show_link()


func _show_link() -> void:
	var status: int = GlobalScript.link_status
	_link_label.text = LINK_STATUS_TEXT.get(status, "?")
	_link_over.text = "over BLE" if Settings.get_value("stream_type", "ble") == "ble" else "over UDP"
	var colour := Style.MUTED
	if status == LinkProtocol.LinkStatus.CONNECTED:
		colour = Style.GOOD
	elif status != LinkProtocol.LinkStatus.IDLE:
		colour = Style.WARN
	Style.set_dot(_link_dot, colour)


func _changed(key: String, value: Variant) -> void:
	if key == "stream_type":
		Settings.set_value(key, value)
		if not Settings.save():
			_say_not_saved()
			return
		_switch_link(value)
		return
	if key == "trunk_enabled":
		TrunkMonitor.set_enabled(value)   # saves, and tells the tracker now
		_say("%s. Applied now." % _describe(key, value))
		return
	Settings.set_value(key, value)
	if not Settings.save():
		_say_not_saved()
		return
	if key == "debug":
		DeviceAgent.start_if_enabled()   # just off: the next login needs the patient lock
		_say("Debug on: games use the mouse, logged as vvv, nothing uploaded." if value \
			else "Debug off: games use the tracker.")
		return
	if LIVE_KEYS.has(key):
		var sent := ("on" if value else "off") if value is bool else _as_text(value)
		GlobalScript.send_tracker_config(LIVE_KEYS[key], sent)
		_say("%s. Sent to the tracker." % _describe(key, value))
		return
	# The tracker reads the rest only when it starts.
	var why := GlobalScript.restart_tracker()
	if why.is_empty():
		_say("%s. The tracker is restarting to apply it." % _describe(key, value))
	else:
		_say("%s. Saved, but the tracker did not restart: %s" % [_describe(key, value), why], Style.WARN)


func _say(text: String, colour: Color = Style.MUTED) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", colour)


func _say_not_saved() -> void:
	_say("Could not save the settings file: %s" % Settings.path, Style.DANGER)


# "Frame rate: 30 fps", in the words the row shows.
func _describe(key: String, value: Variant) -> String:
	for f in FIELDS:
		if f[0] != key:
			continue
		if value is bool:
			return "%s: %s" % [f[1], "on" if value else "off"]
		var names: Dictionary = f[4] if f.size() > 4 else {}
		return "%s: %s" % [f[1], names.get(_as_text(value), _as_text(value))]
	return "%s: %s" % [key, _as_text(value)]


# The tracker picks its transport once, at start, from its own board's settings.json.
# On the board that is this same file, so restart it, over the old link while that is
# still up, and then connect the new way. A tablet has its own file and cannot change
# what the board does.
func _switch_link(value: String) -> void:
	var name := value.to_upper()
	if not GlobalScript.on_the_board():
		GlobalScript.restart_link()
		_say("This app now connects over %s. The tracker must match: change it on the board's Settings too." % name)
		return
	var why := GlobalScript.restart_tracker()
	if why.is_empty() and GlobalScript.link.connected:
		var acked := {"done": false}
		var on_done := func(kind: int, _ok: bool, _detail: String):
			if kind == LinkProtocol.RESTART:
				acked["done"] = true
		GlobalScript.link_command_done.connect(on_done)
		var waited := 0.0
		while not acked["done"] and waited < RESTART_ACK_WAIT_S:
			await get_tree().process_frame
			waited += get_process_delta_time()
		GlobalScript.link_command_done.disconnect(on_done)
	GlobalScript.restart_link()
	if not is_inside_tree():
		return
	if not why.is_empty():
		_say("Saved, but the tracker did not restart: %s" % why, Style.WARN)
	elif value == "ble":
		# The BLE addon has no Linux ARM build, so the app on the board cannot follow.
		_say("This board now waits for a tablet over BLE. This app cannot connect until you switch back to UDP here.")
	else:
		_say("This app and the tracker now connect over %s." % name)


# 1.0 -> "1", 0.5 -> "0.5"; matches how the option lists are written.
static func _as_text(v: Variant) -> String:
	if v is float and is_equal_approx(v, round(v)):
		return str(int(v))
	return str(v)


# Keep numbers numeric in the file: the tracker int()/float()s them, but a string would be sloppy.
static func _typed(key: String, text: String) -> Variant:
	if key in ["stream_type", "tracker_solver", "tracker_refine", "tracker_camera", "trunk_method", "trunk_reference"]:
		return text
	return text.to_float() if "." in text else text.to_int()
