extends Control

const _COLORS = {
	GlobalScript.BLEStatus.IDLE:       Color(0.45, 0.45, 0.45),
	GlobalScript.BLEStatus.SCANNING:   Color(1.00, 0.85, 0.00),
	GlobalScript.BLEStatus.CONNECTING: Color(1.00, 0.55, 0.00),
	GlobalScript.BLEStatus.CONNECTED:  Color(0.20, 0.85, 0.20),
}

var _color: Color = _COLORS[GlobalScript.BLEStatus.IDLE]
var _pulse: float  = 0.0


func _process(delta: float) -> void:
	var status  := GlobalScript.ble_status
	var target  := _COLORS.get(status, _COLORS[GlobalScript.BLEStatus.IDLE])

	# Pulse brightness for non-idle, non-connected states
	var draw_color: Color
	if status == GlobalScript.BLEStatus.SCANNING or status == GlobalScript.BLEStatus.CONNECTING:
		_pulse = fmod(_pulse + delta * 3.0, TAU)
		draw_color = target.lightened(sin(_pulse) * 0.25)
	else:
		_pulse = 0.0
		draw_color = target

	if draw_color != _color:
		_color = draw_color
		queue_redraw()


func _draw() -> void:
	var r := size.x * 0.5
	# subtle dark ring
	draw_circle(Vector2(r, r), r, Color(0, 0, 0, 0.35))
	draw_circle(Vector2(r, r), r - 2.0, _color)
