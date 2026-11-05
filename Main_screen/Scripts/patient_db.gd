extends Node
## The patient list, read from {DOCUMENTS}/NOARK_demo/patients.json. That file
## belongs to sender_raspberryPI.py, which fetches it from the server
## (`--sync`); NOARK never writes it. The ids are the server's user_id.
##
## Patients created on this device (the main screen's "New Patient") go to
## local_patients.json beside it, in the same shape, so a sync never overwrites
## them. Once the server lists the same id the patient is the server's: the
## local entry is dropped, so a later removal on the server removes them here
## too instead of bringing the local copy back.
##
## A server patient is shown only while they are active and this device is in
## their "devices" (being in "assessment_devices" alone is not enough).
##
## Server format:
##   {"version": 2, "updated_at": "...", "patients": [
##       {"user_id": "AG12312", "status": "active", "side": "left", "devices": [...]}]}

signal sync_finished(ok: bool)   # ok: the server answered. The list is already reloaded.

# Singleton instance for global access
static var instance

# This device in the server's "devices" lists (sender_raspberryPI.py DEVICE_ID).
const DEVICE := "NOARK"

const DB_FILE = "patients.json"
const LOCAL_FILE = "local_patients.json"

# The server's "side" -> the affected hand the games train.
const SIDES := {"left": "Left", "right": "Right", "both": "Both"}
const AFFECTED_SIDES := ["Left", "Right", "Both"]

# The tablet build has no server sync (sender_raspberryPI.py cannot run there),
# so it carries one patient of its own to log in with.
const ANDROID_TEST_PATIENT := "test"

# Patient database: user_id -> {name, affected_hand, status, local}
var patient_register: Dictionary = {}
var current_patient_id: String = ""
var version: int = 0

# [program, args] to run instead of the sender: the smoke test's stand-in.
var sync_command: Array = []
var _sync_thread := Thread.new()

# File paths
var database_file_path: String
var local_file_path: String

func _init():
	instance = self
	database_file_path = Settings.base_dir.path_join(DB_FILE)
	local_file_path = Settings.base_dir.path_join(LOCAL_FILE)
	print("Patient database path: ", database_file_path)
	load_database()


## Fetches patients.json from the server: when the main screen opens, and on its
## Refresh. On a thread here and not on that screen, because offline it takes seconds
## and leaving a screen must not wait for it. The sender only uses the standard
## library, so any python3 runs it.
func sync() -> void:
	if is_syncing():
		return   # one at a time; sync_finished tells this caller too
	var command := sync_command if not sync_command.is_empty() 		else [GlobalScript.python(), [GlobalScript.sender_path(), "--sync"]]
	_sync_thread.start(_run_sync.bind(command[0], command[1]))


func is_syncing() -> bool:
	return _sync_thread.is_started()


func _run_sync(program: String, args: Array) -> void:
	var output := []
	var code := OS.execute(program, args, output, true)
	print("[sync] ", "".join(output).strip_edges())
	_on_sync_done.call_deferred(code)


func _on_sync_done(code: int) -> void:
	_sync_thread.wait_to_finish()
	load_database()
	sync_finished.emit(code == 0)


## Quitting is the one time a sync is waited for: a thread must end before the app does.
func _exit_tree() -> void:
	if is_syncing():
		_sync_thread.wait_to_finish()


func load_database() -> bool:
	patient_register = {}
	version = 0
	if OS.get_name() == "Android":
		patient_register[ANDROID_TEST_PATIENT] = {
			"name": ANDROID_TEST_PATIENT, "affected_hand": "Both", "status": "active"}
	var server_ids := {}   # every id in patients.json, shown here or not
	var ok := _load_file(database_file_path, server_ids)
	if not ok:
		print("No usable patients.json yet; it arrives with the first server sync")
	var local := _read_patients(local_file_path)
	var kept := []
	for p in local:
		var id := str(p.get("user_id", ""))
		if server_ids.has(id):
			continue   # the server's patient now
		kept.append(p)
		if id != "" and not patient_register.has(id):
			patient_register[id] = {"name": id, "affected_hand": _side(p), "status": "active", "local": true}
	if kept.size() < local.size():
		print("Local patients now on the server, dropped here: %d" % (local.size() - kept.size()))
		_write_local(kept)
	print("Loaded patient database v%d with %d patients (%d local)" % [version, patient_register.size(), kept.size()])
	return ok


