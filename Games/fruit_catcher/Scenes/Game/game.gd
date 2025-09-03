extends Node2D

# Constants
const LOG_INTERVAL: float = 0.02
const MAX_COUNTDOWN_TIME: int = 2700  # 45 minutes max
const ONE_MINUTE: int = 60
const FIVE_MINUTES: int = 300
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

# Timer UI nodes
@onready var timer_panel: Control = $TimerSelectorPanel
@onready var countdown_display: Label = $CountdownLabel
@onready var time_label: Label = $TimerSelectorPanel/TimeSelector
@onready var countdown_timer: Timer = $CountdownTimer
@onready var top_score_label: Label = $TopScoreLabel

# Button nodes
@onready var _button_nodes = {
	"play_button": $TimerSelectorPanel/VBoxContainer/HBoxContainer/PlayButton,
	"close_button": $TimerSelectorPanel/VBoxContainer/HBoxContainer/CloseButton,
	"pause_button": $PauseButton,
	"retry_button": $ColorRect/GameOverLabel/RetryButton,
	"add_one_btn": $TimerSelectorPanel/HBoxContainer/AddOneButton,
	"add_five_btn": $TimerSelectorPanel/HBoxContainer/AddFiveButton,
	"sub_one_btn": $TimerSelectorPanel/HBoxContainer2/SubOneButton,
	"sub_five_btn": $TimerSelectorPanel/HBoxContainer2/SubFiveButton,
	"close_assess":$Window/HBoxContainer/close_asses,
	"do_assess": $Window/HBoxContainer/do_asses,
	"adapt_prom":$AdaptProm,
	"warning_window": $Window
}

func _init() -> void:
	print("Game:: _init")
	
func _enter_tree() -> void:
	print("Game:: _enter_tree")

func _ready() -> void:
	_setup_screen_boundaries()
	_setup_timers()
	_setup_ui()
	_initialize_game_state()
	_update_top_score_display()
	

func _setup_screen_boundaries() -> void:
	START_OF_SCREEN_X = get_viewport_rect().position.x
	END_OF_SCREEN_X = get_viewport_rect().end.x

func _setup_timers() -> void:
	# Setup log timer
	log_timer = Timer.new()
	log_timer.wait_time = LOG_INTERVAL
	log_timer.autostart = false
	log_timer.timeout.connect(_on_log_timer_timeout)
	add_child(log_timer)
	
	# Stop spawn timer initially
	spawn_timer.stop()

func _setup_ui() -> void:
	timer_panel.visible = true
	game_over_label.visible = false
	countdown_display.hide()
	_button_nodes.pause_button.hide()
	update_time_label()

func _initialize_game_state() -> void:
	game_active = false
	game_started = false
	is_paused = false
	pause_state = 1
	status = "waiting"

func _update_top_score_display() -> void:
	var patient_id = GlobalSignals.current_patient_id if GlobalSignals.current_patient_id else "default"
	var top_score = ScoreManager.get_top_score(patient_id, GAME_NAME)
	top_score_label.text = "Top Score: " + str(top_score)
	print("Top score for patient ", patient_id, " in ", GAME_NAME, ": ", top_score)

func _process(delta: float) -> void:
	if not game_started:
		return
	if game_started and game_active:
		_update_tracking_data()

func _update_tracking_data() -> void:
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

# Timer Control Functions
func update_time_label() -> void:
	var minutes = countdown_time / 60
	time_label.text = "%2d m" % [minutes]

func _modify_countdown_time(amount: int) -> void:
	countdown_time = clamp(countdown_time + amount, 0, MAX_COUNTDOWN_TIME)
	update_time_label()
	countdown_display.visible = true
	_update_countdown_display()

func _on_add_one_pressed() -> void:
	_modify_countdown_time(ONE_MINUTE)

func _on_add_five_pressed() -> void:
	_modify_countdown_time(FIVE_MINUTES)

func _on_sub_one_pressed() -> void:
	_modify_countdown_time(-ONE_MINUTE)

func _on_sub_five_pressed() -> void:
	_modify_countdown_time(-FIVE_MINUTES)

func _on_play_pressed() -> void:
	if countdown_time <= 0:
		return
	
	GlobalTimer.start_timer()
	_hide_timer_ui()
	_start_game_with_timer()

func _on_close_pressed() -> void:
	_hide_timer_ui()
	_start_game_without_timer()

