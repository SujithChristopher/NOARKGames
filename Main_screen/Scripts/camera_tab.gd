extends VBoxContainer
## Settings > Camera: the cameras' exposure and gain, changed while watching what
## they do. Only while the tab is shown does it keep the cameras on and ask the
## tracker for its CAMERA_STATUS and PREVIEW (docs/PROTOCOL.md; CONFIG preview=on).
##
## Over UDP both come on the link. Over BLE the numbers do, but a picture is several
## kB and BLE moves 244 bytes a message, so the board brings up its own hotspot, the
## status says which, and this joins it and takes pictures there (picture_link.gd),
## which is how Quick Share works: a slow link to find each other, Wi-Fi to move data.
## Its password is typed once per board and kept here, never sent over BLE. Without
## Wi-Fi the numbers still work, and they are what say if an exposure is good.
##
## Three things say whether a change worked, each proving something else: the
## exposure and gain the sensors report (they cap what they cannot do), the image
## level and blown-out share (the picture really changed), and the tags found
## (tracking still works, which is the point).
##
## The values go to the tracker as they change and to settings.json on letting go
## (camera_exposure_us, camera_gain), where the tracker reads them at every HELLO.
## Until they are set there, device.toml's apply. Calibration always uses device.toml.

const Style := preload("res://Main_screen/Scripts/settings_style.gd")
const LinkProtocol := preload("res://Main_screen/Scripts/link_protocol.gd")
const PictureLink := preload("res://Main_screen/Scripts/picture_link.gd")
const AndroidWifi := preload("res://Main_screen/Scripts/android_wifi.gd")

const ROWS := {
	"exposure": {"title": "Exposure", "setting": "camera_exposure_us", "min": 100.0,
		"max": 16000.0, "step": 100.0, "button": 500.0, "format": "%d µs"},
	"gain": {"title": "Gain", "setting": "camera_gain", "min": 1.0,
		"max": 16.0, "step": 0.25, "button": 0.5, "format": "×%.2f"},
}
const COLUMNS := [["exposure", "Exposure"], ["gain", "Gain"], ["level", "Image"],
	["blown", "Blown out"], ["tags", "Tags"]]

const PASSWORDS := "camera_wifi_passwords"   ## settings: hotspot name -> password
const WPA2_MIN_PASSWORD := 8
enum Join { NONE, JOINING, JOINED, REJECTED }
const HINT := "10000 µs avoids flicker under 50 Hz lights. Raise exposure before gain: gain adds noise, exposure adds blur."
const SEND_EVERY_S := 0.15   ## while a slider moves
const STALE_MS := 2000       ## the tracker sends a status every 0.5 s
const CAP_TOLERANCE := 0.02  ## the sensor rounds exposure to whole lines
# The calibration's own limits for a usable image (rigidbody_calib.py).
const LEVEL_DARK := 40.0
const LEVEL_BRIGHT := 200.0
const GOOD := Style.GOOD
const WARN := Style.WARN

var _active := false
var _hold: Node             # in the tree while the tab holds the cameras on
var _synced := false        # the sliders show what the tracker has in force
var _dirty := {}            # row -> not yet sent
var _send_wait := 0.0
var _last_status_ms := 0
var _capped := ""
var _refused := ""
var _wifi_note := ""
var _wifi_info := {}        # the status's wifi field while the hotspot is on
var _join := Join.NONE
## The Android plugin's Wi-Fi calls; null elsewhere, where the machine joins by itself.
var _wifi_plugin = null:
	set(plugin):
		_wifi_plugin = plugin
		if plugin != null:
			plugin.joined.connect(_on_wifi_joined)
			plugin.lost.connect(_on_wifi_lost)
			plugin.failed.connect(_on_wifi_failed)

var _picture_link: Node
var _password_row: HBoxContainer
var _password: LineEdit
var _state_dot: Panel
var _state: Label
var _fps: Label
var _controls: VBoxContainer
var _picture: TextureRect
var _no_picture: Label
var _sliders := {}
var _value_labels := {}
var _buttons: Array[Button] = []
var _cells := {}            # "<column><camera>" -> Label
var _message: Label


