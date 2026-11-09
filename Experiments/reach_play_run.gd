extends RefCounted
## Experiment: Random Reach played as an experiment. What one run is, kept across its three
## screens (setup reach_play.gd -> reach scan reach_play_scan.gd -> Random Reach in 2D,
## reach_play_game.gd beside its player) in static variables: no autoload for one experiment.
##
## The run is opened on the tracker at the setup screen's Start (`start reach_play ... play
## <fps> <scale>`), so a refusal (no disk, a run going) is seen before anyone does a scan. Only
## the game is recorded: `record` when play starts, `stop` at game over. The tracker writes the
## images (at the chosen rate and size), poses.csv and metadata.json on the board; the app writes
## the game's own files into the folder of the same name under its experiments/ folder, which on
## the board (UDP) is the same folder, and on a tablet (BLE) the tablet's:
##     reach_boundary.json   the workspace scan, as reach_store.gd writes it
##     random_reach.csv      Random Reach's own rows, 50 a second, then "Final Score: n"
## No patient: nothing goes to sessions.csv, scores, or the server.

const NAME := "reach_play"
const SETUP := "res://Experiments/reach_play.tscn"
const SCAN := "res://Experiments/reach_play_scan.tscn"
const GAME := "res://Games/random_reach/scenes/random_reach.tscn"

enum Phase { NONE, SCAN, PLAYING, SAVING }

# The setup screen's choices, kept for the next run.
static var label := ""
static var notes := ""
static var fps := 30            # recording rate; 0 = every frame
static var scale := 1.0         # 1 full, 0.5 half, 0.25 a quarter of the width and height
static var seconds := 120       # game time

static var phase: int = Phase.NONE
static var tracker_path := ""   # the run's folder on the board, from the start ACK
static var boundary: Array = [] # the scan's outline, table mm
## How the last run ended, for the setup screen: {why, score, frames, error}.
static var result: Dictionary = {}


## The app's copy of the run's folder: the tracker's folder name under this app's experiments/.
static func local_dir() -> String:
	return GlobalSignals.data_path.get_base_dir().path_join("experiments").path_join(NAME) \
		.path_join(tracker_path.get_file())


## Loads Random Reach on a background thread (as the game menus do, AssessmentGate.warm). Loading
## it on the main thread when the scan ends stops the app's heartbeat for over 3 s on the board,
## and the tracker then takes the link as lost and closes the run (seen 2026-11-09).
static func warm_game() -> void:
	if ResourceLoader.has_cached(GAME):
		return
	if ResourceLoader.load_threaded_get_status(GAME) == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		ResourceLoader.load_threaded_request(GAME)


## Random Reach once it is loaded, null while the background load is still going. Never blocks.
static func game_if_loaded() -> PackedScene:
	if ResourceLoader.has_cached(GAME):
		return load(GAME)
	match ResourceLoader.load_threaded_get_status(GAME):
		ResourceLoader.THREAD_LOAD_LOADED:
			return ResourceLoader.load_threaded_get(GAME)
		ResourceLoader.THREAD_LOAD_FAILED:
			push_error("[Reach play] Background load of %s failed; loading it now" % GAME)
			return load(GAME)
		ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			ResourceLoader.load_threaded_request(GAME)   # nobody asked yet
	return null


static func playing() -> bool:
	return phase == Phase.PLAYING


## Writes a file of the run's on the app's side. False if it could not.
static func write_file(file_name: String, text: String) -> bool:
	DirAccess.make_dir_recursive_absolute(local_dir())
	var f := FileAccess.open(local_dir().path_join(file_name), FileAccess.WRITE)
	if f == null:
		push_error("[Reach play] Cannot write %s" % local_dir().path_join(file_name))
		return false
	f.store_string(text)
	f.close()
	return true


## Ends the run on the tracker and goes back to the setup screen, which waits for it to be saved.
## why: "complete" (the game's time ran out) or "stopped" (left early, or the scan cancelled).
static func finish(tree: SceneTree, why: String, extra: Dictionary = {}) -> void:
	if phase == Phase.NONE or phase == Phase.SAVING:
		return
	result = {"why": why, "recorded": phase == Phase.PLAYING}
	result.merge(extra, true)
	phase = Phase.SAVING
	if GlobalScript.link and GlobalScript.link.connected:
		GlobalScript.send_experiment_command("stop " + why)
	else:
		result["error"] = "The link to the tracker was lost: the tracker closed the run itself."
	if tree != null:
		tree.change_scene_to_file.call_deferred(SETUP)
