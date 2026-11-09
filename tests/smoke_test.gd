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
const MENU_2D := "res://Main_screen/Scenes/select_game.tscn"
const CANNON := "res://Games/cannon_defense/cannon_defense.tscn"
const RotationInput := preload("res://Games/cannon_defense/rotation_input.gd")
const REACH_SCAN := "res://Games/firefly_reach/reach_assessment.tscn"
const SHEEP_FLOCK := "res://Games/random_reach/Scripts/sheep_flock.gd"
const APPLE := "res://Games/random_reach/scenes/apple.tscn"
const MAIN_SCREEN := "res://Main_screen/Scenes/main.tscn"
const STATIC_GRID := "res://Experiments/static_grid.tscn"
const StaticGrid := preload("res://Experiments/static_grid.gd")
const CONTINUOUS_RAW := "res://Experiments/continuous_raw.tscn"
const ContinuousRaw := preload("res://Experiments/continuous_raw.gd")
const REACH_PLAY := "res://Experiments/reach_play.tscn"
const ReachPlay := preload("res://Experiments/reach_play.gd")
const ReachPlayRun := preload("res://Experiments/reach_play_run.gd")
const ReachArea := preload("res://Games/random_reach/Scripts/reach_area.gd")

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
	["res://Experiments/experiment_menu.tscn", "2D"],
	[STATIC_GRID, "2D"],
	[CONTINUOUS_RAW, "2D"],
	[REACH_PLAY, "2D"],
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
	await _debug_means_mouse()
	_cannon_range_is_the_arc()
	await _cannon_calibrates_on_enter()
	await _sheep_snack_is_heard()
	await _leaving_main_screen_skips_the_sync()
	await _camera_tab()
	await _calibration_tab()
	_grid_points()
	_reach_area()
	await _static_grid_run()
	await _continuous_raw_run()
	await _reach_play_run()
	print("SMOKE DONE %d scenes" % SCENES.size())
	get_tree().quit()


## Random Reach's apples inside the reach outline: the whole apple, inside the box.
func _reach_area() -> void:
	print("SMOKE reach area")
	var square := PackedVector2Array([Vector2(300, 250), Vector2(500, 250), Vector2(500, 450), Vector2(300, 450)])
	_check(ReachArea.fits(square, Vector2(400, 350), 26.0), "an apple in the middle fits")
	_check(not ReachArea.fits(square, Vector2(310, 350), 26.0), "one over the edge does not, though its centre is in")
	_check(not ReachArea.fits(square, Vector2(700, 350), 26.0), "one outside does not")
	for i in 50:
		var c = ReachArea.pick(square, 26.0, Vector2i(200, 200), Vector2i(900, 600))
		_check(c != null and ReachArea.fits(square, c, 26.0), "picked inside: %s" % str(c))
	_check(ReachArea.pick(square, 26.0, Vector2i(600, 200), Vector2i(900, 600)) == null, "none outside the box")
	_check(ReachArea.pick(PackedVector2Array([Vector2(400, 300), Vector2(420, 300), Vector2(400, 320)]),
		26.0, Vector2i(200, 200), Vector2i(900, 600)) == null, "none in an outline too small")
	_check(ReachArea.outline_px([[0, 0], [1]]).is_empty(), "no outline from under 3 points")
	# The drawn workspace: a 200 px square onto the 700 x 400 box, one scale, centred.
	var view := ReachArea.view_fit(square, Vector2i(200, 200), Vector2i(900, 600))
	_check(is_equal_approx(view.get_scale().x, 2.0) and is_equal_approx(view.get_scale().y, 2.0), "one scale, the tighter side: %s" % str(view.get_scale()))
	_check((view * Vector2(400, 350)).is_equal_approx(Vector2(550, 400)), "its centre on the box's")
	var tiny := PackedVector2Array([Vector2(400, 300), Vector2(420, 300), Vector2(400, 320)])
	_check(is_equal_approx(ReachArea.view_fit(tiny, Vector2i(200, 200), Vector2i(900, 600)).get_scale().x, ReachArea.GAIN_MAX), "the gain limited")
	_check(ReachArea.view_fit(PackedVector2Array(), Vector2i(200, 200), Vector2i(900, 600)) == Transform2D.IDENTITY, "no outline, no scaling")


## The experiment's grid: 4 x 6 inside the margin, snaking, row 1 at the top.
func _grid_points() -> void:
	print("SMOKE grid points")
	var corners := [Vector2(-500, -300), Vector2(-500, 300), Vector2(500, 300), Vector2(500, -300)]
	var points := StaticGrid.grid_targets(corners, 4, 6, 50.0)
	_check(points.size() == 24, "24 points, got %d" % points.size())
	var first: Dictionary = points[0]
	_check(first["mm"].is_equal_approx(Vector2(-450, -250)) and first["row"] == 1 and first["col"] == 1,
		"first point at the top-left margin: %s" % str(first))
	_check(points[5]["mm"].is_equal_approx(Vector2(450, -250)) and points[5]["col"] == 6,
		"row 1 ends at the top-right margin: %s" % str(points[5]))
	_check(points[6]["col"] == 6 and points[6]["row"] == 2, "row 2 starts where row 1 ended: %s" % str(points[6]))
	_check(points[23]["mm"].is_equal_approx(Vector2(-450, 250)), "last point: %s" % str(points[23]))
	_check(points[23]["index"] == 24, "indexed in visiting order")
	_check(StaticGrid.grid_targets(corners, 4, 6, 300.0).is_empty(), "no room inside that margin")
	# One row or column sits on the middle line, however big the margin.
	_check(StaticGrid.grid_targets(corners, 1, 1, 50.0)[0]["mm"].is_equal_approx(Vector2.ZERO), "1 x 1 is the centre")


