extends CharacterBody2D

# Movement configuration
@export var movement_smoothing: float = 1.0
@export var debug_mode = DebugSettings.debug_mode
@export var use_scaled_position: bool = false
@export var ground_level: float = 577
@export var max_score = 500

# Movement bounds
const MIN_BOUNDS = Vector2(44, 40)
const MAX_BOUNDS = Vector2(1105, 577)

# Timer constants
const LOG_INTERVAL = 0.02
const MAX_COUNTDOWN_TIME = 2700
const ONE_MINUTE = 60
const FIVE_MINUTES = 300

# Movement variables
var network_position = Vector2.ZERO
var zero_offset = Vector2.ZERO
var previous_position = Vector2.ZERO
var last_movement_direction = 0

# Game state variables
var game_started: bool = false
var score = 0
var game_over = false
var countdown_time = 0
var countdown_active = false
var current_time := 0
var is_paused = false
var pause_state = 1
var adapt_toggle: bool = false


# Status tracking variables
var coin_collected_timer = 0.0
var coin_missed_timer = 0.0
var status_hold_duration = 0.5  # Hold special status for 0.5 seconds

# Position tracking variables
var pos_x: float
var pos_y: float
var pos_z: float
var game_x: float
var game_y = 0.0
var game_z: float

# Coin tracking variables - NEW - Direct node reference
@onready var coin_node: Area2D = $"../Coin"  # Direct path to your coin
var coin_target_x: float = 0.0
var coin_target_z: float = 0.0

# Game logging variables
var status := "moving"
var error_status = "null"
var packets = "null"
var patient_id = GlobalSignals.current_patient_id
var game_name = "Jumpify"
var game_log_file
var log_timer := Timer.new()

# Node references - UI elements
@onready var _ui_nodes = {
	"score_board": %ScoreLabel,
	"countdown_display": $"../UserInterface/GameUI/CountdownLabel",
	"game_over_label": $"../UserInterface/GameUI/ColorRect/GameOverLabel",
	"time_label": $"../UserInterface/GameUI/TimerSelectorPanel/TimeSelector",
	"top_score_label": $"../UserInterface/GameUI/TopScoreLabel",
	"color_rect": $"../UserInterface/GameUI/ColorRect",
	"warning_window": $"../UserInterface/GameUI/Window"
}

@onready var _timer_nodes = {
	"countdown_timer": $"../UserInterface/GameUI/CountdownTimer"
}

@onready var _panel_nodes = {
	"timer_panel": $"../UserInterface/GameUI/TimerSelectorPanel",
	"pause_button": $"../UserInterface/GameUI/PauseButton"
}

@onready var _button_nodes = {
	"play_button": $"../UserInterface/GameUI/TimerSelectorPanel/VBoxContainer/HBoxContainer/PlayButton",
	"close_button": $"../UserInterface/GameUI/TimerSelectorPanel/VBoxContainer/HBoxContainer/CloseButton",
	"logout_button": $"../UserInterface/GameUI/ColorRect/GameOverLabel/LogoutButton",
	"retry_button": $"../UserInterface/GameUI/ColorRect/GameOverLabel/RetryButton",
	"add_one_btn": $"../UserInterface/GameUI/TimerSelectorPanel/HBoxContainer/AddOneButton",
	"add_five_btn": $"../UserInterface/GameUI/TimerSelectorPanel/HBoxContainer/AddFiveButton",
	"sub_one_btn": $"../UserInterface/GameUI/TimerSelectorPanel/HBoxContainer2/SubOneButton",
	"sub_five_btn": $"../UserInterface/GameUI/TimerSelectorPanel/HBoxContainer2/SubFiveButton",
	"close_assess": $"../UserInterface/GameUI/Window/HBoxContainer/close_asses",
	"do_assess": $"../UserInterface/GameUI/Window/HBoxContainer/do_asses",
	"adapt_prom": $"../UserInterface/GameUI/AdaptProm"
}

# Original node references
@onready var player_sprite = $AnimatedSprite2D  
@onready var particle_trails = $ParticleTrails

# Debug and config
var json = JSON.new()
var path = "res://debug.json"
var debug

