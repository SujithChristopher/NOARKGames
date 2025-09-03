extends Node

var score_data_path := "user://score_data.tres"
var score_data: ScoreData 
func _ready():
	load_or_create_score_data()

func load_or_create_score_data():
	if ResourceLoader.exists(score_data_path):
		score_data = ResourceLoader.load(score_data_path)
	else:
		score_data = ScoreData.new()
		score_data.scores = {}  
		ResourceSaver.save(score_data, score_data_path)
		print(ProjectSettings.globalize_path("user://score_data.tres"))

func get_top_score(patient_id: String, game_name: String) -> int:
	if score_data.scores.has(patient_id) and score_data.scores[patient_id].has(game_name):
		return score_data.scores[patient_id][game_name]
	return 0

func update_top_score(patient_id: String, game_name: String, new_score: int):
	if not score_data.scores.has(patient_id):
		score_data.scores[patient_id] = {}
	var current_score = score_data.scores[patient_id].get(game_name, 0)
	if new_score > current_score:
		score_data.scores[patient_id][game_name] = new_score
		ResourceSaver.save(score_data, score_data_path)
		print(ProjectSettings.globalize_path("user://score_data.tres"))
