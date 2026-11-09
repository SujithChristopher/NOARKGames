extends Control
## Experiment: a continuous raw capture. From Start until Stop (or the time limit) the
## tracker saves every camera frame, both images at full size and the pose when there is
## one, with the mocap trigger's edges (pyscripts/experiment.py, `record`). Nothing is
## asked of the device: move it however the trial needs.
##
## The table is optional. With one defined, poses.csv also gets the table columns and the
## device is drawn on it; without, only the camera frame.
##
## It needs the tracker: in debug the mouse has no images and no pose to save.

const Style := preload("res://Main_screen/Scripts/settings_style.gd")
const TableSpace := preload("res://Games/firefly_reach/table_space.gd")
const TableOverlay := preload("res://Main_screen/Scripts/table_overlay.gd")
const LinkProtocol := preload("res://Main_screen/Scripts/link_protocol.gd")
const SyncIndicatorScript := preload("res://Experiments/sync_indicator.gd")
const MENU := "res://Experiments/experiment_menu.tscn"
const NAME := "continuous_raw"

const LIMIT_MIN_S := 5
const LIMIT_MAX_S := 1800
const LIMIT_DEFAULT_S := 120
const MB_PER_FRAME_PAIR := 2.0   # the board's two full-size images
const FPS_PLAN := 120            # the most the cameras give: the disk check asks for this much
const FRESH_MS := 300
const NOTES_MAX := 100
const LABEL_MAX := 40

enum View { SETUP, RUN, DONE }

var _view: int = View.SETUP
var _limit: SpinBox
var _label: LineEdit
var _notes: LineEdit
var _setup: Control
var _setup_info: Label
var _setup_error: Label
var _start_button: Button
var _run_panel: Control
var _clock: Label
var _frames: Label
var _hint: Label
var _done_panel: Control
var _done_text: Label

var _space: TableSpace
var _corners_mm: Array = []
var _limit_s := 0.0
var _waiting_start := false
var _recording := false          # the tracker has said it is capturing
var _elapsed := 0.0
var _ok := 0
var _failed := 0
var _saved_shown := false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = Style.make_theme()
	GlobalScript.hold_tracking(self)
	GlobalScript.experiment_status.connect(_on_status)
	GlobalScript.link_command_done.connect(_on_command_done)
	GlobalScript.link_connected_changed.connect(_on_link_changed)
	_build_setup()
	_build_run()
	add_child(SyncIndicatorScript.new())
	_show_view(View.SETUP)


func _build_setup() -> void:
	_setup = MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		_setup.add_theme_constant_override("margin_" + side, 24)
	add_child(_setup)
	_setup.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	_setup.add_child(col)

	var back := Button.new()
	back.text = "Back"
	back.icon = Style.icon("back")
	back.theme_type_variation = "QuietButton"
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	back.pressed.connect(_leave)
	col.add_child(back)
	col.add_child(Style.label("Continuous raw capture", "Title"))

	_label = LineEdit.new()
	_label.placeholder_text = "Experiment name or number (required), e.g. trial_03"
	_label.max_length = LABEL_MAX
	_label.text_changed.connect(func(_t): _refresh_setup())
	col.add_child(_label)

	var form := GridContainer.new()
	form.columns = 2
	form.add_theme_constant_override("h_separation", 16)
	var name_label := Style.label("Stops by itself after (s)")
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form.add_child(name_label)
	_limit = SpinBox.new()
	_limit.min_value = LIMIT_MIN_S
	_limit.max_value = LIMIT_MAX_S
	_limit.step = 5
	_limit.value = LIMIT_DEFAULT_S
	_limit.value_changed.connect(func(_v): _refresh_setup())
	form.add_child(_limit)
	col.add_child(Style.card(form))

	_notes = LineEdit.new()
	_notes.placeholder_text = "Notes for this run, saved with it (optional)"
	_notes.max_length = NOTES_MAX
	col.add_child(_notes)
	_setup_info = Style.wrapped("", "Helper")
	col.add_child(_setup_info)
	_setup_error = Style.wrapped("")
	_setup_error.add_theme_color_override("font_color", Style.DANGER)
	col.add_child(_setup_error)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 12)
	_start_button = Button.new()
	_start_button.text = "Start recording"
	_start_button.theme_type_variation = "PrimaryButton"
	_start_button.pressed.connect(_start)
	buttons.add_child(_start_button)
	var define := Button.new()
	define.text = "Define table"
	define.pressed.connect(func():
		TableOverlay.open(self).table_done.connect(_refresh_setup))
	buttons.add_child(define)
	col.add_child(buttons)


