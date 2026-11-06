extends Control
## Experiment: a grid of points over the defined table, for measuring how the tracker
## holds still across it. The device is taken to the highlighted point; once it has been
## inside it and still for the settle time, the tracker saves that many frames (pose and
## images, pyscripts/experiment.py) and the next point lights up. A capture in which the
## device moved is kept in the files, marked not accepted, and the point is done again.
##
## This screen decides where and when. All the data is written by the tracker, on the
## board. The expected positions come from the table's corners, as the tracker measured
## them, so the offsets it reports are not an independent measure of accuracy.
##
## It needs the tracker: in debug the mouse has no images and no pose to save.

const Style := preload("res://Main_screen/Scripts/settings_style.gd")
const TableSpace := preload("res://Games/firefly_reach/table_space.gd")
const TableOverlay := preload("res://Main_screen/Scripts/table_overlay.gd")
const LinkProtocol := preload("res://Main_screen/Scripts/link_protocol.gd")
const MENU := "res://Experiments/experiment_menu.tscn"
const NAME := "static_grid"

# [key, label, min, max, step, default]
const FIELDS := [
	["rows", "Rows", 1, 20, 1, 4],
	["cols", "Columns", 1, 20, 1, 6],
	["frames", "Frames per point", 1, 300, 1, 30],
	["margin_mm", "Margin from the table edge (mm)", 0, 300, 5, 50],
	["settle_s", "Still before capturing (s)", 0, 10, 0.1, 1.0],
	["radius_mm", "Point radius (mm)", 2, 100, 1, 15],
	["still_mm", "Counts as still within (mm)", 0.5, 50, 0.5, 5],
]
const MB_PER_FRAME_PAIR := 2.0   # the board's two full-size images; the tracker checks the disk
const FRESH_MS := 300            # a position older than this: the device is out of view
const NOTES_MAX := 100           # keeps the command inside one BLE write
const LABEL_MAX := 40

enum View { SETUP, RUN, DONE }

var _view: int = View.SETUP
var _inputs := {}                # key -> SpinBox
var _params := {}                # the fields, as the run started
var _label: LineEdit
var _notes: LineEdit
var _setup: Control
var _setup_info: Label
var _setup_error: Label
var _start_button: Button
var _define_button: Button
var _hud: Label
var _hint: Label
var _done_panel: Control
var _done_text: Label

var _space: TableSpace
var _corners_mm: Array = []
var _targets: Array = []         # in visiting order: {index, row, col, mm}
var _at := 0                     # which of _targets is highlighted
var _attempt := 0
var _waiting_start := false
var _capturing := false
var _capture_ok := 0
var _anchor = null               # where the device has been still since (mm), null if not
var _held := 0.0
var _accepted := 0
var _saved_shown := false


## The grid over a table's four corners (the order table_overlay.gd records them:
## top-left, bottom-left, bottom-right, top-right), row 1 at the top, snaking from the
## top-left so the device never crosses the table between two points. A table that is not
## quite a rectangle keeps its shape: the points follow its edges. [] if the margin leaves
## no room.
static func grid_targets(corners: Array, rows: int, cols: int, margin_mm: float) -> Array:
	var tl: Vector2 = corners[0]
	var bl: Vector2 = corners[1]
	var br: Vector2 = corners[2]
	var tr: Vector2 = corners[3]
	var width := (tl.distance_to(tr) + bl.distance_to(br)) * 0.5
	var height := (tl.distance_to(bl) + tr.distance_to(br)) * 0.5
	if margin_mm * 2.0 >= width or margin_mm * 2.0 >= height:
		return []
	var out := []
	for r in rows:
		var v := _along(r, rows, margin_mm / height)
		for c0 in cols:
			var c: int = c0 if r % 2 == 0 else cols - 1 - c0
			var u := _along(c, cols, margin_mm / width)
			out.append({
				"index": out.size() + 1, "row": r + 1, "col": c + 1,
				"mm": tl.lerp(tr, u).lerp(bl.lerp(br, u), v),
			})
	return out


