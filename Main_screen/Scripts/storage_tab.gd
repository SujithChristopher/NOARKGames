extends VBoxContainer
## Settings > Storage: the camera recordings on the board, by patient and
## session, and deleting them. A recording is tens of GB; nothing else (game
## data, sessions.csv, the tracker's position CSVs) is offered here.
##
## Everything goes through the tracker (STORAGE, docs/PROTOCOL.md; storage.py):
## over BLE the app runs on a tablet and cannot see the board's disk. The
## tracker refuses the recording being written now.

const LinkProtocol := preload("res://Main_screen/Scripts/link_protocol.gd")

const DANGER := Color(0.86, 0.27, 0.22)
const ACCENT := Color(0.35, 0.62, 0.9)
const MUTED := Color(0.7, 0.72, 0.75)
const LOW_DISK := 0.1          # free share under which the bar turns red
const CONFIRM_LIST_MAX := 8    # recordings named in the confirm dialog

var _disk_bar: ProgressBar
var _disk_fill: StyleBoxFlat
var _disk_label: Label
var _tree: Tree
var _summary: Label
var _status: Label
var _refresh_button: Button
var _delete_button: Button
var _confirm: ConfirmationDialog

var _recordings: Array = []    # the last listing's recordings
var _selected: Array = []      # their dictionaries, checked in the tree
var _pending: Array = []       # paths sent for deletion, not yet answered
var _batch := {"count": 0, "bytes": 0.0, "errors": []}


func _ready() -> void:
	add_theme_constant_override("separation", 10)

	# Disk
	var disk := HBoxContainer.new()
	disk.add_theme_constant_override("separation", 12)
	add_child(disk)
	var disk_title := Label.new()
	disk_title.text = "Board disk"
	disk.add_child(disk_title)
	_disk_bar = ProgressBar.new()
	_disk_bar.show_percentage = false
	_disk_bar.custom_minimum_size = Vector2(240, 22)
	_disk_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_disk_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_disk_fill = StyleBoxFlat.new()
	_disk_fill.set_corner_radius_all(4)
	_disk_bar.add_theme_stylebox_override("fill", _disk_fill)
	disk.add_child(_disk_bar)
	_disk_label = Label.new()
	disk.add_child(_disk_label)

	# Recordings
	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.columns = 2
	_tree.hide_root = true
	_tree.column_titles_visible = true
	_tree.set_column_title(0, "Camera recordings")
	_tree.set_column_title(1, "Size")
	_tree.set_column_expand(1, false)
	_tree.set_column_custom_minimum_width(1, 140)
	_tree.select_mode = Tree.SELECT_ROW
	_tree.item_edited.connect(_on_item_edited)
	add_child(_tree)

	# Actions
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	add_child(actions)
	_refresh_button = _button("Refresh", refresh)
	actions.add_child(_refresh_button)
	actions.add_child(_button("Select all", func(): _check_all(true)))
	actions.add_child(_button("Clear", func(): _check_all(false)))
	_summary = Label.new()
	_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	actions.add_child(_summary)
	_delete_button = _button("  Delete selected  ", _ask_delete)
	_delete_button.add_theme_color_override("font_color", DANGER)
	_delete_button.add_theme_color_override("font_hover_color", DANGER.lightened(0.2))
	actions.add_child(_delete_button)

	_status = Label.new()
	_status.add_theme_color_override("font_color", MUTED)
	_status.add_theme_font_size_override("font_size", 16)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)

	_confirm = ConfirmationDialog.new()
	_confirm.title = "Delete recordings?"
	_confirm.ok_button_text = "Delete"
	_confirm.cancel_button_text = "Cancel"
	_confirm.get_ok_button().add_theme_color_override("font_color", DANGER)
	_confirm.confirmed.connect(_delete_selected)
	add_child(_confirm)

	GlobalScript.storage_listed.connect(_on_listed)
	GlobalScript.link_command_done.connect(_on_command_done)
	GlobalScript.link_connected_changed.connect(_on_connected_changed)
	_show_disk({})
	_update_selection()


## Ask the tracker for the recordings again (the tab was opened, or Refresh).
func refresh() -> void:
	if not GlobalScript.link.connected:
		_show_offline()
		return
	_status.text = "Reading the board's recordings..."
	_refresh_button.disabled = true
	GlobalScript.send_storage_command("list")


func _button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size.y = 44
	b.pressed.connect(on_press)
	return b


# ── Answers from the tracker ──────────────────────────────────────────────────

