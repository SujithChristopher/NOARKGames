extends CanvasLayer
## In-game trunk posture overlay, for any game: a small status line (top right)
## and a cue banner when the patient compensates. Display only; what the game
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

	TrunkMonitor.updated.connect(_refresh)
	_refresh()


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
	if not on:
		return
	_status.text = TrunkMonitor.status_text()
	if TrunkMonitor.state != TrunkMonitor.TRACKING:
		_status.modulate = GREY
		return
	_status.modulate = COLOURS[TrunkMonitor.level]
	if TrunkMonitor.level > TrunkMonitor.OK or paused_for_trunk:
		_banner.visible = true
		var cue := TrunkMonitor.cue_text()
		if paused_for_trunk:
			_banner.text = ("Paused: " + cue) if cue != "" else "Paused: sit upright to continue"
			_banner.modulate = COLOURS[TrunkMonitor.COMPENSATING]
		else:
			_banner.text = cue
			_banner.modulate = COLOURS[TrunkMonitor.level]
