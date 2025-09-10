extends Control

# Constants
const SCROLL_SPEED: float = 7.0
const PIPE_DELAY: int = 50
const PIPE_RANGE: int = 180
const TIMER_DELAY: int = 2
const LOG_INTERVAL: float = 0.02
const INITIAL_HEALTH: int = 3  

# Signals
signal game_over_signal
signal flash_animation
signal plane_crashed
signal game_started

# Preloaded resources
@onready var pipe_scene = preload("res://Games/flappy_bird/Scenes/pipe.tscn")

# Node references - organized by functionality
@onready var _timer_nodes = {
	"pipe_timer": $PipeTimer,
	"log_timer": Timer.new()
}

@onready var _player_nodes = {
	"pilot": $pilot
}

@onready var _ui_nodes = {
	"score_label": $Score,
	"countdown_display": $CanvasLayer/CountdownTimer/CountdownLabel,
	"game_over_label": $CanvasLayer/GameOverLabel,
	"top_score_label": $CanvasLayer/TextureRect/TopScoreLabel,
	"warning_window": $Window
}

@onready var _panel_nodes = {
	"game_over_scene": $GameOver,
	"pause_button": $CanvasLayer/PauseButton
}

@onready var _button_nodes = {
	"logout_button": $CanvasLayer/GameOverLabel/LogoutButton,
	"retry_button": $CanvasLayer/GameOverLabel/RetryButton,
	"do_assess": $Window/HBoxContainer/do_asses,
	"close_assess": $Window/HBoxContainer/close_asses,
	"adapt_prom": $AdaptRom
}

@onready var _health_nodes = {
	"heart_array": [$Health/heart1, $Health/heart2, $Health/heart3],
	"ground": $ground
}

# Game state variables
var game_running: bool = false
var game_over: bool = false
var scroll: float = 0.0
var score: int = 0
var screen_size: Vector2i
var ground_height: int
var pipes: Array = []
var health: int = INITIAL_HEALTH

# Timer and countdown variables
var countdown_time: int = 0
var countdown_active: bool = false
var is_paused: bool = false
var is_3d_mode := false
var pause_state: int = 1

# Position tracking variables
var pos_x: float
var pos_y: float
var pos_z: float
var target_x: float
var target_y: float
var target_z: float
var game_x: float
var game_y: float = 0.0
var game_z: float

# Game logging variables
var status: String = "idle"
var error_status: String = "null"
var packets: String = "null"
var game_log_file
var pilot_node: CharacterBody2D
var game_name: String = "FlyThrough"  # Dynamic game name that changes with mode

func _ready() -> void:
	_initialize_game_state()
	_setup_screen_and_ground()
	_setup_timers()
	_setup_ui()
	_connect_signals()
	_setup_logging()
	_initialize_scoring()
	_auto_select_mode()
	_setup_global_timer()

func _setup_global_timer() -> void:
	# Add the global timer selector to this game
	GlobalTimerManager.add_timer_selector_to_game(self)
	
	# Connect to global timer signals
	GlobalTimerManager.countdown_finished.connect(_on_global_countdown_finished)
	GlobalTimerManager.countdown_updated.connect(_on_global_countdown_updated)

func _initialize_game_state() -> void:
	game_running = false
	game_over = false
	score = 0
	scroll = 0.0
	health = INITIAL_HEALTH
	pilot_node = _player_nodes.pilot
	_initialize_health_display()

func _initialize_health_display() -> void:
	"""Initialize all hearts to show full health"""
	for i in range(_health_nodes.heart_array.size()):
		if _health_nodes.heart_array[i] != null:
			_health_nodes.heart_array[i].animation = "default"
			_health_nodes.heart_array[i].visible = true

func _setup_screen_and_ground() -> void:
	screen_size = get_window().size
	ground_height = _health_nodes.ground.get_node("Sprite2D").texture.get_height()
	_health_nodes.ground.position.x = screen_size.x / 2

