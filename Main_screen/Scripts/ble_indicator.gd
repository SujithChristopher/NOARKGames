extends Control
## The tracker link's state (GlobalScript.link_status), over UDP or BLE.

const LinkStatus := preload("res://Main_screen/Scripts/link_protocol.gd").LinkStatus

@onready var _label: Label = $StatusLabel
@onready var _coord_label: Label = $CoordLabel

var _color: Color = Color(0.45, 0.45, 0.45)
var _pulse: float = 0.0


func _status_color(status: int) -> Color:
	match status:
		LinkStatus.SCANNING:   return Color(1.00, 0.85, 0.00)
		LinkStatus.CONNECTING: return Color(1.00, 0.55, 0.00)
		LinkStatus.CONNECTED:  return Color(0.20, 0.85, 0.20)
		_:                                 return Color(0.45, 0.45, 0.45)


func _status_text(status: int) -> String:
	match status:
		LinkStatus.SCANNING:   return "Scanning"
		LinkStatus.CONNECTING: return "Connecting"
		LinkStatus.CONNECTED:  return "Receiving"
		_:                                 return "Idle"


func _process(delta: float) -> void:
	var status: int = GlobalScript.link_status
	var base: Color = _status_color(status)

	var draw_color: Color
	if status == LinkStatus.SCANNING or status == LinkStatus.CONNECTING:
		_pulse = fmod(_pulse + delta * 3.0, TAU)
		draw_color = base.lightened(sin(_pulse) * 0.25)
	else:
		_pulse = 0.0
		draw_color = base

	if draw_color != _color:
		_color = draw_color
		queue_redraw()
		_label.text = _status_text(status)
		_label.add_theme_color_override("font_color", base)

	_coord_label.text = "x:%.1f  y:%.1f  z:%.1f" % [GlobalScript.net_x, GlobalScript.net_y, GlobalScript.net_z]


func _draw() -> void:
	var r := size.x * 0.5
	draw_circle(Vector2(r, r), r, Color(0, 0, 0, 0.35))
	draw_circle(Vector2(r, r), r - 2.0, _color)
