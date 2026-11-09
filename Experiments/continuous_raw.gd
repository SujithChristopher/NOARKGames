extends Control
## Experiment: continuous raw capture. The two camera feeds and the mocap trigger, nothing
## of the tracker's: while it records, the tracker detects no tags and solves no pose, it
## only saves every frame of both cameras at full size (pyscripts/experiment.py, a raw run).
##
## One screen, one Start | Stop button. Each Start is a recording of its own (its own folder);
## only Stop ends it (or the board's disk nearly full: the tracker stops it then). The trigger is shown
## throughout (sync_indicator.gd), so the mocap can be checked before Start, and so are both
## feeds, small: the Camera tab's preview (CONFIG preview=on, PREVIEW about 5 a second, both
## cameras side by side), which the tracker keeps sending while it records. Over UDP only:
## over BLE the picture needs the board's hotspot, which only Settings > Camera joins.

const Style := preload("res://Main_screen/Scripts/settings_style.gd")
const LinkProtocol := preload("res://Main_screen/Scripts/link_protocol.gd")
const SyncIndicatorScript := preload("res://Experiments/sync_indicator.gd")
const MENU := "res://Experiments/experiment_menu.tscn"
const NAME := "continuous_raw"

const ROOM_S := 60               # the disk must hold at least this much to start
const MB_PER_FRAME_PAIR := 2.0   # the board's two full-size images
const FPS_PLAN := 120            # the most the cameras give: the disk check asks for this much
const FPS_EVERY := 100           # about what "every frame" is, for the disk estimate
# As Settings > Recording's frame rate (settings_screen.gd): 0 is every frame.
const FPS_CHOICES := [15, 30, 60, 90, 0]
const NOTES_MAX := 100
const LABEL_MAX := 40

enum State { IDLE, STARTING, RECORDING, SAVING }

var _state: int = State.IDLE
var _label: LineEdit
var _notes: LineEdit
var _fps: OptionButton
var _toggle: Button
var _clock: Label
var _frames_label: Label
var _info: Label
var _error: Label
var _saved_label: Label
var _picture: TextureRect
var _no_picture: Label
var _camera_info: Label

var _ended_by := ""              # why the tracker ended it, if it did
var _fps_value := 0              # the recording's, as it started
var _elapsed := 0.0
var _frames := 0
var _seen_capturing := false     # the tracker has said it records this one


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = Style.make_theme()
	GlobalScript.hold_tracking(self)   # the cameras run only while something holds tracking
	GlobalScript.experiment_status.connect(_on_status)
	GlobalScript.link_command_done.connect(_on_command_done)
	GlobalScript.link_connected_changed.connect(_on_link_changed)
	GlobalScript.camera_preview.connect(_on_preview)
	GlobalScript.camera_status.connect(_on_camera_status)
	_build()
	add_child(SyncIndicatorScript.new())
	_preview(true)
	_show()


## The feeds' picture. A tracker forgets it at every HELLO, so it is asked again then.
func _preview(on: bool) -> void:
	if GlobalScript.link and GlobalScript.link.connected:
		GlobalScript.send_tracker_config("preview", "on" if on else "off")


func _on_preview(jpeg: PackedByteArray) -> void:
	var image := Image.new()
	if image.load_jpg_from_buffer(jpeg) != OK:
		push_warning("[Raw capture] Unreadable preview")
		return
	_picture.texture = ImageTexture.create_from_image(image)
	_no_picture.visible = false


func _on_camera_status(info: Dictionary) -> void:
	var level: Array = info.get("level", [])
	var blown: Array = info.get("blown", [])
	_camera_info.text = "Left cam0, right cam1   %.0f fps" % float(info.get("fps", 0.0))
	if level.size() == 2 and blown.size() == 2:
		_camera_info.text += "   image level %.0f / %.0f   blown out %.1f%% / %.1f%%" % [
			level[0], level[1], blown[0], blown[1]]


