extends CanvasLayer
## In-game trunk posture overlay, for any game: a small status line (top right)
## and a cue banner when the patient compensates (a rounded panel while the game
## is paused for it). Display only; what the game
## does about compensation is up to the game (see random_reach player.gd).
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
