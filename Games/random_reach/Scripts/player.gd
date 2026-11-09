extends CharacterBody2D

# Exported variables
@export var max_score = 500
## Debug: mouse instead of the tracker, and no therapy session logged.
@onready var debug_mode = Settings.is_debug()

# Constants
const SPEED = 100.0
const MIN_BOUNDS = Vector2(44, 40)
const MAX_BOUNDS = Vector2(1105, 600)
const LOG_INTERVAL = 0.02

# Node references - grouped by functionality
@onready var _audio_nodes = {
	"apple_sound": $"../apple_sound"
}

@onready var _ui_nodes = {
	"score_board":$"../Apple_Score/Score",
	"time_display": $"../Panel/TimeSeconds",
	"countdown_display": $"../CircularTimer",
	"game_over_label": $"../TileMap/CanvasLayer/ColorRect",
	"top_score_label":$"../TileMap/CanvasLayer/TopScore/TopScoreLabel",
	"color_rect": $"../TileMap/CanvasLayer/ColorRect",
	"bg_2d":$"../2DRR",
	"bg_3d":$"../3DRR",
	"current_score":$"../TileMap/CanvasLayer/ColorRect/CurrentScore",
	"highscore":$"../TileMap/CanvasLayer/ColorRect/Highscore",
	"Paused":$"../Paused",
	"pps_label": $"../PPSLabel"
}

@onready var _timer_nodes = {
	"my_timer": $"../DisplayTimer"
}

@onready var _panel_nodes = {
	"pause_button": $"../TileMap/CanvasLayer/PauseButton"
}

@onready var _sprite_nodes = {
	"anim": $Sprite2D
}

# Game state variables
var network_position = Vector2.ZERO
var current_apple: Node = null
var game_started: bool = false
var score = 0
var zero_offset = Vector2.ZERO
var game_over = false
var countdown_time = 0
var countdown_active = false
var pause_state = 1
var is_3d_mode := false

# Position tracking variables
var target_x: float
var target_y: float
var target_z: float
var pos_x: float
var pos_y: float
var pos_z: float
var game_x: float
var game_y = 0.0
var game_z: float

# Game logging variables
var status := "idle"
var error_status = "null"
var packets = "null"
var patient_id = SessionLog.current_patient()
var game_name = "RandomReach"
var game_log_file
var log_timer := Timer.new()

# ROM bounds
var rom_x_top: int
var rom_y_top: int
var rom_x_bot: int
var rom_y_bot: int

# Preloaded resources
var apple = preload("res://Games/random_reach/scenes/apple.tscn")
const GameFx := preload("res://Main_screen/Scripts/game_fx.gd")
const ReachPlayRun := preload("res://Experiments/reach_play_run.gd")
const ReachArea := preload("res://Games/random_reach/Scripts/reach_area.gd")
const ReachStore := preload("res://Games/firefly_reach/reach_store.gd")
const APPLE_BOX_LO := Vector2i(200, 200)   # where apples go, clear of the HUD
const APPLE_BOX_HI := Vector2i(900, 600)
## Apples placed with no room in the reach outline (none, or too small): in the box as before.
var apples_outside_outline := 0
var _outline_px := PackedVector2Array()   # the reach outline as drawn (display pixels)
var _outline_for := Vector2(INF, INF)      # the Zero offset the outline was turned into pixels for
## Real game pixels -> drawn pixels: the workspace scaled to the apple area, for the eye only
## (reach_area.gd view_fit). Every logged position goes back through _view_inv.
var _view := Transform2D.IDENTITY
var _view_inv := Transform2D.IDENTITY
const ReachPlayGame := preload("res://Experiments/reach_play_game.gd")
var _flock: Node2D
## Played as an experiment (Experiments/reach_play_*.gd): 2D, the tracker even in debug, the
## run's time with no selector, the rows in the run's folder, no patient scores or session.
var _exp: Node = null

# Trunk compensation (TrunkMonitor): play pauses while the trunk is past the
# compensation threshold and resumes once it has been back under the warning
# threshold for TRUNK_RESUME_S. A target reached while compensating does not
# score. An occluded or untracked trunk never pauses the game.
const TRUNK_RESUME_S := 0.5
var trunk_paused := false
var _trunk_ok_ms := -1
var _trunk_feedback: CanvasLayer