func _build_run() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.add_child(Style.label("Recording", "Helper"))
	_clock = Style.label("")
	_clock.add_theme_font_size_override("font_size", 44)
	box.add_child(_clock)
	_frames = Style.label("")
	box.add_child(_frames)
	_hint = Style.wrapped("", "Helper")
	_hint.custom_minimum_size.x = 360
	box.add_child(_hint)
	var stop := Button.new()
	stop.text = "Stop"
	stop.theme_type_variation = "PrimaryButton"
	stop.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	stop.pressed.connect(func(): _finish("Saving..."))
	box.add_child(stop)
	_run_panel = Style.card(box)
	_run_panel.position = Vector2(16, 16)
	add_child(_run_panel)

	var done := VBoxContainer.new()
	done.add_theme_constant_override("separation", 12)
	_done_text = Style.wrapped("")
	_done_text.custom_minimum_size.x = 720
	done.add_child(_done_text)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 12)
	var again := Button.new()
	again.text = "New run"
	again.theme_type_variation = "PrimaryButton"
	again.pressed.connect(func(): _show_view(View.SETUP))
	buttons.add_child(again)
	var out := Button.new()
	out.text = "Back to experiments"
	out.pressed.connect(_leave)
	buttons.add_child(out)
	done.add_child(buttons)
	_done_panel = Style.card(done)
	_done_panel.position = Vector2(200, 240)
	add_child(_done_panel)


func _show_view(view: int) -> void:
	_view = view
	_setup.visible = view == View.SETUP
	_run_panel.visible = view == View.RUN
	_done_panel.visible = view == View.DONE
	if view == View.SETUP:
		_refresh_setup()
	queue_redraw()


# ── Setup ─────────────────────────────────────────────────────────────────────

func _refresh_setup() -> void:
	_corners_mm = GlobalScript.table_corners().map(func(c): return c * 1000.0) \
		if GlobalScript.table_set else []
	var gb: float = _limit.value * 100.0 * MB_PER_FRAME_PAIR / 1000.0
	_setup_info.text = "Every frame, both cameras at full size: about %.0f GB a minute at 100 fps, " \
		% (60.0 * 100.0 * MB_PER_FRAME_PAIR / 1000.0) \
		+ "up to %.0f GB for this limit, saved on the board in %s/experiments.\n" % [gb, Settings.APP_DIR] \
		+ ("The table is defined: poses also get table columns." if not _corners_mm.is_empty()
			else "No table with its corners: poses are in the camera frame only (that is fine).")
	if _run_label() == "":
		_setup_info.text += "\nType the experiment's name or number to start."
	_start_button.disabled = _run_label() == "" or _waiting_start


## As static_grid.gd: spaces become underscores, anything a folder name should not hold goes.
func _run_label() -> String:
	var out := ""
	for ch in _label.text.strip_edges().replace(" ", "_"):
		if ch.is_valid_ascii_identifier() or ch.is_valid_int() or ch == "-":
			out += ch
	return out


func _start() -> void:
	_setup_error.text = ""
	if not GlobalScript.link.connected:
		_setup_error.text = "The tracker is not connected."
		return
	_limit_s = _limit.value
	_waiting_start = true
	_start_button.disabled = true
	GlobalScript.send_experiment_command("start %s %d %s" % [NAME, int(_limit_s * FPS_PLAN), _run_label()])


func _on_command_done(kind: int, ok: bool, detail: String) -> void:
	if kind != LinkProtocol.EXPERIMENT or detail == "sync":
		return
	if _waiting_start:
		_waiting_start = false
		if ok:
			_begin_run()
		else:
			_setup_error.text = "Could not start: %s" % detail
			_refresh_setup()
	elif not ok and _view == View.RUN:
		_hint.text = "The tracker refused that: %s" % detail


