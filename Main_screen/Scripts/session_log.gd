extends Node
## Per-patient session log and therapy dose, after the MARS robot's
## sessions.csv / configdata.csv (external/references/, docs/session_logging_spec.md).
##
##   {data}/{pid}/sessions.csv     one row per trial, written when the trial ends
##   {data}/{pid}/configdata.csv  dose history; the last row is the active dose
##   {data}/{pid}/GameData/raw-sessNN-trialNNN-{Game}-{Mode}.csv  (Manager writes these)
##
## A session starts at login (start_session). A trial starts when a game opens
## its log file (Manager.create_game_log_file -> begin_trial) and ends at game
## over (end_trial), when the next trial starts, when the game scene is left, or
## when the app closes — so an early quit still gets its row.
##
## Each row written is sent to the server: sender_raspberryPI.py --upload {pid}
## runs in the background (one at a time; a trial ending meanwhile queues its
## patient). Closing the app waits for it (global_script.gd).

signal uploads_finished

const DEVICE := "NOARK"

# Movement each game trains; games not listed (Jumpify, Assessment) log a blank.
const MOVEMENT := {
	"FruitCatcher": "ML", "PingPong": "ML",
	"FlyThrough": "AP",
	"RandomReach": "MLAP", "FireflyReach": "MLAP",
}
const MOVEMENTS := ["ML", "AP", "MLAP"]
# Mode for games whose name has no "3D" suffix but are 3D only.
const MODE_OVERRIDE := {"Jumpify": "3D"}

const SESSION_COLUMNS := [
	"SessionNumber", "DateTime", "TrialNumberDay", "TrialNumberSession",
	"TrialStartTime", "TrialStopTime", "TrialRawDataFile", "Movement", "GameName", "Mode",
	"GameDuration", "SuccessRate", "MoveTime", "CurrentTargets", "CurrentHits", "CurrentMisses",
	"CummulativeTargets", "CummulativeHits", "CummulativeMisses", "RawDataFileName",
]
const DOSE_COLUMNS := ["HomerID", "DateTime", "TotalTime", "ML", "AP", "MLAP", "Location"]

var patient_id: String = ""
var session_number: int = 0
var session_start: String = ""

var _trial: Dictionary = {}   # the open trial; empty when none
var _trial_scene: Node = null
var _paused: bool = false
var _upload_pid: int = 0        # OS pid of the running upload, 0 when none
var _upload_queue: Array = []   # patients still to upload after it


func _ready() -> void:
	# Uploads are polled in _process, which must keep running while a game is
	# paused (and while the app waits for them to close). MoveTime checks pause itself.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(delta: float) -> void:
	if not _trial.is_empty() and not _paused and not get_tree().paused:
		_trial["move_time"] += delta
	if _upload_pid != 0 and not OS.is_process_running(_upload_pid):
		print("[upload] finished (exit %d)" % OS.get_process_exit_code(_upload_pid))
		_upload_pid = 0
		if not _upload_queue.is_empty():
			_start_upload(_upload_queue.pop_front())
		else:
			uploads_finished.emit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		end_trial()


# ── paths ─────────────────────────────────────────────────────────────────────

func effective_id(pid: String) -> String:
	return "vvv" if Settings.get_value("debug", false) else pid


func patient_dir(pid: String) -> String:
	return GlobalSignals.data_path.path_join(effective_id(pid))


func session_path(pid: String) -> String:
	return patient_dir(pid).path_join("sessions.csv")


func dose_path(pid: String) -> String:
	return patient_dir(pid).path_join("configdata.csv")


# ── session ───────────────────────────────────────────────────────────────────

## Called at login: the next SessionNumber is one past the highest in sessions.csv.
func start_session(pid: String) -> void:
	end_trial()
	patient_id = effective_id(pid)
	var highest := 0
	for row in read_sessions(patient_id):
		highest = maxi(highest, int(row.get("SessionNumber", "0")))
	session_number = highest + 1
	session_start = _now()


# A game opened without a login (debug, or straight from the editor) still gets a session.
func _ensure_session(pid: String) -> void:
	if session_number == 0 or patient_id != effective_id(pid):
		start_session(pid)


# ── trials ────────────────────────────────────────────────────────────────────

## Opens a trial for game_name ("FlyThrough3D" etc.) and returns the absolute
## path its raw data file should be written to.
func begin_trial(game_name: String, pid: String) -> String:
	end_trial()
	_ensure_session(pid)
	var game := game_name.trim_suffix("3D")
	var mode: String = MODE_OVERRIDE.get(game_name, "3D" if game_name.ends_with("3D") else "2D")
	var today := _now().substr(0, 10)
	var in_session := 1
	var in_day := 1
	for row in read_sessions(patient_id):
		if row.get("GameName") != game or row.get("Mode") != mode:
			continue
		if int(row.get("SessionNumber", "0")) == session_number:
			in_session += 1
		if String(row.get("TrialStartTime", "")).begins_with(today):
			in_day += 1
	var file_name := "raw-sess%02d-trial%03d-%s-%s.csv" % [session_number, in_session, game, mode]
	var duration := ""
	if GlobalTimerManager.is_countdown_active():
		duration = str(GlobalTimerManager.countdown_total)
	_trial = {
		"game": game, "mode": mode, "file": file_name, "start": _now(),
		"trial_day": in_day, "trial_session": in_session, "duration": duration,
		"hits": 0, "misses": 0, "move_time": 0.0,
	}
	_paused = false
	# Leaving the game scene by any button ends the trial. (A game that opens its
	# log in _ready may run before current_scene is set; it ends the trial itself.)
	_trial_scene = get_tree().current_scene
	if _trial_scene and _trial_scene.is_inside_tree() and not _trial_scene.is_queued_for_deletion() 			and not _trial_scene.tree_exiting.is_connected(end_trial):
		_trial_scene.tree_exiting.connect(end_trial)
	var dir := patient_dir(patient_id).path_join("GameData")
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(file_name)


