extends Node

# Entry of Firefly Reach (a game of the select-game menu), from the clinic
# study's fireflies: reach scan -> warm-up -> calibration rounds -> play rounds.
# If the patient has done the Reach Scan assessment (reach_assessment.gd) its
# outline is used and the game's own scan is skipped; otherwise the scan runs
# here and its outline is saved for next time.
# Score = fireflies caught in the play rounds (ScoreManager, "FireflyReach").
# Esc leaves for the menu at any time.

const RoundRunner := preload("res://Games/firefly_reach/round_runner.gd")
const ReachStore := preload("res://Games/firefly_reach/reach_store.gd")
const Protocol := preload("res://Games/firefly_reach/protocol.gd")
const TuningPanel := preload("res://Games/random_reach/Scripts/tuning_panel.gd")

const MENU := "res://Main_screen/Scenes/select_game.tscn"
const LEVEL_INDEX := 1   # Protocol.LEVELS[1]: the middle level

var _runner: RoundRunner
var _patient_id: String = ""
var _prev_scale_size := Vector2i.ZERO
var _prev_aspect := Window.CONTENT_SCALE_ASPECT_IGNORE


func _ready() -> void:
	# The art is authored in pixels for a 1920x1080 canvas (the project default is
	# 1152x648, which renders it ~1.67x too big). Letterbox rather than stretch so a
	# table circle stays a circle; both are restored in _exit_tree.
	var root := get_tree().root
	_prev_scale_size = root.content_scale_size
	_prev_aspect = root.content_scale_aspect
	root.content_scale_size = Vector2i(1920, 1080)
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	_patient_id = "vvv" if Manager.debug else PatientDB.current_patient_id
	GlobalTimerManager.stop_countdown()   # untimed: no GameDuration left over from another game
	_runner = RoundRunner.new()
	_runner.config = {
		"participant": _patient_id, "day": 0, "quick": false, "resume": {},
		"level_index": LEVEL_INDEX, "order_id": 0, "show_check": false,
		"boundary": ReachStore.load_boundary(_patient_id),
	}
	_runner.scan_done.connect(func(boundary: Array): ReachStore.save(_patient_id, boundary))
	_runner.finished.connect(_save_score)
	_runner.leave.connect(_leave)
	add_child(_runner)
	add_child(TuningPanel.new())   # live tracker tuning: F2 or the Tune button


func _save_score() -> void:
	SessionLog.end_trial()
	ScoreManager.update_top_score(_patient_id, RoundRunner.GAME_NAME, _runner.play_caught())


func _leave() -> void:
	get_tree().change_scene_to_file(MENU)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_leave()


func _exit_tree() -> void:
	SessionLog.end_trial()   # left early: the trial still gets its row
	var root := get_tree().root
	root.content_scale_size = _prev_scale_size
	root.content_scale_aspect = _prev_aspect
