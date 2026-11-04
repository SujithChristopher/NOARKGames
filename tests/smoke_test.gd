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