func _ready() -> void:
	_load_debug_config()
	_setup_timers()
	_setup_ui()
	_connect_signals()
	_initialize_game_state()
	network_position = Vector2.ZERO
	previous_position = position

func _load_debug_config() -> void:
	debug = JSON.parse_string(FileAccess.get_file_as_string(path))['debug']

func _setup_timers() -> void:
	log_timer.wait_time = LOG_INTERVAL
	log_timer.autostart = true
	add_child(log_timer)

func _setup_ui() -> void:
	_panel_nodes.timer_panel.visible = true
	_ui_nodes.color_rect.visible = false
	_ui_nodes.game_over_label.visible = false
	_ui_nodes.game_over_label.hide()
	_ui_nodes.color_rect.hide()
	_update_top_score_display()
	update_label()
	
	# Initialize score display
	_ui_nodes.score_board.text = "Score: 0"

func _connect_signals() -> void:
	# Timer connections
	_timer_nodes.countdown_timer.timeout.connect(_on_countdown_timer_timeout)
	
	# Connect coin signal - now using direct node reference
	if coin_node:
		coin_node.coin_missed.connect(_on_coin_missed)
		print("✓ Coin signal connected successfully")
	else:
		print("✗ ERROR: Coin node not found - check the path in @onready var coin_node")
	
func _initialize_game_state() -> void:
	network_position = Vector2.ZERO
	GlobalScript.start_new_session_if_needed()

func _update_top_score_display() -> void:
	var top_score = ScoreManager.get_top_score(patient_id, game_name)
	_ui_nodes.top_score_label.text = "HIGH SCORE: " + str(top_score)

func _physics_process(delta):
	if game_started and not is_paused:
		_update_player_position()
		_update_animations()
		_update_status_based_on_timers(delta)
		_update_timer_display()
		_update_coin_target_position()  # NEW: Update coin target tracking