func _setup_timers() -> void:
	_timer_nodes.pipe_timer.wait_time = TIMER_DELAY / 0.5
	_timer_nodes.log_timer.wait_time = LOG_INTERVAL
	_timer_nodes.log_timer.autostart = true
	add_child(_timer_nodes.log_timer)

func _setup_ui() -> void:
	_ui_nodes.game_over_label.visible = false
	_ui_nodes.game_over_label.hide()
	_ui_nodes.countdown_display.visible = false
	_update_top_score_display()

func _connect_signals() -> void:
	# Button connections
	_button_nodes.logout_button.pressed.connect(_on_logout_button_pressed)
	_button_nodes.retry_button.pressed.connect(_on_retry_button_pressed)
	_panel_nodes.pause_button.pressed.connect(_on_PauseButton_pressed)
	
	# Timer connections
	#_timer_nodes.pipe_timer.timeout.connect(_on_pipe_timer_timeout)
	
	# Game connections
	_panel_nodes.game_over_scene.restart_games.connect(restart_game)

func _setup_logging() -> void:
	GlobalScript.start_new_session_if_needed()

func _initialize_scoring() -> void:
	_update_top_score_display()

func _update_top_score_display() -> void:
	var top_score = ScoreManager.get_top_score(GlobalSignals.current_patient_id, game_name)
	_ui_nodes.top_score_label.text = str(top_score)

func _update_game_name() -> void:
	"""Update game name based on current mode for proper file saving"""
	game_name = "FlyThrough3D" if is_3d_mode else "FlyThrough"

# Global Timer Callbacks
func _on_global_timer_play_pressed(time: int) -> void:
	GlobalTimer.start_timer()
	game_running = true
	countdown_time = time
	_start_game_with_timer(time)
	_setup_game_logging()

func _on_global_timer_close_pressed() -> void:
	game_running = true
	_ui_nodes.countdown_display.hide()
	_start_game_without_timer()
	_setup_game_logging()

func _start_game_with_timer(time: int) -> void:
	countdown_active = true
	countdown_time = time
	_ui_nodes.countdown_display.visible = true
	GlobalTimerManager.start_countdown_with_time(time)
	_timer_nodes.pipe_timer.start()
	
func _start_game_without_timer() -> void:
	countdown_active = false
	GlobalTimer.start_timer()
	GlobalTimerManager.start_game_without_timer()
	_timer_nodes.pipe_timer.start()

func _on_global_countdown_finished() -> void:
	show_game_over()

func _on_global_countdown_updated(time_left: int) -> void:
	countdown_time = time_left
	_ui_nodes.countdown_display.text = GlobalTimerManager.get_countdown_display_text()

func _setup_game_logging() -> void:
	_timer_nodes.log_timer.timeout.connect(_on_log_timer_timeout)
	# Use the dynamic game_name that changes with mode
	game_log_file = Manager.create_game_log_file(game_name, GlobalSignals.current_patient_id)
	game_log_file.store_csv_line(PackedStringArray([
		'epochtime', 'score', 'status', 'error_status', 'packets',
		'device_x', 'device_y', 'device_z', 'target_x', 'target_y', 'target_z',
		'player_x', 'player_y', 'player_z', 'pause_state'
	]))

func _on_PauseButton_pressed() -> void:
	if is_paused:
		_resume_game()
	else:
		_pause_game()
	is_paused = !is_paused

func _pause_game() -> void:
	GlobalTimer.pause_timer()
	GlobalTimerManager.pause_countdown()
	game_running = false
	_panel_nodes.pause_button.text = "Resume"
	pause_state = 0

func _resume_game() -> void:
	GlobalTimer.resume_timer()
	GlobalTimerManager.resume_countdown()
	game_running = true
	_panel_nodes.pause_button.text = "Pause"
	pause_state = 1

func show_game_over() -> void:
	print("Game Over!")
	game_running = false
	save_final_score_to_log(score)
	GlobalTimer.stop_timer()
	_ui_nodes.game_over_label.visible = true
	
