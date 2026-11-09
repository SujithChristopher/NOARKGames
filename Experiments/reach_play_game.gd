extends Node
## Experiment Random Reach, step 3: what the game does differently when it is the experiment
## (reach_play_run.gd). Random Reach's player adds one of these when Run.playing() and asks it:
##   - the hand from the tracker even in debug (it is what is recorded), and the mocap trigger
##     shown on top of the game (sync_indicator.gd), as on every experiment screen;
##   - no timer selector: play starts at once for the run's time, and `begin` starts the
##     recording on the tracker (EXPERIMENT `record`);
##   - the game's rows go to the run's random_reach.csv instead of a patient's raw file, and
##     no score, sessions.csv row or upload;
##   - game over, or leaving by any button, ends the run (`finish`) and goes back to the setup
##     screen, which waits for the tracker to say it is saved. A full disk on the board ends the
##     recording early: the game ends then too.
##   - the time up with the mocap trigger HIGH (the mocap still capturing): play stays frozen but
##     the recording goes on, a dialog says it waits for the mocap to stop, and the run ends
##     SYNC_TAIL_S after the line goes LOW, so the recording holds the mocap's whole take. LOW or
##     no line at the time up ends it at once; "Stop without waiting" ends it whatever the line.
##     Leaving early or a full disk never waits. metadata.json `game_end` says how it ended.

const Style := preload("res://Main_screen/Scripts/settings_style.gd")
const SyncIndicatorScript := preload("res://Experiments/sync_indicator.gd")
const Run := preload("res://Experiments/reach_play_run.gd")
const CSV_NAME := "random_reach.csv"
const SYNC_TAIL_S := 0.5          # recorded on after the mocap's line goes LOW

var player: Node
var log_file: FileAccess
var frames := 0               # pairs the tracker has saved so far
var end_reason := ""          # why the tracker ended the recording, if it did
var sync_level := -1          # the trigger line as the tracker last said: 1 HIGH, 0 LOW, -1 none
var waiting_sync := false     # the time is up, waiting for the mocap to stop
var _recording := false
var _seen_capturing := false
var _score := 0
var _wait_started_ms := 0
var _low_at_ms := -1          # when the line went LOW during the wait
var _dialog: Control
var _dialog_state: Label


func _init(game_player: Node) -> void:
	player = game_player
	name = "ReachPlayExperiment"


func _ready() -> void:
	GlobalScript.hold_tracking(player)   # in debug a game asks for nothing: this one does
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)
	layer.add_child(SyncIndicatorScript.new())
	GlobalScript.experiment_status.connect(_on_status)
	GlobalScript.link_connected_changed.connect(_on_link_changed)


## The game's log in the run's folder, with Random Reach's columns. Null if it cannot be made.
func open_log(columns: PackedStringArray) -> FileAccess:
	DirAccess.make_dir_recursive_absolute(Run.local_dir())
	log_file = FileAccess.open(Run.local_dir().path_join(CSV_NAME), FileAccess.WRITE)
	if log_file == null:
		push_error("[Reach play] Cannot write %s" % Run.local_dir().path_join(CSV_NAME))
		return null
	log_file.store_csv_line(columns)
	return log_file


## Play has started: record from now.
func begin() -> void:
	if _recording:
		return
	_recording = true
	GlobalScript.send_experiment_command("record")


## The game's time is up. With the mocap trigger HIGH, wait for it to go LOW (recording on);
## otherwise end now.
func game_over(score: int) -> void:
	if not Run.playing() or waiting_sync:
		return
	_score = score
	if sync_level != 1 or end_reason != "":
		_send_game_end({"sync_waited": false, "sync_at_end": sync_level})
		finish(score, "complete")
		return
	waiting_sync = true
	_wait_started_ms = Time.get_ticks_msec()
	player.status = "waiting_sync"
	_show_dialog()


func _process(_delta: float) -> void:
	if not waiting_sync:
		return
	var now := Time.get_ticks_msec()
	if sync_level == 1:
		_low_at_ms = -1
		_dialog_state.text = "Mocap sync HIGH: still recording (%.0f s)" % ((now - _wait_started_ms) / 1000.0)
	elif _low_at_ms < 0:
		_low_at_ms = now
	if _low_at_ms >= 0:
		_dialog_state.text = "Mocap stopped. Saving..."
		if now - _low_at_ms >= SYNC_TAIL_S * 1000:
			_end_wait("mocap_stopped")


func _end_wait(how: String) -> void:
	waiting_sync = false
	_send_game_end({"sync_waited": true, "how": how,
		"wait_s": snappedf((Time.get_ticks_msec() - _wait_started_ms) / 1000.0, 0.01),
		"tail_s": SYNC_TAIL_S if how == "mocap_stopped" else 0.0})
	finish(_score, "complete")


func _send_game_end(info: Dictionary) -> void:
	info["score"] = _score
	info["apples_outside_outline"] = int(player.apples_outside_outline)   # no room in the scan's outline
	# The drawn workspace's scale, for the eye only: nothing logged is scaled.
	info["display_gain"] = snappedf(player.view_gain(), 0.001)
	GlobalScript.send_experiment_command("meta game_end %s" % JSON.stringify(info))


func _show_dialog() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 19   # under the trigger's indicator
	add_child(layer)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	layer.add_child(dim)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	panel.theme = Style.make_theme()
	panel.theme_type_variation = "Card"
	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 28)
	panel.add_child(pad)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	pad.add_child(col)
	col.add_child(Style.label("Time's up. Score %d" % _score, "Title"))
	col.add_child(Style.label("Waiting for the mocap to stop..."))
	_dialog_state = Style.label("", "Helper")
	col.add_child(_dialog_state)
	var skip := Button.new()
	skip.text = "Stop without waiting"
	skip.theme_type_variation = "QuietButton"
	skip.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	skip.pressed.connect(func():
		if waiting_sync:
			_end_wait("skipped"))
	col.add_child(skip)
	layer.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_dialog = panel


## Game over ("complete") or left ("stopped"): close the log, end the run, back to setup.
func finish(score: int, why: String) -> void:
	if not Run.playing():
		return
	waiting_sync = false
	GlobalTimerManager.stop_countdown()
	player.game_log_file = null   # the player stops writing: the file closes here
	if log_file:
		log_file.store_line("Final Score: " + str(score))
		log_file.close()
		log_file = null
	var extra := {"score": score, "frames": frames}
	if end_reason != "":
		extra["reason"] = end_reason
	Run.finish(get_tree(), why, extra)


func _on_status(info: Dictionary) -> void:
	var sync = info.get("sync")
	if sync is Dictionary:
		sync_level = int(sync.get("level", -1)) if sync.get("available", false) else -1
	var capture = info.get("capture")
	if info.get("state") == "capturing" and capture is Dictionary:
		_seen_capturing = true
		frames = int(capture.get("frames", frames))
	elif _seen_capturing and info.get("state") == "ready" and Run.playing():
		# The tracker ended the recording itself (the board's disk nearly full).
		var last = info.get("last")
		if last is Dictionary:
			frames = int(last.get("frames", frames))
			end_reason = str(last.get("reason", ""))
		if waiting_sync:   # nothing more is recorded: no point waiting
			_end_wait("recording_ended")
		else:
			player.show_game_over()


func _on_link_changed(connected: bool) -> void:
	if not connected and Run.playing():
		finish(int(player.score), "stopped")


func _exit_tree() -> void:
	# The scene left some other way (the app closing): the run must not stay open.
	if Run.playing():
		if log_file:
			log_file.close()
			log_file = null
		Run.finish(null, "stopped", {"score": int(player.score), "frames": frames})
