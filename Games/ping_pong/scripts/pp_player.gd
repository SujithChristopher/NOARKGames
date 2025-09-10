extends CharacterBody2D

# Constants
const LOG_INTERVAL: float = 0.02
const POSITION_LERP_SPEED: float = 0.8
const PLAYER_Y_POSITION: float = 610.0
const GAME_NAME: String = "PingPong"

# Movement and positioning
var network_position: Vector2 = Vector2.ZERO
var zero_offset: Vector2 = Vector2.ZERO
var centre: Vector2 = Vector2(120, 200)

# Game state
var game_started: bool = false
var is_paused: bool = false
var pause_state: int = 1
var score: int = 0

# Timer and countdown
var countdown_time: int = 0
var countdown_active: bool = false
var current_time: int = 0

# Position tracking
var pos_x: float
var pos_y: float
var pos_z: float
var target_x: float
var target_y: float
var target_z: float = 0.0
var game_x: float
var game_y: float = 0.0
var game_z: float
var ball_x: float
var ball_y: float
var ball_z: float

# Game logging
var status: String = ""
var error_status: String = ""
var packets: String = ""
var game_log_file

# Settings
@onready var adapt_toggle: bool = false
@onready var debug_mode = DebugSettings.debug_mode

# Timers
@onready var log_timer: Timer = Timer.new()

# Game objects
@onready var ball: Node = $"../Ball"

# UI Labels
@onready var countdown_display: Label = $"../CanvasLayer/CountdownLabel"
@onready var top_score_label: Label = $"../CanvasLayer/TextureRect/TopScoreLabel"
@onready var warning_window: Window = $"../Window"
@onready var adapt_prom: Button = $"../AdaptRom"

# UI Panels
@onready var game_over_label: Control = $"../CanvasLayer/GameOverLabel"

# UI Buttons - organized by functionality
@onready var _game_buttons: Dictionary = {
	"pause": $"../CanvasLayer/PauseButton",
	"logout": $"../CanvasLayer/GameOverLabel/LogoutButton",
	"retry": $"../CanvasLayer/GameOverLabel/RetryButton"
}

func _ready() -> void:
	_setup_timers()
	_setup_ui()
	_connect_signals()
	_initialize_game_state()
	_setup_logging()
	_update_top_score_display()
	_setup_global_timer()

func _setup_global_timer() -> void:
	# Add the global timer selector to this game
	GlobalTimerManager.add_timer_selector_to_game(self)
	
	# Connect to global timer signals
	GlobalTimerManager.countdown_finished.connect(_on_global_countdown_finished)
	GlobalTimerManager.countdown_updated.connect(_on_global_countdown_updated)

func _setup_timers() -> void:
	log_timer.wait_time = LOG_INTERVAL
	log_timer.autostart = true
	log_timer.timeout.connect(_on_log_timer_timeout)
	add_child(log_timer)

func _setup_ui() -> void:
	game_over_label.visible = false
	game_over_label.hide()
	countdown_display.visible = false

func _connect_signals() -> void:
	# Game control buttons
	_game_buttons.pause.pressed.connect(_on_pause_button_pressed)
	_game_buttons.logout.pressed.connect(_on_logout_button_pressed)
	_game_buttons.retry.pressed.connect(_on_retry_button_pressed)

func _initialize_game_state() -> void:
	game_started = false  # Changed to false - wait for timer selection
	is_paused = false
	pause_state = 1

func _setup_logging() -> void:
	GlobalScript.start_new_session_if_needed()

func _update_top_score_display() -> void:
	var top_score = ScoreManager.get_top_score(GlobalSignals.current_patient_id, GAME_NAME)
	top_score_label.text = str(top_score)

# Global Timer Callbacks
func _on_global_timer_play_pressed(time: int) -> void:
	GlobalTimer.start_timer()
	game_started = true
	countdown_time = time
	_start_game_with_timer(time)
	_setup_game_logging()

func _on_global_timer_close_pressed() -> void:
	game_started = true
	countdown_display.hide()
	_start_game_without_timer()
	_setup_game_logging()

func _start_game_with_timer(time: int) -> void:
	countdown_active = true
	countdown_time = time
	countdown_display.visible = true
	ball.game_started = true
	GlobalTimerManager.start_countdown_with_time(time)
	
func _start_game_without_timer() -> void:
	countdown_active = false
	ball.game_started = true
	GlobalTimer.start_timer()
	GlobalTimerManager.start_game_without_timer()

func _on_global_countdown_finished() -> void:
	show_game_over()

func _on_global_countdown_updated(time_left: int) -> void:
	countdown_time = time_left
	countdown_display.text = GlobalTimerManager.get_countdown_display_text()

func _physics_process(delta: float) -> void:
	if not game_started:
		return
	
	_update_network_position()
	_update_player_position()
	_update_game_data()

