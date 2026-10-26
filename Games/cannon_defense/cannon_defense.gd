extends Node2D

# Cannon Defense (a game of the 2D select-game menu): turn the handle to aim a
# cannon at meteors falling on a town. It trains turning — forearm rotation,
# wrist deviation or a dial turn, whichever the therapist asks for: calibration
# measures the axis the patient turns about (rotation_input.gd).
#   timer selector -> calibration (middle, left, right) -> play -> game over
# Score = meteors shot (ScoreManager, "CannonDefense"). Every meteor is a target
# for SessionLog: shot = hit, reached the dome = miss.
# Raw CSV (Manager): a row every LOG_INTERVAL. Beside it, <same name>_targets.csv:
# a row per meteor, the calibration in its header (a recalibration mid-trial is
# an event in the raw CSV).
# Play is held — meteors stop, MoveTime and the countdown pause — while paused,
# while the trunk compensates (as Random Reach) and while the handle is out of
# view. "Play with mouse" (shown during the first calibration) lets the mouse aim
# instead, uncalibrated, to try it on a PC. Never chosen automatically: over BLE
# the link can still be connecting when Play is pressed. Esc or Menu leaves for
# the menu; P / Space pauses.

const World := preload("res://Games/cannon_defense/cannon_world.gd")
const RotationInput := preload("res://Games/cannon_defense/rotation_input.gd")
const Sounds := preload("res://Games/cannon_defense/cannon_sounds.gd")
const TuningPanel := preload("res://Games/random_reach/Scripts/tuning_panel.gd")
const TrunkFeedback := preload("res://Main_screen/Scripts/trunk_feedback.gd")

const GAME_NAME := "CannonDefense"
const MENU := "res://Main_screen/Scenes/select_game.tscn"
const LOG_INTERVAL := 0.02
const FRESH_MS := 400          # a POSITION this recent = the handle is in view
const HANDLE_GRACE_MS := 600   # out of view this long holds play
const TRUNK_RESUME_S := 0.5
const SUMMARY_S := 2.5         # the measured range stays up this long after calibration

const COLUMNS: Array = [
	"epochtime", "state", "score", "misses", "level", "countdown",
	"rot_deg", "aim_deg", "cannon_deg", "handle_seen",
	"rvec_x", "rvec_y", "rvec_z",
	"meteors", "lock_id", "lock_progress", "holds", "events",
	"trunk_state", "trunk_level", "trunk_flex", "trunk_lat", "trunk_axi",
]
const TARGET_COLUMNS: Array = [
	"id", "angle_deg", "level", "speed_px_s", "spawn_time", "lock_time", "fire_time",
	"outcome", "outcome_time",
]

enum State { SETUP, CALIBRATE, PLAY, OVER }

var _state: int = State.SETUP
var _patient_id := ""
var _mouse := false            # no tracker: the mouse aims
var _duration := 0             # seconds from the timer selector; 0 = untimed
var _score := 0
var _misses := 0
var _holds := {}               # why play is held: "pause", "trunk", "handle", "calibrate"
var _trunk_ok_ms := -1
var _unseen_ms := -1
var _summary_until := -1
var _aim := 0.0                # where the input points the cannon, before smoothing
var _events: Array = []        # since the last raw row

var _world: World
var _rot := RotationInput.new()
var _sounds: Sounds
var _trunk_feedback: CanvasLayer
var _log: FileAccess = null
var _targets: FileAccess = null
var _log_timer: Timer

var _hud_bar: Label
var _prompt: Label
var _detail: Label
var _mouse_button: Button
var _pause_button: Button
var _recal_button: Button
var _pause_panel: Control
var _over_panel: Control
var _over_text: Label

var _prev_scale_size := Vector2i.ZERO
var _prev_aspect := Window.CONTENT_SCALE_ASPECT_IGNORE


