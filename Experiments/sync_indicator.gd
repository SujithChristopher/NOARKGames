extends PanelContainer
## The mocap trigger, on every experiment screen: HIGH (green) or LOW (grey), and how many
## edges the board has seen. Watching opens the line on the tracker while no run holds it
## (EXPERIMENT `watch on`); during a run it is the run's own line, the one that is recorded.
## Every EXPERIMENT_STATUS carries it (`sync`), a change at once.
##
## Put one on a screen with `add_child(preload("res://Experiments/sync_indicator.gd").new())`: top
## centre, it asks to watch when added and stops when it leaves.

const Style := preload("res://Main_screen/Scripts/settings_style.gd")
const STALE_MS := 1500           # no word on the line this long: say it is not known
const FLASH_MS := 250            # an edge flashes the light, so a short pulse is seen

var level := -1                  # 1 HIGH, 0 LOW, -1 not known
var edges := 0
var available := false

var _light: Panel
var _state: Label
var _count: Label
var _heard_ms := 0
var _flash_until := 0


func _ready() -> void:
	theme_type_variation = "Card"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 20
	# One line at the top centre, clear of the table's points and of the screens' own text.
	var pad := MarginContainer.new()
	for side in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + side, 14)
	for side in ["top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 6)
	add_child(pad)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	pad.add_child(row)
	_light = Style.dot()
	_light.custom_minimum_size = Vector2(20, 20)
	(_light.get_theme_stylebox("panel") as StyleBoxFlat).set_corner_radius_all(10)
	row.add_child(_light)
	row.add_child(Style.label("Mocap sync", "Helper"))
	_state = Style.label("")
	_state.add_theme_font_size_override("font_size", 22)
	_state.custom_minimum_size.x = 96   # HIGH, LOW and NO LINE: the card does not jump
	row.add_child(_state)
	_count = Style.label("", "Helper")
	_count.custom_minimum_size.x = 90
	row.add_child(_count)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 8)

	GlobalScript.experiment_status.connect(_on_status)
	GlobalScript.link_connected_changed.connect(func(connected):
		if connected:
			_watch(true))
	_watch(true)
	_show()


func _exit_tree() -> void:
	_watch(false)


func _watch(on: bool) -> void:
	if GlobalScript.link and GlobalScript.link.connected:
		GlobalScript.send_experiment_command("watch on" if on else "watch off")


func _on_status(info: Dictionary) -> void:
	var sync = info.get("sync")
	if not sync is Dictionary:
		return
	_heard_ms = Time.get_ticks_msec()
	available = bool(sync.get("available", false))
	var now_level := int(sync.get("level", -1)) if available else -1
	var now_edges := int(sync.get("edges", 0))
	if available and (now_edges > edges or now_level != level):
		_flash_until = _heard_ms + FLASH_MS
	level = now_level
	edges = now_edges
	_show()


func _process(_delta: float) -> void:
	_show()


func _show() -> void:
	var now := Time.get_ticks_msec()
	var known := _heard_ms > 0 and now - _heard_ms <= STALE_MS
	var colour := Style.FAINT
	if not known:
		_state.text = "?"
		_count.text = "no word"
	elif not available:
		_state.text = "NO LINE"
		_count.text = "input not open"
		colour = Style.DANGER
	else:
		_state.text = "HIGH" if level == 1 else "LOW"
		_count.text = "%d edge%s" % [edges, "" if edges == 1 else "s"]
		colour = Style.GOOD if level == 1 else Style.TRACK
		if now < _flash_until:
			colour = Style.WARN
	_state.add_theme_color_override("font_color", colour if known and available else Style.MUTED)
	Style.set_dot(_light, colour)
