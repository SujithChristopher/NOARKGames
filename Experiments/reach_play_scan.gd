extends Node
## Experiment Random Reach, step 2: the workspace scan (the same reach scan every game asks for
## once a day, reach_scan.gd), with the tracker's hand even in debug and not recorded. Its outline
## goes into the run's folder (reach_boundary.json, as reach_store.gd writes it), not to a patient,
## then Random Reach starts in 2D. Esc or Back closes the run (nothing recorded) and goes back to
## the setup screen; Enter or Save ends the scan as it is. The mocap trigger is shown throughout.

const RoundRunner := preload("res://Games/firefly_reach/round_runner.gd")
const BackButton := preload("res://Games/firefly_reach/back_button.gd")
const SyncIndicatorScript := preload("res://Experiments/sync_indicator.gd")
const Run := preload("res://Experiments/reach_play_run.gd")

var _prev_scale_size := Vector2i.ZERO
var _prev_aspect := Window.CONTENT_SCALE_ASPECT_IGNORE
var runner: Node2D
var _to_game := false   # the scan is done: switch to the game once it has loaded


func _ready() -> void:
	GlobalScript.hold_tracking(self)   # outside res://Games/: ask for the hand
	Run.warm_game()
	# As reach_assessment.gd: the scan's art is for a 1920x1080 canvas, letterboxed.
	var root := get_tree().root
	_prev_scale_size = root.content_scale_size
	_prev_aspect = root.content_scale_aspect
	root.content_scale_size = Vector2i(1920, 1080)
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	runner = RoundRunner.new()
	runner.config = {"participant": "experiment", "day": 0, "quick": false, "resume": {},
		"level_index": 0, "order_id": 0, "show_check": false, "scan_only": true, "tracker": true}
	runner.scan_done.connect(_on_scan_done)
	add_child(runner)
	var back := BackButton.new()
	back.pressed.connect(_cancel)
	add_child(back)
	var save := BackButton.new()
	save.label = "Save"
	save.corner = Control.PRESET_BOTTOM_RIGHT
	save.pressed.connect(runner.accept_scan)
	add_child(save)
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	layer.add_child(SyncIndicatorScript.new())
	GlobalScript.link_connected_changed.connect(func(connected):
		if not connected:
			Run.finish(get_tree(), "stopped"))


func _on_scan_done(boundary: Array) -> void:
	if Run.phase != Run.Phase.SCAN:
		return
	Run.boundary = boundary
	Run.write_file("reach_boundary.json", JSON.stringify(
		{"saved": Time.get_datetime_string_from_system(), "boundary": boundary}, "\t"))
	_to_game = true
	_process(0.0)


## Waits for the background load rather than loading on the main thread: a long frame here
## stops the heartbeat and the tracker closes the run (reach_play_run.gd warm_game).
func _process(_delta: float) -> void:
	if not _to_game or Run.phase != Run.Phase.SCAN:
		return
	var game := Run.game_if_loaded()
	if game == null:
		return
	_to_game = false
	Run.phase = Run.Phase.PLAYING   # Random Reach sees it and plays the experiment, in 2D
	get_tree().change_scene_to_packed(game)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_cancel()


func _cancel() -> void:
	Run.finish(get_tree(), "stopped")


func _exit_tree() -> void:
	var root := get_tree().root
	root.content_scale_size = _prev_scale_size
	root.content_scale_aspect = _prev_aspect
	# Left some other way (the app closing): the run must not stay open on the tracker.
	if Run.phase == Run.Phase.SCAN:
		Run.finish(null, "stopped")
