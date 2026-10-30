extends Node
## Opens every game scene in turn and lets it run for a moment, so a broken node
## path, a missing autoload or a script error shows up without playing the game.
## GDScript cannot catch an error itself, so this only drives the scenes:
## tests/smoke.py runs it headless and fails on any error Godot prints.
##
##     python tests/smoke.py
##
## Nothing reaches patient data or the server: debug is switched on in memory
## only (patient vvv, no upload; Settings is never saved) and the data folder
## points at Godot's user dir.

const FRAMES := 120
const TRIAL_S := 2   ## countdown for the GameSession trial, seconds
const GameSession := preload("res://Main_screen/Scripts/game_session.gd")

## [scene, mode]. The 2D+3D games run in both modes.
const SCENES := [
	["res://Games/fruit_catcher/Scenes/Game/Game.tscn", "2D"],
	["res://Games/ping_pong/Scenes/PingPong.tscn", "2D"],
	["res://Games/flappy_bird/Scenes/flappy_main.tscn", "2D"],
	["res://Games/flappy_bird/Scenes/flappy_main.tscn", "3D"],
	["res://Games/random_reach/scenes/random_reach.tscn", "2D"],
	["res://Games/random_reach/scenes/random_reach.tscn", "3D"],
	["res://Games/cannon_defense/cannon_defense.tscn", "2D"],
	["res://Games/firefly_reach/firefly_main.tscn", "2D"],
	["res://Games/firefly_reach/reach_assessment.tscn", "2D"],
	["res://Games/Jumpify/Scenes/Levels/Level_01.tscn", "3D"],
	["res://Main_screen/Scenes/select_game.tscn", "2D"],
	["res://Main_screen/Scenes/3d_games.tscn", "3D"],
	["res://Main_screen/Scenes/trunk_view.tscn", "2D"],
	["res://Results/scenes/user_progress.tscn", "2D"],
]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # games pause the tree behind their menus
	Settings.data["debug"] = true
	GlobalSignals.data_path = OS.get_user_data_dir().path_join("smoke")
	_remove_tree(GlobalSignals.data_path)   # FireflyReach logs from _ready: start empty
	await get_tree().process_frame
	for entry in SCENES:
		await _run(entry[0], entry[1])
	print("SMOKE DONE %d scenes" % SCENES.size())
	get_tree().quit()


func _run(path: String, mode: String) -> void:
	print("SMOKE scene %s %s" % [path, mode])
	GlobalSignals.selected_game_mode = mode
	var packed := load(path) as PackedScene
	if packed == null:
		push_error("SMOKE cannot load %s" % path)
		return
	var scene := packed.instantiate()
	get_tree().root.add_child(scene)
	get_tree().current_scene = scene
	for i in FRAMES:
		await get_tree().process_frame
	var session := _find_session(scene) if is_instance_valid(scene) else null
	if session:
		await _trial(session)
	# The game may have changed scene by itself (a redirect, a menu button).
	for node in [scene, get_tree().current_scene]:
		if is_instance_valid(node) and node != self:
			node.queue_free()
	get_tree().paused = false
	await get_tree().process_frame


## A game on GameSession: one short trial through the session (Play with a
## countdown, a pause, the countdown ending the game, a retry) and what it wrote.
func _trial(session: GameSession) -> void:
	var name := session.game_name
	var sessions_before := SessionLog.read_sessions(session.patient_id).size()
	session._on_global_timer_play_pressed(TRIAL_S)   # the timer selector's Play
	if not session.playing or session._log == null:
		push_error("SMOKE trial %s: Play did not open a trial" % name)
		return
	var raw := session._log.get_path_absolute()
	await _seconds(0.5)
	session.pause()
	await _seconds(0.3)
	session.resume()
	var waited := 0.0
	while session.playing and waited < TRIAL_S + 3.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	if session.playing:
		push_error("SMOKE trial %s: the countdown did not end the game" % name)
		return

	var lines := FileAccess.get_file_as_string(raw).split("\n", false)
	var header := ",".join(PackedStringArray(["epochtime"]) + session.columns)
	if lines.size() < 10 or lines[7] != header:
		push_error("SMOKE trial %s: raw header is not %s" % [name, header])
		return
	var end := lines.find("Final Score: %d" % session.score)   # a game may add lines after it
	if end < 0:
		push_error("SMOKE trial %s: no 'Final Score: %d' line" % [name, session.score])
		return
	var rows := lines.slice(8, end)
	var width := header.split(",").size()
	for r in rows:
		if r.split(",").size() != width:
			push_error("SMOKE trial %s: a row has %d fields, not %d: %s" % [name, r.split(",").size(), width, r])
			return
	if rows.size() < 50:
		push_error("SMOKE trial %s: only %d rows in %.1f s" % [name, rows.size(), TRIAL_S + 0.3])
	if SessionLog.read_sessions(session.patient_id).size() != sessions_before + 1:
		push_error("SMOKE trial %s: no sessions.csv row" % name)

	var score := session.score
	session.retry()
	if session.playing or not GlobalTimerManager.timer_selector_instance.visible:
		push_error("SMOKE trial %s: retry did not go back to the timer selector" % name)
	print("SMOKE trial %s: %d rows, score %d" % [name, rows.size(), score])


static func _find_session(scene: Node) -> GameSession:
	for node in scene.find_children("*", "", true, false):
		if node is GameSession:
			return node
	return null


func _seconds(s: float) -> void:
	await get_tree().create_timer(s, true).timeout


static func _remove_tree(dir: String) -> void:
	for sub in DirAccess.get_directories_at(dir):
		_remove_tree(dir.path_join(sub))
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)