func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Style.GROUND
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	margin.add_child(col)

	var back := Button.new()
	back.text = "Back"
	back.icon = Style.icon("back")
	back.theme_type_variation = "QuietButton"
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	back.pressed.connect(_leave)
	col.add_child(back)
	col.add_child(Style.label("Continuous raw capture", "Title"))

	# What this recording is: one row, so the feeds below get the screen.
	var form := HBoxContainer.new()
	form.add_theme_constant_override("separation", 12)
	_label = LineEdit.new()
	_label.placeholder_text = "Name or number (required), e.g. trial_03"
	_label.max_length = LABEL_MAX
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label.text_changed.connect(func(_t): _show())
	form.add_child(_label)
	_notes = LineEdit.new()
	_notes.placeholder_text = "Notes, saved with it (optional)"
	_notes.max_length = NOTES_MAX
	_notes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form.add_child(_notes)
	form.add_child(Style.label("Frame rate"))
	_fps = OptionButton.new()
	for fps in FPS_CHOICES:
		_fps.add_item("Every frame" if fps == 0 else "%d fps" % fps)
	# The session recording's choice to begin with.
	var usual := FPS_CHOICES.find(int(Settings.get_value("recording_fps", 30)))
	_fps.select(usual if usual >= 0 else FPS_CHOICES.find(30))
	_fps.item_selected.connect(func(_i): _show())
	form.add_child(_fps)
	col.add_child(form)

	# The recording: one button that starts and stops it, what it has saved, and why not.
	var rec := HBoxContainer.new()
	rec.add_theme_constant_override("separation", 24)
	_toggle = Button.new()
	_toggle.custom_minimum_size = Vector2(200, 72)
	_toggle.add_theme_font_size_override("font_size", 28)
	_toggle.pressed.connect(_on_toggle)
	rec.add_child(_toggle)
	var readout := VBoxContainer.new()
	readout.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_clock = Style.label("")
	_clock.add_theme_font_size_override("font_size", 36)
	readout.add_child(_clock)
	_frames_label = Style.label("", "Helper")
	readout.add_child(_frames_label)
	rec.add_child(readout)
	var notes := VBoxContainer.new()
	notes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	notes.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_info = Style.wrapped("", "Helper")
	notes.add_child(_info)
	_error = Style.wrapped("")
	_error.add_theme_color_override("font_color", Style.DANGER)
	notes.add_child(_error)
	_saved_label = Style.wrapped("")
	notes.add_child(_saved_label)
	rec.add_child(notes)
	col.add_child(Style.card(rec))

	# Both feeds, as the tracker sends them: cam0 on the left, cam1 on the right.
	_picture = TextureRect.new()
	_picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_picture.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_picture.custom_minimum_size.y = 200
	Style.picture_well(_picture)
	_no_picture = Style.label("", "Helper")
	_no_picture.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_no_picture.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_no_picture.text = "No picture: over BLE it is shown only in Settings > Camera." \
		if Settings.get_value("stream_type", "ble") == "ble" else "No picture yet"
	_picture.add_child(_no_picture)
	_no_picture.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.add_child(_picture)
	_camera_info = Style.label("Left cam0, right cam1", "Helper")
	col.add_child(_camera_info)


func _show() -> void:
	var idle := _state == State.IDLE
	_label.editable = idle
	_notes.editable = idle
	_fps.disabled = not idle
	match _state:
		State.IDLE:
			_toggle.text = "Start"
			_toggle.theme_type_variation = "PrimaryButton"
			_toggle.disabled = _run_label() == ""
		State.STARTING:
			_toggle.text = "Starting..."
			_toggle.disabled = true
		State.RECORDING:
			_toggle.text = "Stop"
			_toggle.theme_type_variation = "DangerButton"
			_toggle.disabled = false
		State.SAVING:
			_toggle.text = "Saving..."
			_toggle.disabled = true
	var recording := _state == State.RECORDING
	_clock.text = _mmss(_elapsed if not idle else 0.0)
	_clock.add_theme_color_override("font_color", Style.DANGER if recording else Style.MUTED)
	_frames_label.text = ("● REC   %d frames saved" % _frames) if recording \
		else ("%d frames saved" % _frames if _state == State.SAVING else "Not recording")
	if idle:
		var rate := _rate(_chosen_fps())
		_info.text = "Both feeds at full size, no tracking: about %.0f GB a minute at %s. Records until Stop (only a nearly full disk stops it sooner). Saved on the board in %s/experiments/%s." \
			% [60.0 * rate * MB_PER_FRAME_PAIR / 1000.0, _fps_text(_chosen_fps()), Settings.APP_DIR, NAME]
		if _run_label() == "":
			_info.text += "\nType the experiment's name or number to start."
	else:
		_info.text = ("Recording at %s. Stop or Esc ends it." % _fps_text(_fps_value)) if recording else ""


func _chosen_fps() -> int:
	return FPS_CHOICES[_fps.selected]


## Frames a second for the disk: "every frame" is what the cameras give.
static func _rate(fps: int) -> float:
	return float(FPS_EVERY if fps == 0 else fps)