## i of n evenly between the margins, as a share of the side.
static func _along(i: int, n: int, margin: float) -> float:
	return 0.5 if n == 1 else margin + (1.0 - 2.0 * margin) * float(i) / float(n - 1)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = Style.make_theme()
	GlobalScript.hold_tracking(self)
	GlobalScript.experiment_status.connect(_on_status)
	GlobalScript.link_command_done.connect(_on_command_done)
	GlobalScript.link_connected_changed.connect(_on_link_changed)
	_build_setup()
	_build_run()
	_show_view(View.SETUP)
	_refresh_setup()


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
	col.add_child(Style.label("Static grid", "Title"))

	_label = LineEdit.new()
	_label.placeholder_text = "Experiment name or number (required), e.g. trial_03"
	_label.max_length = LABEL_MAX
	_label.text_changed.connect(func(_t): _refresh_setup())
	col.add_child(_label)

	var form := GridContainer.new()
	form.columns = 4
	form.add_theme_constant_override("h_separation", 16)
	form.add_theme_constant_override("v_separation", 8)
	for f in FIELDS:
		var name_label := Style.label(f[1])
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		form.add_child(name_label)
		var spin := SpinBox.new()
		spin.min_value = f[2]
		spin.max_value = f[3]
		spin.step = f[4]
		spin.value = f[5]
		spin.value_changed.connect(func(_v): _refresh_setup())
		form.add_child(spin)
		_inputs[f[0]] = spin
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
	_start_button.text = "Start"
	_start_button.theme_type_variation = "PrimaryButton"
	_start_button.pressed.connect(_start)
	buttons.add_child(_start_button)
	_define_button = Button.new()
	_define_button.text = "Define table"
	_define_button.pressed.connect(func():
		TableOverlay.open(self).table_done.connect(_refresh_setup))
	buttons.add_child(_define_button)
	col.add_child(buttons)


func _build_run() -> void:
	_hud = Style.label("")
	_hud.position = Vector2(16, 8)
	add_child(_hud)
	_hint = Style.label("", "Helper")
	_hint.position = Vector2(16, 34)
	add_child(_hint)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	_done_text = Style.wrapped("")
	_done_text.custom_minimum_size.x = 720
	box.add_child(_done_text)
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
	box.add_child(buttons)
	_done_panel = Style.card(box)
	_done_panel.position = Vector2(200, 240)
	add_child(_done_panel)


func _show_view(view: int) -> void:
	_view = view
	_setup.visible = view == View.SETUP
	_hud.visible = view == View.RUN
	_hint.visible = view == View.RUN
	_done_panel.visible = view == View.DONE
	if view == View.SETUP:
		_refresh_setup()
	queue_redraw()


# ── Setup ─────────────────────────────────────────────────────────────────────

## The table's corners in mm, [] if there is no table with its corners kept.
func _table_mm() -> Array:
	return GlobalScript.table_corners().map(func(c): return c * 1000.0) if GlobalScript.table_set else []


func _refresh_setup() -> void:
	_corners_mm = _table_mm()
	if _corners_mm.is_empty():
		_targets = []
		_setup_info.text = "Needs the table's corners. A table defined before this screen " \
			+ "existed did not keep them: define it again."
		_start_button.disabled = true
		return
	var rows := int(_inputs["rows"].value)
	var cols := int(_inputs["cols"].value)
	_targets = grid_targets(_corners_mm, rows, cols, _inputs["margin_mm"].value)
	_start_button.disabled = _targets.is_empty() or _run_label() == ""
	if _targets.is_empty():
		_setup_info.text = "That margin leaves no room on this table."
		return
	var width: float = _corners_mm[0].distance_to(_corners_mm[3])
	var height: float = _corners_mm[0].distance_to(_corners_mm[1])
	var frames: int = _targets.size() * int(_inputs["frames"].value)
	_setup_info.text = "Table %d x %d mm. %d points, %d frames: about %.1f GB, saved on the board in %s/experiments." % [
		roundi(width), roundi(height), _targets.size(), frames,
		frames * MB_PER_FRAME_PAIR / 1000.0, Settings.APP_DIR]
	if _run_label() == "":
		_setup_info.text += "\nType the experiment's name or number to start."


