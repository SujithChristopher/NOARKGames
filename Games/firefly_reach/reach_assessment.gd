extends Node

# Reach Scan assessment: the clinic study's "stretch the bubble" scan
# (reach_scan.gd) and nothing else. Saves the outline (reach_store.gd) for
# Firefly Reach, then returns to the menu. Esc leaves without saving.

const RoundRunner := preload("res://Games/firefly_reach/round_runner.gd")
const ReachStore := preload("res://Games/firefly_reach/reach_store.gd")

const MENU := "res://Main_screen/Scenes/select_game.tscn"

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
	var runner := RoundRunner.new()
	runner.config = {"participant": _patient_id, "day": 0, "quick": false, "resume": {},
		"level_index": 0, "order_id": 0, "show_check": false, "scan_only": true}
	runner.scan_done.connect(func(boundary: Array):
		ReachStore.save(_patient_id, boundary)
		get_tree().change_scene_to_file(MENU))
	add_child(runner)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		get_tree().change_scene_to_file(MENU)


func _exit_tree() -> void:
	var root := get_tree().root
	root.content_scale_size = _prev_scale_size
	root.content_scale_aspect = _prev_aspect
