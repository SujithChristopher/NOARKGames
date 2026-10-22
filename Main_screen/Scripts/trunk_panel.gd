extends CanvasLayer
## Game-menu panel: trunk tracking status and the "Capture neutral" button.
## The neutral is the patient sitting upright; every trunk angle in the games
## is measured from it. It lives in the tracker until it is captured again or
## the app restarts.

const FONT_SIZE := 20

var _status: Label
var _result: Label
var _button: Button
var _pick_button: Button
var _clear_zero: Button   # model frame: back to the model's own zero
var _picker: Node
var _offered := false   # the picker opened by itself for this crowd already


func _ready() -> void:
	# The game menus capture the neutral here, so they track too (trunk on only).
	if TrunkMonitor.enabled():
		GlobalScript.hold_tracking(self)
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	box.position.y -= 18
	box.alignment = BoxContainer.ALIGNMENT_END
	add_child(box)

	_status = _label()
	box.add_child(_status)
	_button = Button.new()
	_button.text = "Capture neutral posture"
	_button.add_theme_font_size_override("font_size", FONT_SIZE)
	_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_button.pressed.connect(_on_capture_pressed)
	box.add_child(_button)
	_clear_zero = Button.new()
	_clear_zero.text = "Clear zero"
	_clear_zero.add_theme_font_size_override("font_size", FONT_SIZE)
	_clear_zero.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_clear_zero.pressed.connect(TrunkMonitor.clear_zero)
	box.add_child(_clear_zero)
	_pick_button = Button.new()
	_pick_button.text = "Select person"
	_pick_button.add_theme_font_size_override("font_size", FONT_SIZE)
	_pick_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_pick_button.pressed.connect(_open_picker)
	box.add_child(_pick_button)
	_result = _label()
	box.add_child(_result)

	TrunkMonitor.updated.connect(_refresh)
	TrunkMonitor.enabled_changed.connect(func(_on): _refresh())
	_refresh()


func _label() -> Label:
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", FONT_SIZE)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 5)
	return l


func _process(_delta: float) -> void:
	# Packets stop arriving when tracking is off; updated never fires then.
	if not TrunkMonitor.available() and _button.visible:
		_refresh()


func _open_picker() -> void:
	if _picker != null and is_instance_valid(_picker):
		return
	_picker = preload("res://Main_screen/Scripts/person_picker.gd").new()
	_picker.closed.connect(func(): _result.text = "Now capture neutral posture" if not TrunkMonitor.has_neutral else "")
	add_child(_picker)


func _on_capture_pressed() -> void:
	TrunkMonitor.capture_neutral()
	_result.text = "Sit upright and hold still..."
	_result.modulate = Color.WHITE


func _refresh() -> void:
	var on := TrunkMonitor.available()
	# Model frame: angles from minisam3d's own frame, no capture needed; the
	# button sets a zero of your own instead.
	var model := TrunkMonitor.model_frame()
	_button.visible = on
	_button.text = "Set zero" if model else "Capture neutral posture"
	_clear_zero.visible = on and model and TrunkMonitor.has_neutral
	_button.disabled = TrunkMonitor.state == TrunkMonitor.CAPTURING
	_pick_button.visible = on
	# More than one person and nobody picked yet: ask once, rather than let the
	# tracker guess the centre-most.
	if TrunkMonitor.people <= 1:
		_offered = false
	elif on and not _offered and not TrunkMonitor.locked and (model or not TrunkMonitor.has_neutral):
		_offered = true
		_open_picker()
	_status.text = TrunkMonitor.status_text()
	if not on:
		_result.text = ""
		return
	if TrunkMonitor.state == TrunkMonitor.CAPTURING:
		_result.text = "Sit upright and hold still..."
		_result.modulate = Color.WHITE
		return
	if model and TrunkMonitor.capture_result in ["", "away"]:
		_result.text = "Zero set by you" if TrunkMonitor.has_neutral else "Model frame: no neutral needed"
		_result.modulate = Color.WHITE
		return
	match TrunkMonitor.capture_result:
		"ok":
			_result.text = "Zero set ✓" if model else "Neutral captured ✓"
			_result.modulate = Color(0.5, 1.0, 0.5)
		"moving":
			_result.text = "Capture failed: please hold still and try again"
			_result.modulate = Color(1.0, 0.6, 0.4)
		"not_visible":
			_result.text = "Capture failed: the trunk is not visible to the cameras"
			_result.modulate = Color(1.0, 0.6, 0.4)
		"away":
			_result.text = "Person was away: capture neutral posture again"
			_result.modulate = Color(1.0, 0.6, 0.4)