static func _fps_text(fps: int) -> String:
	return "every frame (about %d fps)" % FPS_EVERY if fps == 0 else "%d fps" % fps


static func _mmss(seconds: float) -> String:
	var s := int(seconds)
	return "%02d:%02d" % [s / 60, s % 60]


## As static_grid.gd: spaces become underscores, anything a folder name should not hold goes.
func _run_label() -> String:
	var out := ""
	for ch in _label.text.strip_edges().replace(" ", "_"):
		if ch.is_valid_ascii_identifier() or ch.is_valid_int() or ch == "-":
			out += ch
	return out


func _set_state(state: int) -> void:
	_state = state
	_show()


# ── Start | Stop ──────────────────────────────────────────────────────────────

func _on_toggle() -> void:
	if _state == State.IDLE:
		_start()
	elif _state == State.RECORDING:
		_stop()


func _start() -> void:
	_error.text = ""
	if not GlobalScript.link.connected:
		_error.text = "The tracker is not connected."
		return
	_fps_value = _chosen_fps()
	_ended_by = ""
	_elapsed = 0.0
	_frames = 0
	_seen_capturing = false
	_set_state(State.STARTING)
	# The disk check: room for a minute at least. It has no end, so no more can be asked.
	var frames := int(ROOM_S * (FPS_PLAN if _fps_value == 0 else _fps_value))
	GlobalScript.send_experiment_command("start %s %d %s raw %d" % [NAME, frames, _run_label(), _fps_value])


func _stop() -> void:
	_set_state(State.SAVING)
	GlobalScript.send_experiment_command("stop complete")


func _on_command_done(kind: int, ok: bool, detail: String) -> void:
	if kind != LinkProtocol.EXPERIMENT or detail == "sync":   # the indicator's watch
		return
	if _state == State.STARTING:
		if ok:
			_begin_recording()
		else:
			_error.text = "Could not start: %s" % detail
			_set_state(State.IDLE)
	elif not ok and _state == State.RECORDING:
		_error.text = "The tracker refused that: %s" % detail


## A BLE write holds about 240 bytes, so the description goes in pieces.
func _begin_recording() -> void:
	var meta := func(key: String, value: Variant) -> void:
		GlobalScript.send_experiment_command("meta %s %s" % [key, JSON.stringify(value)])
	meta.call("recording", {"kind": "continuous raw", "fps": _fps_value})
	meta.call("app", {"debug": Settings.is_debug(), "platform": OS.get_name(),
		"location": Settings.get_value("location", "")})
	meta.call("notes", _notes.text.strip_edges())
	GlobalScript.send_experiment_command("record")
	_saved_label.text = ""
	_set_state(State.RECORDING)


func _on_status(info: Dictionary) -> void:
	match _state:
		State.RECORDING:
			var capture = info.get("capture")
			if info.get("state") == "capturing" and capture is Dictionary:
				_seen_capturing = true
				_frames = int(capture.get("frames", 0))
				_elapsed = float(capture.get("elapsed_s", 0.0))
				_show()
			elif _seen_capturing and info.get("state") == "ready":
				# The tracker ended it (the disk nearly full): close the run, and say so.
				var last = info.get("last")
				if last is Dictionary:
					_frames = int(last.get("frames", _frames))
					_ended_by = str(last.get("reason", ""))
				_stop()
		State.SAVING:
			var saved = info.get("saved")
			if info.get("state") == "idle" and saved is Dictionary:
				var dropped: Array = saved.get("dropped", [])
				var note := "" if dropped.is_empty() or dropped.max() == 0.0 \
					else "\nImages dropped per camera: %s. The disk did not keep up." % str(dropped)
				if _ended_by == "disk_full":
					note += "\nThe board's disk is nearly full: it stopped by itself."
				_saved_label.text = "Saved %d frames (%s) in\n%s%s" % [
					_frames, _mmss(_elapsed), saved.get("path", ""), note]
				_set_state(State.IDLE)


func _on_link_changed(connected: bool) -> void:
	if connected:
		_preview(true)
	if connected or _state == State.IDLE:
		return
	_error.text = "The link to the tracker was lost. What was recorded is saved on the board."
	_set_state(State.IDLE)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	get_viewport().set_input_as_handled()
	if _state == State.RECORDING:
		_stop()
	elif _state == State.IDLE:
		_leave()


func _leave() -> void:
	get_tree().change_scene_to_file(MENU)


func _exit_tree() -> void:
	_preview(false)
	if _state in [State.STARTING, State.RECORDING] and GlobalScript.link.connected:
		GlobalScript.send_experiment_command("stop stopped")
