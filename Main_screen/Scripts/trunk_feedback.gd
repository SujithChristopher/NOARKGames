extends CanvasLayer
## In-game trunk posture overlay, for any game: a small status line (top right),
## a cue banner when the patient compensates (a rounded panel while the game
## is paused for it) and a "Capture neutral" button (bottom left) to reset the
## neutral without leaving the game. What the game does about compensation is
## up to the game (see random_reach player.gd).
## Hidden while the tracker sends no trunk data.

## By level: OK, WARN, COMPENSATING (TrunkMonitor's enum).
const COLOURS := [Color(0.55, 1.0, 0.55), Color(1.0, 0.85, 0.3), Color(1.0, 0.4, 0.35)]
const GREY := Color(0.75, 0.75, 0.75)

## Set by the game while it is paused for compensation.
var paused_for_trunk := false:
	set(v):
		paused_for_trunk = v
		_refresh()

var _status: Label
var _banner: Label
var _pause_panel: PanelContainer
var _pause_cue: Label
var _capture: Button
var _capture_result: Label
var _capture_asked := false   # show the outcome only of a capture asked for here
var _capture_seen := false    # ...and only once it ran: capture_result still holds the last one


func _ready() -> void:
	layer = 10
	_status = _label(20)
	_status.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_status.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_status.position += Vector2(-16, 10)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_status)

	_banner = _label(40)
	_banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_banner.position.y = 90
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_banner)

	_build_pause_panel()
	_build_capture()

	TrunkMonitor.updated.connect(_refresh)
	TrunkMonitor.enabled_changed.connect(func(_on): _refresh())
	_refresh()


## The card shown while play is held: rounded, dark, edged in the compensating red.
func _build_pause_panel() -> void:
	_pause_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.06, 0.07, 0.88)
	sb.set_corner_radius_all(22)
	sb.set_border_width_all(3)
	sb.border_color = COLOURS[TrunkMonitor.COMPENSATING]
	sb.content_margin_left = 40
	sb.content_margin_right = 40
	sb.content_margin_top = 20
	sb.content_margin_bottom = 24
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = 14
	_pause_panel.add_theme_stylebox_override("panel", sb)
	_pause_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_pause_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_pause_panel.position.y = 80
	add_child(_pause_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_pause_panel.add_child(box)
	var title := Label.new()
	title.text = "PAUSED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", COLOURS[TrunkMonitor.COMPENSATING])
	box.add_child(title)
	_pause_cue = Label.new()
	_pause_cue.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pause_cue.add_theme_font_size_override("font_size", 36)
	box.add_child(_pause_cue)


## Bottom left, clear of the score (top left) and the pause button (bottom right).
func _build_capture() -> void:
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	box.position += Vector2(16, -16)
	box.alignment = BoxContainer.ALIGNMENT_END
	add_child(box)
	_capture_result = _label(18)
	box.add_child(_capture_result)
	_capture = Button.new()
	_capture.add_theme_font_size_override("font_size", 18)
	_capture.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	# Keyboard play (space, arrows) must not press it.
	_capture.focus_mode = Control.FOCUS_NONE
	_capture.pressed.connect(_on_capture_pressed)
	box.add_child(_capture)


func _on_capture_pressed() -> void:
	_capture_asked = true
	_capture_seen = false
	TrunkMonitor.capture_neutral()
	_capture_result.text = "Sit upright and hold still..."
	_capture_result.modulate = Color.WHITE


func _refresh_capture(on: bool) -> void:
	var model := TrunkMonitor.model_frame()
	_capture.visible = on
	_capture.text = "Set zero" if model else "Capture neutral"
	_capture.disabled = TrunkMonitor.state == TrunkMonitor.CAPTURING
	if not on or not _capture_asked:
		_capture_result.text = ""
		return
	if TrunkMonitor.state == TrunkMonitor.CAPTURING:
		_capture_seen = true
		return
	if not _capture_seen:
		return
	match TrunkMonitor.capture_result:
		"ok":
			_capture_result.text = "Zero set ✓" if model else "Neutral captured ✓"
			_capture_result.modulate = COLOURS[TrunkMonitor.OK]
		"moving":
			_capture_result.text = "Capture failed: hold still and try again"
			_capture_result.modulate = COLOURS[TrunkMonitor.COMPENSATING]
		"not_visible":
			_capture_result.text = "Capture failed: trunk not visible"
			_capture_result.modulate = COLOURS[TrunkMonitor.COMPENSATING]
		_:
			return
	# One outcome per press; it clears with the next press.
	_capture_asked = false


func _label(size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 6)
	return l


func _process(_delta: float) -> void:
	if not TrunkMonitor.available() and (_status.visible or _banner.visible):
		_refresh()


func _refresh() -> void:
	if _status == null:
		return
	var on := TrunkMonitor.available()
	_refresh_capture(on)
	_status.visible = on
	_banner.visible = false
	_pause_panel.visible = false
	if not on:
		return
	_status.text = TrunkMonitor.status_text()
	if TrunkMonitor.state != TrunkMonitor.TRACKING:
		_status.modulate = GREY
		return
	_status.modulate = COLOURS[TrunkMonitor.level]
	var cue := TrunkMonitor.cue_text()
	if paused_for_trunk:
		_pause_panel.visible = true
		_pause_cue.text = cue if cue != "" else "Sit upright to continue"
	elif TrunkMonitor.level > TrunkMonitor.OK:
		_banner.visible = true
		_banner.text = cue
		_banner.modulate = COLOURS[TrunkMonitor.level]