func _ready() -> void:
	add_theme_constant_override("separation", 10)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	add_child(top)
	_state_dot = Style.dot()
	top.add_child(_state_dot)
	_state = Style.wrapped("")
	_state.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_state)
	_fps = Style.label("", "Helper")
	top.add_child(_fps)

	_controls = VBoxContainer.new()
	_controls.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_controls.add_theme_constant_override("separation", 10)
	add_child(_controls)
	_picture = TextureRect.new()
	_picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_picture.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_picture.custom_minimum_size.y = 150
	Style.picture_well(_picture)
	_no_picture = Style.label("No picture yet", "Helper")
	_no_picture.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_no_picture.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_picture.add_child(_no_picture)
	_no_picture.set_anchors_preset(Control.PRESET_FULL_RECT)
	_controls.add_child(_picture)
	var sliders := VBoxContainer.new()
	sliders.add_theme_constant_override("separation", 6)
	for row in ROWS:
		sliders.add_child(_slider_row(row))
	_controls.add_child(Style.card(sliders))
	_controls.add_child(_readout())
	_controls.add_child(_password_box())
	_message = Style.wrapped("", "Helper")
	_controls.add_child(_message)
	_start_sync()
	_update_message()

	_picture_link = PictureLink.new()
	_picture_link.picture.connect(_on_preview)
	add_child(_picture_link)
	_wifi_plugin = AndroidWifi.find()
	GlobalScript.camera_status.connect(_on_status)
	GlobalScript.camera_preview.connect(_on_preview)
	GlobalScript.link_connected_changed.connect(_on_link_changed)
	GlobalScript.link_command_done.connect(_on_command_done)


func _exit_tree() -> void:
	if _active:
		set_active(false)


## The tab came into view, or left it. Nothing runs while it is out of view.
func set_active(on: bool) -> void:
	if on == _active:
		return
	_active = on
	if on:
		_start_sync()
		_hold = Node.new()
		add_child(_hold)
		GlobalScript.hold_tracking(_hold)   # let go when this node leaves
	else:
		_hold.queue_free()
		_hold = null
		_leave_wifi()
	GlobalScript.send_tracker_config("preview", "on" if on else "off")


func _process(delta: float) -> void:
	if not _active:
		return
	_send_wait -= delta
	if _send_wait <= 0.0:
		_send_changes()
	_update_state()


func _update_state() -> void:
	var text := "Waiting for the cameras..."
	var colour := Style.MUTED
	if not GlobalScript.link.connected:
		text = "Waiting for the tracker..."
	else:
		match GlobalScript.link.tracker_state:
			LinkProtocol.TrackerState.STARTING:
				text = "Cameras starting..."
			LinkProtocol.TrackerState.FAILED:
				text = "The cameras would not start; trying again..."
				colour = WARN
			LinkProtocol.TrackerState.TRACKING:
				var stale := Time.get_ticks_msec() - _last_status_ms > STALE_MS
				text = "No word from the tracker" if stale else "Live"
				colour = WARN if stale else GOOD
	_state.text = text
	Style.set_dot(_state_dot, colour)


# ── Sliders ───────────────────────────────────────────────────────────────────

func _slider_row(row: String) -> HBoxContainer:
	var spec: Dictionary = ROWS[row]
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	var title := Style.label(spec["title"])
	title.custom_minimum_size.x = 76
	box.add_child(title)
	box.add_child(_step_button("−", row, -spec["button"]))
	var slider := HSlider.new()
	slider.min_value = spec["min"]
	slider.max_value = spec["max"]
	slider.step = spec["step"]
	slider.focus_mode = Control.FOCUS_NONE
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.value_changed.connect(func(_v: float): _on_slider_moved(row))
	slider.drag_ended.connect(func(changed: bool):
		if changed:
			_commit(row))
	box.add_child(slider)
	_sliders[row] = slider
	box.add_child(_step_button("+", row, spec["button"]))
	var value := Style.label("", "Value")
	value.custom_minimum_size.x = 96
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(value)
	_value_labels[row] = value
	return box


func _step_button(text: String, row: String, amount: float) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(44, 38)
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(func():
		_sliders[row].value += amount
		_commit(row))
	_buttons.append(button)
	return button


func _set_editable(on: bool) -> void:
	for row in _sliders:
		_sliders[row].editable = on
	for button in _buttons:
		button.disabled = not on


func _show_value(row: String) -> void:
	_value_labels[row].text = ROWS[row]["format"] % _sliders[row].value


func _on_slider_moved(row: String) -> void:
	_show_value(row)
	_dirty[row] = true


func _send_changes() -> void:
	if _dirty.is_empty():
		return
	_refused = ""
	for row in _dirty:
		GlobalScript.send_tracker_config(row, _wire_value(row))
	_dirty.clear()
	_send_wait = SEND_EVERY_S
	_update_message()