## The name typed for this run, as it goes in the folder's name: spaces become
## underscores and anything else a folder name should not hold is dropped.
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
	for f in FIELDS:
		_params[f[0]] = _inputs[f[0]].value
	_waiting_start = true
	_start_button.disabled = true
	GlobalScript.send_experiment_command("start %s %d %s" % [NAME, _targets.size() * int(_params["frames"]), _run_label()])


func _on_command_done(kind: int, ok: bool, detail: String) -> void:
	if kind != LinkProtocol.EXPERIMENT:
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
		_capturing = false


## A BLE write holds about 240 bytes, so the run's description goes in pieces.
func _begin_run() -> void:
	var meta := func(key: String, value: Variant) -> void:
		GlobalScript.send_experiment_command("meta %s %s" % [key, JSON.stringify(value)])
	meta.call("table_frame", GlobalScript.table_frame())
	meta.call("table_corners_mm", _corners_mm.map(func(c): return [snappedf(c.x, 0.01), snappedf(c.y, 0.01)]))
	meta.call("grid", {
		"rows": int(_params["rows"]), "cols": int(_params["cols"]),
		"margin_mm": _params["margin_mm"], "order": "serpentine, from the top-left",
		"frames_per_target": int(_params["frames"]),
	})
	meta.call("dwell", {
		"settle_s": _params["settle_s"], "radius_mm": _params["radius_mm"], "still_mm": _params["still_mm"],
	})
	meta.call("app", {"debug": Settings.is_debug(), "platform": OS.get_name(),
		"location": Settings.get_value("location", "")})
	meta.call("notes", _notes.text.strip_edges())

	_space = TableSpace.new(get_viewport_rect().size)
	_at = 0
	_attempt = 0
	_accepted = 0
	_saved_shown = false
	_capturing = false
	_reset_hold()
	_show_view(View.RUN)


# ── The run ───────────────────────────────────────────────────────────────────

func _reset_hold() -> void:
	_anchor = null
	_held = 0.0


func _process(delta: float) -> void:
	if _view != View.RUN:
		return
	queue_redraw()
	var target: Dictionary = _targets[_at]
	_hud.text = "Point %d of %d   row %d, column %d" % [target["index"], _targets.size(), target["row"], target["col"]]
	if _capturing:
		_hint.text = "Hold still: %d of %d frames" % [_capture_ok, int(_params["frames"])]
		return
	if Time.get_ticks_msec() - GlobalScript.last_packet_ms > FRESH_MS or GlobalScript.last_packet_ms == 0:
		_reset_hold()
		_hint.text = "The device is out of view.   Esc stops the run."
		return
	var hand: Vector2 = GlobalScript.table_r * 1000.0
	var away: float = hand.distance_to(target["mm"])
	if away > _params["radius_mm"]:
		_reset_hold()
		_hint.text = "Go to the highlighted point: %d mm away.   Esc stops the run." % roundi(away)
		return
	if _anchor == null or hand.distance_to(_anchor) > _params["still_mm"]:
		_anchor = hand
		_held = 0.0
	_held += delta
	_hint.text = "Stay there..."
	if _held >= _params["settle_s"]:
		_capture(target)


func _capture(target: Dictionary) -> void:
	_attempt += 1
	_capturing = true
	_capture_ok = 0
	GlobalScript.send_experiment_command("capture %d %d %d %.3f %.3f %d %.3f" % [
		target["index"], target["row"], target["col"], target["mm"].x, target["mm"].y,
		int(_params["frames"]), _params["still_mm"]])