func _update_network_position() -> void:
	if debug_mode:
		network_position = get_global_mouse_position()
	elif adapt_toggle:
		network_position = GlobalScript.scaled_network_position
	else:
		network_position = GlobalScript.network_position

func _update_player_position() -> void:
	if network_position != Vector2.ZERO:
		network_position = network_position - zero_offset + centre
		position = position.lerp(network_position, POSITION_LERP_SPEED)
	
	position.y = PLAYER_Y_POSITION

func _update_game_data() -> void:
	if not ball.game_started:
		return
	
	# Update position data
	pos_x = GlobalScript.raw_x
	pos_y = GlobalScript.raw_y
	pos_z = GlobalScript.raw_z
	
	# Update target data
	target_x = (GlobalSignals.ball_position.x - GlobalScript.X_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_X
	target_y = (GlobalSignals.ball_position.y - GlobalScript.Y_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_Z
	ball_x = target_x
	ball_y = target_y
	ball_z = target_z
	
	# Update game state
	status = ball.status
	score = ball.player_score
	error_status = "null"
	packets = "null"
	
	# Update player position data
	_calculate_player_game_position()

func _calculate_player_game_position() -> void:
	if not adapt_toggle:
		game_x = (position.x - GlobalScript.X_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_X
		game_z = (position.y - GlobalScript.Y_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_Z
	else:
		game_x = (position.x - GlobalScript.X_SCREEN_OFFSET) / (GlobalScript.PLAYER_POS_SCALER_X * GlobalSignals.global_scalar_x)
		game_z = (position.y - GlobalScript.Y_SCREEN_OFFSET) / (GlobalScript.PLAYER_POS_SCALER_Y * GlobalSignals.global_scalar_y)

func _on_pause_button_pressed() -> void:
	if is_paused:
		_resume_game()
	else:
		_pause_game()
	is_paused = !is_paused

func _pause_game() -> void:
	GlobalTimer.pause_timer()
	GlobalTimerManager.pause_countdown()
	ball.game_started = false
	_game_buttons.pause.text = "Resume"
	pause_state = 0

func _resume_game() -> void:
	GlobalTimer.resume_timer()
	GlobalTimerManager.resume_countdown()
	ball.game_started = true
	_game_buttons.pause.text = "Pause"
	pause_state = 1

func show_game_over() -> void:
	print("Game Over!")
	ball.game_started = false
	save_final_score_to_log(GlobalScript.current_score)
	GlobalTimer.stop_timer()
	game_over_label.visible = true

func _on_logout_button_pressed() -> void:
	GlobalTimerManager.remove_timer_selector_from_game()
	get_tree().paused = false
	get_tree().change_scene_to_file("res://Main_screen/Scenes/select_game.tscn")

func _on_retry_button_pressed() -> void:
	get_tree().paused = false
	game_over_label.hide()
	
	# Reset game state
	game_started = false
	countdown_active = false
	
	# Show timer selector for retry
	GlobalTimerManager.show_timer_selector_for_retry()

func save_final_score_to_log(player_score: int) -> void:
	if game_log_file:
		game_log_file.store_line("Final Score: " + str(player_score))
		game_log_file.flush()

func _setup_game_logging() -> void:
	game_log_file = Manager.create_game_log_file(GAME_NAME, GlobalSignals.current_patient_id)
	game_log_file.store_csv_line(PackedStringArray([
		'epochtime', 'score', 'status', 'error_status', 'packets',
		'device_x', 'device_y', 'device_z', 'target_x', 'target_y', 'target_z',
		'player_x', 'player_y', 'player_z', 'ball_x', 'ball_y', 'ball_z', 'pause_state'
	]))

func _on_log_timer_timeout() -> void:
	if game_log_file:
		game_log_file.store_csv_line(PackedStringArray([
			Time.get_unix_time_from_system(), str(score), status, error_status, packets,
			str(pos_x), str(pos_y), str(pos_z), str(target_x), str(target_y), str(target_z),
			str(game_x), str(game_y), str(game_z), str(ball_x), str(ball_y), str(ball_z), str(pause_state)
		]))

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		print('closed')
		if game_log_file:
			game_log_file.close()
		GlobalTimerManager.remove_timer_selector_from_game()
		get_tree().quit()

func _on_logout_pressed() -> void:
	GlobalTimer.stop_timer()
	GlobalTimerManager.remove_timer_selector_from_game()
	get_tree().change_scene_to_file("res://Main_screen/Scenes/select_game.tscn")

func _on_adapt_rom_toggled(toggled_on: bool) -> void:
	if toggled_on and not GlobalSignals.assessment_done:
		adapt_prom.button_pressed = false
		warning_window.visible = true
		return
	adapt_toggle = toggled_on

func _on_do_asses_pressed() -> void:
	get_tree().change_scene_to_file("res://Games/assessment/workspace.tscn")

func _on_close_asses_pressed() -> void:
	warning_window.visible = false
