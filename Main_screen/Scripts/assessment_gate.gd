extends RefCounted
## Every game starts through here: a patient plays only after a reach scan
## (Games/firefly_reach/reach_assessment.tscn) done today. Without one, the scan
## runs first and then the chosen game starts (GlobalSignals.pending_game).
## The menus' Assessment button always runs a fresh scan.

const ReachStore := preload("res://Games/firefly_reach/reach_store.gd")
const SCAN := "res://Games/firefly_reach/reach_assessment.tscn"


static func patient_id() -> String:
	return "vvv" if Manager.debug else PatientDB.current_patient_id


static func play(tree: SceneTree, game: PackedScene) -> void:
	if ReachStore.assessed_today(patient_id()):
		tree.change_scene_to_packed(game)
	else:
		GlobalSignals.pending_game = game
		tree.change_scene_to_file(SCAN)


static func assess(tree: SceneTree) -> void:
	GlobalSignals.pending_game = null
	tree.change_scene_to_file(SCAN)
