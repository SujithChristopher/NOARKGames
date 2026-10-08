extends Node
## The patient list, read from {DOCUMENTS}/NOARK_demo/patients.json. That file
## belongs to sender_raspberryPI.py, which fetches it from the server
## (`--sync`); NOARK never writes it. The ids are the server's user_id.
##
## Patients created on this device (the main screen's "New Patient") go to
## local_patients.json beside it, in the same shape, so a sync never overwrites
## them. A server patient with the same id wins.
##
## Server format:
##   {"version": 2, "updated_at": "...", "patients": [
##       {"user_id": "AG12312", "status": "active", "side": "left", "devices": [...]}]}

# Singleton instance for global access
static var instance

const DB_FILE = "patients.json"
const LOCAL_FILE = "local_patients.json"

# The server's "side" -> the affected hand the games train.
const SIDES := {"left": "Left", "right": "Right", "both": "Both"}
const AFFECTED_SIDES := ["Left", "Right", "Both"]

# The tablet build has no server sync (sender_raspberryPI.py cannot run there),
# so it carries one patient of its own to log in with.
const ANDROID_TEST_PATIENT := "test"

# Patient database: user_id -> {name, affected_hand, status}
var patient_register: Dictionary = {}
var current_patient_id: String = ""
var version: int = 0

# File paths
var database_file_path: String
var local_file_path: String

func _init():
	instance = self
	database_file_path = Settings.base_dir.path_join(DB_FILE)
	local_file_path = Settings.base_dir.path_join(LOCAL_FILE)
	print("Patient database path: ", database_file_path)
	load_database()

func load_database() -> bool:
	patient_register = {}
	version = 0
	if OS.get_name() == "Android":
		patient_register[ANDROID_TEST_PATIENT] = {
			"name": ANDROID_TEST_PATIENT, "affected_hand": "Both", "status": "active"}
	var ok := _load_file(database_file_path)
	if not ok:
		print("No usable patients.json yet; it arrives with the first server sync")
	var local := _read_patients(local_file_path)
	for p in local:
		var id := str(p.get("user_id", ""))
		if id != "" and not patient_register.has(id):
			patient_register[id] = {"name": id, "affected_hand": _side(p), "status": "active", "local": true}
	print("Loaded patient database v%d with %d patients (%d local)" % [version, patient_register.size(), local.size()])
	return ok


## The server's patients.json.
func _load_file(path: String) -> bool:
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
		if str(p.get("status", "active")).to_lower() != "active":
			continue
		var id := str(p["user_id"])
		patient_register[id] = {"name": id, "affected_hand": _side(p), "status": p.get("status", "")}
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
	var f := FileAccess.open(local_file_path, FileAccess.WRITE)
	if f == null:
		return "Could not save: %s" % error_string(FileAccess.get_open_error())
	f.store_string(JSON.stringify({"patients": local}, "  "))
	f.close()
	patient_register[id] = {"name": id, "affected_hand": side, "status": "active", "local": true}
	return ""

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
