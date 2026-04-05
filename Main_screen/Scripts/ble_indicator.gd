extends Control

@onready var _label: Label = $StatusLabel

var _color: Color = Color(0.45, 0.45, 0.45)
var _pulse: float = 0.0


func _status_color(status: GlobalScript.BLEStatus) -> Color:
	match status:
		GlobalScript.BLEStatus.SCANNING:   return Color(1.00, 0.85, 0.00)
		GlobalScript.BLEStatus.CONNECTING: return Color(1.00, 0.55, 0.00)
		GlobalScript.BLEStatus.CONNECTED:  return Color(0.20, 0.85, 0.20)
		_:                                 return Color(0.45, 0.45, 0.45)


func _status_text(status: GlobalScript.BLEStatus) -> String:
	match status:
		GlobalScript.BLEStatus.SCANNING:   return "Scanning"
		GlobalScript.BLEStatus.CONNECTING: return "Connecting"
		GlobalScript.BLEStatus.CONNECTED:  return "Receiving"
		_:                                 return "Idle"


func _process(delta: float) -> void:
	var status := GlobalScript.ble_status
	var base: Color = _status_color(status)

	var draw_color: Color
	if status == GlobalScript.BLEStatus.SCANNING or status == GlobalScript.BLEStatus.CONNECTING:
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


func _draw() -> void:
	var r := size.x * 0.5
	draw_circle(Vector2(r, r), r, Color(0, 0, 0, 0.35))
	draw_circle(Vector2(r, r), r - 2.0, _color)
