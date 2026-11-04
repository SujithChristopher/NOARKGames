extends VBoxContainer
## Settings > Calibration: measure where the tags sit on the device, after one has been
## moved, swapped or added. A take while the device is turned, a solve on the board, a
## review, and only Save changes what the tracker uses; the one it replaced can be put
## back. All of it runs in the tracker (BODY, BODY_STATUS, docs/PROTOCOL.md; body_take.py).
##
## One tag stays fixed: the hand position is measured from it, so it keeps that position
## valid while everything else moves. The tracker says which.
##
## While a take can start or is running it keeps the cameras on and, over UDP, shows them
## with the tags outlined. Over BLE the picture needs the hotspot the Camera tab joins, so
## here the list says what the cameras see.

const LinkProtocol := preload("res://Main_screen/Scripts/link_protocol.gd")

# The calibration's own limits for a usable image (rigidbody_calib.py).
const LEVEL_DARK := 40
const LEVEL_BRIGHT := 200
const TAG_PX_SMALL := 45
const GOOD := Color(0.45, 0.85, 0.5)
const WARN := Color(0.95, 0.75, 0.3)
const MUTED := Color(0.7, 0.72, 0.75)
const ROW_COLUMNS := 3

var _active := false
var _hold: Node             # in the tree while this tab keeps the cameras on
var _info := {}             # the tracker's last BODY_STATUS
var _note := ""             # the answer to the last button

var _state: Label
var _picture: TextureRect
var _rows: GridContainer
var _message: Label
var _start: Button
var _finish: Button
var _cancel: Button
var _save: Button
var _restore: Button


func _ready() -> void:
	add_theme_constant_override("separation", 8)
	_state = Label.new()
	_state.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_state)

	_picture = TextureRect.new()
	_picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_picture.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_picture.custom_minimum_size.y = 150
	add_child(_picture)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_rows = GridContainer.new()
	_rows.columns = ROW_COLUMNS
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("h_separation", 32)
	scroll.add_child(_rows)

	_message = Label.new()
	_message.add_theme_font_size_override("font_size", 16)
	_message.add_theme_color_override("font_color", MUTED)
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_message)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	add_child(actions)
	_start = _button(actions, "start")
	_finish = _button(actions, "finish")
	_finish.text = "  Finish now  "
	_cancel = _button(actions, "cancel")
	_save = _button(actions, "save")
	_save.text = "  Save and use  "
	_restore = _button(actions, "restore")
	_restore.text = "  Put the previous one back  "

	GlobalScript.body_status.connect(_on_status)
	GlobalScript.camera_preview.connect(_on_preview)
	GlobalScript.link_connected_changed.connect(_on_link_changed)
	GlobalScript.link_command_done.connect(_on_command_done)
	_show()


func _button(parent: Container, command: String) -> Button:
	var button := Button.new()
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size.y = 44
	button.pressed.connect(func():
		_note = ""
		GlobalScript.send_body_command(command))
	parent.add_child(button)
	return button


func _exit_tree() -> void:
	if _active:
		set_active(false)


## The tab came into view, or left it. Leaving ends a take, which needs someone holding
## the device; a solve goes on, and its answer is here when the tab opens again.
func set_active(on: bool) -> void:
	if on == _active:
		return
	_active = on
	if on:
		_info = {}
		_note = ""
		GlobalScript.send_body_command("status")
	elif _state_name() == "capturing":
		GlobalScript.send_body_command("cancel")
	_update_cameras()
	_show()


func _state_name() -> String:
	return _info.get("state", "")


func _sends_picture() -> bool:
	return Settings.get_value("stream_type", "ble") == "udp"


