extends Node2D

# Constants
const LOG_INTERVAL: float = 0.02
const GAME_NAME: String = "FruitCatcher"
const GEM = preload("res://Games/fruit_catcher/Scenes/Fruits/fruit.tscn")
const MARGIN: float = 70.0

# Screen boundaries
var START_OF_SCREEN_X: float
var END_OF_SCREEN_X: float

# Game state
var _score: int = 0
var current_gem: Gem = null  
var game_active: bool = false
var game_started: bool = false
var is_paused: bool = false
var pause_state: int = 1
var missed_gems := 0

# Timer and countdown
var countdown_time: int = 0
var countdown_active: bool = false

# Position tracking for logging
var paddle_x: float = 0.0
var paddle_y: float = 615.0
var gem_x: float = 0.0
var gem_y: float = 0.0
var device_x: float = 0.0
var device_y: float = 0.0
var device_z: float = 0.0

# Game logging
var status: String = "waiting"
var game_log_file
var log_timer: Timer

# Node references
@onready var spawn_timer: Timer = $SpawnTimer
@onready var paddle: Area2D = $Paddle
@onready var score_sound: AudioStreamPlayer2D = $ScoreSound
@onready var sound: AudioStreamPlayer = $Sound
@onready var score_label: Label = $ScoreLabel
@onready var game_over_label: ColorRect = $ColorRect
@onready var countdown_display: Label = $CountdownLabel
@onready var top_score_label: Label = $TopScoreLabel

# Button nodes (cleaned up)
@onready var button_nodes = {
    "pause_button": $PauseButton,
    "retry_button": $ColorRect/GameOverLabel/RetryButton,
    "close_assess": $Window/HBoxContainer/close_asses,
    "do_assess": $Window/HBoxContainer/do_asses,
    "adapt_prom": $AdaptProm,
    "warning_window": $Window
}

func _init() -> void:
    print("Game:: _init")
    
func _enter_tree() -> void:
    print("Game:: _enter_tree")

func _ready() -> void:
    setup_screen_boundaries()
    setup_timers()
    setup_ui()
    initialize_game_state()
    update_top_score_display()
    setup_global_timer()
    
func setup_global_timer() -> void:
    # Add the global timer selector to this game
    GlobalTimerManager.add_timer_selector_to_game(self)
    
    # Connect to global timer signals
    GlobalTimerManager.countdown_finished.connect(_on_global_countdown_finished)
    GlobalTimerManager.countdown_updated.connect(_on_global_countdown_updated)

func setup_screen_boundaries() -> void:
    START_OF_SCREEN_X = get_viewport_rect().position.x
    END_OF_SCREEN_X = get_viewport_rect().end.x

func setup_timers() -> void:
    # Setup log timer
    log_timer = Timer.new()
    log_timer.wait_time = LOG_INTERVAL
    log_timer.autostart = false
    log_timer.timeout.connect(_on_log_timer_timeout)
    add_child(log_timer)
    
    # Stop spawn timer initially
    spawn_timer.stop()

func setup_ui() -> void:
    game_over_label.visible = false
    countdown_display.visible = false
    button_nodes.pause_button.hide()

func initialize_game_state() -> void:
    game_active = false
    game_started = false
    is_paused = false
    pause_state = 1
    status = "waiting"

func update_top_score_display() -> void:
    var patient_id = GlobalSignals.current_patient_id if GlobalSignals.current_patient_id else "default"
    var top_score = ScoreManager.get_top_score(patient_id, GAME_NAME)
    top_score_label.text = "Top Score: " + str(top_score)
    print("Top score for patient ", patient_id, " in ", GAME_NAME, ": ", top_score)

# Global Timer Callbacks
func _on_global_timer_play_pressed(time: int) -> void:
    GlobalTimer.start_timer()
    game_started = true
    countdown_time = time
    start_game_with_timer(time)

func _on_global_timer_close_pressed() -> void:
    game_started = true
    countdown_display.hide()
    start_game_without_timer()

