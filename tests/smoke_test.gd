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
const REACH_SCAN := "res://Games/firefly_reach/reach_assessment.tscn"
const SHEEP_FLOCK := "res://Games/random_reach/Scripts/sheep_flock.gd"
const APPLE := "res://Games/random_reach/scenes/apple.tscn"

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
	await _debug_means_mouse()
	await _sheep_snack_is_heard()
	await _camera_tab()
	await _calibration_tab()
	print("SMOKE DONE %d scenes" % SCENES.size())
	get_tree().quit()


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

	# Opening it: asks where things stand, holds the cameras, asks for the picture.
	scene._tabs.current_tab = tab.get_index()
	await get_tree().process_frame
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
	tab._start.pressed.emit()
	_check(_body_commands()[-1] == "start", "start not sent")

	# Capturing: what the take still needs.
	_feed_body({"state": "capturing", "anchor": 1, "current": current, "capture": {
		"left": null, "frames": 0, "level": null, "tag_px": null, "tags": []}})
	_check("cameras" in tab._state.text, "the clock waits for the cameras: %s" % tab._state.text)
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