## One run through the screen, with the tracker's answers fed in: start, each point held
## until it captures, a capture rejected and repeated, the end. Nothing leaves the app:
## the link is marked connected only for the Start press, and what it would have sent is read back.
func _static_grid_run() -> void:
	print("SMOKE scene static grid run")
	var table_was := [GlobalScript.table_set, GlobalScript.table_k, GlobalScript._table_corners, GlobalScript._table_basis, GlobalScript._table_centre]
	# set in memory only: set_table would write table.json over the real one.
	GlobalScript.table_set = true
	GlobalScript.table_k = 1000.0
	GlobalScript._table_basis = Transform2D.IDENTITY
	GlobalScript._table_centre = Vector2.ZERO
	GlobalScript._table_corners = [Vector2(-0.4, -0.25), Vector2(-0.4, 0.25), Vector2(0.4, 0.25), Vector2(0.4, -0.25)]
	var scene: Control = (load(STATIC_GRID) as PackedScene).instantiate()
	get_tree().root.add_child(scene)
	get_tree().current_scene = scene
	await get_tree().process_frame
	_check(scene._start_button.disabled, "no start without the experiment's name")
	scene._label.text = "trial 03/a"
	scene._label.text_changed.emit(scene._label.text)
	_check(scene._run_label() == "trial_03a", "the name as a folder: %s" % scene._run_label())
	_check(not scene._start_button.disabled, "named, with a table with corners, it can start")
	scene._inputs["rows"].value = 1
	scene._inputs["cols"].value = 2
	scene._inputs["settle_s"].value = 0.05

	GlobalScript.link.connected = true
	scene._start()
	GlobalScript.link.connected = false   # so the link does not send what it holds
	GlobalScript.link_command_done.emit(LinkProtocol.EXPERIMENT, true, "/somewhere")
	_check(scene._view == StaticGrid.View.RUN, "the tracker's yes starts the run")
	var sent: Array = _experiment_commands()
	_check(sent[0] == "start static_grid 60 trial_03a", "start: %s" % str(sent))
	for command in sent:
		_check(command.length() < 240, "fits one BLE write: %d: %s" % [command.length(), command])
	_check(sent.any(func(c): return c.begins_with("meta table_frame")), "the table goes with the run")

	# Away from the point: nothing captures.
	_put_hand(Vector2(0.0, 0.0))
	for i in 10:
		_put_hand(Vector2(0.0, 0.0))
		await get_tree().process_frame
	_check(not scene._capturing, "away from the point nothing captures")

	# On the point and still: it captures, the target's numbers in the command.
	var point: Vector2 = scene._targets[0]["mm"]
	await _hold_hand(scene, point / 1000.0)
	_check(scene._capturing, "held on the point: it captures")
	var capture: String = _experiment_commands().back()
	_check(capture.begins_with("capture 1 1 1 -350.000 0.000 30"), "capture: %s" % capture)

	# Rejected: still point 1, and it has to be held again.
	_feed_experiment({"state": "ready", "last": {"target": 1, "attempt": 1, "accepted": false, "reason": "moved"}})
	_check(not scene._capturing and scene._at == 0, "a rejected capture asks for the same point")
	await _hold_hand(scene, point / 1000.0)
	_check(_experiment_commands().back().begins_with("capture 1 "), "point 1 again")
	# An answer about the attempt before does not count.
	_feed_experiment({"state": "capturing", "last": {"target": 1, "attempt": 1, "accepted": false, "reason": "moved"},
		"capture": {"target": 1, "attempt": 2, "frames": 30, "ok": 12, "failed": 0}})
	_check(scene._capturing and scene._capture_ok == 12, "still on the second attempt")
	_feed_experiment({"state": "ready", "last": {"target": 1, "attempt": 2, "accepted": true, "reason": ""}})
	_check(scene._at == 1, "accepted: the next point lights up")

	# The last point ends the run, and the tracker's word says where it went.
	var last: Vector2 = scene._targets[1]["mm"]
	await _hold_hand(scene, last / 1000.0)
	_feed_experiment({"state": "ready", "last": {"target": 2, "attempt": 1, "accepted": true, "reason": ""}})
	_check(scene._view == StaticGrid.View.DONE, "the last point ends the run")
	_check(_experiment_commands().back() == "stop complete", "stop: %s" % _experiment_commands().back())
	_feed_experiment({"state": "idle", "last": null, "saved": {"path": "/there/run_1", "status": "complete", "accepted": 2, "dropped": [0, 0]}})
	_check("/there/run_1" in scene._done_text.text, "says where: %s" % scene._done_text.text)

	GlobalScript.link._queue.clear()
	scene.queue_free()
	await get_tree().process_frame
	GlobalScript.table_set = table_was[0]
	GlobalScript.table_k = table_was[1]
	GlobalScript._table_corners = table_was[2]
	GlobalScript._table_basis = table_was[3]
	GlobalScript._table_centre = table_was[4]


## The continuous raw capture with the tracker's answers fed in: Start, the feeds counted,
## Stop, then a second recording ended by the tracker (disk nearly full); the mocap trigger shown throughout.
## As the static grid run, nothing leaves the app.
func _continuous_raw_run() -> void:
	print("SMOKE scene continuous raw run")
	var scene: Control = (load(CONTINUOUS_RAW) as PackedScene).instantiate()
	get_tree().root.add_child(scene)
	get_tree().current_scene = scene
	await get_tree().process_frame
	_check(scene._toggle.disabled and scene._toggle.text == "Start", "no start without the experiment's name")
	scene._label.text = "rec 1"
	scene._label.text_changed.emit(scene._label.text)
	_check(scene._fps.get_item_text(scene._fps.selected) == "%d fps" % int(Settings.get_value("recording_fps", 30)) \
		or Settings.get_value("recording_fps", 30) == 0, "the session recording's rate to begin with")
	scene._fps.select(ContinuousRaw.FPS_CHOICES.find(60))
	scene._fps.item_selected.emit(scene._fps.selected)
	_check("60 fps" in scene._info.text, "the estimate follows the rate: %s" % scene._info.text)
	_check(not scene._toggle.disabled, "named, it can start")

	var sync: Control = scene.get_children().filter(func(n): return n.get("edges") != null)[0]
	_check(sync._state.text == "?", "the trigger unknown until the tracker says: %s" % sync._state.text)
	_feed_experiment({"state": "idle", "last": null, "saved": null,
		"sync": {"available": true, "level": 0, "edges": 0, "edge_timestamps": true}})
	_check(sync._state.text == "LOW", "LOW: %s" % sync._state.text)

	# Both feeds: the tracker's PREVIEW, one picture of the two side by side.
	_check(scene._picture.texture == null and scene._no_picture.visible, "no picture before one comes")
	var feeds := Image.create(64, 20, false, Image.FORMAT_RGB8)
	feeds.fill(Color.GRAY)
	_feed(LinkProtocol.PREVIEW, feeds.save_jpg_to_buffer())
	_check(scene._picture.texture != null and not scene._no_picture.visible, "the feeds are shown")
	_feed(LinkProtocol.CAMERA_STATUS, JSON.stringify({"fps": 98.0, "level": [80, 90], "blown": [0, 0.5]}).to_utf8_buffer())
	_check("98 fps" in scene._camera_info.text, "camera status: %s" % scene._camera_info.text)

	GlobalScript.link.connected = true
	scene._toggle.pressed.emit()
	GlobalScript.link.connected = false
	GlobalScript.link_command_done.emit(LinkProtocol.EXPERIMENT, true, "sync")
	_check(scene._state == ContinuousRaw.State.STARTING, "the indicator's watch ACK is not the start's")
	GlobalScript.link_command_done.emit(LinkProtocol.EXPERIMENT, true, "/somewhere")
	_check(scene._state == ContinuousRaw.State.RECORDING and scene._toggle.text == "Stop",
		"the tracker's yes: recording, the button says Stop")
	_check(scene._fps.disabled, "no changing the rate mid-recording")
	var sent: Array = _experiment_commands()
	_check(sent[0] == "start continuous_raw 3600 rec_1 raw 60", "start: %s" % str(sent))
	_check(sent.back() == "record", "then record, with no end: %s" % str(sent))
	_check(not sent.any(func(c): return c.begins_with("meta table")), "no tracker data asked for")
	for command in sent:
		_check(command.length() < 240, "fits one BLE write: %d: %s" % [command.length(), command])

	_feed_experiment({"state": "capturing", "last": null, "saved": null,
		"capture": {"target": 1, "attempt": 1, "frames": 420, "ok": 0, "failed": 0, "elapsed_s": 4.2},
		"sync": {"available": true, "level": 1, "edges": 1, "edge_timestamps": true}})
	_check(scene._frames == 420 and scene._clock.text == "00:04", "counts: %s" % scene._clock.text)
	_check(sync._state.text == "HIGH" and sync.edges == 1, "HIGH: %s" % sync._state.text)

	scene._toggle.pressed.emit()
	_check(scene._state == ContinuousRaw.State.SAVING and scene._toggle.disabled, "Stop: saving")
	_check(_experiment_commands().back() == "stop complete", "stop: %s" % _experiment_commands().back())
	_feed_experiment({"state": "capturing", "capture": {"target": 1, "attempt": 1, "frames": 430}})
	_check(scene._state == ContinuousRaw.State.SAVING, "a status sent before the stop changes nothing")
	_feed_experiment({"state": "idle", "last": null, "saved": {"path": "/there/rec_1", "status": "complete", "accepted": 1, "dropped": [0, 0]},
		"sync": {"available": false}})
	_check(scene._state == ContinuousRaw.State.IDLE and scene._toggle.text == "Start", "saved: Start again")
	_check("/there/rec_1" in scene._saved_label.text, "says where: %s" % scene._saved_label.text)
	_check(sync._state.text == "NO LINE", "no line: %s" % sync._state.text)

	# A second recording, ended by the tracker: the disk nearly full.
	GlobalScript.link._queue.clear()
	GlobalScript.link.connected = true
	scene._toggle.pressed.emit()
	GlobalScript.link.connected = false
	GlobalScript.link_command_done.emit(LinkProtocol.EXPERIMENT, true, "/somewhere/else")
	_feed_experiment({"state": "capturing", "capture": {"target": 1, "attempt": 1, "frames": 10, "elapsed_s": 0.1}})
	_feed_experiment({"state": "ready", "last": {"target": 1, "attempt": 1, "accepted": true, "reason": "disk_full", "frames": 2990}})
	_check(scene._state == ContinuousRaw.State.SAVING and scene._frames == 2990, "a full disk ends it")
	_check(_experiment_commands().back() == "stop complete", "and the app closes the run")
	_feed_experiment({"state": "idle", "last": null, "saved": {"path": "/there/rec_2", "status": "complete", "accepted": 1, "dropped": [0, 0]}})
	_check("nearly full" in scene._saved_label.text, "says why it stopped: %s" % scene._saved_label.text)

	GlobalScript.link._queue.clear()
	scene.queue_free()
	await get_tree().process_frame


