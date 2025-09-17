extends Node

# Signals for timer events
signal countdown_finished()
signal countdown_updated(time_left: int)

# Timer selector scene
var timer_selector_scene = preload("res://Main_screen/Scenes/GlobalTimerSelector.tscn")
var timer_selector_instance: Control = null

# Countdown variables
var countdown_timer: Timer = null
var countdown_time: int = 0
var countdown_active: bool = false
var current_game_node: Node = null

func _ready() -> void:
	_setup_countdown_timer()

func _setup_countdown_timer() -> void:
	countdown_timer = Timer.new()
	countdown_timer.wait_time = 1.0
	countdown_timer.timeout.connect(_on_countdown_timer_timeout)
	add_child(countdown_timer)

func add_timer_selector_to_game(game_node: Node) -> void:
	current_game_node = game_node
	
	# Create timer selector instance if it doesn't exist
	if timer_selector_instance == null:
		timer_selector_instance = timer_selector_scene.instantiate()
		timer_selector_instance.play_pressed.connect(_on_timer_selector_play_pressed)
		timer_selector_instance.close_pressed.connect(_on_timer_selector_close_pressed)
	
	# Add to game node
	game_node.add_child(timer_selector_instance)
	timer_selector_instance.show_panel()
		
func remove_timer_selector_from_game() -> void:
	if timer_selector_instance != null and timer_selector_instance.get_parent() != null:
		timer_selector_instance.countdown_time = 0
		timer_selector_instance._update_label()
		timer_selector_instance.get_parent().remove_child(timer_selector_instance)

func start_countdown_with_time(time: int) -> void:
	countdown_time = time
	countdown_active = true
	countdown_timer.start()
	_emit_countdown_update()

func start_game_without_timer() -> void:
	countdown_active = false
	if countdown_timer.is_stopped() == false:
		countdown_timer.stop()

func pause_countdown() -> void:
	if countdown_active:
		countdown_timer.stop()

func resume_countdown() -> void:
	if countdown_active:
		countdown_timer.start()

func stop_countdown() -> void:
	countdown_active = false
	countdown_timer.stop()

func get_countdown_time() -> int:
	return countdown_time

func is_countdown_active() -> bool:
	return countdown_active

func _on_timer_selector_play_pressed(time: int) -> void:
	timer_selector_instance.hide_panel()
	# Emit signal that game can connect to
	if current_game_node and current_game_node.has_method("_on_global_timer_play_pressed"):
		current_game_node._on_global_timer_play_pressed(time)

func _on_timer_selector_close_pressed() -> void:
	timer_selector_instance.hide_panel()
	# Emit signal that game can connect to  
	if current_game_node and current_game_node.has_method("_on_global_timer_close_pressed"):
		current_game_node._on_global_timer_close_pressed()

func _on_countdown_timer_timeout() -> void:
	if countdown_active:
		countdown_time -= 1
		_emit_countdown_update()
		
		if countdown_time <= 0:
			countdown_active = false
			countdown_timer.stop()
			countdown_finished.emit()

func _emit_countdown_update() -> void:
	countdown_updated.emit(countdown_time)

func show_timer_selector_for_retry() -> void:
	if timer_selector_instance != null:
		timer_selector_instance.reset_for_retry()

func get_countdown_display_text() -> String:
	var minutes = countdown_time / 60
	var seconds = countdown_time % 60
	return "Time Left: %02d:%02d" % [minutes, seconds]
	