func _ready() -> void:
	# Drawn in pixels for 1920x1080, letterboxed so the aim arc stays round
	# (as firefly_main.gd); both are restored in _exit_tree.
	var root := get_tree().root
	_prev_scale_size = root.content_scale_size
	_prev_aspect = root.content_scale_aspect
	root.content_scale_size = Vector2i(1920, 1080)
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	_patient_id = "vvv" if Manager.debug else PatientDB.current_patient_id
	# Aim is the handle's rotation: the tracker sends ROTATION, not POSITION.
	GlobalScript.want_rotation(self)

	_world = World.new()
	_world.spawned.connect(_on_spawned)
	_world.fired.connect(_on_fired)
	_world.resolved.connect(_on_resolved)
	add_child(_world)
	_sounds = Sounds.new()
	add_child(_sounds)
	_log_timer = Timer.new()
	_log_timer.wait_time = LOG_INTERVAL
	_log_timer.timeout.connect(_write_row)
	add_child(_log_timer)

	_build_hud()
	add_child(TuningPanel.new())   # live tracker tuning: F2 or the Tune button
	_trunk_feedback = TrunkFeedback.new()
	add_child(_trunk_feedback)

	GlobalTimerManager.stop_countdown()   # nothing left over from another game
	GlobalTimerManager.countdown_finished.connect(_game_over)
	GlobalTimerManager.add_timer_selector_to_game(self)
	_show_prompt("", "")


# ── timer selector (GlobalTimerManager calls these) ───────────────────────────

func _on_global_timer_play_pressed(time: int) -> void:
	_duration = time
	_begin()


func _on_global_timer_close_pressed() -> void:
	_duration = 0
	_begin()


func _begin() -> void:
	if _rot.calibrated() or _mouse:
		_start_play()   # Play again: same sitting, same range
	else:
		_start_calibration()


# ── calibration ───────────────────────────────────────────────────────────────

func _start_calibration() -> void:
	_rot.reset()
	_summary_until = -1
	_state = State.CALIBRATE
	_world.show_aim = false
	_mouse_button.visible = not _trial_open()
	_pause_button.visible = false


func _calibrate() -> void:
	if _rot.calibrated():
		_world.hold = -1.0
		_world.arrow = 0
		if Time.get_ticks_msec() >= _summary_until:
			_calibration_done()
		return
	if not _handle_seen():
		_world.hold = -1.0
		_world.arrow = 0
		_show_prompt("Waiting for the handle...", "Make sure the cameras can see it.")
		return
	var r := GlobalScript.hand_rotation()
	if _rot.feed(r):
		_sounds.play("step")
		if _rot.calibrated():
			_summary_until = Time.get_ticks_msec() + int(SUMMARY_S * 1000)
			_world.show_aim = true
			_events.append("calibrated:left=%.1f:right=%.1f" % [_rot.left_deg, _rot.right_deg])
			_show_prompt("Ready!", _range_text())
			return
	_world.hold = _rot.hold_progress
	match _rot.step:
		RotationInput.Step.MIDDLE:
			_world.arrow = 0
			_show_prompt("Hold the handle in a relaxed middle position", "Keep it still.")
		RotationInput.Step.LEFT:
			_world.arrow = -1
			_show_prompt("Turn LEFT as far as is comfortable, and hold",
				"Turned %d°" % roundi(_rot.turned_from_middle(r)))
		RotationInput.Step.RIGHT:
			_world.arrow = 1
			_show_prompt("Now turn RIGHT as far as is comfortable, and hold",
				_rot.problem if _rot.problem != "" else "Turned %d°" % roundi(_rot.turned_from_middle(r)))


func _calibration_done() -> void:
	_mouse_button.visible = false
	_show_prompt("", "")
	if _trial_open():
		_state = State.PLAY
		_pause_button.visible = true
		_set_hold("calibrate", false)
	else:
		_start_play()


func _range_text() -> String:
	return "Your turning range: left %d°, right %d°" % [roundi(-_rot.left_deg), roundi(_rot.right_deg)]


func _on_mouse_pressed() -> void:
	_mouse = true
	_world.show_aim = true
	_calibration_done()


# ── play ──────────────────────────────────────────────────────────────────────

func _start_play() -> void:
	_score = 0
	_misses = 0
	_holds.clear()
	_world.reset()
	_world.show_aim = true
	_world.hold = -1.0
	_world.arrow = 0
	if _duration > 0:
		GlobalTimerManager.start_countdown_with_time(_duration)
	else:
		GlobalTimerManager.start_game_without_timer()
	GlobalTimer.start_timer()
	_open_logs()   # after the countdown starts: SessionLog takes GameDuration from it
	_state = State.PLAY
	_pause_button.visible = true
	_world.running = true
	_log_timer.start()


func _trial_open() -> bool:
	return _log != null


func _process(_delta: float) -> void:
	_update_aim()
	match _state:
		State.CALIBRATE:
			_calibrate()
		State.PLAY:
			_update_handle()
			_update_trunk()
	_update_hud()


