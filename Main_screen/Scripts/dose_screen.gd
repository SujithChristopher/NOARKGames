extends Control
## Therapy dose screen, between login and the 2D/3D choice: minutes per day of
## ML / AP / MLAP movement, not tied to a game. A patient with a dose sees it
## filled in to confirm or change; one without must enter it. A new or changed
## dose is appended to configdata.csv (SessionLog.save_dose); confirming an
## unchanged dose writes nothing. Confirm starts the session.
##
## The patient is PatientDB.current_patient_id, set by the main screen.

const MAIN_SCENE := "res://Main_screen/Scenes/main.tscn"
const NEXT_SCENE := "res://Main_screen/Scenes/mode.tscn"
const BUNGEE := preload("res://Assets/Fonts/Bungee-Regular.ttf")
const OSWALD := preload("res://Assets/Fonts/Oswald-SemiBold.ttf")

const MAX_MINUTES := 180
const STEP := 5
const MOVEMENT_NAMES := {
	"ML": "Side to side",
	"AP": "Forward and back",
	"MLAP": "Reach all around",
}
const ACCENT := Color(0.27, 0.72, 0.47)

var _pid: String = ""
var _previous: Dictionary = {}
var _fields: Dictionary = {}   # movement -> LineEdit holding its minutes

@onready var _subtitle: Label = %Subtitle
@onready var _rows: VBoxContainer = %Rows
@onready var _location: LineEdit = %Location
@onready var _total: Label = %Total
@onready var _note: Label = %Note
@onready var _confirm: Button = %Confirm
@onready var _back: Button = %Back


func _ready() -> void:
	_pid = PatientDB.current_patient_id
	_previous = SessionLog.latest_dose(_pid)
	if _previous.is_empty():
		_subtitle.text = "Patient %s  ·  No dose set yet - enter today's minutes" % _pid
	else:
		_subtitle.text = "Patient %s  ·  Last set %s" % [_pid, _previous["DateTime"]]

	for m in SessionLog.MOVEMENTS:
		_rows.add_child(_movement_row(m, int(_previous.get(m, "0"))))
	_location.text = _previous.get("Location", Settings.get_value("location", ""))
	_location.text_changed.connect(func(_t): _refresh())

	_style_button(_back, Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.35))
	_style_button(_confirm, ACCENT, ACCENT)
	_back.pressed.connect(_on_back)
	_confirm.pressed.connect(_on_confirm)
	_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_on_back()
	elif event.is_action_pressed("ui_accept") and not _confirm.disabled:
		_on_confirm()


# One movement: its name and games on the left, a -/+ stepper on the right.
func _movement_row(m: String, minutes: int) -> Control:
	var panel := PanelContainer.new()
	var style := _box(Color(1, 1, 1, 0.06), 14)
	style.content_margin_left = 20
	style.content_margin_right = 14
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)

	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", -2)
	row.add_child(text)
	text.add_child(_label("%s  (%s)" % [MOVEMENT_NAMES.get(m, m), m], BUNGEE, 21))
	var games := _label(_games_for(m), OSWALD, 16)
	games.modulate = Color(1, 1, 1, 0.6)
	text.add_child(games)

	var field := LineEdit.new()
	field.text = str(minutes)
	field.alignment = HORIZONTAL_ALIGNMENT_CENTER
	field.custom_minimum_size = Vector2(92, 56)
	field.max_length = 3
	field.select_all_on_focus = true
	field.add_theme_font_override("font", BUNGEE)
	field.add_theme_font_size_override("font_size", 28)
	var field_style := _box(Color(0, 0, 0, 0.25), 10)
	field.add_theme_stylebox_override("normal", field_style)
	var focus_style := field_style.duplicate()
	focus_style.set_border_width_all(2)
	focus_style.border_color = ACCENT
	field.add_theme_stylebox_override("focus", focus_style)
	field.text_changed.connect(func(_t): _clean(field))
	field.focus_exited.connect(func(): field.text = str(_minutes_in(field)))
	_fields[m] = field

	row.add_child(_step_button("-", field, -STEP))
	row.add_child(field)
	row.add_child(_step_button("+", field, STEP))
	var unit := _label("min", OSWALD, 18)
	unit.modulate = Color(1, 1, 1, 0.6)
	unit.custom_minimum_size.x = 36
	row.add_child(unit)
	return panel