## A BLE write holds about 240 bytes, so the run's description goes in pieces.
func _begin_run() -> void:
	var meta := func(key: String, value: Variant) -> void:
		GlobalScript.send_experiment_command("meta %s %s" % [key, JSON.stringify(value)])
	if not _corners_mm.is_empty():
		meta.call("table_frame", GlobalScript.table_frame())
		meta.call("table_corners_mm", _corners_mm.map(func(c): return [snappedf(c.x, 0.01), snappedf(c.y, 0.01)]))
	meta.call("recording", {"kind": "continuous", "limit_s": _limit_s})
	meta.call("app", {"debug": Settings.is_debug(), "platform": OS.get_name(),
		"location": Settings.get_value("location", "")})
	meta.call("notes", _notes.text.strip_edges())
	GlobalScript.send_experiment_command("record %d" % int(_limit_s))

	_space = TableSpace.new(get_viewport_rect().size)
	_recording = false
	_elapsed = 0.0
	_ok = 0
	_failed = 0
	_saved_shown = false
	_show_view(View.RUN)


# ── The run ───────────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if _view != View.RUN:
		return
	queue_redraw()
	_clock.text = "%s / %s" % [_mmss(_elapsed), _mmss(_limit_s)]
	_frames.text = "%d frames saved, %d without a pose" % [_ok + _failed, _failed]
	if not _recording:
		_hint.text = "Starting..."
	elif Time.get_ticks_msec() - GlobalScript.last_packet_ms > FRESH_MS or GlobalScript.last_packet_ms == 0:
		_hint.text = "The device is out of view: the images are still saved.   Esc stops."
	else:
		_hint.text = "Esc or Stop ends the recording."


static func _mmss(seconds: float) -> String:
	var s := int(seconds)
	return "%02d:%02d" % [s / 60, s % 60]


func _on_status(info: Dictionary) -> void:
	var saved = info.get("saved")
	if _view == View.DONE and saved is Dictionary and not _saved_shown:
		_saved_shown = true
		var dropped: Array = saved.get("dropped", [])
		var note := "" if dropped.is_empty() or dropped.max() == 0.0 \
			else "\nImages dropped per camera: %s. The disk did not keep up." % str(dropped)
		_done_text.text = "%s\n%d frames, %s.\nSaved on the board in\n%s%s" % [
			"Finished." if saved.get("status") == "complete" else "Stopped: the run is saved as far as it got.",
			_ok + _failed, _mmss(_elapsed), saved.get("path", ""), note]
	if _view != View.RUN:
		return
	var capture = info.get("capture")
	if info.get("state") == "capturing" and capture is Dictionary:
		_recording = true
		_ok = int(capture.get("ok", 0))
		_failed = int(capture.get("failed", 0))
		_elapsed = float(capture.get("elapsed_s", 0.0))
	elif _recording and info.get("state") == "ready":
		# The tracker ended it at the limit: close the run.
		var last = info.get("last")
		if last is Dictionary:
			_ok = int(last.get("frames_ok", _ok))
			_failed = int(last.get("frames_failed", _failed))
		_elapsed = _limit_s
		_finish("Time is up. Saving...")


func _finish(text: String) -> void:
	_done_text.text = text
	_recording = false
	_show_view(View.DONE)
	GlobalScript.send_experiment_command("stop complete")


func _on_link_changed(connected: bool) -> void:
	if connected:
		return
	if _waiting_start:
		_waiting_start = false
		_refresh_setup()
	if _view == View.RUN:
		_saved_shown = true
		_recording = false
		_done_text.text = "The link to the tracker was lost. The recording is saved on the board as far as it got."
		_show_view(View.DONE)


func _input(event: InputEvent) -> void:
	if _view == View.RUN and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_finish("Saving...")


func _unhandled_input(event: InputEvent) -> void:
	if _view != View.RUN and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_leave()


func _leave() -> void:
	get_tree().change_scene_to_file(MENU)


func _exit_tree() -> void:
	if _view == View.RUN and GlobalScript.link.connected:
		GlobalScript.send_experiment_command("stop stopped")


# ── Drawing ───────────────────────────────────────────────────────────────────

func _draw() -> void:
	draw_rect(get_viewport_rect(), Style.GROUND)
	if _view != View.RUN or _corners_mm.is_empty():
		return
	var outline := PackedVector2Array()
	for c in _corners_mm:
		outline.append(_space.mm_to_screen(c))
	outline.append(outline[0])
	draw_colored_polygon(outline, Style.CARD)
	draw_polyline(outline, Style.TRACK, 2.0)
	if Time.get_ticks_msec() - GlobalScript.last_packet_ms <= FRESH_MS:
		var hand := _space.mm_to_screen(GlobalScript.table_r * 1000.0)
		draw_arc(hand, 10.0, 0.0, TAU, 32, Style.WARN, 2.5)
		draw_circle(hand, 3.0, Style.WARN)
