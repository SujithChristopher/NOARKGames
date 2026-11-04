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

## Opening the login screens talks to the server (the patient sync, the patient
## lock), so these are only loaded: that still catches a broken script in them.
const LOADED_ONLY := ["res://Main_screen/Scenes/main.tscn", "res://Main_screen/Scenes/dose.tscn"]
const FRAMES := 120
const TRIAL_S := 2   ## countdown for the GameSession trial, seconds
const GameSession := preload("res://Main_screen/Scripts/game_session.gd")
const LinkProtocol := preload("res://Main_screen/Scripts/link_protocol.gd")
const SETTINGS_SCREEN := "res://Main_screen/Scenes/settings_screen.tscn"

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
	for path in LOADED_ONLY:
		print("SMOKE load %s" % path)
		if load(path) == null:
			push_error("SMOKE cannot load %s" % path)
	for entry in SCENES:
		await _run(entry[0], entry[1])
	await _camera_tab()
	print("SMOKE DONE %d scenes" % SCENES.size())
	get_tree().quit()


## Settings > Camera, with the tracker's messages fed in as the link would hand
## them over. A settings file in the user dir stands in for the real one.
func _camera_tab() -> void:
	print("SMOKE camera tab")
	Settings.path = GlobalSignals.data_path.path_join("settings.json")
	var scene := (load(SETTINGS_SCREEN) as PackedScene).instantiate()
	get_tree().root.add_child(scene)
	get_tree().current_scene = scene
	await get_tree().process_frame
	var tab = scene._camera

	# Over BLE it only says why not, and starts nothing.
	Settings.data["stream_type"] = "ble"
	var sent_before := _configs().size()
	tab.set_active(true)
	await get_tree().process_frame
	_check(not tab._controls.visible and "UDP" in tab._state.text, "over BLE the tab should say it needs UDP")
	_check(GlobalScript.tracking_mode() == "off", "over BLE the cameras must stay off")
	_check(_configs().size() == sent_before, "over BLE nothing should be sent")
	tab.set_active(false)

	# Shown over UDP: the cameras on, the preview asked for.
	Settings.data["stream_type"] = "udp"
	tab.set_active(true)
	await get_tree().process_frame
	_check(tab._controls.visible, "over UDP the controls should show")
	_check(GlobalScript.tracking_mode() == "position", "the tab should hold tracking")
	_check(_configs()[-1] == "preview=on", "the tab should ask for the preview")
	_check(not tab._sliders["gain"].editable, "no slider before the tracker says what is in force")
	_check(tab._value_labels["exposure"].text == "-", "no value before the tracker says what is in force")

	# A status: the sliders start from what is in force, the readout shows what
	# the sensors took, and a cap is spelled out.
	_feed(LinkProtocol.CAMERA_STATUS, JSON.stringify({
		"ask": [25000, 2.5], "exposure": [16353.0, null], "gain": [2.5, 2.5],
		"level": [19.0, 57.5], "blown": [0.0, 30.2], "tags": [3, 0], "fps": 59.6,
	}).to_utf8_buffer())
	_check(tab._sliders["gain"].editable, "the sliders should open after the first status")
	_check(tab._sliders["gain"].value == 2.5, "gain slider should start at 2.5")
	_check(tab._sliders["exposure"].value == 16000.0, "exposure slider should stop at its end")
	_check("16353" in tab._cells["exposure0"].text, "exposure read back not shown")
	_check("?" in tab._cells["exposure1"].text, "an unreadable sensor should show as ?")
	_check("dark" in tab._cells["level0"].text, "level 19 should read dark")
	_check("ok" in tab._cells["level1"].text, "level 57 should read ok")
	_check("30.2" in tab._cells["blown1"].text, "blown out not shown")
	_check(tab._cells["tags0"].text == "3", "tags not shown")
	_check("59.6" in tab._fps.text, "fps not shown")
	_check("25000" in tab._message.text and "16353" in tab._message.text, "a capped exposure should be spelled out")
	await _seconds(0.3)
	_check(_configs()[-1] == "preview=on", "starting the sliders should send nothing")

	# A preview becomes the picture.
	var picture := Image.create(640, 200, false, Image.FORMAT_RGB8)
	picture.fill(Color.GRAY)
	_feed(LinkProtocol.PREVIEW, picture.save_jpg_to_buffer())
	_check(tab._picture.texture != null and tab._picture.texture.get_size() == Vector2(640, 200),
		"the preview should become the picture")

	# A slider sends what it settled on, not every step of a drag.
	tab._sliders["gain"].value = 4.25
	tab._sliders["gain"].value = 5.25
	await _seconds(0.4)
	_check(_configs()[-1] == "gain=5.25", "the gain should go to the tracker, got %s" % _configs()[-1])
	_check(not _configs().has("gain=4.25"), "a passed-over value should not be sent")

	# Letting go saves it where the tracker reads it, a whole number when it is one.
	tab._sliders["exposure"].value = 5000
	tab._commit("exposure")
	var saved = JSON.parse_string(FileAccess.get_file_as_string(Settings.path))
	_check(saved is Dictionary and saved.get("camera_exposure_us") == 5000.0, "exposure not saved")
	_check(_configs()[-1] == "exposure=5000", "exposure should be sent as a whole number")

	# A refusal from the tracker is shown.
	GlobalScript.link_command_done.emit(LinkProtocol.CONFIG, false, "bad gain: 99")
	_check("bad gain" in tab._message.text, "a refusal should be shown")

	# The tracker restarted: it forgets the preview, so ask again.
	var asked_before := _configs().count("preview=on")
	GlobalScript.link_connected_changed.emit(true)
	_check(_configs().count("preview=on") == asked_before + 1, "a reconnect should ask for the preview again")

	# Leaving: everything stops.
	tab.set_active(false)
	await get_tree().process_frame
	_check(_configs()[-1] == "preview=off", "leaving should end the preview")
	_check(GlobalScript.tracking_mode() == "off", "leaving should let the cameras go")
	scene.queue_free()
	await get_tree().process_frame
	print("SMOKE camera tab done")


func _feed(kind: int, payload: PackedByteArray) -> void:
	var message := PackedByteArray([kind])
	message.append_array(payload)
	GlobalScript._on_tracker_message(kind, message)


## The CONFIG commands waiting to go out: no tracker answers in the smoke test.
func _configs() -> PackedStringArray:
	var out := PackedStringArray()
	for command in GlobalScript.link._queue:
		if command["kind"] == LinkProtocol.CONFIG:
			out.append(command["body"].get_string_from_utf8())
	return out


func _check(ok: bool, what: String) -> void:
	if not ok:
		push_error("SMOKE camera tab: %s" % what)


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
