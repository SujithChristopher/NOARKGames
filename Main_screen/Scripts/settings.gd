extends Node
## User settings, stored outside the project at {DOCUMENTS}/NOARK_demo/settings.json
## (Android: the app's user dir) so they are writable in an exported build and
## survive an update. Must be the FIRST autoload: Manager and GlobalScript read
## it in their own _ready().
##
## `debug` is deliberately file-only: it skips patient authentication, so no
## in-app screen exposes it. Edit the file to change it.
##
## First run: if the file is missing it is seeded from a legacy
## res://settings.json when one exists, otherwise from DEFAULTS.

const LEGACY_PATH := "res://settings.json"
## Every file the app writes lives under {DOCUMENTS}/<APP_DIR>. This is the demo
## build, so it keeps clear of the real {DOCUMENTS}/NOARK data.
const APP_DIR := "NOARK_demo"
const DEFAULTS := {
	"debug": false,
	"location": "PMR",
	"udp_port": 8000,
	"display": false,
	"tracker_cpus": "4-7",
	"game_cpus": "0-3",
	"tracker_solver": "joint",
	"tracker_camera": "both",
	"tracker_refine": "subpix",
	"corner_deadband_px": 0,
	"recording": false,
	"sync_chip": "gpiochip4",
	"sync_pin": "PIN_11",
	"recording_fps": 30,
	"recording_chunk_frames": 900,
	"recording_scale": 0.5,
	# Trunk tracking (pyscripts/trunk/): thresholds are degrees from the neutral
	# captured in the game menu, a number for every axis or a dictionary
	# {"flexion": .., "lateral": .., "axial": ..}.
	"trunk_enabled": true,
	"trunk_cpus": "7",
	"trunk_warn_deg": 8,
	"trunk_comp_deg": 15,
}

var base_dir: String   # {DOCUMENTS}/NOARK_demo, or the app's user dir on Android
var path: String
var data: Dictionary = {}


func _init() -> void:
	base_dir = OS.get_user_data_dir() if OS.get_name() == "Android" \
		else OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS).path_join(APP_DIR)
	path = base_dir.path_join("settings.json")
	_load()


func get_value(key: String, default: Variant = null) -> Variant:
	if data.has(key):
		return data[key]
	return DEFAULTS.get(key, default)


func set_value(key: String, value: Variant) -> void:
	data[key] = value


func save() -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("Cannot write %s (error %d)" % [path, FileAccess.get_open_error()])
		return false
	f.store_string(JSON.stringify(_whole_numbers(data), "    ") + "\n")
	return true


func _load() -> void:
	if FileAccess.file_exists(path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(parsed) == TYPE_DICTIONARY:
			data = _whole_numbers(parsed)
			return
		push_error("%s is not a valid JSON object; using defaults" % path)
		data = DEFAULTS.duplicate()
		return
	# First run.
	data = DEFAULTS.duplicate()
	if FileAccess.file_exists(LEGACY_PATH):
		var legacy = JSON.parse_string(FileAccess.get_file_as_string(LEGACY_PATH))
		if typeof(legacy) == TYPE_DICTIONARY:
			data.merge(legacy, true)
	save()


# Godot's JSON parses every number as a float, so a plain save would turn 8000 into
# 8000.0 and the tracker's socket bind would reject the port. Keep whole numbers integers.
static func _whole_numbers(d: Dictionary) -> Dictionary:
	var out := {}
	for k in d:
		var v = d[k]
		out[k] = int(v) if v is float and is_equal_approx(v, round(v)) else v
	return out