## The server's patients.json. Every id in it goes into `seen`.
func _load_file(path: String, seen: Dictionary) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("patients")) != TYPE_ARRAY:
		push_error("Invalid patient database format: ", path)
		return false
	version = int(data.get("version", 0))
	for p in data["patients"]:
		if typeof(p) != TYPE_DICTIONARY or str(p.get("user_id", "")) == "":
			continue
		var id := str(p["user_id"])
		seen[id] = true
		if str(p.get("status", "active")).to_lower() != "active":
			continue
		if p.has("devices") and not DEVICE in p["devices"]:
			continue   # not assigned to this device (maybe assessment only)
		patient_register[id] = {"name": id, "affected_hand": _side(p), "status": p.get("status", ""), "local": false}
	return true


func _read_patients(path: String) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("patients")) != TYPE_ARRAY:
		push_error("Invalid patient database format: ", path)
		return []
	return data["patients"]


func _side(p: Dictionary) -> String:
	var side: String = SIDES.get(str(p.get("side", "")).to_lower(), "")
	if side == "":
		push_warning("Patient %s has no usable side (%s); training Both" % [p.get("user_id"), p.get("side")])
		return "Both"
	return side


## Create a patient on this device. `side` is "Left", "Right" or "Both".
## Returns "" on success, otherwise why not.
func add_local_patient(id: String, side: String) -> String:
	id = id.strip_edges()
	if id == "":
		return "Enter a patient ID"
	if not id.is_valid_filename():
		return "The ID cannot contain / \\ : * ? \" < > |"
	if patient_register.has(id):
		return "Patient %s already exists" % id
	if side not in AFFECTED_SIDES:
		return "Pick the training hand"
	var local := _read_patients(local_file_path)
	local.append({"user_id": id, "status": "active", "side": side.to_lower(),
		"created_at": Time.get_datetime_string_from_system()})
	var why := _write_local(local)
	if why != "":
		return why
	patient_register[id] = {"name": id, "affected_hand": side, "status": "active", "local": true}
	return ""


## Returns "" on success, otherwise why not.
func _write_local(patients: Array) -> String:
	var f := FileAccess.open(local_file_path, FileAccess.WRITE)
	if f == null:
		return "Could not save: %s" % error_string(FileAccess.get_open_error())
	f.store_string(JSON.stringify({"patients": patients}, "  "))
	f.close()
	return ""


## True for a patient created on this device (not from the server).
func is_local(hospital_id: String) -> bool:
	return patient_register.get(hospital_id, {}).get("local", false)


## How many patients came from the server and how many were made here.
func counts() -> Dictionary:
	var local := 0
	for id in patient_register:
		if patient_register[id].get("local", false):
			local += 1
	return {"server": patient_register.size() - local, "local": local}

# The file is the server's; the logged-in patient lives only in memory.
func save_database() -> bool:
	return true

func get_patient(hospital_id: String) -> Dictionary:
	if hospital_id in patient_register:
		return patient_register[hospital_id]
	print("No patient with this hospital ID found!")
	return {}

# Sorted ids, for the main screen's dropdown.
func patient_ids() -> Array:
	var ids := patient_register.keys()
	ids.sort()
	return ids

func list_all_patients() -> Array:
	var patients = []
	for hospital_id in patient_ids():
		var p: Dictionary = patient_register[hospital_id]
		patients.append({
			"hospital_id": hospital_id,
			"name": p["name"],
			"affected_hand": p["affected_hand"],
		})
	return patients
