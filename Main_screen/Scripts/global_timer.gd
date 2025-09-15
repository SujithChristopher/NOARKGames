extends Node

var total_play_time := 0.0
var timer_running := false
var timer_paused := false

func _process(delta: float) -> void:
	if timer_running and not timer_paused:
		total_play_time += delta

func start_timer() -> void:
	timer_running = true
	timer_paused = false

func stop_timer() -> void:
	timer_running = false
	timer_paused = false
	

func pause_timer() -> void:
	if timer_running:
		timer_paused = true

func resume_timer() -> void:
	if timer_running and timer_paused:
		timer_paused = false

func reset_timer() -> void:
	total_play_time = 0.0
	timer_running = false
	timer_paused = false

func get_time() -> float:
	return total_play_time
	
func get_time_formatted() -> String:
	var minutes = int(total_play_time) / 60
	var seconds = int(total_play_time) % 60
	return "%02d:%02d" % [minutes, seconds]
