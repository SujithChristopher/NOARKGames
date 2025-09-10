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
var is_paused = false
var pause_state = 1
var adapt_toggle: bool = false

# Status tracking variables
var coin_collected_timer = 0.0
var coin_missed_timer = 0.0
var status_hold_duration = 0.5

# Position tracking variables
var pos_x: float
var pos_y: float
var pos_z: float
var game_x: float
var game_y = 0.0
var game_z: float

# Coin tracking variables - Direct node reference
@onready var coin_node: Area2D = $"../Coin"
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

# Node references - UI elements (cleaned up)
@onready var ui_nodes = {
    "score_board": %ScoreLabel,
    "countdown_display": $"../UserInterface/GameUI/CountdownLabel",
    "game_over_label": $"../UserInterface/GameUI/ColorRect/GameOverLabel",
    "top_score_label": $"../UserInterface/GameUI/TopScoreLabel",
    "color_rect": $"../UserInterface/GameUI/ColorRect",
    "warning_window": $"../UserInterface/GameUI/Window"
}

@onready var panel_nodes = {
    "pause_button": $"../UserInterface/GameUI/PauseButton"
}

@onready var button_nodes = {
    "logout_button": $"../UserInterface/GameUI/ColorRect/GameOverLabel/LogoutButton",
    "retry_button": $"../UserInterface/GameUI/ColorRect/GameOverLabel/RetryButton",
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
    load_debug_config()
    setup_timers()
    setup_ui()
    connect_signals()
    initialize_game_state()
    setup_global_timer()
    network_position = Vector2.ZERO
    previous_position = position

func setup_global_timer() -> void:
    # Add the global timer selector to this game
    GlobalTimerManager.add_timer_selector_to_game(self)
    
    # Connect to global timer signals
    GlobalTimerManager.countdown_finished.connect(_on_global_countdown_finished)
    GlobalTimerManager.countdown_updated.connect(_on_global_countdown_updated)

func load_debug_config() -> void:
    debug = JSON.parse_string(FileAccess.get_file_as_string(path))['debug']

func setup_timers() -> void:
    log_timer.wait_time = LOG_INTERVAL
    log_timer.autostart = true
    add_child(log_timer)

func setup_ui() -> void:
    ui_nodes.color_rect.visible = false
    ui_nodes.game_over_label.visible = false
    ui_nodes.game_over_label.hide()
    ui_nodes.color_rect.hide()
    ui_nodes.countdown_display.visible = false
    update_top_score_display()
    
    # Initialize score display
    ui_nodes.score_board.text = "Score: 0"

func connect_signals() -> void:
    # Connect coin signal - using direct node reference
    if coin_node:
        coin_node.coin_missed.connect(_on_coin_missed)
        print("✓ Coin signal connected successfully")
    else:
        print("✗ ERROR: Coin node not found - check the path in @onready var coin_node")

func initialize_game_state() -> void:
    network_position = Vector2.ZERO
    GlobalScript.start_new_session_if_needed()

func update_top_score_display() -> void:
    var top_score = ScoreManager.get_top_score(patient_id, game_name)
    ui_nodes.top_score_label.text = "HIGH SCORE: " + str(top_score)

# Global Timer Callbacks
func _on_global_timer_play_pressed(time: int) -> void:
    GlobalTimer.start_timer()
    game_started = true
    countdown_time = time
    start_game_with_timer(time)
    setup_game_logging()

func _on_global_timer_close_pressed() -> void:
    game_started = true
    ui_nodes.countdown_display.hide()
    start_game_without_timer()
    setup_game_logging()

func start_game_with_timer(time: int) -> void:
    countdown_active = true
    countdown_time = time
    ui_nodes.countdown_display.visible = true
    GlobalTimerManager.start_countdown_with_time(time)
    
func start_game_without_timer() -> void:
    countdown_active = false
    GlobalTimer.start_timer()
    GlobalTimerManager.start_game_without_timer()

func _on_global_countdown_finished() -> void:
    show_game_over()

func _on_global_countdown_updated(time_left: int) -> void:
    countdown_time = time_left
    ui_nodes.countdown_display.text = GlobalTimerManager.get_countdown_display_text()

func _physics_process(delta):
    if game_started and not is_paused:
        update_player_position()
        update_animations()
        update_status_based_on_timers(delta)
        update_coin_target_position()

# Function to update coin target position for logging
func update_coin_target_position() -> void:
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

func update_player_position() -> void:
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
        
        update_position_tracking()

func update_position_tracking() -> void:
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
func update_status_based_on_timers(delta):
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

func update_animations():
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

# Pause System
func _on_pause_button_pressed() -> void:
    if is_paused:
        resume_game()
    else:
        pause_game()
    is_paused = !is_paused

func pause_game() -> void:
    GlobalTimer.pause_timer()
    GlobalTimerManager.pause_countdown()
    panel_nodes.pause_button.text = "Resume"
    game_started = false
    pause_state = 0

func resume_game() -> void:
    GlobalTimer.resume_timer()
    GlobalTimerManager.resume_countdown()
    panel_nodes.pause_button.text = "Pause"
    game_started = true
    pause_state = 1

# Scoring System
func add_score(points: int = 1) -> void:
    if score < max_score:
        score += points
        ui_nodes.score_board.text = "Score: " + str(score)
        
        # Update top score
        ScoreManager.update_top_score(patient_id, game_name, score)
        update_top_score_display()

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
    ui_nodes.game_over_label.visible = true
    ui_nodes.color_rect.visible = true

func _on_logout_button_pressed() -> void:
    GlobalTimerManager.remove_timer_selector_from_game()
    get_tree().paused = false
    get_tree().change_scene_to_file("res://Main_screen/Scenes/3d_games.tscn")

func _on_retry_button_pressed() -> void:
    get_tree().paused = false
    ui_nodes.color_rect.visible = false
    ui_nodes.game_over_label.hide()
    
    # Reset game state
    score = 0
    ui_nodes.score_board.text = "Score: 0"
    game_over = false
    countdown_time = 0
    countdown_active = false
    game_started = false
    status = "moving"
    
    # Show timer selector for retry
    GlobalTimerManager.show_timer_selector_for_retry()

# Adaptive ROM System
func _on_adapt_rom_toggled(toggled_on: bool) -> void:
    if toggled_on and not GlobalSignals.assessment_done:
        button_nodes.adapt_prom.button_pressed = false
        ui_nodes.warning_window.visible = true
        return
    adapt_toggle = toggled_on

func _on_do_assess_pressed() -> void:
    get_tree().change_scene_to_file("res://Games/assessment/workspace.tscn")

func _on_close_assess_pressed() -> void:
    ui_nodes.warning_window.visible = false

# CSV Logging System
func setup_game_logging() -> void:
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
        # Using actual coin position as target
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
        GlobalTimerManager.remove_timer_selector_from_game()