func _on_status(info: Dictionary) -> void:
	var saved = info.get("saved")
	if _view == View.DONE and saved is Dictionary and not _saved_shown:
		_saved_shown = true
		var dropped: Array = saved.get("dropped", [])
		var note := "" if dropped.max() == 0.0 else "\nImages dropped per camera: %s. The disk did not keep up." % str(dropped)
		_done_text.text = "%s\n%d of %d points captured.\nSaved on the board in\n%s%s" % [
			"Finished." if saved.get("status") == "complete" else "Stopped: the run is saved as far as it got.",
			int(saved.get("accepted", 0)), _targets.size(), saved.get("path", ""), note]
	if _view != View.RUN or not _capturing:
		return
	var capture = info.get("capture")
	if capture is Dictionary and int(capture.get("target", 0)) == _targets[_at]["index"]:
		_capture_ok = int(capture.get("ok", 0))
	var last = info.get("last")
	if last is Dictionary and int(last.get("target", 0)) == _targets[_at]["index"] and int(last.get("attempt", 0)) == _attempt:
		_capture_finished(last)


func _capture_finished(result: Dictionary) -> void:
	_capturing = false
	_reset_hold()
	if not result.get("accepted", false):
		var why := "the device moved" if result.get("reason") == "moved" else "the device was not seen"
		push_warning("[EXPERIMENT] Point %d attempt %d: %s" % [_targets[_at]["index"], _attempt, why])
		_hint.text = "Again: %s." % why
		return
	_accepted += 1
	_at += 1
	_attempt = 0
	if _at >= _targets.size():
		_finish("complete", "Finished. Saving...")


func _finish(status: String, text: String) -> void:
	_done_text.text = text
	_capturing = false
	_show_view(View.DONE)
	GlobalScript.send_experiment_command("stop " + status)


func _on_link_changed(connected: bool) -> void:
	if connected:
		return
	if _waiting_start:
		_waiting_start = false
		_refresh_setup()
	if _view == View.RUN:
		_saved_shown = true
		_capturing = false
		_done_text.text = "The link to the tracker was lost. The run is saved on the board as far as it got."
		_show_view(View.DONE)


func _input(event: InputEvent) -> void:
	if _view == View.RUN and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_finish("stopped", "Stopping...")


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
	if _view != View.RUN:
		return
	var outline := PackedVector2Array()
	for c in _corners_mm:
		outline.append(_space.mm_to_screen(c))
	outline.append(outline[0])
	draw_colored_polygon(outline, Style.CARD)
	draw_polyline(outline, Style.TRACK, 2.0)

	var font := Style.font(Style.WEIGHT_BODY)
	for i in _targets.size():
		var at := _space.mm_to_screen(_targets[i]["mm"])
		if i < _at:
			draw_circle(at, 7.0, Style.GOOD)
		elif i > _at:
			draw_arc(at, 6.0, 0.0, TAU, 24, Style.MUTED, 1.5)
		draw_string(font, at + Vector2(10, -8), str(_targets[i]["index"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Style.MUTED)

	# The point being asked for, drawn at its true size, filling as it is held and saved.
	var centre := _space.mm_to_screen(_targets[_at]["mm"])
	var radius: float = _params["radius_mm"] * _space.px_per_mm().x
	var pulse := 0.7 + 0.3 * sin(Time.get_ticks_msec() / 180.0)
	draw_circle(centre, radius, Color(Style.ACCENT, 0.25))
	draw_arc(centre, radius, 0.0, TAU, 48, Color(Style.ACCENT, pulse), 3.0)
	draw_arc(centre, radius + 12.0, 0.0, TAU, 48, Color(Style.ACCENT, pulse * 0.5), 2.0)
	var share: float = float(_capture_ok) / _params["frames"] if _capturing \
		else (_held / _params["settle_s"] if _params["settle_s"] > 0.0 else 0.0)
	if share > 0.0:
		var ring := Style.GOOD if _capturing else Style.WARN
		draw_arc(centre, radius + 6.0, -PI / 2.0, -PI / 2.0 + TAU * minf(share, 1.0), 48, ring, 5.0)

	if Time.get_ticks_msec() - GlobalScript.last_packet_ms <= FRESH_MS:
		var hand := _space.mm_to_screen(GlobalScript.table_r * 1000.0)
		draw_arc(hand, 10.0, 0.0, TAU, 32, Style.WARN, 2.5)
		draw_circle(hand, 3.0, Style.WARN)