# A take needs the cameras and so does seeing what they see before one. A solve does not,
# and it is much of the board's work for two minutes, in the same box as the heat.
func _update_cameras() -> void:
	var want := _active and _state_name() in ["", "idle", "capturing", "failed"]
	if want == (_hold != null):
		return
	if want:
		_hold = Node.new()
		add_child(_hold)
		GlobalScript.hold_tracking(_hold)   # let go when this node leaves
	else:
		_hold.queue_free()
		_hold = null
	if _sends_picture():
		GlobalScript.send_tracker_config("preview", "on" if want else "off")


func _on_status(info: Dictionary) -> void:
	if not _active:
		return
	_info = info
	_update_cameras()
	_show()


func _on_preview(jpeg: PackedByteArray) -> void:
	if not _active:
		return
	var image := Image.new()
	if image.load_jpg_from_buffer(jpeg) != OK:
		push_warning("[Calibration] Unreadable preview")
		return
	_picture.texture = ImageTexture.create_from_image(image)
	_picture.visible = _hold != null


func _on_link_changed(connected: bool) -> void:
	if not _active:
		return
	if connected:
		# A tracker forgets the preview at every HELLO, and a take with it.
		GlobalScript.send_body_command("status")
		if _hold != null and _sends_picture():
			GlobalScript.send_tracker_config("preview", "on")
	_show(connected)


func _on_command_done(kind: int, ok: bool, detail: String) -> void:
	if not _active or kind != LinkProtocol.BODY:
		return
	if detail == "link lost":
		_note = ""   # the state line says so, and asks again on reconnect
	elif detail == "no answer":
		_note = "The tracker did not answer, so that may not have happened."
	elif not ok:
		_note = "The tracker refused that: %s" % detail
	elif detail == "saved":
		_note = "Saved. The tracker is using the new measurement."
	elif detail == "restored":
		_note = "The previous measurement is back in use."
	_show()


# ── What is on the screen ─────────────────────────────────────────────────────

func _show(connected: bool = GlobalScript.link.connected) -> void:
	for button in [_start, _finish, _cancel, _save, _restore]:
		button.visible = false
	for label in _rows.get_children():
		_rows.remove_child(label)
		label.queue_free()
	_start.text = "  Start a take  "
	_cancel.text = "  Cancel  "
	_state.remove_theme_color_override("font_color")
	_message.add_theme_color_override("font_color", MUTED)
	_picture.visible = _hold != null and _sends_picture() and _picture.texture != null

	var text := ""
	if not connected:
		_state.text = "Waiting for the tracker..."
	else:
		match _state_name():
			"idle":
				text = _show_idle()
			"capturing":
				text = _show_capture(_info.get("capture", {}))
			"solving":
				_state.text = "Working it out: %d s. Usually about 2 minutes. The device can be put down." % _info.get("elapsed", 0)
				_cancel.visible = true
			"review":
				text = _show_review(_info.get("result", {}))
			"failed":
				_state.text = "That take did not work."
				_state.add_theme_color_override("font_color", WARN)
				text = _info.get("reason", "")
				_start.text = "  Try again  "
				_start.visible = true
				_restore.visible = _info.get("current", {}).get("can_restore", false)
			_:
				_state.text = "Asking the tracker..."
	_message.text = text if _note.is_empty() else ("%s\n%s" % [_note, text]).strip_edges()


func _show_idle() -> String:
	var current: Dictionary = _info.get("current", {})
	var tags: Array = current.get("tags", [])
	if tags.is_empty():
		_state.text = "No measurement yet: tracking falls back to hand-measured offsets."
	else:
		_state.text = "In use: tags %s, measured %s" % [_ids(tags), current.get("created", "?").get_slice("T", 0)]
		var agreement = current.get("agreement_mm")
		if agreement != null:
			_state.text += ", agreeing within %.1f mm" % agreement
		_state.text += "."
	_start.visible = true
	_restore.visible = current.get("can_restore", false)
	var text := "Moved, swapped or added a tag? Take a new measurement. Tag %d must stay where it is: the hand position is measured from it. Everything else can change." % _anchor()
	if not _sends_picture():
		text += " Over BLE there is no picture here: the list says what the cameras see."
	return text


