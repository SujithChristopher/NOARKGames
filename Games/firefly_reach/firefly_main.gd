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

const MENU := "res://Main_screen/Scenes/select_game.tscn"
const LEVEL_INDEX := 1   # Protocol.LEVELS[1]: the middle level

var _runner: RoundRunner
var _patient_id: String = ""


func _ready() -> void:
	_patient_id = "vvv" if Manager.debug else PatientDB.current_patient_id
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


func _save_score() -> void:
	ScoreManager.update_top_score(_patient_id, RoundRunner.GAME_NAME, _runner.play_caught())


func _leave() -> void:
	get_tree().change_scene_to_file(MENU)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_leave()