func _on_listed(info: Dictionary) -> void:
	_refresh_button.disabled = false
	_recordings = info.get("recordings", [])
	_show_disk(info)
	var event: String = info.get("event", "")
	if event.begins_with("deleted "):
		_answered(event.trim_prefix("deleted "), "")
	elif event.begins_with("error: "):
		_answered("", event.trim_prefix("error: "))
	elif _pending.is_empty():   # a plain listing
		var n := _recordings.size()
		_status.text = "%d recording%s on the board." % [n, "" if n == 1 else "s"]
	_build_tree()


func _on_command_done(kind: int, ok: bool, detail: String) -> void:
	if kind != LinkProtocol.STORAGE or ok:
		return
	_refresh_button.disabled = false
	if detail == "no answer":   # whether any of them happened is unknown
		_pending.clear()
		_batch = {"count": 0, "bytes": 0.0, "errors": []}
		_status.text = "The tracker did not answer. Refresh to see what is on the board."
		_build_tree()
		return
	_answered("", detail)
	_build_tree()


func _on_connected_changed(connected: bool) -> void:
	if not is_visible_in_tree():
		return
	if connected:
		refresh()
	else:
		_pending.clear()
		_finish_batch()
		_show_offline()


func _show_offline() -> void:
	_recordings = []
	_build_tree()
	_show_disk({})
	_status.text = "Not connected to the tracker. The recordings are on the board; " \
		+ "this tab lists them once the tracker is running."


# One deletion answered: `path` deleted, or refused / failed with `error`.
func _answered(path: String, error: String) -> void:
	if error.is_empty():
		_pending.erase(path)
	else:
		_batch.errors.append(error)
		for p in _pending:   # the error names the recording
			if error.contains(p):
				_pending.erase(p)
				break
	if _pending.is_empty():
		_finish_batch()
	else:
		_status.text = "Deleting... %d of %d done" % [_batch.count - _pending.size(), _batch.count]


func _finish_batch() -> void:
	if _batch.count == 0:
		return
	var failed: int = _batch.errors.size()
	var done: int = _batch.count - failed
	var text := "Deleted %d recording%s." % [done, "" if done == 1 else "s"]
	if failed:
		text += "  Not deleted: " + "; ".join(_batch.errors)
	else:
		text = "Deleted %d recording%s, %s freed." % [done, "" if done == 1 else "s", _size_text(_batch.bytes)]
	_status.text = text
	_batch = {"count": 0, "bytes": 0.0, "errors": []}


# ── Disk ──────────────────────────────────────────────────────────────────────

func _show_disk(info: Dictionary) -> void:
	var total: float = info.get("total", 0.0)
	if total <= 0:
		_disk_bar.value = 0
		_disk_label.text = "—"
		return
	var free: float = info.get("free", 0.0)
	var in_recordings := 0.0
	for r in _recordings:
		in_recordings += r.bytes
	_disk_bar.value = 100.0 * (total - free) / total
	_disk_fill.bg_color = DANGER if free / total < LOW_DISK else ACCENT
	_disk_label.text = "%s free of %s  ·  recordings %s" % [
		_size_text(free), _size_text(total), _size_text(in_recordings)]


# ── Tree: patient > session > recording, each with a checkbox ─────────────────

func _build_tree() -> void:
	_tree.clear()
	var root := _tree.create_item()
	if _recordings.is_empty():
		var empty := _tree.create_item(root)
		empty.set_text(0, "No camera recordings on the board." if GlobalScript.link.connected else "—")
		empty.set_selectable(0, false)
		empty.set_selectable(1, false)
		_update_selection()
		return

	# patient -> session -> [recording]
	var grouped := {}
	var patient_bytes := {}
	for r in _recordings:
		var sessions: Dictionary = grouped.get_or_add(r.patient, {})
		(sessions.get_or_add(r.session, []) as Array).append(r)
		patient_bytes[r.patient] = patient_bytes.get(r.patient, 0.0) + r.bytes
	var patients := grouped.keys()
	patients.sort_custom(func(a, b): return patient_bytes[a] > patient_bytes[b])   # biggest first

	for patient in patients:
		var p_item := _tree.create_item(root)
		_checkable(p_item, patient, patient_bytes[patient])
		var sessions: Dictionary = grouped[patient]
		var names := sessions.keys()
		names.sort()
		names.reverse()   # newest first
		for session in names:
			var recs: Array = sessions[session]
			var s_bytes := 0.0
			for r in recs:
				s_bytes += r.bytes
			var s_item := _tree.create_item(p_item)
			_checkable(s_item, String(session).trim_prefix("Session-"), s_bytes)
			for r in recs:
				_recording_item(s_item, r)
	_update_selection()


