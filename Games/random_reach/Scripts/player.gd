extends CharacterBody2D

# Exported variables
@export var max_score = 500
@onready var debug_mode = DebugSettings.debug_mode

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
    "score_board": $"../ScoreBoard/Score",
    "time_display": $"../Panel/TimeSeconds",
    "countdown_display": $"../TileMap/CanvasLayer/CountdownLabel",
    "game_over_label": $"../TileMap/CanvasLayer/ColorRect/GameOverLabel",
    "top_score_label":$"../TileMap/CanvasLayer/TopScoreLabel",
    "color_rect": $"../TileMap/CanvasLayer/ColorRect",
    "warning_window":$"../Window",
    "bg_2d":$"../2DRR",
    "bg_3d":$"../3DRR"
}

@onready var _timer_nodes = {
    "my_timer": $"../DisplayTimer"
}

@onready var _panel_nodes = {
    "pause_button": $"../TileMap/CanvasLayer/PauseButton"
}

@onready var _button_nodes = {
    "logout_button": $"../TileMap/CanvasLayer/ColorRect/GameOverLabel/LogoutButton",
    "retry_button": $"../TileMap/CanvasLayer/ColorRect/GameOverLabel/RetryButton",
    "close_assess": $"../Window/HBoxContainer/close_asses",
    "do_assess": $"../Window/HBoxContainer/do_asses",
    "adapt_prom": $"../AdaptRom"
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
var is_paused = false
var pause_state = 1
var adapt_toggle: bool = false
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
var patient_id = GlobalSignals.current_patient_id
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

# Debug and config
var json = JSON.new()
var path = "res://debug.json"
var debug

func _ready() -> void:
    _load_debug_config()
    _setup_training_hand()
    _setup_timers()
    _setup_ui()
    _connect_signals()
    _initialize_game_state()
    _auto_select_mode()
    _setup_global_timer()

func _setup_global_timer() -> void:
    # Add the global timer selector to this game
    GlobalTimerManager.add_timer_selector_to_game(self)
    
    # Connect to global timer signals
    GlobalTimerManager.countdown_finished.connect(_on_global_countdown_finished)
    GlobalTimerManager.countdown_updated.connect(_on_global_countdown_updated)

func _auto_select_mode() -> void:
    # Automatically set mode based on GlobalSignals
    if GlobalSignals.selected_game_mode == "3D":
        _set_3d_mode()
    else:
        _set_2d_mode()

func _load_debug_config() -> void:
    debug = JSON.parse_string(FileAccess.get_file_as_string(path))['debug']

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
    _ui_nodes.game_over_label.visible = false
    _ui_nodes.game_over_label.hide()
    _ui_nodes.color_rect.hide()
    _ui_nodes.countdown_display.visible = false
    _update_top_score_display()

func _connect_signals() -> void:
    # Button connections
    _button_nodes.logout_button.pressed.connect(_on_logout_button_pressed)
    _button_nodes.retry_button.pressed.connect(_on_retry_button_pressed)
    _panel_nodes.pause_button.pressed.connect(_on_PauseButton_pressed)

func _initialize_game_state() -> void:
    network_position = Vector2.ZERO
    GlobalScript.start_new_session_if_needed()

func _update_top_score_display() -> void:
    var top_score = ScoreManager.get_top_score(patient_id, game_name)
    _ui_nodes.top_score_label.text = "HIGH SCORE : " + str(top_score)

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
    GlobalTimerManager.start_countdown_with_time(time)
    
func _start_game_without_timer() -> void:
    countdown_active = false
    GlobalTimer.start_timer()
    GlobalTimerManager.start_game_without_timer()

func _on_global_countdown_finished() -> void:
    show_game_over()

func _on_global_countdown_updated(time_left: int) -> void:
    countdown_time = time_left
    _ui_nodes.countdown_display.text = GlobalTimerManager.get_countdown_display_text()

func _physics_process(delta):
    if not game_started:
        return
    
    _update_player_position()
    _update_sprite_direction()
    _handle_apple_spawning()
    _update_timer_display()

func _update_player_position() -> void:
    if debug_mode:
        network_position = get_global_mouse_position()
    elif adapt_toggle:
        if is_3d_mode:
            network_position = GlobalScript.scaled_network_position3D
        else:
            network_position = GlobalScript.scaled_network_position
    else:
        network_position = GlobalScript.network_position3D if is_3d_mode else GlobalScript.network_position
    if network_position != Vector2.ZERO:
        network_position = network_position - zero_offset
        position = position.lerp(network_position, 0.8)
        position.x = clamp(position.x, MIN_BOUNDS.x, MAX_BOUNDS.x)
        position.y = clamp(position.y, MIN_BOUNDS.y, MAX_BOUNDS.y)
        
        _update_position_tracking()

func _update_position_tracking() -> void:
    pos_x = GlobalScript.raw_x
    pos_y = GlobalScript.raw_y
    pos_z = GlobalScript.raw_z
    
    if not adapt_toggle:
        # Standard mode calculations
        game_x = (position.x - GlobalScript.X_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_X
        
        if is_3d_mode:
            # 3D mode: calculate game_y from screen Y position
            game_y = (position.y - GlobalScript.Y_SCREEN_OFFSET3D) / GlobalScript.PLAYER3D_POS_SCALER_Y
            game_z = 0.0  # Z not used in 3D screen mapping
        else:
            # 2D mode: Y is always 0, Z calculated from screen Y position
            game_y = 0.0
            game_z = (position.y - GlobalScript.Y_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_Z
            
    else:
        # Adaptive mode calculations
        game_x = (position.x - GlobalScript.X_SCREEN_OFFSET) / (GlobalScript.PLAYER_POS_SCALER_X * GlobalSignals.global_scalar_x)
        
        if is_3d_mode:
            # 3D adaptive mode: calculate game_y with scaling
            game_y = (position.y - GlobalScript.Y_SCREEN_OFFSET3D) / (GlobalScript.PLAYER3D_POS_SCALER_Y * GlobalSignals.global_scalar_y)
            game_z = 0.0
        else:
            # 2D adaptive mode: Y is 0, Z calculated with scaling
            game_y = 0.0
            game_z = (position.y - GlobalScript.Y_SCREEN_OFFSET) / (GlobalScript.PLAYER_POS_SCALER_Z * GlobalSignals.global_scalar_y)

        
func _update_sprite_direction() -> void:
    if current_apple != null:
        var direction = current_apple.position.x - position.x
        _sprite_nodes.anim.flip_h = direction < 0
    
    # Control animation based on Y position
    if position.y == 600:
        _sprite_nodes.anim.animation = "no_jet"
    else:
        _sprite_nodes.anim.animation = "jet"

func _handle_apple_spawning() -> void:
    if current_apple == null and (debug_mode or network_position != Vector2.ZERO):
        _spawn_new_apple()

func _spawn_new_apple() -> void:
    _timer_nodes.my_timer.start()
    current_apple = apple.instantiate()
    add_child(current_apple)
    current_apple.top_level = true
    status = ""

    # Connect apple signals
    current_apple.apple_eaten.connect(_on_apple_eaten)
    current_apple.tree_exited.connect(_on_apple_removed)

    # Set apple position
    _set_apple_position()

func _set_apple_position() -> void:
    var apple_position: Vector2
    
    if adapt_toggle:
        apple_position = _get_valid_apple_position()
    else:
        apple_position = Vector2(randi_range(200, 900), randi_range(200, 600))
        _update_target_position(apple_position)
    
    current_apple.position = apple_position

func _get_valid_apple_position() -> Vector2:
    var apple_position: Vector2
    while true:
        if debug_mode:
            apple_position = get_global_mouse_position()
        else:
            apple_position = Vector2(randi_range(200, 900), randi_range(200, 600))
        
        if Geometry2D.is_point_in_polygon(apple_position, GlobalSignals.inflated_workspace):
            break
    
    return apple_position

func _update_target_position(apple_position: Vector2) -> void:
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
        var remaining_time = round(_timer_nodes.my_timer.time_left)
        _ui_nodes.time_display.text = str(remaining_time) + "s"
        
        if remaining_time > 0:
            if status != "captured":
                status = "moving"
        else:
            if status != "captured":
                status = "missed"

func _on_PauseButton_pressed() -> void:
    if is_paused:
        _resume_game()
    else:
        _pause_game()
    is_paused = !is_paused

func _pause_game() -> void:
    GlobalTimer.pause_timer()
    GlobalTimerManager.pause_countdown()
    _panel_nodes.pause_button.text = "Resume"
    game_started = false
    pause_state = 0

func _resume_game() -> void:
    GlobalTimer.resume_timer()
    GlobalTimerManager.resume_countdown()
    _panel_nodes.pause_button.text = "Pause"
    game_started = true
    pause_state = 1

func show_game_over() -> void:
    GlobalTimer.stop_timer()
    game_started = false
    save_final_score_to_log(score)
    _ui_nodes.game_over_label.visible = true
    _ui_nodes.color_rect.visible = true
    
func _on_logout_button_pressed() -> void:
    GlobalTimerManager.remove_timer_selector_from_game()
    get_tree().paused = false
    get_tree().change_scene_to_file("res://Main_screen/Scenes/select_game.tscn")

func _on_retry_button_pressed() -> void:
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

func _setup_game_logging() -> void:
    log_timer.timeout.connect(_on_log_timer_timeout)
    
    # Use the updated game_name variable
    game_log_file = Manager.create_game_log_file(game_name, GlobalSignals.current_patient_id)
    game_log_file.store_csv_line(PackedStringArray([
        'epochtime', 'score', 'status', 'error_status', 'packets', 
        'device_x', 'device_y', 'device_z', 'target_x', 'target_y', 'target_z',
        'player_x', 'player_y', 'player_z', 'pause_state'
    ]))

func _on_log_timer_timeout() -> void:
    if game_log_file and not debug:
        game_log_file.store_csv_line(PackedStringArray([
            Time.get_unix_time_from_system(), score, status, error_status, packets,
            str(pos_x), str(pos_y), str(pos_z), str(target_x), str(target_y), str(target_z),
            str(game_x), str(game_y), str(game_z), str(pause_state)
        ]))

func _on_reach_game_ready() -> void:
    rom_x_top = 20
    rom_y_top = 20
    rom_x_bot = 1100
    rom_y_bot = 600
    rom_y_bot = min(rom_y_bot, 600)
    rom_x_bot = min(rom_x_bot, 1100)
        
func _on_apple_removed() -> void:
    current_apple = null
    
func _on_apple_eaten() -> void:
    if score < max_score:
        score += 1
        _ui_nodes.score_board.text = str(score)
        if _audio_nodes.apple_sound:
            _audio_nodes.apple_sound.play()
    
    ScoreManager.update_top_score(patient_id, game_name, score)
    _update_top_score_display()
    status = "captured"

func _notification(what) -> void:
    if what == NOTIFICATION_WM_CLOSE_REQUEST:
        if game_log_file:
            game_log_file.close()
        GlobalTimerManager.remove_timer_selector_from_game()

func _on_area_2d_area_entered(area) -> void:
    _sprite_nodes.anim.animation = "jet"
    await _sprite_nodes.anim.animation_finished

func _on_area_2d_area_exited(area) -> void:
    _sprite_nodes.anim.animation = "jet"

func _on_zero_pressed() -> void:
    zero_offset = network_position

func _on_button_pressed() -> void:
    get_tree().quit()

func _on_logout_pressed() -> void:
    GlobalTimer.stop_timer()
    GlobalSignals.enable_game_buttons(true)
    GlobalTimerManager.remove_timer_selector_from_game()
    if not is_3d_mode:
        get_tree().change_scene_to_file("res://Main_screen/Scenes/select_game.tscn")
    else:
        get_tree().change_scene_to_file("res://Main_screen/Scenes/3d_games.tscn")

func _on_adapt_rom_toggled(toggled_on: bool) -> void:
    if toggled_on and not GlobalSignals.assessment_done:
        _button_nodes.adapt_prom.button_pressed = false
        _ui_nodes.warning_window.visible = true
        return
    adapt_toggle = toggled_on

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

func _on_do_asses_pressed() -> void:
    get_tree().change_scene_to_file("res://Games/assessment/workspace.tscn")

func _on_close_asses_pressed() -> void:
    _ui_nodes.warning_window.visible = false