## Random Reach as an experiment, with the tracker's answers fed in: the setup screen's Start
## opens a play run at the chosen rate and size, the scan's outline goes into the run's folder,
## the game plays at once for the run's time and records, game over stops the run, and the setup
## screen says it is saved. Then a scan left with Esc: the run closes, nothing recorded.
func _reach_play_run() -> void:
	print("SMOKE scene reach play run")
	# The game's files go beside the data folder: never the real one.
	GlobalSignals.data_path = OS.get_user_data_dir().path_join("smoke")
	var setup: Control = (load(REACH_PLAY) as PackedScene).instantiate()
	get_tree().root.add_child(setup)
	get_tree().current_scene = setup
	await get_tree().process_frame
	_check(setup._start.disabled, "no start without the experiment's name")
	setup._label.text = "rr 1"
	setup._label.text_changed.emit(setup._label.text)
	setup._fps.select(ReachPlay.FPS_CHOICES.find(60))
	setup._fps.item_selected.emit(setup._fps.selected)
	setup._scale.select(ReachPlay.SCALE_CHOICES.find(0.5))
	setup._scale.item_selected.emit(setup._scale.selected)
	setup._minutes.value = 1.0
	_check("60 fps" in setup._info.text and "640 x 400" in setup._info.text, "the estimate: %s" % setup._info.text)
	_check(not setup._start.disabled, "named, it can start")

	GlobalScript.link.connected = true
	setup._start.pressed.emit()
	GlobalScript.link.connected = false
	_check(setup._state == ReachPlay.State.STARTING, "waits for the tracker")
	GlobalScript.link_command_done.emit(LinkProtocol.EXPERIMENT, true, "sync")
	_check(setup._state == ReachPlay.State.STARTING, "the indicator's watch ACK is not the start's")
	var sent: Array = _experiment_commands()
	_check(sent[0] == "start reach_play 3600 rr_1 play 60 0.50", "start: %s" % str(sent))
	GlobalScript.link_command_done.emit(LinkProtocol.EXPERIMENT, true, "/there/reach_play/rr_1_x")
	_check(ReachPlayRun.phase == ReachPlayRun.Phase.SCAN, "the tracker's yes: the scan")
	sent = _experiment_commands()
	_check(sent.any(func(c): return c.begins_with("meta table_frame")), "the table goes with the run")
	_check(not sent.has("record"), "the scan is not recorded")
	for command in sent:
		_check(command.length() < 240, "fits one BLE write: %d: %s" % [command.length(), command])
	await get_tree().process_frame
	await get_tree().process_frame
	var scan = get_tree().current_scene
	_check(scan != null and scan.scene_file_path == ReachPlayRun.SCAN, "the scan opens: %s" % str(scan))
	_check(scan.runner.config.get("tracker", false), "the scan takes the tracker's hand, even in debug")

	# The scan's outline: into the run's folder, then the game.
	GlobalScript.link._queue.clear()
	scan._on_scan_done([[-100, -100], [150, -100], [-100, 150]])
	_check(FileAccess.file_exists(ReachPlayRun.local_dir().path_join("reach_boundary.json")), "the outline is saved with the run")
	# The game opens once its background load is done: the switch never loads it on the main thread.
	var waited := Time.get_ticks_msec()
	while Time.get_ticks_msec() - waited < 20000 and (get_tree().current_scene == null \
			or get_tree().current_scene.scene_file_path != ReachPlayRun.GAME):
		await get_tree().process_frame
	for i in 3:
		await get_tree().process_frame
	var game = get_tree().current_scene
	_check(game != null and game.scene_file_path == ReachPlayRun.GAME, "Random Reach opens: %s" % str(game))
	var player = game.get_node("Player")
	_check(player._exp != null and not player.is_3d_mode and not player.debug_mode, "the experiment's game: 2D, the tracker")
	_check(player.game_started and GlobalTimerManager.countdown_total == 60, "plays at once for the run's time")
	_check(GlobalScript.tracking_mode() == "position", "asks the tracker for the hand in debug too")
	_check(_experiment_commands().has("record"), "records from play: %s" % str(_experiment_commands()))
	# Apples only where the run's scan says the hand reaches.
	var outline: PackedVector2Array = player._reach_outline()
	_check(outline.size() == 3, "the scan's outline in the game: %s" % str(outline))
	for i in 20:
		if player.current_apple != null:
			player.current_apple.free()
			player.current_apple = null
		player._spawn_new_apple()
		_check(ReachArea.fits(outline, player.current_apple.position, player._apple_radius()),
			"the apple inside the outline: %s" % str(player.current_apple.position))
	_check(player.apples_outside_outline == 0, "none had to go outside")
	# Scaled for the eye only: what is logged is the real hand and the real apple.
	_check(not is_equal_approx(player.view_gain(), 1.0), "the workspace is drawn scaled: %s" % player.view_gain())
	var apple_real: Vector2 = player._view_inv * player.current_apple.position
	_check(is_equal_approx(player.target_x, (apple_real.x - GlobalScript.X_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_X),
		"the apple logged where it really is")
	var hand_was: Vector2 = GlobalScript.network_position
	var real_hand := Vector2(GlobalScript.X_SCREEN_OFFSET + 30, GlobalScript.Y_SCREEN_OFFSET + 20)
	GlobalScript.network_position = real_hand
	for i in 40:
		player._update_player_position()
	GlobalScript.network_position = hand_was
	_check(player.position.distance_to(player._view * real_hand) < 0.5, "the sheep drawn scaled: %s" % str(player.position))
	_check(absf(player.game_x - 30.0 / GlobalScript.PLAYER_POS_SCALER_X) < 1e-4 \
		and absf(player.game_z - 20.0 / GlobalScript.PLAYER_POS_SCALER_Z) < 1e-4,
		"the hand logged unscaled: %f %f" % [player.game_x, player.game_z])
	_check(not game.get_node("Paused/Restart").visible, "no restart in the experiment")
	var sync: Array = player._exp.find_children("*", "PanelContainer", true, false) \
		.filter(func(n): return n.get("edges") != null)
	_check(sync.size() == 1, "the mocap trigger is shown in the game")
	_feed_experiment({"state": "capturing", "capture": {"target": 1, "attempt": 1, "frames": 300, "elapsed_s": 5.0},
		"sync": {"available": true, "level": 1, "edges": 3, "edge_timestamps": true}})
	_check(player._exp.frames == 300, "counts the frames saved")
	player.score = 4
	await get_tree().create_timer(0.1).timeout   # a few of the game's rows

	# The time up with the mocap's line HIGH: frozen, still recording, waiting for it to go LOW.
	GlobalScript.link._queue.clear()
	player.show_game_over()
	_check(player._exp.waiting_sync and not _experiment_commands().any(func(c): return c.begins_with("stop")),
		"sync HIGH at the time up: waits, still recording: %s" % str(_experiment_commands()))
	_check(player._exp._dialog != null and player._exp._dialog.visible, "says it waits for the mocap")
	await get_tree().create_timer(0.1).timeout
	_check(get_tree().current_scene == game, "still in the game while the mocap runs")
	_feed_experiment({"state": "capturing", "capture": {"target": 1, "attempt": 1, "frames": 310, "elapsed_s": 5.1},
		"sync": {"available": true, "level": 0, "edges": 4, "edge_timestamps": true}})
	await get_tree().create_timer(0.2).timeout
	_check(not _experiment_commands().any(func(c): return c.begins_with("stop")), "LOW: the half second first")
	_check(player._exp.waiting_sync and player._exp._low_at_ms >= 0, "LOW seen, the tail running")
	# The half second gone by, in one step: the link is connected for this call only, so nothing leaves.
	player._exp._low_at_ms -= 600
	GlobalScript.link.connected = true
	player._exp._process(0.0)
	GlobalScript.link.connected = false
	var ended: Array = _experiment_commands()
	_check(ended.back() == "stop complete", "then the run stops: %s" % str(ended))
	_check(ended.any(func(c): return c.begins_with("meta game_end") and "mocap_stopped" in c), "how it ended, in the metadata: %s" % str(ended))
	var csv := FileAccess.get_file_as_string(ReachPlayRun.local_dir().path_join("random_reach.csv"))
	_check(csv.begins_with("epochtime,score,") and csv.strip_edges().ends_with("Final Score: 4"), "the game's rows: %s" % csv.left(80))
	_check(csv.split("\n").size() > 3, "rows were logged")
	await get_tree().process_frame
	await get_tree().process_frame
	setup = get_tree().current_scene
	_check(setup != null and setup.scene_file_path == REACH_PLAY, "back to the setup screen")
	_check(setup._state == ReachPlay.State.SAVING, "waits for the tracker to save")
	_feed_experiment({"state": "idle", "last": null, "saved": {"path": "/there/reach_play/rr_1_x", "status": "complete", "accepted": 1, "dropped": [0, 0]}})
	_check(setup._state == ReachPlay.State.IDLE and "Score 4" in setup._saved_label.text \
		and "310 frames" in setup._saved_label.text, "saved: %s" % setup._saved_label.text)
	_check(setup._label.text == "rr 1" or setup._label.text == "rr_1", "the choices are kept for the next run")

	# A second run, its scan left with Esc: closed, nothing recorded.
	GlobalScript.link._queue.clear()
	GlobalScript.link.connected = true
	setup._start.pressed.emit()
	GlobalScript.link.connected = false
	GlobalScript.link_command_done.emit(LinkProtocol.EXPERIMENT, true, "/there/reach_play/rr_1_y")
	await get_tree().process_frame
	await get_tree().process_frame
	scan = get_tree().current_scene
	GlobalScript.link.connected = true
	scan._cancel()
	GlobalScript.link.connected = false
	_check(_experiment_commands().back() == "stop stopped", "Esc in the scan closes the run")
	await get_tree().process_frame
	await get_tree().process_frame
	setup = get_tree().current_scene
	_feed_experiment({"state": "idle", "last": null, "saved": {"path": "/there/reach_play/rr_1_y", "status": "stopped", "accepted": 0, "dropped": [0, 0]}})
	_check("nothing recorded" in setup._saved_label.text, "says so: %s" % setup._saved_label.text)

	var made := GlobalSignals.data_path.get_base_dir().path_join("experiments")
	if made.begins_with(OS.get_user_data_dir()):
		_remove_tree(made)
	GlobalScript.link._queue.clear()
	ReachPlayRun.phase = ReachPlayRun.Phase.NONE
	setup.queue_free()
	await get_tree().process_frame


func _put_hand(table_m: Vector2) -> void:
	GlobalScript.table_r = table_m
	GlobalScript.last_packet_ms = Time.get_ticks_msec()


## Keeps the hand there until the screen asks for a capture, or a second has passed.
func _hold_hand(scene: Control, table_m: Vector2) -> void:
	var end := Time.get_ticks_msec() + 1000
	while not scene._capturing and Time.get_ticks_msec() < end:
		_put_hand(table_m)
		await get_tree().process_frame


func _feed_experiment(info: Dictionary) -> void:
	_feed(LinkProtocol.EXPERIMENT_STATUS, JSON.stringify(info).to_utf8_buffer())


## The EXPERIMENT commands waiting to go out, as text.
func _experiment_commands() -> Array:
	var out := []
	for command in GlobalScript.link._queue:
		if command["kind"] == LinkProtocol.EXPERIMENT:
			out.append(command["body"].get_string_from_utf8())
	return out


## Cannon Defense's whole arc is the patient's turn from initial to max: both are
## usually the extremes of what that arm allows, so there is no middle to measure from.
func _cannon_range_is_the_arc() -> void:
	print("SMOKE cannon range")
	# Any grip: an arbitrary axis and starting orientation, turned either way round.
	var about := Vector3(1, 2, -2).normalized()
	var start := Basis(Vector3.RIGHT, 0.7)
	for way in [1.0, -1.0]:
		var at := func(deg: float) -> Basis: return Basis(about, deg_to_rad(way * deg)) * start
		# [degrees turned from initial, aim for start_side 1]; start_side -1 mirrors it.
		for turn in [[0.0, 65.0], [15.0, 32.5], [30.0, 0.0], [60.0, -65.0], [-10.0, 65.0], [75.0, -65.0]]:
			for side in [1, -1]:
				var rot = RotationInput.new()
				rot.start_side = side
				rot.capture(at.call(0.0))
				rot.capture(at.call(60.0))
				_check(rot.calibrated(), "initial and a 60° max should calibrate")
				var aim: float = rot.aim_deg(at.call(turn[0]), 65.0)
				_check(absf(aim - side * turn[1]) < 0.01,
					"%.0f° turned, side %d: aim %.2f, wanted %.2f" % [turn[0], side, aim, side * turn[1]])

	# Tilting the handle sideways is not turning it.
	var tilted = RotationInput.new()
	tilted.capture(Basis.IDENTITY)
	tilted.capture(Basis(Vector3.UP, deg_to_rad(60)))
	var tilt := Basis(Vector3.RIGHT, deg_to_rad(20)) * Basis(Vector3.UP, deg_to_rad(30))
	_check(absf(tilted.aim_deg(tilt, 65.0)) < 0.01, "a sideways tilt should not move the aim")

	# Past the end of a wide range the twist wraps at 180°: stay at the far end, no jump back.
	var wide = RotationInput.new()
	wide.capture(Basis.IDENTITY)
	wide.capture(Basis(Vector3.UP, deg_to_rad(170)))
	var past: float = wide.aim_deg(Basis(Vector3.UP, deg_to_rad(200)), 65.0)
	_check(absf(past + 65.0) < 0.01, "30° past a 170° range: aim %.2f, wanted -65" % past)

	# A turn too small to fill the arc is asked again, and the initial pose is kept.
	var small = RotationInput.new()
	small.capture(Basis.IDENTITY)
	small.capture(Basis(Vector3.UP, deg_to_rad(5)))
	_check(not small.calibrated() and small.problem != "", "a 5° turn should be asked again")
	small.capture(Basis(Vector3.UP, deg_to_rad(60)))
	_check(small.calibrated() and small.problem == "", "the next turn should still count from initial")
	_check(absf(small.aim_deg(Basis.IDENTITY, 65.0) - 65.0) < 0.01, "initial should be the first pose")


## Enter takes the poses, in the game; the training hand says which end initial is.
func _cannon_calibrates_on_enter() -> void:
	print("SMOKE cannon calibrates on enter")
	# [training hand, aim at max, the way the calibration arrow points at max].
	for case in [["Left", 65.0, 1], ["Right", -65.0, -1], ["", -65.0, -1]]:
		GlobalSignals.selected_training_hand = case[0]
		var cannon := await _open(CANNON)
		cannon._mouse = false   # as without debug; the handle is set here, not by a tracker
		cannon._on_global_timer_play_pressed(0)
		_check(cannon._state == cannon.State.CALIBRATE, "the game should start by calibrating")

		# Not in view: no pose, however far it last was.
		GlobalScript.last_packet_ms = 0
		GlobalScript._last_rvec = Vector3(0, deg_to_rad(60), 0)
		_press_enter(cannon)
		GlobalScript.last_packet_ms = Time.get_ticks_msec()
		GlobalScript._last_rvec = Vector3.ZERO
		_press_enter(cannon)
		_check(not cannon._rot.calibrated(), "Enter with the handle out of view should capture nothing")
		await _frames(1)
		_check(cannon._world.arrow == case[2], "%s hand: arrow %d" % [case[0], cannon._world.arrow])

		GlobalScript._last_rvec = Vector3(0, deg_to_rad(60), 0)
		_press_enter(cannon)
		_check(cannon._rot.calibrated(), "%s hand: Enter at max should finish calibrating" % case[0])
		cannon._summary_until = 0
		await _frames(2)
		_check(cannon._state == cannon.State.PLAY, "%s hand: play should follow calibration" % case[0])
		GlobalScript.last_packet_ms = Time.get_ticks_msec()
		await _frames(2)
		_check(absf(cannon._aim - case[1]) < 0.01, "%s hand: aim at max %.2f" % [case[0], cannon._aim])

		cannon._recalibrate()
		_check(not cannon._rot.calibrated(), "recalibrating should start again")
		await _close(cannon)
	GlobalSignals.selected_training_hand = ""
	GlobalScript.last_packet_ms = 0
	GlobalScript._last_rvec = Vector3.ZERO
	print("SMOKE cannon calibrates on enter done")


func _press_enter(node: Node) -> void:
	var key := InputEventKey.new()
	key.keycode = KEY_ENTER
	key.pressed = true
	node._unhandled_input(key)


## Debug means the mouse instead of the tracker, in every game, whatever the tracker
## is doing; without debug no game takes the mouse. Debug only goes off between
## awaits, in memory, so nothing that reaches the server can see it off.
func _debug_means_mouse() -> void:
	print("SMOKE debug means mouse")
	Settings.path = GlobalSignals.data_path.path_join("settings.json")

	# The Settings screen turns it on: saved, and none of the tracker's business.
	var screen := await _open(SETTINGS_SCREEN)
	_check(screen.FIELDS.any(func(f): return f[0] == "debug"), "Settings should offer debug")
	var link = GlobalScript.link
	link.connected = true
	var commands: int = link._queue.size()
	screen._changed("debug", true)
	_check(link._queue.size() == commands, "debug should send the tracker nothing")
	link.connected = false
	var saved = JSON.parse_string(FileAccess.get_file_as_string(Settings.path))
	_check(saved is Dictionary and saved.get("debug") == true, "debug should be saved")
	_check(Settings.get_node("DebugBanner").visible, "debug should show on every screen")
	await _close(screen)

	# The game menus do not hold the cameras for the trunk panel, even with trunk on.
	var settings_before: Dictionary = Settings.data.duplicate()
	Settings.data["trunk_enabled"] = true
	var menu := await _open(MENU_2D)
	_check(GlobalScript.tracking_mode() == "off", "a menu in debug should not hold the cameras")
	await _close(menu)
	Settings.data = settings_before

	# Cannon Defense: no calibration, the tracker asked for nothing, the mouse aims.
	var cannon := await _open(CANNON)
	_check(GlobalScript.tracking_mode() == "off", "a game in debug should ask the tracker for nothing")
	Settings.data["debug"] = false
	var without_debug := GlobalScript.tracking_mode()
	Settings.data["debug"] = true
	_check(without_debug == "rotation", "Cannon Defense should ask for rotation without debug")
	cannon._on_global_timer_play_pressed(0)
	_check(cannon._state == cannon.State.PLAY, "debug should start without calibrating")
	_mouse_at(cannon, cannon.World.PIVOT + Vector2(300, -300))
	await _frames(2)
	_check(cannon._aim > 30.0, "the mouse should aim right: %.1f" % cannon._aim)
	_mouse_at(cannon, cannon.World.PIVOT + Vector2(-300, -300))
	await _frames(2)
	_check(cannon._aim < -30.0, "the mouse should aim left: %.1f" % cannon._aim)
	await _close(cannon)

	# Reach Scan: the mouse is the hand, even with a tracker that was streaming.
	var scan := await _open(REACH_SCAN)
	var runner = scan.get_child(0)
	GlobalScript.last_packet_ms = Time.get_ticks_msec() - 60000
	_mouse_at(runner, Vector2(500, 400))
	await _frames(2)
	_check(runner._hand.distance_to(runner._ts.screen_to_mm(Vector2(500, 400))) < 1.0, "the mouse should move the hand")
	_check(not runner._paused, "debug should not wait for the tracker")

	# Without debug and without a tracker: it waits, and the mouse does nothing.
	var hand: Vector2 = runner._hand
	GlobalScript.last_packet_ms = 0
	_mouse_at(runner, Vector2(900, 300))
	Settings.data["debug"] = false
	runner._read_hand()
	runner._update_pause()
	Settings.data["debug"] = true
	_check(runner._hand == hand, "without debug the mouse should not move the hand")
	_check(runner._paused, "without debug the scan should wait for the tracker")
	await _close(scan)
	print("SMOKE debug means mouse done")


## The black sheep eating a missed apple is heard, and lower than the player's own
## apple (pitch 1.0): a miss must not sound like a point.
func _sheep_snack_is_heard() -> void:
	var field := Node2D.new()
	get_tree().root.add_child(field)
	get_tree().current_scene = field   # the apple's sparkles go here
	var flock: Node2D = load(SHEEP_FLOCK).new()
	field.add_child(flock)
	var apple: Node2D = (load(APPLE) as PackedScene).instantiate()
	apple.flock = flock
	field.add_child(apple)
	apple.global_position = flock.sheep[0].sprite.global_position + Vector2(40, 0)
	_check(not flock._munch.playing, "the sheep should be quiet before its snack")
	apple._on_timer_timeout()
	for i in 120:
		await get_tree().process_frame
		if apple.score_label.text == "Black sheep's snack!":
			break
	_check(apple.score_label.text == "Black sheep's snack!", "the sheep should reach the missed apple")
	_check(flock._munch.playing, "the sheep's snack should make a sound")
	_check(flock._munch.pitch_scale < 1.0, "the sheep should sound lower than a point")
	_check(not flock._laugh.playing, "the sheep should finish eating before it laughs")
	await get_tree().create_timer(1.2).timeout
	_check(flock._laugh.playing, "the sheep should laugh after its snack")
	await _close(field)
	print("SMOKE sheep snack done")


## Leaving the main screen must not wait for its patient sync: offline that froze the
## app until the connection gave up. A stand-in sleeps in the sender's place, then exits
## as the sender does when the server is unreachable, so this never reaches the server.
func _leaving_main_screen_skips_the_sync() -> void:
	var sender := OS.get_user_data_dir().path_join("smoke_slow_sender.py")
	var file := FileAccess.open(sender, FileAccess.WRITE)
	file.store_string("import sys, time\ntime.sleep(2)\nsys.exit(3)\n")
	file.close()
	PatientDB.sync_command = [GlobalScript.python(), [sender]]
	var main := await _open(MAIN_SCREEN)
	_check(PatientDB.is_syncing(), "the main screen should start a sync")
	var left := Time.get_ticks_msec()
	await _close(main)
	_check(Time.get_ticks_msec() - left < 1000, "leaving the main screen should not wait for the sync")
	_check(PatientDB.is_syncing(), "the sync should carry on after the screen has gone")
	# Back before it ends: this screen joins that sync and shows how it ended.
	main = await _open(MAIN_SCREEN)
	var status: Label = main.find_child("SyncStatus", true, false)
	var refresh: Button = main.find_child("RefreshButton", true, false)
	_check(status.text == "Fetching patients..." and refresh.disabled, "the screen should show the sync still running")
	if PatientDB.is_syncing():
		await PatientDB.sync_finished
	_check(status.text.begins_with("Server unreachable"), "the screen should show how the sync ended")
	_check(not refresh.disabled, "Refresh should work again after the sync")
	await _close(main)
	PatientDB.sync_command = []
	DirAccess.remove_absolute(sender)
	print("SMOKE leaving the main screen done")


func _open(path: String) -> Node:
	var scene := (load(path) as PackedScene).instantiate()
	get_tree().root.add_child(scene)
	get_tree().current_scene = scene
	await get_tree().process_frame
	return scene


func _close(scene: Node) -> void:
	scene.queue_free()
	await get_tree().process_frame


func _frames(count: int) -> void:
	for i in count:
		await get_tree().process_frame


## Puts the mouse at pos on node's canvas: headless, the event is what moves it.
func _mouse_at(node: CanvasItem, pos: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.global_position = node.get_viewport().get_screen_transform() * pos
	motion.position = motion.global_position
	Input.parse_input_event(motion)
	Input.flush_buffered_events()


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

	# A setting the tracker reads only at start restarts it: nobody has to type sudo.
	# One it takes live does not. No frame passes, so the link does not act on these.
	var link = GlobalScript.link
	link.connected = true
	scene._changed("tracker_solver", "joint")
	_check(not _restart_queued(link), "a live setting must not restart the tracker")
	scene._changed("display", false)
	_check(_restart_queued(link), "a setting read at start should restart the tracker")
	_check("restarting" in scene._status.text, "the screen should say it is restarting")
	_check(not "sudo" in scene._status.text, "nobody should be told to type sudo")
	for command in link._queue.duplicate():
		if command["kind"] == LinkProtocol.RESTART:
			link._queue.erase(command)
	link.connected = false

	# Over BLE: numbers over the link, the picture over the board's hotspot.
	await _camera_tab_over_ble(tab)

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


## The tab over BLE: the tracker's status says what the hotspot is doing, the tablet
## joins it with a password typed once, and pictures come over Wi-Fi. A plain UDP
## socket here plays the tracker's side of that, and FakeWifi the Android plugin.
func _camera_tab_over_ble(tab) -> void:
	Settings.data["stream_type"] = "ble"
	var wifi := FakeWifi.new()
	tab._wifi_plugin = wifi
	tab.set_active(true)
	await get_tree().process_frame
	_check(tab._controls.visible, "over BLE the controls should show")
	_check(GlobalScript.tracking_mode() == "position", "over BLE the tab should hold tracking")
	_check(_configs()[-1] == "preview=on", "over BLE the tab should ask for the preview")

	_feed(LinkProtocol.CAMERA_STATUS, _status({"state": "starting"}))
	_check("Starting" in tab._message.text, "the tab should say the Wi-Fi is starting")
	_check(tab._sliders["gain"].editable, "the sliders should work before the picture does")

	# The tracker's side of the picture channel.
	var tracker := PacketPeerUDP.new()
	tracker.bind(0, "127.0.0.1")
	var bssid := "36:22:7f:b9:c9:20"
	var on := {"state": "on", "ssid": "NOARK-test", "ip": "127.0.0.1", "port": tracker.get_local_port(), "bssid": bssid}

	# First time for this board: it needs the password, and joins nothing without it.
	_feed(LinkProtocol.CAMERA_STATUS, _status(on))
	_check(tab._password_row.visible, "an unknown network should ask for its password")
	_check(wifi.joins.is_empty(), "nothing to join with until the password is known")
	tab._password.text = "short"
	tab._save_password()
	_check(wifi.joins.is_empty(), "WPA2 needs 8 characters: a shorter one must not be tried")
	tab._password.text = "password-1"
	tab._save_password()
	_check(wifi.joins == [["NOARK-test", "password-1", bssid]], "the tab should join that exact access point with what was typed")
	_check(not tab._password_row.visible, "the password box should go once it is entered")
	var saved = JSON.parse_string(FileAccess.get_file_as_string(Settings.path))
	_check(saved["camera_wifi_passwords"]["NOARK-test"] == "password-1", "the password should be kept per network")

	# Asked again while joining: one attempt, not one per status.
	_feed(LinkProtocol.CAMERA_STATUS, _status(on))
	_check(wifi.joins.size() == 1, "a status while joining should not join again")

	# Joined: it says hello to the tracker, and a picture sent in chunks becomes the picture.
	wifi.joined.emit()
	await _seconds(0.3)
	_check(tracker.get_available_packet_count() > 0, "the tablet should say hello once on the Wi-Fi")
	var hello := tracker.get_packet()
	_check(hello == PackedByteArray([LinkProtocol.PICTURE_HELLO]), "that should be a PICTURE_HELLO")
	tracker.set_dest_address(tracker.get_packet_ip(), tracker.get_packet_port())
	var frame := Image.create(640, 200, false, Image.FORMAT_RGB8)
	frame.fill(Color.DARK_GRAY)
	var message := PackedByteArray([LinkProtocol.PREVIEW])
	message.append_array(frame.save_jpg_to_buffer())
	var size := 500
	var parts := ceili(float(message.size()) / size)
	for i in parts:
		var chunk := PackedByteArray([LinkProtocol.CHUNK, 7, i, parts])
		chunk.append_array(message.slice(i * size, mini((i + 1) * size, message.size())))
		tracker.put_packet(chunk)
	await _seconds(0.3)
	_check(tab._picture.texture != null and tab._picture.texture.get_size() == Vector2(640, 200),
		"a picture over the Wi-Fi should become the picture")

	# The Wi-Fi dropped: it joins again at the next status.
	wifi.lost.emit()
	_feed(LinkProtocol.CAMERA_STATUS, _status(on))
	_check(wifi.joins.size() == 2, "a lost network should be joined again")

	# The tracker could not start it: said plainly, the rest of the tab still works.
	_feed(LinkProtocol.CAMERA_STATUS, _status({"state": "failed", "reason": "no such device"}))
	_check("no such device" in tab._message.text, "why the Wi-Fi failed should be shown")
	_check(tab._sliders["gain"].editable, "the sliders should still work without the picture")

	# A wrong password: asks again rather than repeating it for ever.
	wifi.joins.clear()
	_feed(LinkProtocol.CAMERA_STATUS, _status(on))
	_check(wifi.joins.size() == 1, "it should try once more when the Wi-Fi is back")
	wifi.failed.emit("declined or not found")
	_check(tab._password_row.visible, "a failed join should offer the password again")
	_feed(LinkProtocol.CAMERA_STATUS, _status(on))
	_check(wifi.joins.size() == 1, "a failed join should wait for a new password")
	tab._password.text = "password-2"
	tab._save_password()
	_check(wifi.joins[-1] == ["NOARK-test", "password-2", bssid], "the new password should be tried")

	# Leaving lets go of the network and the cameras.
	wifi.joined.emit()
	tab.set_active(false)
	await get_tree().process_frame
	_check(wifi.leaves > 0, "leaving should let go of the network")
	_check(not tab._picture_link.running(), "leaving should stop the picture channel")
	_check(_configs()[-1] == "preview=off", "leaving should end the preview")
	_check(GlobalScript.tracking_mode() == "off", "leaving should let the cameras go")

	# Next time: the same network joins straight away, no password box.
	wifi.joins.clear()
	tab.set_active(true)
	await get_tree().process_frame
	_feed(LinkProtocol.CAMERA_STATUS, _status(on))
	_check(not tab._password_row.visible, "a known network should not ask again")
	_check(wifi.joins == [["NOARK-test", "password-2", bssid]], "a known network should join by itself")
	tab.set_active(false)
	await get_tree().process_frame
	tracker.close()
	tab._wifi_plugin = null


## Settings > Calibration, with the tracker's BODY_STATUS fed in as the link would hand
## it over. No frame passes while connected, so the link does not act on what is queued.
func _calibration_tab() -> void:
	print("SMOKE calibration tab")
	Settings.data["stream_type"] = "udp"
	var scene := (load(SETTINGS_SCREEN) as PackedScene).instantiate()
	get_tree().root.add_child(scene)
	get_tree().current_scene = scene
	await get_tree().process_frame
	var tab = scene._calibration
	var camera = scene._camera
	var current := {"tags": [1, 2, 3, 4, 5], "created": "2026-10-29T09:08:46", "agreement_mm": 1.6, "can_restore": true}

	# The rail picks the tab, and shows the one in view however it got there.
	scene._nav[camera.get_index()].pressed.emit()
	_check(scene._tabs.current_tab == camera.get_index(), "the rail should pick the tab")

	# Opening it: asks where things stand, holds the cameras, asks for the picture.
	scene._tabs.current_tab = tab.get_index()
	await get_tree().process_frame
	_check(scene._nav[tab.get_index()].button_pressed and not scene._nav[camera.get_index()].button_pressed,
		"the rail should show the tab in view")
	_check(_body_commands()[-1] == "status", "opening should ask where things stand")
	_check(_configs()[-1] == "preview=on", "opening should ask for the picture")
	_check(GlobalScript.tracking_mode() == "position", "opening should hold the cameras")

	# Idle: what is in use, and what can be done.
	_feed_body({"state": "idle", "anchor": 1, "current": current})
	_check("1, 2, 3, 4, 5" in tab._state.text and "1.6" in tab._state.text, "what is in use not shown: %s" % tab._state.text)
	_check("2026-10-29" in tab._state.text, "when it was measured not shown")
	_check("Tag 1" in tab._message.text, "it should say which tag stays fixed: %s" % tab._message.text)
	_check(tab._start.visible and tab._restore.visible, "idle should offer start and restore")
	_check(not tab._save.visible and not tab._finish.visible, "idle offers nothing else")
	_check(not tab._tip_card.visible, "a tracker without tip_m gets no Tracked point card")

	# The tracked point: the tracker's numbers, a typed change, and a status not wiping it.
	var tip_status := {"state": "idle", "anchor": 1, "tip_m": [0.0, 0.01, -0.069], "current": current}
	_feed_body(tip_status)
	_check(tab._tip_card.visible, "idle should show the Tracked point card")
	_check(tab._tip_tag.text == "1" and float(tab._tip_fields[1].text) == 10.0 and float(tab._tip_fields[2].text) == -69.0,
		"the fields should show tag 1 and the offset in mm: %s" % tab._tip_texts())
	_check(tab._tip_apply.disabled, "nothing to apply yet")
	tab._tip_tag.text = "3"
	tab._tip_fields[0].text = "12.5"
	tab._update_tip_apply()
	_check(not tab._tip_apply.disabled, "a change can be applied")
	_feed_body(tip_status)
	_check(tab._tip_tag.text == "3", "a status should not wipe what is being typed")
	tab._tip_fields[0].text = "abc"
	tab._update_tip_apply()
	_check(tab._tip_apply.disabled, "not a number: nothing to apply")
	tab._tip_fields[0].text = "12.5"
	tab._tip_tag.text = "587"
	tab._update_tip_apply()
	_check(tab._tip_apply.disabled, "not a tag id: nothing to apply")
	tab._tip_tag.text = "3"
	tab._update_tip_apply()
	tab._tip_apply.pressed.emit()
	_check(_body_commands()[-1] == "tip 3 0.012500 0.010000 -0.069000", "tip not sent: %s" % _body_commands()[-1])
	_feed_body({"state": "idle", "anchor": 3, "tip_m": [0.0125, 0.01, -0.069], "current": current})
	_check(tab._tip_apply.disabled, "what was applied is what is shown")
	_check("Tag 3" in tab._message.text, "it should say the new fixed tag: %s" % tab._message.text)
	_feed_body({"state": "idle", "anchor": 9, "tip_m": [0.0, 0.0, -0.05], "current": current})
	_check("Tag 9 is not in" in tab._tip_help.text, "a tag not in use should be said: %s" % tab._tip_help.text)
	tab._fill_tag_pick()
	_check(tab._tip_tag_pick.get_popup().item_count == 5, "Pick should list the tags in use")
	_feed_body({"state": "idle", "anchor": 1, "tip_m": [0.0, 0.01, -0.069], "current": current})

	tab._start.pressed.emit()
	_check(_body_commands()[-1] == "start", "start not sent")

	# Capturing: what the take still needs.
	_feed_body({"state": "capturing", "anchor": 1, "current": current, "capture": {
		"left": null, "frames": 0, "level": null, "tag_px": null, "tags": []}})
	_check("cameras" in tab._state.text, "the clock waits for the cameras: %s" % tab._state.text)
	_check(not tab._tip_card.visible, "the tracked point cannot change during a take")
	_feed_body({"state": "capturing", "anchor": 1, "current": current, "capture": {
		"left": 41.5, "frames": 185, "level": 20, "tag_px": 30, "tags": [
			{"id": 1, "seen": 180, "joined": true}, {"id": 2, "seen": 90, "joined": true},
			{"id": 3, "seen": 12, "joined": false}, {"id": 5, "seen": 0, "joined": false}]}})
	_check("42" in tab._state.text, "time left not shown: %s" % tab._state.text)
	_check(tab._finish.visible and tab._cancel.visible and not tab._start.visible, "capturing offers finish and cancel")
	var rows := _row_text(tab)
	_check("Tag 2 | joined | seen 90" in rows, "a joined tag not shown: %s" % rows)
	_check("Tag 3 | show it beside another tag | seen 12" in rows, "a tag without a neighbour not shown: %s" % rows)
	_check("Tag 5 | not seen" in rows, "an unseen tag not shown: %s" % rows)
	_check("dark" in tab._message.text, "a dark image should be said: %s" % tab._message.text)
	_feed_body({"state": "capturing", "anchor": 1, "current": current, "capture": {
		"left": 30.0, "frames": 300, "level": 100, "tag_px": 30, "tags": [{"id": 1, "seen": 180, "joined": true}]}})
	_check("closer" in tab._message.text, "small tags should be said: %s" % tab._message.text)
	_feed_body({"state": "capturing", "anchor": 1, "current": current, "capture": {
		"left": 29.0, "frames": 310, "level": 100, "tag_px": 60, "tags": [{"id": 1, "seen": 180, "joined": true}]}})
	_check("joined" in tab._message.text, "all joined should be said: %s" % tab._message.text)
	var picture := Image.create(640, 200, false, Image.FORMAT_RGB8)
	_feed(LinkProtocol.PREVIEW, picture.save_jpg_to_buffer())
	_check(tab._picture.texture != null and tab._picture.visible, "the preview should become the picture")
	tab._finish.pressed.emit()
	_check(_body_commands()[-1] == "finish", "finish not sent")

	# Solving: the cameras are let go, and the wait is said.
	var previews := _configs().count("preview=off")
	_feed_body({"state": "solving", "anchor": 1, "current": current, "elapsed": 40})
	await get_tree().process_frame
	_check("40" in tab._state.text, "the wait not shown: %s" % tab._state.text)
	_check(tab._cancel.visible and not tab._finish.visible, "solving offers cancel only")
	_check(GlobalScript.tracking_mode() == "off", "solving should let the cameras go")
	_check(_configs().count("preview=off") == previews + 1, "solving should end the preview")
	_check(not tab._picture.visible, "no picture while solving")

	# Review: where each tag went, and Save.
	var good := {"ok": true, "problems": [], "warnings": ["Tag 1 may have moved: every other tag shifted."],
		"tags": [{"id": 1, "state": "same", "moved_mm": 0.0, "seen": 300, "spread_mm": 0.0},
			{"id": 2, "state": "moved", "moved_mm": 31.2, "seen": 200, "spread_mm": 1.2},
			{"id": 3, "state": "same", "moved_mm": 1.1, "seen": 200, "spread_mm": 1.1},
			{"id": 9, "state": "new", "moved_mm": null, "seen": 100, "spread_mm": 1.4}],
		"gone": [5], "dropped": [7], "agreement_mm": [0.9, 2.6], "reprojection_px": [0.3, 0.4],
		"turned_deg": 34.0, "solve_s": 98}
	_feed_body({"state": "review", "anchor": 1, "current": current, "result": good})
	rows = _row_text(tab)
	_check("0.9" in tab._state.text, "the agreement not shown: %s" % tab._state.text)
	_check("Tag 2 | moved 31 mm" in rows, "a moved tag not shown: %s" % rows)
	_check("Tag 3 | same place" in rows, "a tag that stayed not shown: %s" % rows)
	_check("Tag 9 | new" in rows, "a new tag not shown: %s" % rows)
	_check("Tag 5 | gone" in rows, "a tag no longer found not shown: %s" % rows)
	_check("Tag 7 | left out" in rows, "a tag left out not shown: %s" % rows)
	_check("Tag 1 may have moved" in tab._message.text, "a warning should be shown: %s" % tab._message.text)
	_check(tab._message.get_theme_color("font_color") == tab.WARN, "a warning should stand out")
	_check(tab._save.visible and tab._cancel.visible and not tab._start.visible, "review offers save and discard")
	tab._save.pressed.emit()
	_check(_body_commands()[-1] == "save", "save not sent")
	GlobalScript.link_command_done.emit(LinkProtocol.BODY, true, "saved")
	_feed_body({"state": "idle", "anchor": 1, "current": current})
	_check("in use" in tab._message.text.to_lower() or "using" in tab._message.text, "saving should be confirmed: %s" % tab._message.text)
	await get_tree().process_frame
	_check(GlobalScript.tracking_mode() == "position", "back to idle should hold the cameras again")

	# A refused take: no Save, and why.
	_feed_body({"state": "review", "anchor": 1, "current": current, "result": {
		"ok": false, "problems": ["the device hardly turned (0 degrees, needs 15)"], "warnings": [],
		"tags": [], "gone": [4], "dropped": []}})
	rows = _row_text(tab)
	_check("Tag 4 | not found in this take" in rows, "a refused take changes nothing: %s" % rows)
	_check(not tab._save.visible, "a refused take cannot be saved")
	_check(tab._start.visible, "a refused take should offer another go")
	_check("The device hardly turned" in tab._message.text, "the reason should be shown: %s" % tab._message.text)

	# Back to plain text once there is nothing to warn about.
	_feed_body({"state": "idle", "anchor": 1, "current": current})
	_check(tab._message.get_theme_color("font_color") == tab.MUTED, "the hint is not a warning")

	# A failure: why, and another go.
	_feed_body({"state": "failed", "anchor": 1, "current": current, "reason": "Tag 1 was never seen."})
	_check("Tag 1 was never seen." in tab._message.text, "the failure not shown: %s" % tab._message.text)
	_check(tab._start.visible and not tab._save.visible, "a failure should offer another go")

	# A refusal is shown.
	GlobalScript.link.connected = true
	GlobalScript.link_command_done.emit(LinkProtocol.BODY, false, "already solving")
	GlobalScript.link.connected = false
	_check("already solving" in tab._message.text, "a refusal should be shown: %s" % tab._message.text)

	# The link giving up on a command is not the tracker refusing it.
	GlobalScript.link.connected = true
	GlobalScript.link_command_done.emit(LinkProtocol.BODY, false, "link lost")
	_check(not "refused" in tab._message.text and not "link lost" in tab._message.text,
		"a lost link is not a refusal: %s" % tab._message.text)
	GlobalScript.link_command_done.emit(LinkProtocol.BODY, false, "no answer")
	_check("did not answer" in tab._message.text and not "refused" in tab._message.text,
		"no answer is not a refusal: %s" % tab._message.text)
	GlobalScript.link.connected = false

	# The link: gone, then back; a tracker forgets the preview at every HELLO.
	GlobalScript.link_connected_changed.emit(false)
	_check("tracker" in tab._state.text and not tab._start.visible, "no link: nothing to offer")
	var asked := _body_commands().size()
	var asked_preview := _configs().count("preview=on")
	GlobalScript.link_connected_changed.emit(true)
	_check(_body_commands().size() == asked + 1, "a reconnect should ask where things stand")
	await get_tree().process_frame
	_check(_configs().count("preview=on") == asked_preview + 1, "a reconnect should ask for the picture again")

	# To the Camera tab and back: the tab coming into view has the last word on the
	# preview. Leaving a take ends it; a solve goes on.
	_feed_body({"state": "capturing", "anchor": 1, "current": current, "capture": {
		"left": 20.0, "frames": 10, "level": 100, "tag_px": 60, "tags": []}})
	scene._tabs.current_tab = camera.get_index()
	await get_tree().process_frame
	_check(_body_commands()[-1] == "cancel", "leaving should end a take")
	_check(_configs()[-1] == "preview=on", "the Camera tab should have the preview, got %s" % _configs()[-1])
	_check(GlobalScript.tracking_mode() == "position", "the Camera tab should hold the cameras")
	scene._tabs.current_tab = tab.get_index()
	await get_tree().process_frame
	_check(_configs()[-1] == "preview=on", "this tab should have the preview, got %s" % _configs()[-1])
	_feed_body({"state": "solving", "anchor": 1, "current": current, "elapsed": 1})
	var commands := _body_commands().size()
	scene._tabs.current_tab = 0
	await get_tree().process_frame
	_check(_body_commands().size() == commands, "leaving should not end a solve")
	_check(GlobalScript.tracking_mode() == "off", "leaving should let the cameras go")

	# Over BLE no picture is asked for here: the hotspot belongs to the Camera tab.
	Settings.data["stream_type"] = "ble"
	var configs_before := _configs().size()
	scene._tabs.current_tab = tab.get_index()
	await get_tree().process_frame
	_check(_configs().size() == configs_before, "over BLE this tab should not ask for the picture")
	_feed_body({"state": "idle", "anchor": 1, "current": current})
	_check(not tab._picture.visible and "BLE" in tab._message.text, "over BLE it should say why there is no picture")
	scene._tabs.current_tab = 0
	await get_tree().process_frame
	Settings.data["stream_type"] = "udp"
	scene.queue_free()
	await get_tree().process_frame
	print("SMOKE calibration tab done")


func _feed_body(info: Dictionary) -> void:
	GlobalScript.link.connected = true
	_feed(LinkProtocol.BODY_STATUS, JSON.stringify(info).to_utf8_buffer())
	GlobalScript.link.connected = false


## Each row of the tab's list, as "cell | cell | cell", one to a line.
func _row_text(tab) -> String:
	var cells: Array[String] = []
	for label in tab._rows.get_children():
		cells.append(label.text)
	var lines := PackedStringArray()
	for i in range(0, cells.size(), tab._rows.columns):
		lines.append(" | ".join(cells.slice(i, i + tab._rows.columns)))
	return "\n".join(lines)


## The BODY commands waiting to go out.
func _body_commands() -> PackedStringArray:
	var out := PackedStringArray()
	for command in GlobalScript.link._queue:
		if command["kind"] == LinkProtocol.BODY:
			out.append(command["body"].get_string_from_utf8())
	return out


func _restart_queued(link) -> bool:
	for command in link._queue:
		if command["kind"] == LinkProtocol.RESTART:
			return true
	return false


func _status(wifi: Dictionary) -> PackedByteArray:
	return JSON.stringify({"ask": [10000, 2.5], "exposure": [10000.0, 10000.0], "gain": [2.5, 2.5],
		"level": [100.0, 100.0], "blown": [0.0, 0.0], "tags": [0, 0], "fps": 30.0,
		"wifi": wifi}).to_utf8_buffer()


## Stands in for the Android plugin's Wi-Fi calls.
class FakeWifi:
	signal joined
	signal lost
	signal failed(reason: String)
	var joins := []
	var leaves := 0

	func join(ssid: String, password: String, bssid: String) -> void:
		joins.append([ssid, password, bssid])

	func leave() -> void:
		leaves += 1


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
		push_error("SMOKE settings: %s" % what)


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
