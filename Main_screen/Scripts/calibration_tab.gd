extends VBoxContainer
## Settings > Calibration: measure where the tags sit on the device, after one has been
## moved, swapped or added. A take while the device is turned, a solve on the board, a
## review, and only Save changes what the tracker uses; the one it replaced can be put
## back. All of it runs in the tracker (BODY, BODY_STATUS, docs/PROTOCOL.md; body_take.py).
##
## One tag stays fixed: the hand position is measured from it, so it keeps that position
## valid while everything else moves. The tracker says which, and where from it the hand
## position is; the Tracked point card changes both (BODY `tip`).
##
## While a take can start or is running it keeps the cameras on and, over UDP, shows them
## with the tags outlined. Over BLE the picture needs the hotspot the Camera tab joins, so
## here the list says what the cameras see.

const Style := preload("res://Main_screen/Scripts/settings_style.gd")
const LinkProtocol := preload("res://Main_screen/Scripts/link_protocol.gd")

# The calibration's own limits for a usable image (rigidbody_calib.py).
const LEVEL_DARK := 40
const LEVEL_BRIGHT := 200
const TAG_PX_SMALL := 45
const GOOD := Style.GOOD
const WARN := Style.WARN
const MUTED := Style.MUTED
const ROW_COLUMNS := 3
const ROWS_MAX_HEIGHT := 270   # about 9 tags; past that the list scrolls, and the picture keeps its room
const TIP_FIELD_WIDTH := 84
const TAG_ID_MAX := 586        # tag36h11; the tracker refuses past these as well (body_take.py)
const TIP_MAX_MM := 1000.0

var _active := false
var _hold: Node             # in the tree while this tab keeps the cameras on
var _info := {}             # the tracker's last BODY_STATUS
var _note := ""             # the answer to the last button

var _state: Label
var _picture: TextureRect
var _rows_card: Control
var _rows_scroll: ScrollContainer
var _rows: GridContainer
var _message: Label
var _actions: HBoxContainer
var _start: Button
var _finish: Button
var _cancel: Button
var _save: Button
var _restore: Button
var _tip_card: Control
var _tip_tag: LineEdit
var _tip_tag_pick: MenuButton
var _tip_fields: Array[LineEdit] = []   # x, y, z in mm
var _tip_apply: Button
var _tip_help: Label
var _tip_shown := PackedStringArray()   # what the tracker last said, as the fields would show it


func _ready() -> void:
	add_theme_constant_override("separation", 10)

	# Where things stand, what to do about it, and the buttons to do it with, together;
	# what the cameras see is the evidence below.
	var summary := VBoxContainer.new()
	summary.add_theme_constant_override("separation", 6)
	add_child(Style.card(summary))
	_state = Style.wrapped("", "Value")
	summary.add_child(_state)
	_message = Style.wrapped("", "Helper")
	_message.add_theme_color_override("font_color", MUTED)
	summary.add_child(_message)
	_actions = HBoxContainer.new()
	_actions.add_theme_constant_override("separation", 10)
	summary.add_child(_actions)
	_start = _button(_actions, "start", "PrimaryButton")
	_finish = _button(_actions, "finish", "PrimaryButton")
	_finish.text = "Finish now"
	_save = _button(_actions, "save", "PrimaryButton")
	_save.text = "Save and use"
	_cancel = _button(_actions, "cancel")
	_restore = _button(_actions, "restore")
	_restore.text = "Put the previous one back"

	_tip_card = _tip_section()
	add_child(_tip_card)

	_picture = TextureRect.new()
	_picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_picture.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_picture.custom_minimum_size.y = 150
	Style.picture_well(_picture)
	add_child(_picture)

	_rows_scroll = ScrollContainer.new()
	_rows_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_rows_card = Style.card(_rows_scroll)
	add_child(_rows_card)
	_rows = GridContainer.new()
	_rows.columns = ROW_COLUMNS
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("h_separation", 24)
	_rows.add_theme_constant_override("v_separation", 8)
	_rows_scroll.add_child(_rows)

	GlobalScript.body_status.connect(_on_status)
	GlobalScript.camera_preview.connect(_on_preview)
	GlobalScript.link_connected_changed.connect(_on_link_changed)
	GlobalScript.link_command_done.connect(_on_command_done)
	_show()


func _button(parent: Container, command: String, variation: String = "") -> Button:
	var button := Button.new()
	button.theme_type_variation = variation
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size.y = 40
	button.pressed.connect(func():
		_note = ""
		GlobalScript.send_body_command(command))
	parent.add_child(button)
	return button