func _update_aim() -> void:
	if _mouse:
		var to := get_global_mouse_position() - World.PIVOT
		if to.y < 0.0:
			_aim = clampf(rad_to_deg(atan2(to.x, -to.y)), -World.ARC_DEG, World.ARC_DEG)
		_world.aim_live = true
	elif _rot.calibrated() and _handle_seen():
		_aim = _rot.aim_deg(GlobalScript.hand_rotation(), World.ARC_DEG)
		_world.aim_live = true
	else:
		_world.aim_live = false
	_world.aim_deg = lerpf(_world.aim_deg, _aim, GlobalScript.smooth_factor)


func _handle_seen() -> bool:
	return GlobalScript.last_packet_ms > 0 and Time.get_ticks_msec() - GlobalScript.last_packet_ms <= FRESH_MS


# Out of view for HANDLE_GRACE_MS holds play: a meteor missed then would not be the patient's.
func _update_handle() -> void:
	if _mouse:
		return
	if _handle_seen():
		_unseen_ms = -1
		if _holds.has("handle"):
			_set_hold("handle", false)
			_show_prompt("", "")
		return
	if _unseen_ms < 0:
		_unseen_ms = Time.get_ticks_msec()
	elif Time.get_ticks_msec() - _unseen_ms >= HANDLE_GRACE_MS and not _holds.has("handle"):
		_set_hold("handle", true)
		_show_prompt("Handle not seen", "Bring it back in front of the cameras.")


static func _trunk_compensating() -> bool:
	return TrunkMonitor.available() and TrunkMonitor.state == TrunkMonitor.TRACKING \
		and TrunkMonitor.level == TrunkMonitor.COMPENSATING


# As Random Reach: held while the trunk is past the compensation threshold,
# resumed after TRUNK_RESUME_S back under the warning one. An occluded or
# untracked trunk never holds play. A manual pause takes over from it.
func _update_trunk() -> void:
	if _holds.has("pause"):
		return
	if _holds.has("trunk"):
		if not TrunkMonitor.available() or TrunkMonitor.state != TrunkMonitor.TRACKING:
			_trunk_hold(false)
		elif TrunkMonitor.level == TrunkMonitor.OK:
			if _trunk_ok_ms < 0:
				_trunk_ok_ms = Time.get_ticks_msec()
			elif Time.get_ticks_msec() - _trunk_ok_ms >= TRUNK_RESUME_S * 1000:
				_trunk_hold(false)
		else:
			_trunk_ok_ms = -1
	elif _trunk_compensating():
		_trunk_hold(true)


func _trunk_hold(on: bool) -> void:
	_trunk_ok_ms = -1
	_set_hold("trunk", on)
	_trunk_feedback.paused_for_trunk = on
	if on:
		TrunkMonitor.play_beep()


# MoveTime and the countdown stop while anything holds play, and meteors freeze.
func _set_hold(why: String, on: bool) -> void:
	var was_free := _holds.is_empty()
	if on:
		_holds[why] = true
	else:
		_holds.erase(why)
	if was_free and not _holds.is_empty():
		GlobalTimer.pause_timer()
		GlobalTimerManager.pause_countdown()
		_events.append("hold:" + why)
	elif not was_free and _holds.is_empty():
		GlobalTimer.resume_timer()
		GlobalTimerManager.resume_countdown()
		_events.append("resume")
	_world.running = _state == State.PLAY and _holds.is_empty()


func _on_spawned(m: Dictionary) -> void:
	_events.append("spawn:%d:%.1f" % [m["id"], m["angle"]])


func _on_fired(m: Dictionary) -> void:
	_sounds.play("fire")
	_events.append("fire:%d" % m["id"])


func _on_resolved(m: Dictionary, outcome: String) -> void:
	if outcome == "hit":
		_score += 1
		SessionLog.hit()
		_sounds.play("boom", randf_range(0.9, 1.1))
	else:
		_misses += 1
		SessionLog.miss()
		_sounds.play("miss")
	_events.append("%s:%d" % [outcome, m["id"]])
	_write_target(m, outcome)


func _toggle_pause() -> void:
	if _state != State.PLAY:
		return
	var on := not _holds.has("pause")
	if on and _holds.has("trunk"):
		_trunk_hold(false)
	_set_hold("pause", on)
	_recal_button.visible = not _mouse
	_pause_panel.visible = on


func _recalibrate() -> void:
	_pause_panel.visible = false
	_set_hold("calibrate", true)
	_set_hold("pause", false)
	_start_calibration()