func start_game_with_timer(time: int) -> void:
    countdown_active = true
    countdown_time = time
    countdown_display.visible = true
    GlobalTimerManager.start_countdown_with_time(time)
    start_game()
    
func start_game_without_timer() -> void:
    countdown_active = false
    GlobalTimer.start_timer()
    GlobalTimerManager.start_game_without_timer()
    start_game()

func _on_global_countdown_finished() -> void:
    end_game()

func _on_global_countdown_updated(time_left: int) -> void:
    countdown_time = time_left
    countdown_display.text = GlobalTimerManager.get_countdown_display_text()

func _process(delta: float) -> void:
    if not game_started:
        return
    if game_started and game_active:
        update_tracking_data()

func update_tracking_data() -> void:
    # Update paddle position
    paddle_x = paddle.position.x
    paddle_y = paddle.position.y
    
    # Update gem position
    if current_gem and is_instance_valid(current_gem):
        gem_x = current_gem.position.x
        gem_y = current_gem.position.y
    else:
        gem_x = 0.0
        gem_y = 0.0
    
    # Update device position
    device_x = GlobalScript.raw_x
    device_y = GlobalScript.raw_y
    device_z = GlobalScript.raw_z

func start_game() -> void:
    game_active = true
    game_started = true
    status = "playing"
    setup_game_logging()
    log_timer.start()
    button_nodes.pause_button.show()
    spawn_gem()

func setup_game_logging() -> void:
    GlobalScript.start_new_session_if_needed()
    game_log_file = Manager.create_game_log_file(GAME_NAME, GlobalSignals.current_patient_id)
    game_log_file.store_csv_line(PackedStringArray([
        'epochtime', 'score', 'status', 'pause_state',
        'device_x', 'device_y', 'device_z',
        'paddle_x', 'paddle_y', 'gem_x', 'gem_y',
        'countdown_time', 'gems_caught', 'gems_missed'
    ]))

# Game Logic Functions
func spawn_gem() -> void:
    if current_gem != null or not game_active:
        return
        
    var new_gem: Gem = GEM.instantiate()
    var x_pos: float = randf_range(
        START_OF_SCREEN_X + MARGIN,
        END_OF_SCREEN_X - MARGIN
    )
    new_gem.position = Vector2(x_pos, -MARGIN)
    new_gem.gem_off_screen.connect(_on_gem_off_screen)
    
    current_gem = new_gem
    add_child(new_gem)
    status = "gem_spawned"

func _on_gem_off_screen() -> void:
    if not game_active:
        return
        
    print("Game:: _on_gem_off_screen - Gem missed")
    current_gem = null
    status = "gem_missed"
    missed_gems += 1
    if missed_gems >= 3:
        game_over_label.show()
        game_active = false
        return
    
    await get_tree().create_timer(0.5).timeout
    if game_active:
        spawn_gem()

func _on_paddle_area_entered(area: Area2D) -> void:
    if area == current_gem and game_active:
        _score += 1
        score_label.text = "SCORE: " + str(_score)
        print("Gem caught! Score: ", _score)
        status = "gem_caught"
        
        ScoreManager.update_top_score(GlobalSignals.current_patient_id, GAME_NAME, _score)
        update_top_score_display()
        if not score_sound.playing:
            score_sound.position = area.position
            score_sound.play()
        
        current_gem = null
        
        await get_tree().create_timer(0.5).timeout
        if game_active:
            spawn_gem()

func _on_pause_button_pressed() -> void:
    if is_paused:
        resume_game()
    else:
        pause_game()
    is_paused = !is_paused

func pause_game() -> void:
    GlobalTimer.pause_timer()
    GlobalTimerManager.pause_countdown()
    
    game_active = false
    paddle.set_process(false)
    
    if current_gem and is_instance_valid(current_gem):
        current_gem.set_process(false)
    
    button_nodes.pause_button.text = "Resume"
    pause_state = 0
    status = "paused"