func _wire_value(row: String) -> String:
	var value: float = _sliders[row].value
	return str(int(value)) if row == "exposure" else String.num(value, 2)


## Let go of a slider, or a step button: send what is left and keep it.
func _commit(row: String) -> void:
	_send_changes()
	Settings.set_value(ROWS[row]["setting"], _sliders[row].value)
	if not Settings.save():
		_refused = "Could not save settings!"
		_update_message()


# The tracker says what is in force in its first status; until then nothing can be
# changed, or a slider's starting position could overwrite a value it never showed.
func _start_sync() -> void:
	_synced = false
	_dirty.clear()
	_set_editable(false)
	_last_status_ms = Time.get_ticks_msec()   # no complaint until one is overdue
	for row in _value_labels:
		_value_labels[row].text = "-"


func _sync_sliders(ask: Array) -> void:
	for i in ask.size():
		var row: String = ["exposure", "gain"][i]
		_sliders[row].set_value_no_signal(ask[i])
		_show_value(row)
	_synced = true
	_set_editable(true)


# ── What the tracker says ─────────────────────────────────────────────────────

func _readout() -> Control:
	var grid := GridContainer.new()
	grid.columns = COLUMNS.size() + 1
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 2)
	grid.add_child(Control.new())
	for column in COLUMNS:
		grid.add_child(_cell(column[1], "TableHead"))
	for camera in 2:
		grid.add_child(_cell("Left picture" if camera == 0 else "Right picture", "TableHead"))
		for column in COLUMNS:
			var label := _cell("-", "Value")
			grid.add_child(label)
			_cells["%s%d" % [column[0], camera]] = label
	return Style.card(grid)


func _cell(text: String, variation: String) -> Label:
	var label := Style.label(text, variation)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _on_status(info: Dictionary) -> void:
	if not _active:
		return
	_last_status_ms = Time.get_ticks_msec()
	if not _synced:
		_sync_sliders(info.get("ask", []))
	for camera in 2:
		_show_camera(info, camera)
	_fps.text = "%.1f fps" % info.get("fps", 0.0)
	_capped = _capped_note(info)
	if info.has("wifi"):
		_on_wifi_status(info["wifi"])
	_update_message()


# ── The picture over the board's hotspot (BLE) ────────────────────────────────

func _password_box() -> HBoxContainer:
	_password_row = HBoxContainer.new()
	_password_row.add_theme_constant_override("separation", 10)
	_password_row.visible = false
	_password_row.add_child(Style.label("Hotspot password"))
	_password = LineEdit.new()
	_password.secret = true
	_password.custom_minimum_size.x = 260
	_password.text_submitted.connect(func(_text: String): _save_password())
	_password_row.add_child(_password)
	var join := Button.new()
	join.text = "Join"
	join.theme_type_variation = "PrimaryButton"
	join.focus_mode = Control.FOCUS_NONE
	join.pressed.connect(_save_password)
	_password_row.add_child(join)
	return _password_row


func _on_wifi_status(wifi: Dictionary) -> void:
	match wifi.get("state", ""):
		"on":
			_wifi_info = wifi
			if _join == Join.JOINING or _join == Join.JOINED:
				return
			if _join == Join.REJECTED:
				return   # waits for a new password, rather than trying this one for ever
			var known: String = Settings.get_value(PASSWORDS, {}).get(wifi["ssid"], "")
			if known.is_empty():
				_password_row.visible = true
				_wifi_note = "No picture yet: type the password of %s. It is asked once." % wifi["ssid"]
			else:
				_join_wifi(known)
		"failed":
			_leave_wifi()
			_wifi_note = "No picture, the numbers still work: %s" % wifi.get("reason", "the board's Wi-Fi did not start")
		_:
			_leave_wifi()
			_wifi_note = "Starting the board's Wi-Fi for the picture..."


func _join_wifi(password: String) -> void:
	_join = Join.JOINING
	_password_row.visible = false
	_wifi_note = "Joining %s: approve it on the tablet if it asks." % _wifi_info["ssid"]
	if _wifi_plugin != null:
		_wifi_plugin.join(_wifi_info["ssid"], password, _wifi_info.get("bssid", ""))
	else:
		_on_wifi_joined()   # off Android: the machine's own Wi-Fi settings did it


