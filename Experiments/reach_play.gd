extends Control
## Experiment: Random Reach played as an experiment (reach_play_run.gd says what a run is).
## The setup screen: the run's name, the recording's frame rate and image size, the game's
## time. Start opens the run on the tracker, then the workspace scan runs, then Random Reach
## in 2D for that time, recorded from play to game over. The tracker runs at the cameras' full
## rate throughout; only what is saved follows the choice here (frames kept on sensor time, none
## made up). Back here after the game, it waits for the tracker to say the run is saved.
##
## It needs the tracker: in debug too the scan and the game take the hand, not the mouse.

const Style := preload("res://Main_screen/Scripts/settings_style.gd")
const LinkProtocol := preload("res://Main_screen/Scripts/link_protocol.gd")
const SyncIndicatorScript := preload("res://Experiments/sync_indicator.gd")
const Run := preload("res://Experiments/reach_play_run.gd")
const MENU := "res://Experiments/experiment_menu.tscn"

const MB_PER_FRAME_PAIR := 2.0   # the board's two full-size images
const FPS_PLAN := 120            # the most the cameras give: the disk check asks for this much
const FPS_EVERY := 100           # about what "every frame" is, for the estimate
# As continuous raw capture's (and Settings > Recording's): 0 is every frame.
const FPS_CHOICES := [15, 30, 60, 90, 0]
# The image size saved, of each side: the sensor's 1280 x 800, half, a quarter.
const SCALE_CHOICES := [1.0, 0.5, 0.25]
const SCALE_NAMES := ["Full", "Half", "Quarter"]
const SENSOR := Vector2i(1280, 800)
const MINUTES_MIN := 0.5
const MINUTES_MAX := 30.0
const NOTES_MAX := 100
const LABEL_MAX := 40

enum State { IDLE, STARTING, SAVING }

var _state: int = State.IDLE
var _label: LineEdit
var _notes: LineEdit
var _fps: OptionButton
var _scale: OptionButton
var _minutes: SpinBox
var _start: Button
var _info: Label
var _error: Label
var _saved_label: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = Style.make_theme()
	GlobalScript.hold_tracking(self)   # the cameras up before the scan, and the trigger's line
	GlobalScript.experiment_status.connect(_on_status)
	GlobalScript.link_command_done.connect(_on_command_done)
	GlobalScript.link_connected_changed.connect(_on_link_changed)
	_build()
	add_child(SyncIndicatorScript.new())
	Run.warm_game()   # ready by the scan's end, so the switch does not stall the link
	if Run.phase == Run.Phase.SAVING:
		if Run.result.has("error"):   # the tracker closed it already: nothing to wait for
			Run.phase = Run.Phase.NONE
			_error.text = Run.result["error"]
		else:
			_state = State.SAVING
			_saved_label.text = "Saving the run..."
	_show()


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
	col.add_child(Style.label("Random Reach", "Title"))
	col.add_child(Style.wrapped("Assess the workspace, then play Random Reach (2D) for the time set "
		+ "here. Only the game is recorded: both camera feeds at the rate and size chosen, a pose for "
		+ "every frame saved, and the mocap trigger. No patient: nothing goes to sessions or scores.", "Helper"))

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 10)
	_label = LineEdit.new()
	_label.placeholder_text = "Name or number (required), e.g. rr_01"
	_label.max_length = LABEL_MAX
	_label.text = Run.label
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label.text_changed.connect(func(_t): _show())
	_row(grid, "Experiment name", _label)
	_fps = OptionButton.new()
	for fps in FPS_CHOICES:
		_fps.add_item("Every frame" if fps == 0 else "%d fps" % fps)
	var at := FPS_CHOICES.find(Run.fps)
	_fps.select(at if at >= 0 else FPS_CHOICES.find(30))
	_fps.item_selected.connect(func(_i): _show())
	_row(grid, "Frame rate saved", _fps)
	_scale = OptionButton.new()
	for i in SCALE_CHOICES.size():
		_scale.add_item("%s  %d x %d" % [SCALE_NAMES[i], int(SENSOR.x * SCALE_CHOICES[i]),
			int(SENSOR.y * SCALE_CHOICES[i])])
	var size_at := SCALE_CHOICES.find(Run.scale)
	_scale.select(size_at if size_at >= 0 else 0)
	_scale.item_selected.connect(func(_i): _show())
	_row(grid, "Image size saved", _scale)
	_minutes = SpinBox.new()
	_minutes.min_value = MINUTES_MIN
	_minutes.max_value = MINUTES_MAX
	_minutes.step = 0.5
	_minutes.suffix = "min"
	_minutes.value = Run.seconds / 60.0
	_minutes.value_changed.connect(func(_v): _show())
	_row(grid, "Game time", _minutes)
	_notes = LineEdit.new()
	_notes.placeholder_text = "Notes, saved with it (optional)"
	_notes.max_length = NOTES_MAX
	_notes.text = Run.notes
	_notes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_row(grid, "Notes", _notes)
	col.add_child(Style.card(grid))

	var go := HBoxContainer.new()
	go.add_theme_constant_override("separation", 24)
	_start = Button.new()
	_start.custom_minimum_size = Vector2(260, 72)
	_start.add_theme_font_size_override("font_size", 26)
	_start.theme_type_variation = "PrimaryButton"
	_start.pressed.connect(_on_start)
	go.add_child(_start)
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_info = Style.wrapped("", "Helper")
	text.add_child(_info)
	_error = Style.wrapped("")
	_error.add_theme_color_override("font_color", Style.DANGER)
	text.add_child(_error)
	_saved_label = Style.wrapped("")
	text.add_child(_saved_label)
	go.add_child(text)
	col.add_child(Style.card(go))


