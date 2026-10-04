extends RefCounted
## Every game starts through here: a patient plays only after a reach scan
## (Games/firefly_reach/reach_assessment.tscn) done today. Without one, the scan
## runs first and then the chosen game starts (GlobalSignals.pending_game).
## The menus' Assessment button always runs a fresh scan.

const ReachStore := preload("res://Games/firefly_reach/reach_store.gd")
const SCAN := "res://Games/firefly_reach/reach_assessment.tscn"


static func patient_id() -> String:
	return "vvv" if Manager.debug else PatientDB.current_patient_id


## Starts loading the menu's games on background threads, so the menu itself
## opens at once. Preloading them all in the menu script made the 2D/3D menu
## take 10-15 s to appear on the Pi (every game's textures, audio and shaders).
static func warm(paths: Array) -> void:
	for path in paths:
		if not ResourceLoader.has_cached(path):
			ResourceLoader.load_threaded_request(path)


## The scene at path: from the background load (waiting for it if it is still
## running), or loaded now if it was never started.
static func scene(path: String) -> PackedScene:
	if ResourceLoader.load_threaded_get_status(path) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		return ResourceLoader.load_threaded_get(path)
	return load(path)


static func play(tree: SceneTree, game: PackedScene) -> void:
	if ReachStore.assessed_today(patient_id()):
		tree.change_scene_to_packed(game)
	else:
		GlobalSignals.pending_game = game
		tree.change_scene_to_file(SCAN)


static func assess(tree: SceneTree) -> void:
	GlobalSignals.pending_game = null
	tree.change_scene_to_file(SCAN)
