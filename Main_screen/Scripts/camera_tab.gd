extends VBoxContainer
## Settings > Camera: the cameras' exposure and gain, changed while watching what
## they do. Only while the tab is shown does it keep the cameras on and ask the
## tracker for its CAMERA_STATUS and PREVIEW (docs/PROTOCOL.md; CONFIG preview=on).
## UDP only for now: a preview is several kB per picture, BLE 244 bytes a message.
##
## Three things say whether a change worked, each proving something else: the
## exposure and gain the sensors report (they cap what they cannot do), the image
## level and blown-out share (the picture really changed), and the tags found
## (tracking still works, which is the point).
##
## The values go to the tracker as they change and to settings.json on letting go
## (camera_exposure_us, camera_gain), where the tracker reads them at every HELLO.
## Until they are set there, device.toml's apply. Calibration always uses device.toml.

const LinkProtocol := preload("res://Main_screen/Scripts/link_protocol.gd")

const ROWS := {
	"exposure": {"title": "Exposure", "setting": "camera_exposure_us", "min": 100.0,
		"max": 16000.0, "step": 100.0, "button": 500.0, "format": "%d µs"},
	"gain": {"title": "Gain", "setting": "camera_gain", "min": 1.0,
		"max": 16.0, "step": 0.25, "button": 0.5, "format": "×%.2f"},
}
const COLUMNS := [["exposure", "Exposure"], ["gain", "Gain"], ["level", "Image"],
	["blown", "Blown out"], ["tags", "Tags"]]

const NEEDS_UDP := "Camera settings work over UDP only. This app is set to BLE: change the link on the Tracker tab."
const HINT := "10000 µs avoids flicker under 50 Hz lights. Raise exposure before gain: gain adds noise, exposure adds blur."
const SEND_EVERY_S := 0.15   ## while a slider moves
const STALE_MS := 2000       ## the tracker sends a status every 0.5 s
const CAP_TOLERANCE := 0.02  ## the sensor rounds exposure to whole lines
# The calibration's own limits for a usable image (rigidbody_calib.py).
const LEVEL_DARK := 40.0
const LEVEL_BRIGHT := 200.0
const GOOD := Color(0.45, 0.85, 0.5)
const WARN := Color(0.95, 0.75, 0.3)
const MUTED := Color(0.7, 0.72, 0.75)
const TRACK := Color(0.32, 0.34, 0.38)

var _active := false
var _hold: Node             # in the tree while the tab holds the cameras on
var _synced := false        # the sliders show what the tracker has in force
var _dirty := {}            # row -> not yet sent
var _send_wait := 0.0
var _last_status_ms := 0
var _capped := ""
var _refused := ""

var _state: Label
var _fps: Label
var _controls: VBoxContainer
var _picture: TextureRect
var _sliders := {}
var _value_labels := {}
var _buttons: Array[Button] = []
var _cells := {}            # "<column><camera>" -> Label
var _message: Label


func _ready() -> void:
	add_theme_constant_override("separation", 8)
	var top := HBoxContainer.new()
	add_child(top)
	_state = Label.new()
	_state.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_state.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	top.add_child(_state)
	_fps = Label.new()
	_fps.add_theme_color_override("font_color", MUTED)
	top.add_child(_fps)

	_controls = VBoxContainer.new()
	_controls.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_controls.add_theme_constant_override("separation", 6)
	add_child(_controls)
	_picture = TextureRect.new()
	_picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_picture.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_picture.custom_minimum_size.y = 150
	_controls.add_child(_picture)
	for row in ROWS:
		_controls.add_child(_slider_row(row))
	_controls.add_child(_readout())
	_message = Label.new()
	_message.add_theme_font_size_override("font_size", 16)
	_message.add_theme_color_override("font_color", MUTED)
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_controls.add_child(_message)
	_start_sync()
	_update_message()

	GlobalScript.camera_status.connect(_on_status)
	GlobalScript.camera_preview.connect(_on_preview)
	GlobalScript.link_connected_changed.connect(_on_link_changed)
	GlobalScript.link_command_done.connect(_on_command_done)


func _exit_tree() -> void:
	if _active:
		set_active(false)


## The tab came into view, or left it. Nothing runs while it is out of view.
func set_active(on: bool) -> void:
	var udp: bool = Settings.get_value("stream_type", "ble") == "udp"
	_controls.visible = udp
	if not udp:
		_state.text = NEEDS_UDP
		_fps.text = ""
	if on == _active or (on and not udp):
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
	if not GlobalScript.link.connected:
		text = "Waiting for the tracker..."
	else:
		match GlobalScript.link.tracker_state:
			LinkProtocol.TrackerState.STARTING:
				text = "Cameras starting..."
			LinkProtocol.TrackerState.FAILED:
				text = "The cameras would not start; trying again..."
			LinkProtocol.TrackerState.TRACKING:
				var stale := Time.get_ticks_msec() - _last_status_ms > STALE_MS
				text = "No word from the tracker" if stale else "Live"
	_state.text = text


# ── Sliders ───────────────────────────────────────────────────────────────────

func _slider_row(row: String) -> HBoxContainer:
	var spec: Dictionary = ROWS[row]
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var title := Label.new()
	title.text = spec["title"]
	title.custom_minimum_size.x = 110
	box.add_child(title)
	box.add_child(_step_button("-", row, -spec["button"]))
	var slider := HSlider.new()
	slider.min_value = spec["min"]
	slider.max_value = spec["max"]
	slider.step = spec["step"]
	slider.focus_mode = Control.FOCUS_NONE
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# The default track vanishes on this background: how far it goes would not show.
	var track := StyleBoxFlat.new()
	track.bg_color = TRACK
	track.set_corner_radius_all(3)
	track.content_margin_top = 3
	track.content_margin_bottom = 3
	slider.add_theme_stylebox_override("slider", track)
	slider.value_changed.connect(func(_v: float): _on_slider_moved(row))
	slider.drag_ended.connect(func(changed: bool):
		if changed:
			_commit(row))
	box.add_child(slider)
	_sliders[row] = slider
	box.add_child(_step_button("+", row, spec["button"]))
	var value := Label.new()
	value.custom_minimum_size.x = 120
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(value)
	_value_labels[row] = value
	return box


func _step_button(text: String, row: String, amount: float) -> Button:
	var button := Button.new()
	button.text = "  %s  " % text
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

func _readout() -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = COLUMNS.size() + 1
	grid.add_theme_constant_override("h_separation", 32)
	grid.add_child(Control.new())
	for column in COLUMNS:
		grid.add_child(_cell(column[1], MUTED))
	for camera in 2:
		grid.add_child(_cell("Left picture" if camera == 0 else "Right picture", MUTED))
		for column in COLUMNS:
			var label := _cell("-", Color.WHITE)
			grid.add_child(label)
			_cells["%s%d" % [column[0], camera]] = label
	return grid


func _cell(text: String, colour: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", colour)
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
	if not _refused.is_empty():
		_message.text = _refused
	elif not _capped.is_empty():
		_message.text = _capped
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


func _on_link_changed(connected: bool) -> void:
	# A tracker forgets the preview at every HELLO, and re-reads settings.json.
	if connected and _active:
		_start_sync()
		GlobalScript.send_tracker_config("preview", "on")


func _on_command_done(kind: int, ok: bool, detail: String) -> void:
	if _active and kind == LinkProtocol.CONFIG and not ok:
		_refused = detail
		_update_message()
