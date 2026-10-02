extends Node

# Singleton instance for global access
static var instance

# Constants
const RECORDS_DIR = "NOARK//records"
const DB_FILE = "patients.json"

# Patient database
var patient_register: Dictionary = {}
var current_patient_id: String = ""

# File paths
var records_path: String
var database_file_path: String

func _init():
	instance = self
	_setup_paths()
	_ensure_directory_exists()
	load_database()

func _setup_paths() -> void:
	var base_dir = OS.get_user_data_dir() if OS.get_name() == "Android" else OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS) + "/NOARK"
	
	records_path = base_dir.path_join("records")
	database_file_path = records_path.path_join(DB_FILE)

	print("Patient database path: ", database_file_path)

func _ensure_directory_exists() -> void:
	if not DirAccess.dir_exists_absolute(records_path):
		var result = DirAccess.make_dir_recursive_absolute(records_path)
		if result == OK:
			print("Created patient records directory: ", records_path)
		else:
			push_error("Failed to create patient records directory: ", records_path)

# The side the patient trains; required at registration.
const AFFECTED_SIDES := ["Left", "Right", "Both"]

func load_database() -> bool:
	if not FileAccess.file_exists(database_file_path):
		print("Patient database not found, creating new one")
		patient_register = {}
		current_patient_id = ""
		save_database()
		return true

	var file = FileAccess.open(database_file_path, FileAccess.READ)
	if not file:
		push_error("Failed to open patient database file: ", database_file_path)
		return false

	var json_string = file.get_as_text()
	file.close()

	var json = JSON.new()
	var parse_result = json.parse(json_string)

	if parse_result != OK:
		push_error("Failed to parse patient database JSON: ", json.get_error_message())
		return false

	var data = json.get_data()
	if typeof(data) == TYPE_DICTIONARY:
		patient_register = data.get("patient_register", {})
		current_patient_id = data.get("current_patient_id", "")
		print("Loaded patient database with ", patient_register.size(), " patients")
		_fill_missing_affected_side()
		return true
	else:
		push_error("Invalid patient database format")
		return false

# Patients registered before the affected side was required get one at random,
# so every patient has a training side. Saved at once, so it is assigned only once.
func _fill_missing_affected_side() -> void:
	var changed := false
	for id in patient_register:
		var patient: Dictionary = patient_register[id]
		if patient.get("affected_hand", "") not in AFFECTED_SIDES:
			patient["affected_hand"] = AFFECTED_SIDES.pick_random()
			push_warning("Patient %s had no affected side; assigned %s at random" % [id, patient["affected_hand"]])
			changed = true
	if changed:
		save_database()

func save_database() -> bool:
	var data = {
		"patient_register": patient_register,
		"current_patient_id": current_patient_id
	}

	var json_string = JSON.stringify(data, "\t")

	var file = FileAccess.open(database_file_path, FileAccess.WRITE)
	if not file:
		push_error("Failed to save patient database file: ", database_file_path)
		return false

	file.store_string(json_string)
	file.close()
	print("Patient database saved successfully")
	return true

# Function to add a patient to the register
func add_patient(hospital_id: String, patient_name: String, age: int, gender: String,
				stroke_time: int, dominant_hand: String, affected_hand: String, comments: String = "") -> bool:
	if hospital_id in patient_register:
		print("Patient with this hospital ID already exists!")
		return false

	patient_register[hospital_id] = {
		"name": patient_name,
		"age": age,
		"gender": gender,
		"stroke_time": stroke_time,
		"dominant_hand": dominant_hand,
		"affected_hand": affected_hand,
		"comments": comments
	}

	save_database()
	return true

# Function to remove a patient from the register
func remove_patient(hospital_id: String) -> bool:
	if hospital_id in patient_register:
		patient_register.erase(hospital_id)
		save_database()
		return true
	print("No patient with this hospital ID found!")
	return false

# Function to get a patient's details
func get_patient(hospital_id: String) -> Dictionary:
	if hospital_id in patient_register:
		return patient_register[hospital_id]
	print("No patient with this hospital ID found!")
	return {}

# Function to list all patients
func list_all_patients() -> Array:
	var patients = []
	for hospital_id in patient_register.keys():
		patients.append({
			"hospital_id": hospital_id,
			"name": patient_register[hospital_id]["name"],
			"age": patient_register[hospital_id]["age"],
			"gender": patient_register[hospital_id]["gender"],
			"stroke_time": patient_register[hospital_id]["stroke_time"],
			"dominant_hand": patient_register[hospital_id]["dominant_hand"],
			"affected_hand": patient_register[hospital_id]["affected_hand"],
			"comments": patient_register[hospital_id]["comments"],
		})
	return patients

# Note: If migrating from old patient_register.tres, manually copy data or
# re-register patients. The old PatientDetails class has been removed.