func _game_over() -> void:
	if _state != State.PLAY and _state != State.CALIBRATE:
		return
	_state = State.OVER
	_holds.clear()
	_world.running = false
	_world.hold = -1.0
	_world.arrow = 0
	_trunk_feedback.paused_for_trunk = false
	_pause_panel.visible = false
	_pause_button.visible = false
	_mouse_button.visible = false
	_show_prompt("", "")
	GlobalTimerManager.stop_countdown()
	GlobalTimer.stop_timer()
	_log_timer.stop()
	_write_row()
	SessionLog.end_trial()
	_close_logs()
	_save_score()
	MusicManager.play_sound_effect("game_over")
	var lines := PackedStringArray([
		"Score  %d" % _score,
		"Best  %d" % ScoreManager.get_top_score(_patient_id, GAME_NAME),
		"Meteors shot: %d of %d" % [_score, _score + _misses],
	])
	if _rot.calibrated() and not _mouse:
		lines.append(_range_text())
	_over_text.text = "\n".join(lines)
	_over_panel.visible = true


func _play_again() -> void:
	_over_panel.visible = false
	_world.reset()
	_state = State.SETUP
	GlobalTimerManager.show_timer_selector_for_retry()


func _save_score() -> void:
	if _score > 0:
		ScoreManager.update_top_score(_patient_id, GAME_NAME, _score)


func _leave() -> void:
	GlobalTimerManager.remove_timer_selector_from_game()   # shared: it must not be freed with this scene
	get_tree().change_scene_to_file(MENU)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			_leave()
		KEY_P, KEY_SPACE:
			get_viewport().set_input_as_handled()
			_toggle_pause()


func _exit_tree() -> void:
	SessionLog.end_trial()   # left early: the trial still gets its row
	_save_score()
	_close_logs()
	GlobalTimerManager.stop_countdown()
	GlobalTimer.stop_timer()
	var root := get_tree().root
	root.content_scale_size = _prev_scale_size
	root.content_scale_aspect = _prev_aspect


# ── logging ───────────────────────────────────────────────────────────────────

func _open_logs() -> void:
	_close_logs()
	_log = Manager.create_game_log_file(GAME_NAME, _patient_id)
	if _log == null:
		return
	_log.store_csv_line(PackedStringArray(COLUMNS))
	_log.flush()
	var path := _log.get_path_absolute()
	var side := path.get_base_dir().path_join(path.get_file().get_basename() + "_targets.csv")
	_targets = FileAccess.open(side, FileAccess.WRITE)
	if _targets == null:
		push_error("Could not create " + side)
		return
	var header := [
		"input,%s" % ("mouse" if _mouse else "tracker"),
		"rot_axis_x,%f" % _rot.axis.x, "rot_axis_y,%f" % _rot.axis.y, "rot_axis_z,%f" % _rot.axis.z,
		"rot_left_deg,%.2f" % _rot.left_deg, "rot_right_deg,%.2f" % _rot.right_deg,
		"arc_deg,%.1f" % World.ARC_DEG, "aim_tol_deg,%.1f" % World.AIM_TOL_DEG,
		"dwell_s,%.2f" % World.DWELL_S,
	]
	_targets.store_line("headerrows,%d" % (header.size() + 2))
	for line in header:
		_targets.store_line(line)
	_targets.store_line("start_time,%s" % Time.get_datetime_string_from_system())
	_targets.store_csv_line(PackedStringArray(TARGET_COLUMNS))
	_targets.flush()


func _close_logs() -> void:
	if _log:
		_log.close()
		_log = null
	if _targets:
		_targets.close()
		_targets = null


func _write_row() -> void:
	if _log == null:
		return
	var lock: Array = _world.lock_state()
	var r := GlobalScript.hand_rvec()
	var calibrated := _rot.calibrated() and not _mouse
	var row := [
		"%.3f" % Time.get_unix_time_from_system(), State.keys()[_state].to_lower(), _score, _misses,
		_world.level, GlobalTimerManager.get_countdown_time() if _duration > 0 else "",
		"%.2f" % _rot.angle_deg(GlobalScript.hand_rotation()) if calibrated else "",
		"%.2f" % _aim, "%.2f" % _world.aim_deg, int(_handle_seen()),
		r.x, r.y, r.z,
		_world.meteor_count(), lock[0].get("id", -1), "%.2f" % lock[1],
		"|".join(PackedStringArray(_holds.keys())), ";".join(PackedStringArray(_events)),
		TrunkMonitor.state, TrunkMonitor.level,
		"%.1f" % TrunkMonitor.angles.x, "%.1f" % TrunkMonitor.angles.y, "%.1f" % TrunkMonitor.angles.z,
	]
	_events.clear()
	var out := PackedStringArray()
	for v in row:
		out.append(str(v))
	_log.store_csv_line(out)


