extends Node
## The patient list, read from {DOCUMENTS}/NOARK_demo/patients.json. That file
## belongs to sender_raspberryPI.py, which fetches it from the server
## (`--sync`); NOARK never writes it and has no registry of its own. The ids are
## the server's user_id.
##
## Server format:
##   {"version": 2, "updated_at": "...", "patients": [
##       {"user_id": "AG12312", "status": "active", "side": "left", "devices": [...]}]}

# Singleton instance for global access
static var instance

const DB_FILE = "patients.json"

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

func _init():
	instance = self
	database_file_path = Settings.base_dir.path_join(DB_FILE)
	print("Patient database path: ", database_file_path)
	load_database()

func load_database() -> bool:
	patient_register = {}
	version = 0
	if OS.get_name() == "Android":
		patient_register[ANDROID_TEST_PATIENT] = {
			"name": ANDROID_TEST_PATIENT, "affected_hand": "Both", "status": "active"}
	if not FileAccess.file_exists(database_file_path):
		print("No patients.json yet; it arrives with the first server sync")
		return false

	var data = JSON.parse_string(FileAccess.get_file_as_string(database_file_path))
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("patients")) != TYPE_ARRAY:
		push_error("Invalid patient database format: ", database_file_path)
		return false

	version = int(data.get("version", 0))
	for p in data["patients"]:
		if typeof(p) != TYPE_DICTIONARY or str(p.get("user_id", "")) == "":
			continue
		if str(p.get("status", "active")).to_lower() != "active":
			continue
		var id := str(p["user_id"])
		var side: String = SIDES.get(str(p.get("side", "")).to_lower(), "")
		if side == "":
			side = "Both"
			push_warning("Patient %s has no usable side (%s); training Both" % [id, p.get("side")])
		patient_register[id] = {"name": id, "affected_hand": side, "status": p.get("status", "")}
	print("Loaded patient database v%d with %d patients" % [version, patient_register.size()])
	return true

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
