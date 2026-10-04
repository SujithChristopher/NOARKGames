extends Node

# Singleton instance for global access
static var instance

# Constants
const SCORES_FILE = "scores.json"

# Score database structure: { "patient_id": { "game_name": top_score } }
var scores: Dictionary = {}

# File paths
var records_path: String
var scores_file_path: String

func _init():
	instance = self
	_setup_paths()
	_ensure_directory_exists()
	load_scores()

func _setup_paths() -> void:
	records_path = Settings.base_dir.path_join("records")
	scores_file_path = records_path.path_join(SCORES_FILE)

	print("Scores database path: ", scores_file_path)

func _ensure_directory_exists() -> void:
	if not DirAccess.dir_exists_absolute(records_path):
		var result = DirAccess.make_dir_recursive_absolute(records_path)
		if result == OK:
			print("Created records directory: ", records_path)
		else:
			push_error("Failed to create records directory: ", records_path)

func load_scores() -> bool:
	if not FileAccess.file_exists(scores_file_path):
		print("Scores database not found, creating new one")
		scores = {}
		save_scores()
		_migrate_from_old_system()
		return true

	var file = FileAccess.open(scores_file_path, FileAccess.READ)
	if not file:
		push_error("Failed to open scores database file: ", scores_file_path)
		return false

	var json_string = file.get_as_text()
	file.close()

	var json = JSON.new()
	var parse_result = json.parse(json_string)

	if parse_result != OK:
		push_error("Failed to parse scores database JSON: ", json.get_error_message())
		return false

	var data = json.get_data()
	if typeof(data) == TYPE_DICTIONARY:
		scores = data
		print("Loaded scores database with ", scores.size(), " patients")
		return true
	else:
		push_error("Invalid scores database format")
		return false

func save_scores() -> bool:
	var json_string = JSON.stringify(scores, "\t")

	var file = FileAccess.open(scores_file_path, FileAccess.WRITE)
	if not file:
		push_error("Failed to save scores database file: ", scores_file_path)
		return false

	file.store_string(json_string)
	file.close()
	return true

func get_top_score(patient_id: String, game_name: String) -> int:
	if scores.has(patient_id) and scores[patient_id].has(game_name):
		return scores[patient_id][game_name]
	return 0

func update_top_score(patient_id: String, game_name: String, new_score: int) -> void:
	if not scores.has(patient_id):
		scores[patient_id] = {}

	var current_score = scores[patient_id].get(game_name, 0)
	if new_score > current_score:
		scores[patient_id][game_name] = new_score
		save_scores()
		print("New top score for %s - %s: %d" % [patient_id, game_name, new_score])

func get_all_scores_for_patient(patient_id: String) -> Dictionary:
	if scores.has(patient_id):
		return scores[patient_id]
	return {}

func get_all_scores_for_game(game_name: String) -> Dictionary:
	var game_scores = {}
	for patient_id in scores.keys():
		if scores[patient_id].has(game_name):
			game_scores[patient_id] = scores[patient_id][game_name]
	return game_scores

func delete_patient_scores(patient_id: String) -> bool:
	if scores.has(patient_id):
		scores.erase(patient_id)
		save_scores()
		return true
	return false

# Migration function to import old score_data.tres if it exists
func _migrate_from_old_system() -> void:
	var old_score_path = "user://score_data.tres"
	if ResourceLoader.exists(old_score_path):
		print("Found old score_data.tres, migrating...")
		var old_data = ResourceLoader.load(old_score_path)
		if old_data and old_data.has("scores"):
			scores = old_data.scores.duplicate(true)
			save_scores()
			print("Score migration complete. %d patients migrated." % scores.size())
