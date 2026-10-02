extends RefCounted

# A patient's reach outline from the reach-scan assessment (reach_scan.gd), in
# table mm, kept beside their game data:
#     <data_path>/<patient>/reach_boundary.json
#     {"saved": "<datetime>", "boundary": [[x_mm, y_mm], ...]}
# Firefly Reach uses it to place targets and skips its own scan when present.


static func _path(patient_id: String) -> String:
	return GlobalSignals.data_path.path_join(patient_id).path_join("reach_boundary.json")


static func save(patient_id: String, boundary: Array) -> bool:
	DirAccess.make_dir_recursive_absolute(GlobalSignals.data_path.path_join(patient_id))
	var f := FileAccess.open(_path(patient_id), FileAccess.WRITE)
	if f == null:
		push_error("Could not write " + _path(patient_id))
		return false
	f.store_string(JSON.stringify({"saved": Time.get_datetime_string_from_system(), "boundary": boundary}, "\t"))
	f.close()
	return true


# The saved outline, or [] when none (or an unreadable file).
static func load_boundary(patient_id: String) -> Array:
	if not FileAccess.file_exists(_path(patient_id)):
		return []
	var d = JSON.parse_string(FileAccess.get_file_as_string(_path(patient_id)))
	if d is Dictionary and d.get("boundary") is Array and d["boundary"].size() >= 3:
		return d["boundary"]
	return []


# True when the saved outline was scanned today: the reach scan is required once a day.
static func assessed_today(patient_id: String) -> bool:
	if load_boundary(patient_id).is_empty():
		return false
	var d = JSON.parse_string(FileAccess.get_file_as_string(_path(patient_id)))
	return String(d.get("saved", "")).begins_with(Time.get_date_string_from_system())


static func clear(patient_id: String) -> void:
	if FileAccess.file_exists(_path(patient_id)):
		DirAccess.remove_absolute(_path(patient_id))
