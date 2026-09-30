extends RefCounted

# One session's files, written through Manager (manager.gd). Target rows are
# flushed as they are written, hand rows once per frame, so a power cut loses
# at most one frame.
#   <stem>.csv             — one row per firefly (Manager's 7-line header, then the rows)
#   <stem>_hand.csv        — every hand sample (one per frame)
#   <stem>_reach.csv       — the reach scan, one row per polygon corner
#   <stem>_calibration.csv — per pair: calibration result and the play lifetime
# "attempt" counts calibration redos; analysis uses the last attempt's rows.

const TARGET_COLUMNS: Array = [
	"phase", "attempt", "round", "apple", "pair", "a_mm", "w_mm", "a_actual_mm", "angle_deg",
	"start_x_mm", "start_y_mm", "target_x_mm", "target_y_mm",
	"spawn_time", "lifetime_s", "hold_start_time", "outcome", "outcome_time", "mt_s", "points",
]
# Timed calibration (staircase.gd, 2026-09-28): cal_rate = the catch rate its
# staircase kept; start_lifetime_s = the warm-up median it began at;
# km_reach = how far the Kaplan–Meier curve F got (below level_p: the level
# was beyond it and play uses the longest lifetime tried).
const CALIB_COLUMNS: Array = [
	"attempt", "pair", "a_mm", "w_mm", "caught", "missed", "cal_rate", "start_lifetime_s",
	"km_reach", "level_p", "lifetime_s",
]
const HAND_COLUMNS: Array = [
	"epochtime", "capture_time", "phase", "round",
	"hand_x_mm", "hand_y_mm", "tracker_x", "tracker_y", "tracker_z",
]
const REACH_COLUMNS: Array = [
	"attempt", "vertex", "angle_deg", "reach_mm", "edge_x_mm", "edge_y_mm", "screen_limit_mm", "limited_by",
]

var folder: String = ""
var _targets: FileAccess = null
var _hand: FileAccess = null
var _reach: FileAccess = null
var _calib: FileAccess = null


# header: Array of "key,value" lines (game settings) for the side files. The target rows go in Manager's usual
# GameData/<game>_S<s>_T<t>_<date>.csv; hand, reach and calibration rows go
# beside it as <same name>_hand.csv etc. Returns false if a file could not be made.
func open(game_name: String, patient_id: String, header: Array) -> bool:
	var handle: FileAccess = Manager.create_game_log_file(game_name, patient_id)
	if handle == null:
		return false
	var target_path: String = handle.get_path_absolute()
	folder = target_path.get_base_dir()
	var stem := target_path.get_file().get_basename()
	# Manager's 7 header rows stay as they are (readers count on them); this
	# session's settings are in the header of the side files.
	handle.store_csv_line(PackedStringArray(TARGET_COLUMNS))
	handle.flush()
	_targets = handle
	_hand = _open_csv(stem + "_hand.csv", header, HAND_COLUMNS)
	_reach = _open_csv(stem + "_reach.csv", header, REACH_COLUMNS)
	_calib = _open_csv(stem + "_calibration.csv", header, CALIB_COLUMNS)
	return _hand != null and _reach != null and _calib != null


func _open_csv(file_name: String, header: Array, columns: Array) -> FileAccess:
	var f := FileAccess.open(folder + "/" + file_name, FileAccess.WRITE)
	if f == null:
		push_error("Could not create " + folder + "/" + file_name)
		return null
	f.store_line("headerrows,%d" % (header.size() + 2))
	for line in header:
		f.store_line(line)
	f.store_line("start_time,%s" % Time.get_datetime_string_from_system())
	f.store_csv_line(PackedStringArray(columns))
	f.flush()
	return f


func log_target(row: Array) -> void:
	_write(_targets, [row])


# One frame's worth of hand rows, flushed together.
func log_hand(rows: Array) -> void:
	_write(_hand, rows)


func log_reach(rows: Array) -> void:
	_write(_reach, rows)


func log_calibration(rows: Array) -> void:
	_write(_calib, rows)


func _write(f: FileAccess, rows: Array) -> void:
	if f == null or rows.is_empty():
		return
	for row in rows:
		var out := PackedStringArray()
		for v in row:
			out.append(str(v))
		f.store_csv_line(out)
	f.flush()


func close() -> void:
	if _targets:
		_targets.close()
		_targets = null
	if _hand:
		_hand.close()
		_hand = null
	if _reach:
		_reach.close()
		_reach = null
	if _calib:
		_calib.close()
		_calib = null