func _write_target(m: Dictionary, outcome: String) -> void:
	if _targets == null:
		return
	var t := func(v: float) -> String: return "%.3f" % v if v >= 0.0 else ""
	_targets.store_csv_line(PackedStringArray([
		str(m["id"]), "%.1f" % m["angle"], str(m["level"]), "%.0f" % m["speed"],
		t.call(m["spawn_t"]), t.call(m["lock_t"]), t.call(m["fire_t"]),
		outcome, t.call(Time.get_unix_time_from_system()),
	]))
	_targets.flush()


# ── HUD ───────────────────────────────────────────────────────────────────────

func _build_hud() -> void:
	var hud := CanvasLayer.new()
	hud.layer = 5
	add_child(hud)

	_hud_bar = _label(30)
	_hud_bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_hud_bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hud_bar.position.y = 14
	hud.add_child(_hud_bar)

	_prompt = _label(48)
	_prompt.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_prompt.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_prompt.position.y -= 220
	hud.add_child(_prompt)
	_detail = _label(32)
	_detail.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_detail.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_detail.position.y -= 150
	_detail.add_theme_color_override("font_color", Color(1.0, 0.88, 0.55))
	hud.add_child(_detail)

	# Bottom right, clear of the cannon (the trunk overlay's Capture button is bottom left).
	var corner := HBoxContainer.new()
	corner.add_theme_constant_override("separation", 12)
	corner.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
	corner.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	corner.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_mouse_button = _button("Play with mouse", _on_mouse_pressed)
	_mouse_button.visible = false
	corner.add_child(_mouse_button)
	_pause_button = _button("Pause", _toggle_pause)
	_pause_button.visible = false
	corner.add_child(_pause_button)
	corner.add_child(_button("Menu", _leave))
	hud.add_child(corner)

	_pause_panel = _card()
	var pause_box: VBoxContainer = _pause_panel.get_child(0)
	var paused := _label(48)
	paused.text = "Paused"
	pause_box.add_child(paused)
	pause_box.add_child(_button("Resume", _toggle_pause))
	_recal_button = _button("Recalibrate turning", _recalibrate)
	pause_box.add_child(_recal_button)
	pause_box.add_child(_button("End game", _game_over))
	pause_box.add_child(_button("Menu", _leave))
	hud.add_child(_pause_panel)

	_over_panel = _card()
	var over_box: VBoxContainer = _over_panel.get_child(0)
	var title := _label(52)
	title.text = "Well defended!"
	title.add_theme_color_override("font_color", World.GOLD)
	over_box.add_child(title)
	_over_text = _label(32)
	over_box.add_child(_over_text)
	over_box.add_child(_button("Play again", _play_again))
	over_box.add_child(_button("Menu", _leave))
	hud.add_child(_over_panel)


func _update_hud() -> void:
	var parts := PackedStringArray(["Score %d" % _score, "Missed %d" % _misses, "Level %d" % _world.level])
	if _duration > 0 and _state != State.SETUP:
		var left := GlobalTimerManager.get_countdown_time()
		parts.append("%d:%02d" % [left / 60, left % 60])
	if _mouse and _state != State.SETUP:
		parts.append("(mouse)")
	_hud_bar.text = "     ".join(parts)


func _show_prompt(text: String, detail: String) -> void:
	_prompt.text = text
	_detail.text = detail


func _label(size: int) -> Label:
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", load("res://Assets/Fonts/Bungee-Regular.ttf"))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 8)
	return l


# Styled as firefly_reach/back_button.gd, sized for the operator's mouse.
func _button(text: String, on_pressed: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(170, 64)
	b.add_theme_font_size_override("font_size", 28)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.1, 0.22, 0.8)
	style.border_color = Color(1, 1, 1, 0.35)
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.content_margin_left = 20
	style.content_margin_right = 20
	b.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate()
	hover.bg_color = Color(0.12, 0.2, 0.38, 0.95)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.pressed.connect(on_pressed)
	return b


# A centred rounded card holding a VBoxContainer; hidden until shown.
func _card() -> Control:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.12, 0.92)
	sb.border_color = Color(1, 1, 1, 0.3)
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(24)
	sb.set_content_margin_all(40)
	panel.add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 18)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(box)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.visible = false
	return panel