func hit() -> void:
	if not _trial.is_empty():
		_trial["hits"] += 1


func miss() -> void:
	if not _trial.is_empty():
		_trial["misses"] += 1


## MoveTime leaves out paused time. GlobalTimer.pause_timer/resume_timer call this.
func set_paused(paused: bool) -> void:
	_paused = paused


func end_trial() -> void:
	if _trial.is_empty():
		return
	var t := _trial
	_trial = {}
	if is_instance_valid(_trial_scene) and _trial_scene.tree_exiting.is_connected(end_trial):
		_trial_scene.tree_exiting.disconnect(end_trial)
	_trial_scene = null

	var scored: bool = MOVEMENT.has(t["game"])   # Jumpify, Assessment: no targets
	var hits: int = t["hits"]
	var misses: int = t["misses"]
	var targets := hits + misses
	var cum := [targets, hits, misses]
	for row in read_sessions(patient_id):
		if row.get("GameName") == t["game"] and row.get("Mode") == t["mode"]:
			cum[0] += int(row.get("CurrentTargets", "0"))
			cum[1] += int(row.get("CurrentHits", "0"))
			cum[2] += int(row.get("CurrentMisses", "0"))
	var rate := str(roundi(100.0 * hits / targets)) if scored and targets > 0 else ""

	var row := [
		session_number, session_start, t["trial_day"], t["trial_session"],
		t["start"], _now(), patient_id, MOVEMENT.get(t["game"], ""), t["game"], t["mode"],
		t["duration"], rate, "%.1f" % t["move_time"],
		targets if scored else "", hits if scored else "", misses if scored else "",
		cum[0] if scored else "", cum[1] if scored else "", cum[2] if scored else "",
		t["file"],
	]
	_append(session_path(patient_id), _session_header(patient_id), row)
	upload(patient_id)
	DeviceAgent.trial_ended()


# ── server upload ─────────────────────────────────────────────────────────────

## Sends pid's sessions.csv and configdata.csv to the server in the background.
## The debug patient (vvv) is not a real patient, so it stays local.
func upload(pid: String) -> void:
	if pid == "" or Settings.get_value("debug", false):
		return
	if _upload_pid == 0:
		_start_upload(pid)
	elif not pid in _upload_queue:
		_upload_queue.append(pid)


func is_uploading() -> bool:
	return _upload_pid != 0


func _start_upload(pid: String) -> void:
	_upload_pid = OS.create_process(GlobalScript.python(), [GlobalScript.sender_path(), "--upload", pid])
	if _upload_pid <= 0:
		push_error("[upload] could not start sender_raspberryPI.py for %s" % pid)
		_upload_pid = 0
		uploads_finished.emit()
	else:
		print("[upload] sending %s's session files" % pid)


## Today's minutes of play per movement, from sessions.csv: {"ML": 12.5, ...}.
func today_minutes(pid: String) -> Dictionary:
	var out := {"ML": 0.0, "AP": 0.0, "MLAP": 0.0}
	var today := _now().substr(0, 10)
	for row in read_sessions(pid):
		var m: String = row.get("Movement", "")
		if out.has(m) and String(row.get("TrialStartTime", "")).begins_with(today):
			out[m] += float(row.get("MoveTime", "0")) / 60.0
	return out


func read_sessions(pid: String) -> Array:
	return _read(session_path(pid))


# ── dose ──────────────────────────────────────────────────────────────────────

## The active dose (last row of configdata.csv), or {} if none was ever set.
func latest_dose(pid: String) -> Dictionary:
	var rows := _read(dose_path(pid))
	return rows[-1] if not rows.is_empty() else {}


## Minutes per day for each movement; TotalTime is their sum.
## The training side is not stored: it is the patient's affected hand (patients.json).
func save_dose(pid: String, ml: int, ap: int, mlap: int, location: String) -> void:
	var id := effective_id(pid)
	_append(dose_path(id), [",".join(PackedStringArray(DOSE_COLUMNS))],
		[id, _now(), ml + ap + mlap, ml, ap, mlap, location.replace(",", " ")])


# ── csv ───────────────────────────────────────────────────────────────────────

func _session_header(pid: String) -> Array:
	return [
		":Location: %s" % Settings.get_value("location", ""),
		":Device: %s" % DEVICE,
		":User: %s" % pid,
		",".join(PackedStringArray(SESSION_COLUMNS)),
	]


# Rows as Dictionaries keyed by the column row; ":Key: value" lines are skipped.
func _read(path: String) -> Array:
	var rows := []
	if not FileAccess.file_exists(path):
		return rows
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return rows
	var columns := PackedStringArray()
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line == "" or line.begins_with(":"):
			continue
		var cells := line.split(",")
		if columns.is_empty():
			columns = cells
			continue
		var row := {}
		for i in mini(columns.size(), cells.size()):
			row[columns[i]] = cells[i]
		rows.append(row)
	return rows


func _append(path: String, header_lines: Array, row: Array) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var is_new := not FileAccess.file_exists(path)
	var f := FileAccess.open(path, FileAccess.WRITE if is_new else FileAccess.READ_WRITE)
	if f == null:
		push_error("Cannot write %s (error %d)" % [path, FileAccess.get_open_error()])
		return
	if is_new:
		for line in header_lines:
			f.store_line(line)
	else:
		f.seek_end()
	var cells := PackedStringArray()
	for v in row:
		cells.append(str(v))
	f.store_line(",".join(cells))
	f.close()


func _now() -> String:
	return Time.get_datetime_string_from_system(false, true)
