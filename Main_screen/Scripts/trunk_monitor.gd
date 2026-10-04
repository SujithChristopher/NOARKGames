extends Node
## Trunk posture from the tracker (pyscripts/trunk/): neutral capture, angles
## from neutral and a per-axis compensation level.
##
## tracker.py sends a text datagram per trunk update (~10 Hz), which
## GlobalScript hands to on_packet():
##   TRK:state,level,lvl_flex,lvl_lat,lvl_axi,flex,lat,axi,progress,has_neutral,
##       reason,capture_result
## The thresholds, hysteresis and dwell are applied in Python
## (settings.json trunk_warn_deg / trunk_comp_deg); this only reports them.
##
## Angle signs: flexion + = leaning forward, lateral + = leaning to the
## patient's left, axial + = turning to the patient's right.

signal updated
signal state_changed(state: int)
signal level_changed(level: int)

enum { NO_NEUTRAL, CAPTURING, TRACKING, OCCLUDED }
enum { OK, WARN, COMPENSATING }
const AXES := ["flexion", "lateral", "axial"]
## No packet for this long = the tracker has no trunk tracking (disabled, no
## NPU, or not running).
const STALE_S := 1.5

var state: int = NO_NEUTRAL
var level: int = OK
var levels: Array[int] = [OK, OK, OK]
var angles := Vector3.ZERO          # flexion, lateral, axial (degrees)
var progress := 0.0                 # neutral capture, 0..1
var has_neutral := false
var reason := ""                    # why OCCLUDED
var capture_result := ""            # "", "ok", "moving", "not_visible"
var _last_packet_ms := -100000

var _beep: AudioStreamPlayer


func _ready() -> void:
	_beep = AudioStreamPlayer.new()
	_beep.stream = _make_beep()
	_beep.volume_db = -6.0
	add_child(_beep)


## True while the tracker is sending trunk updates.
func available() -> bool:
	return Time.get_ticks_msec() - _last_packet_ms < STALE_S * 1000


func capture_neutral() -> void:
	GlobalScript._send_transport_message("TRUNK:neutral")


## Called (deferred) from GlobalScript's network thread.
func on_packet(text: String) -> void:
	var f := text.substr(4).split(",")
	if f.size() < 12:
		return
	_last_packet_ms = Time.get_ticks_msec()
	var new_state := int(f[0])
	var new_level := int(f[1])
	levels = [int(f[2]), int(f[3]), int(f[4])]
	angles = Vector3(float(f[5]), float(f[6]), float(f[7]))
	progress = float(f[8])
	has_neutral = f[9] == "1"
	reason = f[10]
	capture_result = f[11]
	if new_state != state:
		state = new_state
		state_changed.emit(state)
	if new_level != level:
		level = new_level
		level_changed.emit(level)
	updated.emit()


## The axis furthest past its level, as an index into AXES, or -1.
func worst_axis() -> int:
	var best := -1
	for i in 3:
		if levels[i] > OK and (best < 0 or levels[i] > levels[best]
				or (levels[i] == levels[best] and absf(angles[i]) > absf(angles[best]))):
			best = i
	return best


## What to tell the patient, for the worst axis.
func cue_text() -> String:
	match worst_axis():
		0:
			return "Sit back, don't lean forward" if angles.x > 0 else "Sit up, don't lean back"
		1:
			return "Sit straight, don't lean left" if angles.y > 0 else "Sit straight, don't lean right"
		2:
			return "Face forward, don't twist"
	return ""


func status_text() -> String:
	if not available():
		return "Trunk tracking off"
	match state:
		NO_NEUTRAL:
			return "Trunk: capture neutral first"
		CAPTURING:
			return "Hold still... %d%%" % int(progress * 100)
		OCCLUDED:
			return "Trunk occluded"
	return "Trunk  fwd %+.0f°  side %+.0f°  twist %+.0f°" % [angles.x, angles.y, angles.z]


func play_beep() -> void:
	_beep.play()


## A short two-tone chime, generated so no asset is needed.
static func _make_beep() -> AudioStreamWAV:
	var rate := 22050
	var data := PackedByteArray()
	for tone in [[660.0, 0.12], [440.0, 0.18]]:
		var n := int(rate * tone[1])
		for i in n:
			var env := minf(1.0, minf(i, n - i) / (rate * 0.01))
			var v := int(sin(TAU * tone[0] * i / rate) * env * 0.5 * 32767)
			data.append(v & 0xFF)
			data.append((v >> 8) & 0xFF)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.data = data
	return wav