func _show_capture(capture: Dictionary) -> String:
	var left = capture.get("left")
	if left == null:
		_state.text = "Waiting for the cameras..."
	else:
		_state.text = "Turn the device slowly: %d s left" % ceili(left)
	_finish.visible = true
	_cancel.visible = true
	var tags: Array = capture.get("tags", [])
	var all_joined := not tags.is_empty()
	for tag in tags:
		var seen := int(tag["seen"])
		var joined: bool = tag["joined"]
		all_joined = all_joined and joined
		if joined:
			_row(_tag_name(tag["id"]), "joined", GOOD, "seen %d" % seen)
		elif seen > 0:
			_row(_tag_name(tag["id"]), "show it beside another tag", WARN, "seen %d" % seen)
		else:
			_row(_tag_name(tag["id"]), "not seen yet", WARN, "")
	var level = capture.get("level")
	var tag_px = capture.get("tag_px")
	if level != null and level < LEVEL_DARK:
		return "The image is too dark for a good take: add light, or raise exposure on the Camera tab."
	if level != null and level > LEVEL_BRIGHT:
		return "The image is very bright: check the tags are not glaring."
	if tag_px != null and tag_px < TAG_PX_SMALL:
		return "The tags are small in the picture: bring the device closer."
	if all_joined:
		return "All tags joined. Keep turning for more angles, or finish now."
	return "Show every tag beside a neighbour, from a range of angles."


func _show_review(result: Dictionary) -> String:
	var lines := PackedStringArray()
	if result.get("ok", false):
		_state.text = "New measurement: the tags agree within %.1f mm." % result.get("agreement_mm", [0.0])[0]
		_state.add_theme_color_override("font_color", GOOD)
		_save.visible = true
	else:
		_state.text = "This take cannot be used. Nothing has changed."
		_state.add_theme_color_override("font_color", WARN)
		_start.text = "  Try again  "
		_start.visible = true
		for problem in result.get("problems", []):
			lines.append(_sentence(problem))
	_cancel.text = "  Discard  "
	_cancel.visible = true
	for tag in result.get("tags", []):
		var seen := "seen %d" % tag["seen"]
		match tag["state"]:
			"same":
				_row(_tag_name(tag["id"]), "same place", GOOD, seen)
			"moved":
				_row(_tag_name(tag["id"]), "moved %d mm" % roundi(tag["moved_mm"]), WARN, seen)
			_:
				_row(_tag_name(tag["id"]), "new", GOOD, seen)
	var gone := "gone: will no longer be tracked" if result.get("ok", false) else "not found in this take"
	for id in result.get("gone", []):
		_row(_tag_name(id), gone, WARN, "")
	for id in result.get("dropped", []):
		_row(_tag_name(id), "left out: did not move with the device, or never beside another tag", MUTED, "")
	for warning in result.get("warnings", []):
		lines.append(warning)
	if not lines.is_empty():
		_message.add_theme_color_override("font_color", WARN)
	return "\n".join(lines)


func _row(tag: String, what: String, colour: Color, seen: String) -> void:
	var cells := [tag, what, seen]
	for i in cells.size():
		var label := Label.new()
		label.text = cells[i]
		label.add_theme_font_size_override("font_size", 18)
		if i == 1:
			label.add_theme_color_override("font_color", colour)
		_rows.add_child(label)


func _anchor() -> int:
	return int(_info.get("anchor", 1))


func _tag_name(id) -> String:
	return "Tag %d (fixed)" % int(id) if int(id) == _anchor() else "Tag %d" % int(id)


static func _ids(ids: Array) -> String:
	var names := PackedStringArray()
	for id in ids:
		names.append(str(int(id)))
	return ", ".join(names)


static func _sentence(text: String) -> String:
	return text.substr(0, 1).to_upper() + text.substr(1) + "."