func _ready() -> void:
	z_index = 2
	if ReachPlayRun.playing():
		_exp = ReachPlayGame.new(self)
		add_child(_exp)
		debug_mode = false
		_panel_hide_restart()
	get_parent().add_child.call_deferred(preload("res://Games/random_reach/Scripts/tuning_panel.gd").new())
	_setup_training_hand()
	_setup_timers()
	_setup_ui()
	_connect_signals()
	_initialize_game_state()
	_auto_select_mode()  # Must be called BEFORE _update_top_score_display() to set correct game_name
	_update_top_score_display()
	_flock = preload("res://Games/random_reach/Scripts/sheep_flock.gd").new()
	_flock.player = self
	get_parent().add_child.call_deferred(_flock)
	var meadow = preload("res://Games/random_reach/Scripts/meadow.gd").new()
	meadow.is_3d = is_3d_mode
	get_parent().add_child.call_deferred(meadow)
	var fx = preload("res://Games/random_reach/Scripts/player_fx.gd").new()
	fx.player = self
	add_child(fx)
	_setup_global_timer()
	_trunk_feedback = preload("res://Main_screen/Scripts/trunk_feedback.gd").new()
	get_parent().add_child.call_deferred(_trunk_feedback)

func _setup_global_timer() -> void:
	# Connect to global timer signals
	GlobalTimerManager.countdown_finished.connect(_on_global_countdown_finished)
	GlobalTimerManager.countdown_updated.connect(_on_global_countdown_updated)
	if _exp:
		# The experiment's time was set on its setup screen: play at once.
		_on_global_timer_play_pressed.call_deferred(ReachPlayRun.seconds)
		return
	# Add the global timer selector to this game
	GlobalTimerManager.add_timer_selector_to_game(self)

func _auto_select_mode() -> void:
	# Automatically set mode based on GlobalSignals
	if GlobalSignals.selected_game_mode == "3D" and not _exp:
		_set_3d_mode()
	else:
		_set_2d_mode()

func _setup_training_hand() -> void:
	var training_hand = GlobalSignals.selected_training_hand
	if training_hand != "":
		print("Training for %s hand" % training_hand)

func _setup_timers() -> void:
	log_timer.wait_time = LOG_INTERVAL
	log_timer.autostart = true
	add_child(log_timer)

func _setup_ui() -> void:
	_ui_nodes.color_rect.visible = false
	_ui_nodes.game_over_label.hide()
	_ui_nodes.game_over_label.hide()
	_ui_nodes.color_rect.hide()
	_ui_nodes.countdown_display.visible = false
	GameFx.dim_behind(_ui_nodes.Paused)
	# Note: _update_top_score_display() is now called after _auto_select_mode() in _ready()

func _connect_signals() -> void:
	# Button connections
	_panel_nodes.pause_button.pressed.connect(_on_PauseButton_pressed)

func _initialize_game_state() -> void:
	network_position = Vector2.ZERO

func _update_top_score_display() -> void:
	if _exp:
		_ui_nodes.top_score_label.text = "-"   # no patient
		return
	var top_score = ScoreManager.get_top_score(patient_id, game_name)
	_ui_nodes.top_score_label.text = str(top_score)

# Global Timer Callbacks
func _on_global_timer_play_pressed(time: int) -> void:
	GlobalTimer.start_timer()
	game_started = true
	countdown_time = time
	_start_game_with_timer(time)
	_setup_game_logging()

func _on_global_timer_close_pressed() -> void:
	game_started = true
	_ui_nodes.countdown_display.hide()
	_start_game_without_timer()
	_setup_game_logging()


func _start_game_with_timer(time: int) -> void:
	countdown_active = true
	countdown_time = time
	_ui_nodes.countdown_display.visible = true
	_ui_nodes.countdown_display.set_time(time)  # Initialize the timer
	GlobalTimerManager.start_countdown_with_time(time)
	
	
func _start_game_without_timer() -> void:
	countdown_active = false
	GlobalTimer.start_timer()
	GlobalTimerManager.start_game_without_timer()