func _hide_timer_ui() -> void:
	timer_panel.visible = false
	time_label.hide()
	_button_nodes.pause_button.show()

func _show_timer_ui() -> void:
	timer_panel.show()
	_button_nodes.pause_button.hide()
	update_time_label()

func _start_game_with_timer() -> void:
	countdown_active = true
	countdown_timer.wait_time = 1.0
	countdown_timer.start()
	_start_game()
	_update_countdown_display()

func _start_game_without_timer() -> void:
	countdown_active = false
	GlobalTimer.start_timer()
	_start_game()

func _start_game() -> void:
	game_active = true
	game_started = true
	status = "playing"
	_setup_game_logging()
	log_timer.start()
	spawn_gem()

func _setup_game_logging() -> void:
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
	missed_gems +=1
	if missed_gems >=3:
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
		_update_top_score_display()
		if not score_sound.playing:
			score_sound.position = area.position
			score_sound.play()
		
		current_gem = null
		
		await get_tree().create_timer(0.5).timeout
		if game_active:
			spawn_gem()


func _on_pause_button_pressed() -> void:
	if is_paused:
		_resume_game()
	else:
		_pause_game()
	is_paused = !is_paused

func _pause_game() -> void:
	GlobalTimer.pause_timer()
	if countdown_active:
		countdown_timer.stop()
	
	game_active = false
	paddle.set_process(false)
	
	if current_gem and is_instance_valid(current_gem):
		current_gem.set_process(false)
	
	_button_nodes.pause_button.text = "Resume"
	pause_state = 0
	status = "paused"

func _resume_game() -> void:
	GlobalTimer.resume_timer()
	if countdown_active:
		countdown_timer.start()
	
	game_active = true
	paddle.set_process(true)
	
	if current_gem and is_instance_valid(current_gem):
		current_gem.set_process(true)
	
	_button_nodes.pause_button.text = "Pause"
	pause_state = 1
	status = "playing"

# Countdown Timer Functions
func _on_countdown_timer_timeout() -> void:
	if countdown_active:
		countdown_time -= 1
		_update_countdown_display()
		if countdown_time <= 0:
			countdown_active = false
			countdown_timer.stop()
			_end_game()

func _update_countdown_display() -> void:
	var minutes = countdown_time / 60
	var seconds = countdown_time % 60
	countdown_display.text = "TIME LEFT: %02d:%02d" % [minutes, seconds]

func _end_game() -> void:
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
	_save_final_score()
	
	# Play end sound
	#sound.stream = EXPLODE
	sound.play()
	
	# Show game over UI
	GlobalTimer.stop_timer()
	game_over_label.visible = true

func _save_final_score() -> void:
	print("Saving final score: ", _score)
	
	if game_log_file:
		game_log_file.store_line("Final Score: " + str(_score))
		game_log_file.flush()
	
	# Use update_top_score method (your ScoreManager's correct method)
	var patient_id = GlobalSignals.current_patient_id if GlobalSignals.current_patient_id else "default"
	print("Updating top score for patient: ", patient_id, " Game: ", GAME_NAME, " Score: ", _score)
	
	ScoreManager.update_top_score(patient_id, GAME_NAME, _score)
	
	# Update top score display immediately
	_update_top_score_display()
	
	# Debug: Print current scores
	print("Current top score after saving: ", ScoreManager.get_top_score(patient_id, GAME_NAME))


func _on_retry_button_pressed() -> void:
	timer_panel.show()
	_reset_game()
	_show_timer_ui()

func _on_logout_button_pressed() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://Main_screen/Scenes/select_game.tscn")

func _reset_game() -> void:
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
	
	# Reset UI
	game_over_label.visible = false
	countdown_display.hide()
	countdown_timer.stop()
	log_timer.stop()
	
	# Close log file
	if game_log_file:
		game_log_file.close()
		game_log_file = null
	
	# Reset paddle
	paddle.set_process(true)
	
	# Update top score display
	_update_top_score_display()

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
			"0"  # gems_missed (could be tracked separately if needed)
		]))

# Assessment Functions
func _on_do_asses_pressed() -> void:
	get_tree().change_scene_to_file("res://Games/assessment/workspace.tscn")

func _on_close_asses_pressed() -> void:
	_button_nodes.warning_window.visible = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if game_log_file:
			game_log_file.close()
		get_tree().quit()

func _on_gameover_logout_pressed() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://Main_screen/Scenes/select_game.tscn")