func _on_logout_button_pressed() -> void:
	GlobalTimerManager.remove_timer_selector_from_game()
	get_tree().paused = false
	get_tree().change_scene_to_file("res://Main_screen/Scenes/select_game.tscn")

func _on_retry_button_pressed() -> void:
	get_tree().paused = false
	_ui_nodes.game_over_label.hide()
	score = 0
	_ui_nodes.score_label.text = "0"
	health = INITIAL_HEALTH
	_reset_health_display()
	
	# Clear existing pipes
	for pipe in pipes:
		pipe.queue_free()
	pipes.clear()
	
	# Reset game state
	game_running = false
	countdown_active = false
	
	# Show timer selector for retry
	GlobalTimerManager.show_timer_selector_for_retry()

func _process(delta: float) -> void:
	if not game_running:
		return
	
	_update_game_status()
	_update_player_position()
	_update_scroll_and_pipes()
	_update_position_tracking()

func _update_game_status() -> void:
	if status not in ["collided", "reached", "restarting"]:
		status = "moving"

func _update_player_position() -> void:
	if pilot_node:
		if not pilot_node.adapt_toggle:
			# Standard mode calculations
			game_x = (pilot_node.position.x - GlobalScript.X_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_X
			
			if is_3d_mode:
				# 3D mode: calculate game_y from screen Y position
				game_y = (pilot_node.position.y - GlobalScript.Y_SCREEN_OFFSET3D) / GlobalScript.PLAYER3D_POS_SCALER_Y
				game_z = 0.0  # Z not used in 3D screen mapping
			else:
				# 2D mode: Y is always 0, Z calculated from screen Y position
				game_y = 0.0
				game_z = (pilot_node.position.y - GlobalScript.Y_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_Z
		else:
			# Adaptive mode calculations
			game_x = (pilot_node.position.x - GlobalScript.X_SCREEN_OFFSET) / (GlobalScript.PLAYER_POS_SCALER_X * GlobalSignals.global_scalar_x)
			
			if is_3d_mode:
				# 3D adaptive mode: calculate game_y with scaling
				game_y = (pilot_node.position.y - GlobalScript.Y_SCREEN_OFFSET3D) / (GlobalScript.PLAYER3D_POS_SCALER_Y * GlobalSignals.global_scalar_y)
				game_z = 0.0
			else:
				# 2D adaptive mode: Y is 0, Z calculated with scaling
				game_y = 0.0
				game_z = (pilot_node.position.y - GlobalScript.Y_SCREEN_OFFSET) / (GlobalScript.PLAYER_POS_SCALER_Z * GlobalSignals.global_scalar_y)

func _update_scroll_and_pipes() -> void:
	scroll += SCROLL_SPEED
	if scroll >= screen_size.x / 5:
		scroll = 0
	
	_health_nodes.ground.position.x = -scroll
	
	for pipe in pipes:
		pipe.position.x -= SCROLL_SPEED

func _update_position_tracking() -> void:
	pos_x = GlobalScript.raw_x
	pos_y = GlobalScript.raw_y
	pos_z = GlobalScript.raw_z

func stop_game() -> void:
	_timer_nodes.pipe_timer.stop()
	_panel_nodes.game_over_scene.show()
	game_running = false
	game_over = true

func _on_pipe_timer_timeout() -> void:
	if game_running:
		generate_pipe()

func generate_pipe() -> void:
	if not game_running:
		return
	
	var pipe = pipe_scene.instantiate()
	_setup_pipe_position(pipe)
	_setup_pipe_signals(pipe)
	add_child(pipe)
	pipes.append(pipe)

func _setup_pipe_position(pipe: Node) -> void:
	pipe.position.x = screen_size.x / 1.5 + PIPE_DELAY
	pipe.position.y = 400 + randi_range(-PIPE_RANGE, PIPE_RANGE)
	
	# Update target position based on mode - similar to RandomReach logic
	target_x = (pipe.position.x - GlobalScript.X_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_X
	
	if is_3d_mode:
		# 3D mode: pipe Y position maps to target_y
		target_y = (pipe.position.y - GlobalScript.Y_SCREEN_OFFSET3D) / GlobalScript.PLAYER3D_POS_SCALER_Y
		target_z = 0.0
	else:
		# 2D mode: pipe Y position maps to target_z, target_y is 0
		target_y = 0.0
		target_z = (pipe.position.y - GlobalScript.Y_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_Z

func _setup_pipe_signals(pipe: Node) -> void:
	pipe.hit.connect(pipe_hit)
	pipe.scored.connect(scored)

func restart_game() -> void:
	game_running = true
	game_over = false
	score = 0
	health = INITIAL_HEALTH
	_reset_health_display()
	_timer_nodes.pipe_timer.start()
	game_started.emit()
	_ui_nodes.score_label.text = str(score)

func _reset_health_display() -> void:
	"""Reset all hearts to show full health"""
	for i in range(_health_nodes.heart_array.size()):
		if _health_nodes.heart_array[i] != null:
			_health_nodes.heart_array[i].animation = "default"
			_health_nodes.heart_array[i].visible = true

func _update_health_display() -> void:
	"""Update the visual representation of health"""
	for i in range(_health_nodes.heart_array.size()):
		if _health_nodes.heart_array[i] != null:
			if i < health:
				# Show healthy heart
				_health_nodes.heart_array[i].animation = "default"
				_health_nodes.heart_array[i].visible = true
			else:
				# Show dead heart
				_health_nodes.heart_array[i].animation = "Dead"
				_health_nodes.heart_array[i].visible = true

func pipe_hit() -> void:
	if health > 0:
		health -= 1
		_update_health_display()
		flash_animation.emit()
		
		if health <= 0:
			_handle_game_over()
		else:
			status = "collided"

func _handle_game_over() -> void:
	game_over_signal.emit()
	status = "restarting"
	plane_crashed.emit()
	stop_game()

func scored() -> void:
	score += 1
	# Use the dynamic game_name for score tracking
	ScoreManager.update_top_score(GlobalSignals.current_patient_id, game_name, score)
	_update_top_score_display()
	status = "reached"
	_ui_nodes.score_label.text = str(score)

func _on_logout_pressed() -> void:
	GlobalTimer.stop_timer()
	GlobalTimerManager.remove_timer_selector_from_game()
	if not is_3d_mode:
		get_tree().change_scene_to_file("res://Main_screen/Scenes/select_game.tscn")
	else:
		get_tree().change_scene_to_file("res://Main_screen/Scenes/3d_games.tscn")

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if game_log_file:
			game_log_file.close()
		GlobalTimerManager.remove_timer_selector_from_game()

func save_final_score_to_log(score: int) -> void:
	if game_log_file:
		game_log_file.store_line("Final Score: " + str(score))
		game_log_file.flush()

func _on_log_timer_timeout() -> void:
	if game_log_file:
		game_log_file.store_csv_line(PackedStringArray([
			Time.get_unix_time_from_system(), score, status, error_status, packets,
			str(pos_x), str(pos_y), str(pos_z), str(target_x), str(target_y), str(target_z),
			str(game_x), str(game_y), str(game_z), str(pause_state)
		]))
		
func _auto_select_mode() -> void:
	# Automatically set mode based on GlobalSignals
	if GlobalSignals.selected_game_mode == "3D":
		_set_3d_mode()
	else:
		_set_2d_mode()

# Replace your existing mode functions with these:
func _set_2d_mode() -> void:
	is_3d_mode = false
	_update_game_name()  # Update game name for file saving
	print("2D mode selected - game_name:", game_name)

func _set_3d_mode() -> void:
	is_3d_mode = true
	_update_game_name()  # Update game name for file saving
	print("3D mode selected - game_name:", game_name)
	
func _on_do_asses_pressed() -> void:
	get_tree().change_scene_to_file("res://Games/assessment/workspace.tscn")

func _on_close_asses_pressed() -> void:
	_ui_nodes.warning_window.visible = false