func _on_global_countdown_finished() -> void:
	show_game_over()

func _on_global_countdown_updated(time_left: int) -> void:
	countdown_time = time_left
	_ui_nodes.countdown_display.update_time(time_left)
	
	
func _physics_process(delta):
	_update_trunk()
	if not game_started:
		return

	_update_player_position()
	_update_sprite_direction()
	_handle_apple_spawning()
	_update_timer_display()
	_update_pps_display()

func _update_player_position() -> void:
	if debug_mode:
		network_position = get_global_mouse_position()
	else:
		network_position = GlobalScript.network_position3D if is_3d_mode else GlobalScript.network_position
	if network_position != Vector2.ZERO:
		_reach_outline()   # the view follows today's outline
		# The mouse is already where it is drawn; the tracker's hand is real, drawn scaled.
		var drawn: Vector2 = network_position if debug_mode else _view * (network_position - zero_offset)
		network_position = network_position - zero_offset
		position = position.lerp(drawn, 0.8)
		position.x = clamp(position.x, MIN_BOUNDS.x, MAX_BOUNDS.x)
		position.y = clamp(position.y, MIN_BOUNDS.y, MAX_BOUNDS.y)

		_update_position_tracking()

func _update_position_tracking() -> void:
	pos_x = GlobalScript.raw_x
	pos_y = GlobalScript.raw_y
	pos_z = GlobalScript.raw_z

	# Logged in real units: the drawn position taken back through the display scaling.
	var real: Vector2 = _view_inv * position
	game_x = (real.x - GlobalScript.X_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_X

	if is_3d_mode:
		# 3D mode: calculate game_y from screen Y position
		game_y = (real.y - GlobalScript.Y_SCREEN_OFFSET3D) / GlobalScript.PLAYER3D_POS_SCALER_Y
		game_z = 0.0  # Z not used in 3D screen mapping
	else:
		# 2D mode: Y is always 0, Z calculated from screen Y position
		game_y = 0.0
		game_z = (real.y - GlobalScript.Y_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_Z


func _update_pps_display() -> void:
	_ui_nodes.pps_label.text = "PPS: " + str(GlobalScript.packets_per_second)

func _update_sprite_direction() -> void:
	if current_apple != null:
		var direction = current_apple.position.x - position.x
		_sprite_nodes.anim.flip_h = direction < 0

	_sprite_nodes.anim.play(&"no_jet" if position.y == MAX_BOUNDS.y else &"jet")

func _handle_apple_spawning() -> void:
	if current_apple == null and (debug_mode or network_position != Vector2.ZERO):
		_spawn_new_apple()

func _spawn_new_apple() -> void:
	_timer_nodes.my_timer.start()
	current_apple = apple.instantiate()
	current_apple.flock = _flock
	add_child(current_apple)
	current_apple.top_level = true
	status = ""

	# Connect apple signals
	current_apple.apple_eaten.connect(_on_apple_eaten)
	current_apple.apple_missed.connect(_on_apple_missed)
	current_apple.tree_exited.connect(_on_apple_removed)

	# Set apple position
	_set_apple_position()
	_flock.watch_apple(current_apple)

func _set_apple_position() -> void:
	var apple_position: Vector2
	var spot = ReachArea.pick(_reach_outline(), _apple_radius(), APPLE_BOX_LO, APPLE_BOX_HI)
	if spot != null:
		apple_position = spot
	else:
		if apples_outside_outline == 0 and not is_3d_mode:
			push_warning("[RandomReach] No room in the reach outline: apples anywhere in the box")
		apples_outside_outline += 1
		apple_position = Vector2(randi_range(APPLE_BOX_LO.x, APPLE_BOX_HI.x), randi_range(APPLE_BOX_LO.y, APPLE_BOX_HI.y))
	_update_target_position(apple_position)
	current_apple.position = apple_position

## Today's reach outline as drawn: the experiment's own scan, or the patient's (the daily
## assessment, assessment_gate.gd), scaled onto the apple area (_view). Empty in 3D (the
## screen's y is height there), or with no outline. Worked out again if Zero moves the hand.
func _reach_outline() -> PackedVector2Array:
	if is_3d_mode:
		return PackedVector2Array()
	if zero_offset != _outline_for:
		var mm: Array = ReachPlayRun.boundary if _exp else ReachStore.load_boundary(patient_id)
		var real := ReachArea.outline_px(mm, zero_offset)
		_view = ReachArea.view_fit(real, APPLE_BOX_LO, APPLE_BOX_HI)
		_view_inv = _view.affine_inverse()
		_outline_px = _view * real
		_outline_for = zero_offset
	return _outline_px

## The display gain (1 when the workspace is drawn at its real size).
func view_gain() -> float:
	return _view.get_scale().x

## The apple's catch circle, in the game's pixels.
func _apple_radius() -> float:
	var shape := current_apple.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if shape and shape.shape is CircleShape2D:
		var s: Vector2 = shape.global_scale
		return (shape.shape as CircleShape2D).radius * maxf(absf(s.x), absf(s.y))
	return 26.0

func _update_target_position(drawn_position: Vector2) -> void:
	# Logged in real units, as the player's position is.
	var apple_position: Vector2 = _view_inv * drawn_position
	target_x = (apple_position.x - GlobalScript.X_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_X

	if is_3d_mode:
		# 3D mode: apple Y position maps to target_y
		target_y = (apple_position.y - GlobalScript.Y_SCREEN_OFFSET3D) / GlobalScript.PLAYER3D_POS_SCALER_Y
		target_z = 0.0
	else:
		# 2D mode: apple Y position maps to target_z, target_y is 0
		target_y = 0.0
		target_z = (apple_position.y - GlobalScript.Y_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_Z

func _update_timer_display() -> void:
	if current_apple != null:
		var remaining_time = ceili(current_apple.get_time_left())
		_ui_nodes.time_display.text = str(remaining_time) + "s"

		if remaining_time > 0:
			if status != "captured":
				status = "moving"
		else:
			if status != "captured":
				status = "missed"
	
func _on_PauseButton_pressed() -> void:
	_pause_game()

static func _trunk_compensating() -> bool:
	return TrunkMonitor.available() and TrunkMonitor.state == TrunkMonitor.TRACKING \
		and TrunkMonitor.level == TrunkMonitor.COMPENSATING

func _update_trunk() -> void:
	if trunk_paused:
		# Occluded, untracked or no neutral: nothing to wait for, so play on.
		if not TrunkMonitor.available() or TrunkMonitor.state != TrunkMonitor.TRACKING:
			_trunk_resume()
		elif TrunkMonitor.level == TrunkMonitor.OK:
			if _trunk_ok_ms < 0:
				_trunk_ok_ms = Time.get_ticks_msec()
			elif Time.get_ticks_msec() - _trunk_ok_ms >= TRUNK_RESUME_S * 1000:
				_trunk_resume()
		else:
			_trunk_ok_ms = -1
	elif game_started and _trunk_compensating():
		_trunk_pause()

func _trunk_pause() -> void:
	trunk_paused = true
	_trunk_ok_ms = -1
	GlobalTimer.pause_timer()
	GlobalTimerManager.pause_countdown()
	game_started = false
	pause_state = 0
	_freeze_targets(true)
	TrunkMonitor.play_beep()
	_trunk_feedback.paused_for_trunk = true

func _trunk_resume() -> void:
	trunk_paused = false
	_trunk_feedback.paused_for_trunk = false
	_resume_game()

## Stop the target's own countdown and its eating timer while play is paused.
func _freeze_targets(frozen: bool) -> void:
	_timer_nodes.my_timer.paused = frozen
	if is_instance_valid(_flock):
		_flock.process_mode = Node.PROCESS_MODE_DISABLED if frozen else Node.PROCESS_MODE_INHERIT
	if current_apple != null:
		current_apple.process_mode = Node.PROCESS_MODE_DISABLED if frozen \
			else Node.PROCESS_MODE_INHERIT

func _pause_game() -> void:
	if trunk_paused:
		# Already paused for the trunk: the manual pause takes over from it.
		trunk_paused = false
		_trunk_feedback.paused_for_trunk = false
		_ui_nodes.Paused.show()
		return
	_ui_nodes.Paused.show()
	GlobalTimer.pause_timer()
	GlobalTimerManager.pause_countdown()
	game_started = false
	pause_state = 0
	_freeze_targets(true)

func _resume_game() -> void:
	GlobalTimer.resume_timer()
	GlobalTimerManager.resume_countdown()
	_freeze_targets(false)
	game_started = true
	pause_state = 1

func show_game_over() -> void:
	_freeze_targets(true)
	MusicManager.play_sound_effect("game_over")
	if _exp:
		# The experiment ends the run, after the mocap has stopped if it is still going;
		# rows go on being logged meanwhile.
		game_started = false
		GlobalTimer.stop_timer()
		_exp.game_over(score)
		return
	var top_score = ScoreManager.get_top_score(patient_id, game_name)
	_ui_nodes.highscore.text = str(top_score)
	_ui_nodes.current_score.text = "CURRENT SCORE - " + str(score)
	GlobalTimer.stop_timer()
	game_started = false
	SessionLog.end_trial()
	save_final_score_to_log(score)
	_ui_nodes.game_over_label.show()
	_ui_nodes.color_rect.visible = true

func _on_logout_button_pressed() -> void:
	if _exp:
		_leave_experiment()
		return
	GlobalTimerManager.remove_timer_selector_from_game()
	get_tree().paused = false
	get_tree().change_scene_to_file("res://Main_screen/Scenes/select_game.tscn")

func _on_retry_button_pressed() -> void:
	_flock.reset()
	if is_instance_valid(current_apple):
		current_apple.queue_free()
		current_apple = null
	get_tree().paused = false
	_ui_nodes.color_rect.visible = false
	_ui_nodes.game_over_label.hide()
	score = 0
	_ui_nodes.score_board.text = "0"

	# Reset game state
	game_started = false
	countdown_active = false

	# Show timer selector for retry
	GlobalTimerManager.show_timer_selector_for_retry()

func save_final_score_to_log(score: int) -> void:
	if game_log_file:
		game_log_file.store_line("Final Score: " + str(score))
		game_log_file.flush()

const LOG_COLUMNS := [
	'epochtime', 'score', 'status', 'error_status', 'packets',
	'device_x', 'device_y', 'device_z', 'target_x', 'target_y', 'target_z',
	'player_x', 'player_y', 'player_z', 'pause_state',
	'trunk_state', 'trunk_level', 'trunk_flexion', 'trunk_lateral', 'trunk_axial',
	'trunk_how', 'trunk_rms_mm', 'trunk_frac', 'trunk_pts', 'trunk_mask_px', 'trunk_held', 'trunk_doubt'
]

func _setup_game_logging() -> void:
	# Mouse testing must not create or upload a patient therapy session.
	if debug_mode:
		return
	if not log_timer.timeout.is_connected(_on_log_timer_timeout):
		log_timer.timeout.connect(_on_log_timer_timeout)

	if _exp:
		# The run's own file, not a patient's; the recording starts with play.
		game_log_file = _exp.open_log(PackedStringArray(LOG_COLUMNS))
		_exp.begin()
		return
	# Use the updated game_name variable
	game_log_file = Manager.create_game_log_file(game_name, patient_id)
	if game_log_file == null:
		return
	game_log_file.store_csv_line(PackedStringArray(LOG_COLUMNS))

func _on_log_timer_timeout() -> void:
	if game_log_file and not debug_mode:
		game_log_file.store_csv_line(PackedStringArray([
			Time.get_unix_time_from_system(), score, status, error_status, packets,
			str(pos_x), str(pos_y), str(pos_z), str(target_x), str(target_y), str(target_z),
			str(game_x), str(game_y), str(game_z), str(pause_state),
		] + _trunk_columns()))

## Trunk state/level/angles and this frame's quality for the raw log; empty while the tracker sends none.
static func _trunk_columns() -> Array:
	if not TrunkMonitor.available():
		return ["", "", "", "", "", "", "", "", "", "", "", ""]
	var a := TrunkMonitor.angles
	return [str(TrunkMonitor.state), str(TrunkMonitor.level),
		"%.2f" % a.x, "%.2f" % a.y, "%.2f" % a.z,
		TrunkMonitor.q_how, "%.1f" % TrunkMonitor.q_rms_mm, "%.2f" % TrunkMonitor.q_frac,
		str(TrunkMonitor.raw_pts), str(TrunkMonitor.mask_px), str(int(TrunkMonitor.held)), TrunkMonitor.doubt]

func _on_reach_game_ready() -> void:
	rom_x_top = 20
	rom_y_top = 20
	rom_x_bot = 1100
	rom_y_bot = 600
	rom_y_bot = min(rom_y_bot, 600)
	rom_x_bot = min(rom_x_bot, 1100)

func _on_apple_removed() -> void:
	current_apple = null

func _on_apple_missed() -> void:
	status = "missed"
	SessionLog.miss()

func _on_apple_eaten() -> void:
	if _trunk_compensating():
		# Reached by leaning, not by the arm: no score.
		status = "compensated"
		return
	SessionLog.hit()
	if score < max_score:
		score += 1
		_ui_nodes.score_board.text = str(score)
		GameFx.pop(_ui_nodes.score_board.get_parent())
		if _audio_nodes.apple_sound:
			_audio_nodes.apple_sound.play()

	if not _exp:
		ScoreManager.update_top_score(patient_id, game_name, score)
		_update_top_score_display()
	status = "captured"

func _notification(what) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if game_log_file:
			game_log_file.close()
		GlobalTimerManager.remove_timer_selector_from_game()

func _on_area_2d_area_entered(area) -> void:
	_sprite_nodes.anim.play(&"jet")

func _on_area_2d_area_exited(area) -> void:
	_sprite_nodes.anim.play(&"jet")

func _on_zero_pressed() -> void:
	zero_offset = network_position

func _on_button_pressed() -> void:
	GlobalScript.request_quit()

func _on_logout_pressed() -> void:
	if _exp:
		_leave_experiment()
		return
	MusicManager.play_music("main")
	GlobalTimer.stop_timer()
	GlobalSignals.enable_game_buttons(true)
	GlobalTimerManager.remove_timer_selector_from_game()
	if not is_3d_mode:
		get_tree().change_scene_to_file("res://Main_screen/Scenes/select_game.tscn")
	else:
		get_tree().change_scene_to_file("res://Main_screen/Scenes/3d_games.tscn")

# Legacy functions maintained for compatibility
func apple_function() -> void:
	if score <= max_score:
		if _audio_nodes.apple_sound != null:
			score += 1
			_ui_nodes.score_board.text = str(score)

func _on_reach_game_tree_exiting() -> void:
	GlobalTimerManager.remove_timer_selector_from_game()

func _on_udp_timer_timeout() -> void:
	pass

func _on_dummy_timeout() -> void:
	pass

func _set_2d_mode() -> void:
	is_3d_mode = false
	_update_game_name()
	_ui_nodes.bg_2d.visible = true
	_ui_nodes.bg_3d.visible = false

func _set_3d_mode() -> void:
	is_3d_mode = true
	_update_game_name()
	_ui_nodes.bg_3d.visible = true
	_ui_nodes.bg_2d.visible = false

func _update_game_name() -> void:
	game_name = "RandomReach3D" if is_3d_mode else "RandomReach"


## Left before the time was up: the experiment's run ends, back to its setup screen.
func _leave_experiment() -> void:
	game_started = false
	GlobalTimer.stop_timer()
	game_log_file = null
	get_tree().paused = false
	_exp.finish(score, "stopped")

## The experiment plays once for its time: no restart from the pause menu.
func _panel_hide_restart() -> void:
	var restart := get_node_or_null("../Paused/Restart")
	if restart:
		restart.hide()

func _on_home_pressed() -> void:
	if _exp:
		_leave_experiment()
		return
	get_tree().change_scene_to_file("res://Main_screen/Scenes/select_game.tscn")

func _on_resume_pressed() -> void:
	_ui_nodes.Paused.hide()
	_resume_game()

func _on_restart_pressed() -> void:
	_ui_nodes.Paused.hide()
	_on_retry_button_pressed()
