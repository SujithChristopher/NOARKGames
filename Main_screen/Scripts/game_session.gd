extends Node
## One game's trial plumbing, the same for every game: the timer selector and
## countdown, the raw log at 50 Hz, pause (MoveTime and the countdown stop
## together), game over (the sessions.csv row and the best score) and the way
## back to the menu. Each game used to carry its own copy of all of this.
##
##     const GameSession := preload("res://Main_screen/Scripts/game_session.gd")
##     session = GameSession.new(GAME_NAME, COLUMNS, _log_row, $CircularTimer)
##     session.started.connect(start_game)
##     session.time_up.connect(end_game)
##     add_child(session)   # last in _ready, so the timer selector draws on top
##
## The game keeps what is its own — what is on screen and what scores — adds to
## `score`, and calls pause() / resume(), finish(), retry() and to_menu().
## Leaving the scene any other way still ends the trial and saves the score.

signal started   ## the timer selector closed: play
signal time_up   ## the countdown reached 0

const LOG_INTERVAL := 0.02
const MENU_2D := "res://Main_screen/Scenes/select_game.tscn"
const MENU_3D := "res://Main_screen/Scenes/3d_games.tscn"

## "FruitCatcher", or "FlyThrough3D" in 3D; read when a trial opens.
var game_name: String
## The raw CSV's columns after epochtime, and the values of one row of them.
var columns: PackedStringArray
var row: Callable
## A circular_timer.gd (set_time / update_time), or null.
var countdown_display: Control

var patient_id := SessionLog.current_patient()
var score := 0
var time_left := 0   ## seconds left on the countdown; 0 without one
var playing := false
var paused := false

var _log: FileAccess
var _log_timer := Timer.new()


func _init(game: String = "", log_columns: Array = [], log_row := Callable(),
		display: Control = null) -> void:
	game_name = game
	columns = PackedStringArray(log_columns)
	row = log_row
	countdown_display = display


func _ready() -> void:
	_log_timer.wait_time = LOG_INTERVAL
	_log_timer.timeout.connect(_write_row)
	add_child(_log_timer)
	if countdown_display:
		countdown_display.hide()
	GlobalTimerManager.countdown_updated.connect(_on_countdown_updated)
	GlobalTimerManager.countdown_finished.connect(_on_countdown_finished)
	GlobalTimerManager.add_timer_selector_to_game(get_parent(), self)


func _exit_tree() -> void:
	_end()   # left mid-game: the trial still gets its row
	_close_log()


func best_score() -> int:
	return ScoreManager.get_top_score(patient_id, game_name)


## Pause: MoveTime and the countdown stop together. The log keeps writing, so
## the game's row should say it is paused.
func pause() -> void:
	if not playing or paused:
		return
	paused = true
	GlobalTimer.pause_timer()
	GlobalTimerManager.pause_countdown()


func resume() -> void:
	if not paused:
		return
	paused = false
	GlobalTimer.resume_timer()
	GlobalTimerManager.resume_countdown()


## Game over: the trial ends, its score (and any `footer` lines after it) goes
## in the raw log and the best score is saved. Returns the patient's best for
## this game, this score included.
func finish(footer := PackedStringArray()) -> int:
	if playing:
		_end()
		if _log:
			_log.store_line("Final Score: " + str(score))
			for line in footer:
				_log.store_line(line)
		_close_log()
		MusicManager.play_sound_effect("game_over")
	return best_score()


## Play again: back to the timer selector. From the pause screen the trial so
## far still gets its row.
func retry() -> void:
	_end()
	_close_log()
	score = 0
	time_left = 0
	if countdown_display:
		countdown_display.hide()
	GlobalTimerManager.show_timer_selector_for_retry()


func to_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file(MENU_3D if GlobalSignals.selected_game_mode == "3D" else MENU_2D)


# ── the timer selector (GlobalTimerManager calls these) ──────────────────────

func _on_global_timer_play_pressed(seconds: int) -> void:
	GlobalTimerManager.start_countdown_with_time(seconds)
	time_left = seconds
	if countdown_display:
		countdown_display.set_time(seconds)
		countdown_display.show()
	_start()


func _on_global_timer_close_pressed() -> void:
	GlobalTimerManager.start_game_without_timer()
	time_left = 0
	if countdown_display:
		countdown_display.hide()
	_start()


func _on_countdown_updated(seconds: int) -> void:
	if not playing:
		return
	time_left = seconds
	if countdown_display:
		countdown_display.update_time(seconds)


func _on_countdown_finished() -> void:
	if playing:
		time_up.emit()


# ── the trial ────────────────────────────────────────────────────────────────

func _start() -> void:
	GlobalTimer.start_timer()
	_open_log()   # after the countdown starts: SessionLog takes GameDuration from it
	score = 0
	playing = true
	paused = false
	_log_timer.start()
	started.emit()


## Stops the trial if one is running: the countdown and MoveTime stop, the
## sessions.csv row is written and the best score saved.
func _end() -> void:
	if not playing:
		return
	playing = false
	paused = false
	_log_timer.stop()
	GlobalTimerManager.stop_countdown()
	GlobalTimer.stop_timer()
	SessionLog.end_trial()
	ScoreManager.update_top_score(patient_id, game_name, score)


func _open_log() -> void:
	_close_log()
	_log = Manager.create_game_log_file(game_name, patient_id)
	if _log:
		_log.store_csv_line(PackedStringArray(["epochtime"]) + columns)


func _write_row() -> void:
	if _log:
		_log.store_csv_line(PackedStringArray([Time.get_unix_time_from_system()] + row.call()))


func _close_log() -> void:
	if _log:
		_log.close()
		_log = null
