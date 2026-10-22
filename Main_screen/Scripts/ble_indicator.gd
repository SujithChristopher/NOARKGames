extends Control
## The tracker link's state (GlobalScript.link_status), over UDP or BLE, and
## once connected what the tracker's cameras are doing (idle until a game).

const LinkProtocol := preload("res://Main_screen/Scripts/link_protocol.gd")
const LinkStatus := LinkProtocol.LinkStatus
const TrackerState := LinkProtocol.TrackerState

@onready var _label: Label = $StatusLabel
@onready var _coord_label: Label = $CoordLabel

var _color: Color = Color(0.45, 0.45, 0.45)
var _text := ""
var _pulse: float = 0.0


func _status_color(status: int, tracker: int) -> Color:
	match status:
		LinkStatus.SCANNING:   return Color(1.00, 0.85, 0.00)
		LinkStatus.CONNECTING: return Color(1.00, 0.55, 0.00)
		LinkStatus.CONNECTED:
			match tracker:
				TrackerState.IDLE:     return Color(0.40, 0.75, 1.00)
				TrackerState.STARTING: return Color(1.00, 0.85, 0.00)
				TrackerState.FAILED:   return Color(1.00, 0.30, 0.30)
				_:                     return Color(0.20, 0.85, 0.20)
		_:                     return Color(0.45, 0.45, 0.45)


func _status_text(status: int, tracker: int) -> String:
	match status:
		LinkStatus.SCANNING:   return "Scanning"
		LinkStatus.CONNECTING: return "Connecting"
		LinkStatus.CONNECTED:
			match tracker:
				TrackerState.IDLE:     return "Connected · cameras off"
				TrackerState.STARTING: return "Starting cameras..."
				TrackerState.TRACKING: return "Tracking"
				TrackerState.FAILED:   return "Cameras failed, retrying"
				_:                     return "Connected"
		_:                     return "Not connected"


func _process(delta: float) -> void:
	var status: int = GlobalScript.link_status
	var tracker: int = GlobalScript.link.tracker_state if GlobalScript.link else TrackerState.UNKNOWN
	var base: Color = _status_color(status, tracker)

	var draw_color: Color
	if status == LinkStatus.SCANNING or status == LinkStatus.CONNECTING 			or (status == LinkStatus.CONNECTED and tracker == TrackerState.STARTING):
		_pulse = fmod(_pulse + delta * 3.0, TAU)
		draw_color = base.lightened(sin(_pulse) * 0.25)
	else:
		_pulse = 0.0
		draw_color = base

	if draw_color != _color:
		_color = draw_color
		queue_redraw()
	var text := _status_text(status, tracker)
	if text != _text:
		_text = text
		_label.text = text
		_label.add_theme_color_override("font_color", base)

	_coord_label.text = "x:%.1f  y:%.1f  z:%.1f" % [GlobalScript.net_x, GlobalScript.net_y, GlobalScript.net_z]


func _draw() -> void:
	var r := size.x * 0.5
	draw_circle(Vector2(r, r), r, Color(0, 0, 0, 0.35))
	draw_circle(Vector2(r, r), r - 2.0, _color)