func _games_for(m: String) -> String:
	var names := PackedStringArray()
	for game in SessionLog.MOVEMENT:
		if SessionLog.MOVEMENT[game] == m:
			names.append(game.capitalize())
	return ", ".join(names)


func _step_button(text: String, field: LineEdit, delta: int) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(56, 56)
	b.add_theme_font_override("font", BUNGEE)
	b.add_theme_font_size_override("font_size", 26)
	_style_button(b, Color(1, 1, 1, 0.12), Color(1, 1, 1, 0.0), 28)
	b.pressed.connect(func():
		field.text = str(clampi(_minutes_in(field) + delta, 0, MAX_MINUTES))
		_refresh())
	return b


# Digits only, at most MAX_MINUTES, keeping the caret where the user is typing.
func _clean(field: LineEdit) -> void:
	var digits := ""
	for c in field.text:
		if c >= "0" and c <= "9":
			digits += c
	if digits != "" and int(digits) > MAX_MINUTES:
		digits = str(MAX_MINUTES)
	if digits != field.text:
		var caret := field.caret_column
		field.text = digits
		field.caret_column = mini(caret, digits.length())
	_refresh()


func _minutes_in(field: LineEdit) -> int:
	return clampi(int(field.text), 0, MAX_MINUTES)


func _minutes(m: String) -> int:
	return _minutes_in(_fields[m])


func _changed() -> bool:
	if _previous.is_empty() or _location.text.strip_edges() != _previous.get("Location", ""):
		return true
	for m in SessionLog.MOVEMENTS:
		if _minutes(m) != int(_previous.get(m, "0")):
			return true
	return false


func _refresh() -> void:
	var total := 0
	for m in SessionLog.MOVEMENTS:
		total += _minutes(m)
	_total.text = "Total  %d min / day" % total
	_confirm.disabled = total == 0   # a dose of nothing is not a dose
	if total == 0:
		_note.text = "Set at least one movement to continue"
	elif _previous.is_empty():
		_note.text = "This will be saved as the patient's first dose"
	elif _changed():
		_note.text = "Changed - will be saved as a new dose"
	else:
		_note.text = ""


func _on_confirm() -> void:
	var location := _location.text.strip_edges()
	if _changed():
		SessionLog.save_dose(_pid, _minutes("ML"), _minutes("AP"), _minutes("MLAP"), location)
	# The site is the device's, not the patient's: sessions.csv and the raw logs read it from settings.
	if location != "" and location != Settings.get_value("location", ""):
		Settings.set_value("location", location)
		Settings.save()
	SessionLog.start_session(_pid)
	get_tree().change_scene_to_file(NEXT_SCENE)


func _on_back() -> void:
	get_tree().change_scene_to_file(MAIN_SCENE)


func _label(text: String, font: Font, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	return l


func _box(color: Color, radius: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(radius)
	return s


# Flat rounded button: fill, optional outline, lighter on hover, faded when disabled.
func _style_button(b: Button, fill: Color, outline: Color, radius: int = 12) -> void:
	var normal := _box(fill, radius)
	if outline.a > 0.0:
		normal.set_border_width_all(2)
		normal.border_color = outline
	var hover := normal.duplicate()
	hover.bg_color = fill.lightened(0.15) if fill.a > 0.0 else Color(1, 1, 1, 0.1)
	var pressed := normal.duplicate()
	pressed.bg_color = fill.darkened(0.15) if fill.a > 0.0 else Color(1, 1, 1, 0.18)
	var disabled := normal.duplicate()
	disabled.bg_color = Color(fill, fill.a * 0.35)
	disabled.border_color = Color(outline, outline.a * 0.35)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("disabled", disabled)
	b.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.35))