# Which tag the hand position is measured from, and how far from it. Never rebuilt, since
# someone may be typing in it when a status arrives.
func _tip_section() -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	col.add_child(Style.label("Tracked point: where the hand holds the device"))
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 8)
	col.add_child(line)
	line.add_child(Style.label("From tag"))
	_tip_tag = _tip_field(line, LineEdit.KEYBOARD_TYPE_NUMBER)
	_tip_tag_pick = MenuButton.new()
	_tip_tag_pick.text = "Pick"
	_tip_tag_pick.flat = false
	_tip_tag_pick.focus_mode = Control.FOCUS_NONE
	_tip_tag_pick.about_to_popup.connect(_fill_tag_pick)
	_tip_tag_pick.get_popup().id_pressed.connect(func(id: int):
		_tip_tag.text = str(id)
		_update_tip_apply())
	line.add_child(_tip_tag_pick)
	for axis in ["X", "Y", "Z"]:
		var name_label := Style.label(axis)
		name_label.custom_minimum_size.x = 24
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		line.add_child(name_label)
		_tip_fields.append(_tip_field(line, LineEdit.KEYBOARD_TYPE_NUMBER_DECIMAL))
	line.add_child(Style.label("mm"))
	_tip_apply = Button.new()
	_tip_apply.text = "Apply"
	_tip_apply.theme_type_variation = "PrimaryButton"
	_tip_apply.focus_mode = Control.FOCUS_NONE
	_tip_apply.pressed.connect(_apply_tip)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(gap)
	line.add_child(_tip_apply)
	_tip_help = Style.wrapped("", "Helper")
	col.add_child(_tip_help)
	return Style.card(col)


func _tip_field(parent: Container, keyboard: int) -> LineEdit:
	var field := LineEdit.new()
	field.custom_minimum_size.x = TIP_FIELD_WIDTH
	field.virtual_keyboard_type = keyboard
	field.text_changed.connect(func(_text: String): _update_tip_apply())
	parent.add_child(field)
	return field


func _fill_tag_pick() -> void:
	var popup := _tip_tag_pick.get_popup()
	popup.clear()
	for id in _info.get("current", {}).get("tags", []):
		popup.add_item("Tag %d" % int(id), int(id))


func _tip_texts() -> PackedStringArray:
	var texts := PackedStringArray([_tip_tag.text.strip_edges()])
	for field in _tip_fields:
		texts.append(field.text.strip_edges())
	return texts


func _tip_valid() -> bool:
	var texts := _tip_texts()
	if not texts[0].is_valid_int() or not int(texts[0]) in range(0, TAG_ID_MAX + 1):
		return false
	for i in range(1, texts.size()):
		if not texts[i].is_valid_float() or absf(float(texts[i])) > TIP_MAX_MM:
			return false
	return true


func _update_tip_apply() -> void:
	_tip_apply.disabled = _tip_texts() == _tip_shown or not _tip_valid()


func _apply_tip() -> void:
	var texts := _tip_texts()
	_note = ""
	GlobalScript.send_body_command("tip %d %.6f %.6f %.6f" % [int(texts[0]),
		float(texts[1]) / 1000.0, float(texts[2]) / 1000.0, float(texts[3]) / 1000.0])


# The fields follow the tracker only when what it says changes, so a status cannot wipe
# out something half typed.
func _sync_tip() -> void:
	var tip = _info.get("tip_m")
	if tip == null:
		return
	var said := PackedStringArray([str(_anchor())])
	for value in tip:
		said.append(String.num(float(value) * 1000.0, 2))
	if said == _tip_shown:
		return
	_tip_shown = said
	_tip_tag.text = said[0]
	for i in _tip_fields.size():
		_tip_fields[i].text = said[i + 1]


func _show_tip(connected: bool) -> void:
	_tip_card.visible = connected and _info.has("tip_m") and _state_name() in ["idle", "failed"]
	var tags: Array = _info.get("current", {}).get("tags", [])
	_tip_tag_pick.disabled = tags.is_empty()
	_tip_help.text = "Measured in the tag's own frame: X right along its top edge, Y up along its left edge, Z out of the printed face (so usually negative)."
	if not tags.is_empty() and not float(_anchor()) in tags.map(func(id): return float(id)):
		_tip_help.text += " Tag %d is not in the measurement in use, so tracking keeps the old point until a take includes it." % _anchor()
	_update_tip_apply()


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
		_tip_shown = PackedStringArray()
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
	_sync_tip()
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
	elif detail == "tip set":
		_note = "Saved. The tracker is using the new tracked point."
	elif detail == "tip waits":
		_note = "Saved. The tracked point changes with the first take that includes this tag, and that tag then stays fixed."
	_show()


# ── What is on the screen ─────────────────────────────────────────────────────

func _show(connected: bool = GlobalScript.link.connected) -> void:
	for button in [_start, _finish, _cancel, _save, _restore]:
		button.visible = false
	for label in _rows.get_children():
		_rows.remove_child(label)
		label.queue_free()
	_start.text = "Start a take"
	_cancel.text = "Cancel"
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
				_start.text = "Try again"
				_start.visible = true
				_restore.visible = _info.get("current", {}).get("can_restore", false)
			_:
				_state.text = "Asking the tracker..."
	_message.text = text if _note.is_empty() else ("%s\n%s" % [_note, text]).strip_edges()
	_message.visible = not _message.text.is_empty()
	_actions.visible = [_start, _finish, _cancel, _save, _restore].any(func(b: Button): return b.visible)
	# As tall as its rows, so the picture takes the rest. A scroll has no height of its own.
	_rows_card.visible = _rows.get_child_count() > 0
	_show_tip(connected)
	_rows_scroll.custom_minimum_size.y = minf(_rows.get_combined_minimum_size().y, ROWS_MAX_HEIGHT)


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
		_start.text = "Try again"
		_start.visible = true
		for problem in result.get("problems", []):
			lines.append(_sentence(problem))
	_cancel.text = "Discard"
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
		var label := Style.label(cells[i], "Helper" if i == 2 else "")
		if i == 1:
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