func _save_password() -> void:
	var text := _password.text.strip_edges()
	if _wifi_info.is_empty():
		return
	if text.length() < WPA2_MIN_PASSWORD:
		_wifi_note = "That is too short: the password has at least %d characters." % WPA2_MIN_PASSWORD
		_update_message()
		return
	var known: Dictionary = Settings.get_value(PASSWORDS, {}).duplicate()
	known[_wifi_info["ssid"]] = text
	Settings.set_value(PASSWORDS, known)
	if not Settings.save():
		_refused = "Could not save settings!"
	_password.text = ""
	_join_wifi(text)
	_update_message()


func _leave_wifi() -> void:
	_picture_link.stop()
	if _join != Join.NONE and _wifi_plugin != null:
		_wifi_plugin.leave()
	_join = Join.NONE
	_wifi_info = {}
	_wifi_note = ""
	_password_row.visible = false


func _on_wifi_joined() -> void:
	if not _active or _wifi_info.is_empty():
		return
	_join = Join.JOINED
	_wifi_note = ""
	_picture_link.start(_wifi_info["ip"], int(_wifi_info["port"]))
	_update_message()


func _on_wifi_lost() -> void:
	_picture_link.stop()
	_join = Join.NONE   # joined again at the next status that says it is on
	_wifi_note = "The picture's Wi-Fi dropped: joining again."
	_update_message()


func _on_wifi_failed(reason: String) -> void:
	_picture_link.stop()
	_join = Join.REJECTED
	_password_row.visible = true
	_wifi_note = "Could not join %s (%s). Check the password." % [_wifi_info.get("ssid", "the board's Wi-Fi"), reason]
	_update_message()


func _show_camera(info: Dictionary, camera: int) -> void:
	var exposure = _at(info, "exposure", camera)
	var gain = _at(info, "gain", camera)
	var level = _at(info, "level", camera)
	var blown = _at(info, "blown", camera)
	var tags = _at(info, "tags", camera)
	_cells["exposure%d" % camera].text = "?" if exposure == null else "%d µs" % exposure
	_cells["gain%d" % camera].text = "?" if gain == null else "×%.2f" % gain
	_cells["blown%d" % camera].text = "?" if blown == null else "%.1f %%" % blown
	_cells["tags%d" % camera].text = "?" if tags == null else str(int(tags))
	_cells["tags%d" % camera].add_theme_color_override("font_color", GOOD if tags else WARN)
	var level_cell: Label = _cells["level%d" % camera]
	if level == null:
		level_cell.text = "?"
	elif level < LEVEL_DARK:
		level_cell.text = "%d / 255 dark" % level
		level_cell.add_theme_color_override("font_color", WARN)
	elif level > LEVEL_BRIGHT:
		level_cell.text = "%d / 255 bright" % level
		level_cell.add_theme_color_override("font_color", WARN)
	else:
		level_cell.text = "%d / 255 ok" % level
		level_cell.add_theme_color_override("font_color", GOOD)


static func _at(info: Dictionary, key: String, camera: int) -> Variant:
	var values = info.get(key)
	return values[camera] if values is Array and camera < values.size() else null


# The sensor keeps exposure under the frame period, so a value edited into the
# file can be more than it takes. The status is the only place that shows.
static func _capped_note(info: Dictionary) -> String:
	var asked = _at(info, "ask", 0)
	var took = _at(info, "exposure", 0)
	if asked == null or took == null or absf(took - asked) <= CAP_TOLERANCE * asked:
		return ""
	return "Asked for %d µs; the sensor took %d µs." % [asked, took]


func _update_message() -> void:
	_message.add_theme_color_override("font_color",
		WARN if not (_refused.is_empty() and _capped.is_empty()) else Style.MUTED)
	if not _refused.is_empty():
		_message.text = _refused
	elif not _capped.is_empty():
		_message.text = _capped
	elif not _wifi_note.is_empty():
		_message.text = _wifi_note
	else:
		_message.text = HINT


func _on_preview(jpeg: PackedByteArray) -> void:
	if not _active:
		return
	var image := Image.new()
	if image.load_jpg_from_buffer(jpeg) != OK:
		push_warning("[Camera] Unreadable preview")
		return
	_picture.texture = ImageTexture.create_from_image(image)
	_no_picture.visible = false


func _on_link_changed(connected: bool) -> void:
	# A tracker forgets the preview at every HELLO, and re-reads settings.json.
	if connected and _active:
		_start_sync()
		_leave_wifi()   # it takes the hotspot down too; the status brings it back
		GlobalScript.send_tracker_config("preview", "on")


func _on_command_done(kind: int, ok: bool, detail: String) -> void:
	if _active and kind == LinkProtocol.CONFIG and not ok:
		_refused = detail
		_update_message()