# NEW: Function to update coin target position for logging
func _update_coin_target_position() -> void:
	if coin_node and is_instance_valid(coin_node):
		var coin_pos = coin_node.position
		
		if not adapt_toggle:
			# Standard mode calculations - convert coin position to game coordinates
			coin_target_x = (coin_pos.x - GlobalScript.X_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_X
			coin_target_z = (coin_pos.y - GlobalScript.Y_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_Z
		else:
			# Adaptive mode calculations - convert coin position to game coordinates
			coin_target_x = (coin_pos.x - GlobalScript.X_SCREEN_OFFSET) / (GlobalScript.PLAYER_POS_SCALER_X * GlobalSignals.global_scalar_x)
			coin_target_z = (coin_pos.y - GlobalScript.Y_SCREEN_OFFSET) / (GlobalScript.PLAYER_POS_SCALER_Z * GlobalSignals.global_scalar_y)
	else:
		# If coin node is invalid, use player position as fallback
		coin_target_x = game_x
		coin_target_z = game_z

func _update_player_position() -> void:
	# Store previous position for animation calculations
	previous_position = position
	
	# Get position from different sources based on mode
	if debug_mode:
		network_position = get_global_mouse_position()
	elif adapt_toggle:
		network_position = GlobalScript.scaled_network_position3D
	else:
		network_position = GlobalScript.network_position3D
	
	# Apply movement if we have valid network position
	if network_position != Vector2.ZERO:
		# Apply zero offset calibration
		network_position = network_position - zero_offset
		
		# Smooth movement to target position
		position = position.lerp(network_position, movement_smoothing)
		
		# Clamp position within bounds
		position.x = clamp(position.x, MIN_BOUNDS.x, MAX_BOUNDS.x)
		position.y = clamp(position.y, MIN_BOUNDS.y, MAX_BOUNDS.y)
		
		_update_position_tracking()

func _update_position_tracking() -> void:
	pos_x = GlobalScript.raw_x
	pos_y = GlobalScript.raw_y
	pos_z = GlobalScript.raw_z
	
	if not adapt_toggle:
		# Standard mode calculations for Jumpify (2D mode)
		game_x = (position.x - GlobalScript.X_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_X
		game_y = 0.0  # Jumpify is primarily 2D
		game_z = (position.y - GlobalScript.Y_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_Z
	else:
		# Adaptive mode calculations
		game_x = (position.x - GlobalScript.X_SCREEN_OFFSET) / (GlobalScript.PLAYER_POS_SCALER_X * GlobalSignals.global_scalar_x)
		game_y = 0.0
		game_z = (position.y - GlobalScript.Y_SCREEN_OFFSET) / (GlobalScript.PLAYER_POS_SCALER_Z * GlobalSignals.global_scalar_y)

# Handle status with timers - no coin.gd changes needed
func _update_status_based_on_timers(delta):
	# Update timers
	if coin_collected_timer > 0:
		coin_collected_timer -= delta
		status = "collected"
		return
	
	if coin_missed_timer > 0:
		coin_missed_timer -= delta
		status = "missed"
		return
	
	# Default to moving
	status = "moving"

func _update_animations():
	# Calculate movement based on position changes
	var position_diff = position - previous_position
	var is_moving = position_diff.length() > 1.0
	
	# Only update direction if movement is significant enough
	if abs(position_diff.x) > 2.0:
		last_movement_direction = sign(position_diff.x)
	
	# Animation logic - check if player is above ground level
	if position.y < ground_level - 10:
		if player_sprite:
			player_sprite.play("Jump")
		if particle_trails:
			particle_trails.emitting = false
	elif is_moving:
		if player_sprite:
			player_sprite.play("Walk")
		if particle_trails:
			particle_trails.emitting = true
	else:
		if player_sprite:
			player_sprite.play("Idle")
		if particle_trails:
			particle_trails.emitting = false
	
	# Flip sprite based on last significant movement direction
	if abs(last_movement_direction) > 0 and player_sprite:
		if last_movement_direction < 0:
			player_sprite.flip_h = true
		elif last_movement_direction > 0:
			player_sprite.flip_h = false

# Timer Selection Functions
func update_label() -> void:
	_ui_nodes.time_label.text = str(current_time) + " sec"
	var minutes = countdown_time / 60
	_ui_nodes.time_label.text = "%2d m" % [minutes]

func _modify_countdown_time(amount: int) -> void:
	countdown_time = clamp(countdown_time + amount, 0, MAX_COUNTDOWN_TIME)
	_update_time_display()
	_ui_nodes.countdown_display.visible = true
	update_label()

func _on_add_one_pressed() -> void:
	_modify_countdown_time(ONE_MINUTE)

func _on_add_five_pressed() -> void:
	_modify_countdown_time(FIVE_MINUTES)

func _on_sub_one_pressed() -> void:
	_modify_countdown_time(-ONE_MINUTE)

func _on_sub_five_pressed() -> void:
	_modify_countdown_time(-FIVE_MINUTES)

func _on_play_pressed() -> void:
	GlobalTimer.start_timer()
	_panel_nodes.timer_panel.visible = false
	game_started = true
	_hide_timer_buttons()
	start_game_with_timer()
	_setup_game_logging()

func _on_close_pressed() -> void:
	_panel_nodes.timer_panel.visible = false
	_hide_timer_buttons()
	game_started = true
	_ui_nodes.countdown_display.hide()
	start_game_without_timer()
	_setup_game_logging()

func _hide_timer_buttons() -> void:
	for button_name in ["add_one_btn", "add_five_btn", "sub_one_btn", "sub_five_btn"]:
		_button_nodes[button_name].hide()

func _show_timer_buttons() -> void:
	for button_name in ["add_one_btn", "add_five_btn", "sub_one_btn", "sub_five_btn"]:
		_button_nodes[button_name].show()

func start_game_with_timer() -> void:
	countdown_active = true
	_timer_nodes.countdown_timer.wait_time = 1.0
	_timer_nodes.countdown_timer.start()
	_update_time_display()
	
func start_game_without_timer() -> void:
	countdown_active = false
	GlobalTimer.start_timer()

func _on_countdown_timer_timeout() -> void:
	if countdown_active:
		countdown_time -= 1
		_ui_nodes.countdown_display.text = "%02d:%02d" % [countdown_time / 60, countdown_time % 60]
		_update_time_display()
		if countdown_time <= 0:
			countdown_active = false
			_timer_nodes.countdown_timer.stop()
			show_game_over()

func _update_time_display() -> void:
	var minutes = countdown_time / 60
	var seconds = countdown_time % 60
	_ui_nodes.countdown_display.text = "Time Left: %02d:%02d" % [minutes, seconds]

func _update_timer_display() -> void:
	if countdown_active:
		var minutes = countdown_time / 60
		var seconds = countdown_time % 60

# Pause System
func _on_pause_button_pressed() -> void:
	if is_paused:
		_resume_game()
	else:
		_pause_game()
	is_paused = !is_paused

func _pause_game() -> void:
	GlobalTimer.pause_timer()
	_timer_nodes.countdown_timer.stop()
	_panel_nodes.pause_button.text = "Resume"
	game_started = false
	pause_state = 0

func _resume_game() -> void:
	GlobalTimer.resume_timer()
	_timer_nodes.countdown_timer.start()
	_panel_nodes.pause_button.text = "Pause"
	game_started = true
	pause_state = 1

# Scoring System
func add_score(points: int = 1) -> void:
	if score < max_score:
		score += points
		_ui_nodes.score_board.text = "Score: " + str(score)
		
		# Update top score
		ScoreManager.update_top_score(patient_id, game_name, score)
		_update_top_score_display()

# Coin event handlers
func _on_coin_missed() -> void:
	coin_missed_timer = status_hold_duration
	print("🔴 COIN MISSED - timer started: ", coin_missed_timer)

func on_coin_collected() -> void:
	add_score(1)
	coin_collected_timer = status_hold_duration
	print("🟢 COIN COLLECTED - timer started: ", coin_collected_timer)

# Game Over and Restart
func show_game_over() -> void:
	GlobalTimer.stop_timer()
	game_started = false
	save_final_score_to_log(score)
	_ui_nodes.game_over_label.visible = true
	_ui_nodes.color_rect.visible = true
	
func _on_logout_button_pressed() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://Main_screen/Scenes/3d_games.tscn")

func _on_retry_button_pressed() -> void:
	get_tree().paused = false
	_ui_nodes.color_rect.visible = false
	_ui_nodes.game_over_label.hide()
	_panel_nodes.timer_panel.show()
	_show_timer_buttons()
	
	# Reset game state
	score = 0
	_ui_nodes.score_board.text = "Score: 0"
	game_over = false
	countdown_time = 0
	status = "moving"

# Adaptive ROM System
func _on_adapt_rom_toggled(toggled_on: bool) -> void:
	if toggled_on and not GlobalSignals.assessment_done:
		_button_nodes.adapt_prom.button_pressed = false
		_ui_nodes.warning_window.visible = true
		return
	adapt_toggle = toggled_on

func _on_do_assess_pressed() -> void:
	get_tree().change_scene_to_file("res://Games/assessment/workspace.tscn")

func _on_close_assess_pressed() -> void:
	_ui_nodes.warning_window.visible = false

# CSV Logging System
func _setup_game_logging() -> void:
	log_timer.timeout.connect(_on_log_timer_timeout)
	
	game_log_file = Manager.create_game_log_file(game_name, GlobalSignals.current_patient_id)
	game_log_file.store_csv_line(PackedStringArray([
		'epochtime', 'score', 'status', 'error_status', 'packets', 
		'device_x', 'device_y', 'device_z', 'target_x', 'target_y', 'target_z',
		'player_x', 'player_y', 'player_z', 'pause_state'
	]))

func save_final_score_to_log(final_score: int) -> void:
	if game_log_file:
		game_log_file.store_line("Final Score: " + str(final_score))
		game_log_file.flush()

func _on_log_timer_timeout() -> void:
	if game_log_file and not debug:
		# FIXED: Now using actual coin position as target
		var target_x = coin_target_x
		var target_y = 0.0  # Jumpify is 2D, so target_y is always 0
		var target_z = coin_target_z
		
		game_log_file.store_csv_line(PackedStringArray([
			Time.get_unix_time_from_system(), score, status, error_status, packets,
			str(pos_x), str(pos_y), str(pos_z), str(target_x), str(target_y), str(target_z),
			str(game_x), str(game_y), str(game_z), str(pause_state)
		]))

# Calibration function - call this to set current position as zero point
func calibrate_zero_position() -> void:
	zero_offset = network_position
	print("Zero position calibrated to: ", zero_offset)

# Cleanup
func _notification(what) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if game_log_file:
			game_log_file.close()
