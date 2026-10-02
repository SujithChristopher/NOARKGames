extends ConfirmationDialog
## Therapy dose at login: minutes per day of ML / AP / MLAP movement, not tied
## to a game. A patient with a dose sees it filled in to confirm or change; one
## without must enter it. A new or changed dose is appended to configdata.csv
## (SessionLog.save_dose); confirming an unchanged dose writes nothing.
##
##   var d := DoseDialog.new()
##   d.confirmed_dose.connect(_go_on)
##   d.open(self, patient_id)

signal confirmed_dose

const FONT_SIZE := 28
const MAX_MINUTES := 180

var _pid: String = ""
var _previous: Dictionary = {}
var _spins: Dictionary = {}   # movement -> SpinBox
var _location: LineEdit
var _total: Label


func open(parent: Node, pid: String) -> void:
	_pid = pid
	_previous = SessionLog.latest_dose(pid)
	title = "Confirm therapy dose" if not _previous.is_empty() else "Enter therapy dose"
	ok_button_text = "Confirm"
	exclusive = true
	_build()
	confirmed.connect(_on_confirmed)
	canceled.connect(queue_free)
	parent.add_child(self)
	popup_centered(Vector2i(640, 0))


func _build() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	add_child(box)

	var note := Label.new()
	note.text = "Last set %s" % _previous["DateTime"] if not _previous.is_empty() \
		else "No dose set for this patient yet."
	box.add_child(_sized(note))

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 24)
	box.add_child(grid)
	for m in SessionLog.MOVEMENTS:
		grid.add_child(_sized(_label("%s (min/day)" % m)))
		var spin := SpinBox.new()
		spin.max_value = MAX_MINUTES
		spin.value = int(_previous.get(m, "0"))
		spin.custom_minimum_size.x = 160
		spin.get_line_edit().add_theme_font_size_override("font_size", FONT_SIZE)
		spin.value_changed.connect(func(_v): _refresh())
		grid.add_child(spin)
		_spins[m] = spin

	grid.add_child(_sized(_label("Location")))
	_location = LineEdit.new()
	_location.text = _previous.get("Location", Settings.get_value("location", ""))
	grid.add_child(_sized(_location))

	_total = Label.new()
	box.add_child(_sized(_total))
	get_ok_button().add_theme_font_size_override("font_size", FONT_SIZE)
	get_cancel_button().add_theme_font_size_override("font_size", FONT_SIZE)
	_refresh()


func _minutes(m: String) -> int:
	return int((_spins[m] as SpinBox).value)


func _refresh() -> void:
	var total := 0
	for m in SessionLog.MOVEMENTS:
		total += _minutes(m)
	_total.text = "Total: %d min/day" % total
	get_ok_button().disabled = total == 0   # a dose of nothing is not a dose


func _on_confirmed() -> void:
	var location := _location.text.strip_edges()
	var changed: bool = _previous.is_empty() \
\
		or location != _previous.get("Location", "")
	for m in SessionLog.MOVEMENTS:
		changed = changed or _minutes(m) != int(_previous.get(m, "0"))
	if changed:
		SessionLog.save_dose(_pid, _minutes("ML"), _minutes("AP"), _minutes("MLAP"), location)
	# The site is the device's, not the patient's: session.csv and the raw logs read it from settings.
	if location != "" and location != Settings.get_value("location", ""):
		Settings.set_value("location", location)
		Settings.save()
	confirmed_dose.emit()
	queue_free()


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _sized(c: Control) -> Control:
	c.add_theme_font_size_override("font_size", FONT_SIZE)
	return c