func resume_game() -> void:
    GlobalTimer.resume_timer()
    GlobalTimerManager.resume_countdown()
    
    game_active = true
    paddle.set_process(true)
    
    if current_gem and is_instance_valid(current_gem):
        current_gem.set_process(true)
    
    button_nodes.pause_button.text = "Pause"
    pause_state = 1
    status = "playing"

func end_game() -> void:
    print("Game Over! Final Score: ", _score)
    game_active = false
    game_started = false
    status = "game_over"
    
    # Stop all game elements
    if current_gem and is_instance_valid(current_gem):
        current_gem.set_process(false)
    
    paddle.set_process(false)
    log_timer.stop()
    
    # Save final score
    save_final_score()
    
    # Play end sound
    sound.play()
    
    # Show game over UI
    GlobalTimer.stop_timer()
    game_over_label.visible = true

func save_final_score() -> void:
    print("Saving final score: ", _score)
    
    if game_log_file:
        game_log_file.store_line("Final Score: " + str(_score))
        game_log_file.flush()
    
    # Use update_top_score method
    var patient_id = GlobalSignals.current_patient_id if GlobalSignals.current_patient_id else "default"
    print("Updating top score for patient: ", patient_id, " Game: ", GAME_NAME, " Score: ", _score)
    
    ScoreManager.update_top_score(patient_id, GAME_NAME, _score)
    
    # Update top score display immediately
    update_top_score_display()
    
    # Debug: Print current scores
    print("Current top score after saving: ", ScoreManager.get_top_score(patient_id, GAME_NAME))

func _on_retry_button_pressed() -> void:
    reset_game()
    # Show timer selector for retry
    GlobalTimerManager.show_timer_selector_for_retry()

func _on_logout_button_pressed() -> void:
    GlobalTimerManager.remove_timer_selector_from_game()
    get_tree().paused = false
    get_tree().change_scene_to_file("res://Main_screen/Scenes/select_game.tscn")

func reset_game() -> void:
    # Clean up current gem
    if current_gem and is_instance_valid(current_gem):
        current_gem.queue_free()
    current_gem = null
    
    # Reset game state
    _score = 0
    score_label.text = "SCORE: 0"
    countdown_time = 0
    countdown_active = false
    game_active = false
    game_started = false
    is_paused = false
    pause_state = 1
    status = "waiting"
    missed_gems = 0
    
    # Reset UI
    game_over_label.visible = false
    countdown_display.visible = false
    button_nodes.pause_button.hide()
    
    # Close log file
    if game_log_file:
        game_log_file.close()
        game_log_file = null
    
    log_timer.stop()
    
    # Reset paddle
    paddle.set_process(true)
    
    # Update top score display
    update_top_score_display()

# Logging Function
func _on_log_timer_timeout() -> void:
    if game_log_file and game_started:
        game_log_file.store_csv_line(PackedStringArray([
            str(Time.get_unix_time_from_system()),
            str(_score),
            status,
            str(pause_state),
            str(device_x),
            str(device_y),
            str(device_z),
            str(paddle_x),
            str(paddle_y),
            str(gem_x),
            str(gem_y),
            str(countdown_time),
            str(_score),  # gems_caught (same as score)
            str(missed_gems)
        ]))

# Assessment Functions
func _on_do_asses_pressed() -> void:
    get_tree().change_scene_to_file("res://Games/assessment/workspace.tscn")

func _on_close_asses_pressed() -> void:
    button_nodes.warning_window.visible = false

func _notification(what: int) -> void:
    if what == NOTIFICATION_WM_CLOSE_REQUEST:
        if game_log_file:
            game_log_file.close()
        GlobalTimerManager.remove_timer_selector_from_game()
        get_tree().quit()

func _on_gameover_logout_pressed() -> void:
    GlobalTimerManager.remove_timer_selector_from_game()
    get_tree().paused = false
    get_tree().change_scene_to_file("res://Main_screen/Scenes/select_game.tscn")
