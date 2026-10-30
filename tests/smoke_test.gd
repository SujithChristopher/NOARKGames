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
	# The game may have changed scene by itself (a redirect, a menu button).
	for node in [scene, get_tree().current_scene]:
		if is_instance_valid(node) and node != self:
			node.queue_free()
	get_tree().paused = false
	await get_tree().process_frame


static func _remove_tree(dir: String) -> void:
	for sub in DirAccess.get_directories_at(dir):
		_remove_tree(dir.path_join(sub))
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)