func _checkable(item: TreeItem, text: String, bytes: float) -> void:
	item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
	item.set_editable(0, true)
	item.set_text(0, text)
	item.set_text(1, _size_text(bytes))
	item.set_text_alignment(1, HORIZONTAL_ALIGNMENT_RIGHT)


func _recording_item(parent: TreeItem, r: Dictionary) -> void:
	var item := _tree.create_item(parent)
	# rec_10-22-33 -> 10:22:33, the time it started
	var started := String(r.name).trim_prefix("rec_").replace("-", ":")
	_checkable(item, "Recording at " + started, r.bytes)
	item.set_metadata(0, r)
	var note := ""
	if r.active:
		note = "  —  recording now"
	elif r.path in _pending:
		note = "  —  deleting..."
	if not note.is_empty():
		item.set_text(0, item.get_text(0) + note)
		item.set_editable(0, false)
		item.set_custom_color(0, MUTED)


func _on_item_edited() -> void:
	var item := _tree.get_edited()
	if item == null:
		return
	item.propagate_check(0, false)
	_uncheck_locked(_tree.get_root())
	_update_selection()


# A patient or session ticks every recording under it; not the ones that
# cannot be deleted (being recorded, or already on their way).
func _uncheck_locked(item: TreeItem) -> void:
	for child in item.get_children():
		_uncheck_locked(child)
	var r = item.get_metadata(0)
	if r is Dictionary and not item.is_editable(0) and item.is_checked(0):
		item.set_checked(0, false)
		item.propagate_check(0, false)   # puts the parents right


func _check_all(on: bool) -> void:
	var root := _tree.get_root()
	if root == null:
		return
	for item in root.get_children():
		if item.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK:
			item.set_checked(0, on)
			item.propagate_check(0, false)
	_uncheck_locked(root)
	_update_selection()


func _update_selection() -> void:
	_selected.clear()
	var root := _tree.get_root()
	if root != null:
		_collect_checked(root)
	var bytes := 0.0
	for r in _selected:
		bytes += r.bytes
	_summary.text = "" if _selected.is_empty() else "%d selected  ·  %s" % [_selected.size(), _size_text(bytes)]
	_delete_button.disabled = _selected.is_empty() or not _pending.is_empty()


func _collect_checked(item: TreeItem) -> void:
	for child in item.get_children():
		_collect_checked(child)
	var r = item.get_metadata(0)
	if r is Dictionary and item.is_checked(0) and item.is_editable(0):
		_selected.append(r)


# ── Delete ────────────────────────────────────────────────────────────────────

func _ask_delete() -> void:
	if _selected.is_empty():
		return
	var bytes := 0.0
	var lines: Array[String] = []
	for r in _selected:
		bytes += r.bytes
		if lines.size() < CONFIRM_LIST_MAX:
			lines.append("    %s  /  %s  /  %s   (%s)" % [r.patient, String(r.session).trim_prefix("Session-"),
				String(r.name).trim_prefix("rec_").replace("-", ":"), _size_text(r.bytes)])
	if _selected.size() > lines.size():
		lines.append("    ...and %d more" % (_selected.size() - lines.size()))
	var n := _selected.size()
	_confirm.dialog_text = "Delete %d camera recording%s (%s) from the board?\n\n%s\n\n" % [
		n, "" if n == 1 else "s", _size_text(bytes), "\n".join(lines)] \
		+ "This cannot be undone. Game data and session records are kept."
	_confirm.popup_centered()


func _delete_selected() -> void:
	if not GlobalScript.link.connected:
		_show_offline()
		return
	_batch = {"count": _selected.size(), "bytes": 0.0, "errors": []}
	for r in _selected:
		_batch.bytes += r.bytes
		_pending.append(r.path)
		GlobalScript.send_storage_command("delete=" + r.path)
	_status.text = "Deleting %d recording%s..." % [_batch.count, "" if _batch.count == 1 else "s"]
	_build_tree()


static func _size_text(bytes: float) -> String:
	if bytes >= 1e9:
		return "%.1f GB" % (bytes / 1e9)
	if bytes >= 1e6:
		return "%.0f MB" % (bytes / 1e6)
	return "%.0f KB" % (bytes / 1e3)