func _row(grid: GridContainer, title: String, control: Control) -> void:
	grid.add_child(Style.label(title))
	grid.add_child(control)


func _show() -> void:
	var idle := _state == State.IDLE
	for c in [_label, _notes]:
		c.editable = idle
	_fps.disabled = not idle
	_scale.disabled = not idle
	_minutes.editable = idle
	match _state:
		State.IDLE:
			_start.text = "Start: scan, then play"
			_start.disabled = _run_label() == ""
		State.STARTING:
			_start.text = "Starting..."
			_start.disabled = true
		State.SAVING:
			_start.text = "Saving..."
			_start.disabled = true
	if idle:
		var fps := _chosen_fps()
		var gb := _seconds() * _rate(fps) * MB_PER_FRAME_PAIR * pow(_chosen_scale(), 2) / 1000.0
		_info.text = "Saves %s at %s: about %.1f GB for the game. The tracker itself runs at the cameras' full rate. Saved on the board in %s/experiments/%s." \
			% [_fps_text(fps), _scale.get_item_text(_scale.selected).strip_edges(), gb, Settings.APP_DIR, Run.NAME]
		if _run_label() == "":
			_info.text += "\nType the experiment's name or number to start."
	else:
		_info.text = ""


func _chosen_fps() -> int:
	return FPS_CHOICES[_fps.selected]


func _chosen_scale() -> float:
	return SCALE_CHOICES[_scale.selected]


func _seconds() -> int:
	return int(round(_minutes.value * 60.0))


static func _rate(fps: int) -> float:
	return float(FPS_EVERY if fps == 0 else fps)


static func _fps_text(fps: int) -> String:
	return "every frame (about %d fps)" % FPS_EVERY if fps == 0 else "%d fps" % fps


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


# ── Start ─────────────────────────────────────────────────────────────────────

func _on_start() -> void:
	if _state != State.IDLE:
		return
	_error.text = ""
	_saved_label.text = ""
	if not GlobalScript.link.connected:
		_error.text = "The tracker is not connected."
		return
	Run.label = _run_label()
	Run.notes = _notes.text.strip_edges()
	Run.fps = _chosen_fps()
	Run.scale = _chosen_scale()
	Run.seconds = _seconds()
	Run.result = {}
	_set_state(State.STARTING)
	# The disk check: the whole game at the rate asked, "every frame" at the most the cameras give.
	var frames := int(Run.seconds * (FPS_PLAN if Run.fps == 0 else Run.fps))
	GlobalScript.send_experiment_command("start %s %d %s play %d %.2f" % [
		Run.NAME, frames, Run.label, Run.fps, Run.scale])


func _on_command_done(kind: int, ok: bool, detail: String) -> void:
	if kind != LinkProtocol.EXPERIMENT or detail == "sync" or _state != State.STARTING:
		return
	if not ok:
		_error.text = "Could not start: %s" % detail
		_set_state(State.IDLE)
		return
	Run.tracker_path = detail
	Run.boundary = []
	# A BLE write holds about 240 bytes, so the description goes in pieces.
	var meta := func(key: String, value: Variant) -> void:
		GlobalScript.send_experiment_command("meta %s %s" % [key, JSON.stringify(value)])
	meta.call("table_frame", GlobalScript.table_frame())
	meta.call("game", {"name": "RandomReach", "mode": "2D", "seconds": Run.seconds,
		"files": ["reach_boundary.json", "random_reach.csv"]})
	meta.call("recording", {"kind": "game", "fps": Run.fps, "scale": Run.scale})
	meta.call("app", {"debug": Settings.is_debug(), "platform": OS.get_name(),
		"location": Settings.get_value("location", ""), "files_on": "the app's own experiments folder"})
	meta.call("notes", Run.notes)
	Run.phase = Run.Phase.SCAN
	get_tree().change_scene_to_file(Run.SCAN)


func _on_status(info: Dictionary) -> void:
	if _state != State.SAVING:
		return
	var saved = info.get("saved")
	if info.get("state") != "idle" or not saved is Dictionary:
		return
	Run.phase = Run.Phase.NONE
	var r := Run.result
	var dropped: Array = saved.get("dropped", [])
	var note := "" if dropped.is_empty() or dropped.max() == 0.0 \
		else "\nImages dropped per camera: %s. The disk did not keep up." % str(dropped)
	if not r.get("recorded", false):
		_saved_label.text = "Stopped before the game: nothing recorded.\n%s" % saved.get("path", "")
	else:
		var how := "Game over" if r.get("why") == "complete" else "Left before the time was up"
		if r.get("reason", "") == "disk_full":
			how = "The board's disk is nearly full: it stopped by itself"
		_saved_label.text = "%s. Score %d, %d frames saved in\n%s%s" % [
			how, int(r.get("score", 0)), int(r.get("frames", 0)), saved.get("path", ""), note]
	_set_state(State.IDLE)


func _on_link_changed(connected: bool) -> void:
	if connected or _state == State.IDLE:
		return
	Run.phase = Run.Phase.NONE
	_error.text = "The link to the tracker was lost. What was recorded is saved on the board."
	_set_state(State.IDLE)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and _state == State.IDLE:
		get_viewport().set_input_as_handled()
		_leave()


func _leave() -> void:
	get_tree().change_scene_to_file(MENU)


func _exit_tree() -> void:
	# Started, then the screen left some other way than to the scan: close the run.
	if _state == State.STARTING and Run.phase == Run.Phase.NONE and GlobalScript.link.connected:
		GlobalScript.send_experiment_command("stop stopped")
