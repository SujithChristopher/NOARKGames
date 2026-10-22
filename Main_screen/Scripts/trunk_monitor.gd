extends Node
## Trunk posture from the tracker (pyscripts/trunk/): neutral capture, angles
## from neutral and a per-axis compensation level.
##
## tracker.py sends a TRUNK_STATUS message per trunk update (~10 Hz), whose
## CSV payload GlobalScript hands to on_packet() (docs/PROTOCOL.md):
##   state,level,lvl_flex,lvl_lat,lvl_axi,flex,lat,axi,progress,has_neutral,
##       reason,capture_result,people,locked,q_how,q_rms_mm,q_frac,raw_pts,mask_px,held,
##       hz,method,doubt,reference
## (q_how..held describe this frame's own quality, for the raw log)
## The thresholds, hysteresis and dwell are applied in Python
## (settings.json trunk_warn_deg / trunk_comp_deg); this only reports them.
##
## Angle signs: flexion + = leaning forward, lateral + = leaning to the
## patient's left, axial + = turning to the patient's right.

signal updated
## trunk_enabled was switched (settings panel or the in-game Tune panel).
signal enabled_changed(on: bool)
signal state_changed(state: int)
signal level_changed(level: int)
## The subject picker's image: people[i] is the outline (PackedVector2Array, in
## image pixels) of person i, locked the one being followed (-1 = none).
signal snapshot_ready(texture: ImageTexture, people: Array, locked: int)

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
var capture_result := ""            # "", "ok", "moving", "not_visible", "away"
var people := 0                     # torsos the tracker sees
var locked := false                 # following a picked person
var q_how := ""                     # this frame: direct/odometry/failed/gated/no_torso/...
var q_rms_mm := NAN                 # this frame's ICP residual
var q_frac := NAN                   # share of the cloud that matched
var raw_pts := 0                    # shell points before the cloud cap
var mask_px := 0                    # torso mask area
var held := false                   # angles are the last good ones, not this frame's
var hz := 0.0                       # trunk updates per second, measured by the tracker
var method := ""                    # what measures it: icp / msam_r18 / msam_v3rot
var doubt := ""                     # used but less trusted: "low_conf" / "arm_over_chest"
## What the tracker measures the angles from right now: "neutral" (the captured
## neutral) or "model" (minisam3d's own frame, no capture). See set_reference().
var reference := "neutral"

## How each trunk_method is shown (Settings, the Trunk angles screen).
const METHOD_NAMES := {
	"icp": "ICP (stereo point cloud)",
	"msam_r18": "minisam3d r18 (v3mix)",
	"msam_v3rot": "minisam3d v3rot (older)",
}
## How each trunk_reference is shown.
const REFERENCE_NAMES := {
	"neutral": "From captured neutral",
	"model": "Model frame (no capture, minisam3d only)",
}
var _last_packet_ms := -100000

var _beep: AudioStreamPlayer


func _ready() -> void:
	_beep = AudioStreamPlayer.new()
	_beep.stream = _make_beep()
	_beep.volume_db = -6.0
	add_child(_beep)


## The settings.json switch. Everything trunk-related (panels, cues, pausing,
## raw-CSV columns) asks available(), so this one flag turns all of it off.
func enabled() -> bool:
	return bool(Settings.get_value("trunk_enabled", true))


## True while trunk tracking is on and the tracker is sending updates.
func available() -> bool:
	return enabled() and Time.get_ticks_msec() - _last_packet_ms < STALE_S * 1000


## Switch trunk tracking on or off: saved to settings.json and sent to the
## running tracker, so it takes effect now rather than next launch.
func set_enabled(on: bool) -> void:
	if on == enabled():
		return
	Settings.set_value("trunk_enabled", on)
	Settings.save()
	GlobalScript.send_tracker_config("trunk", "on" if on else "off")
	if not on:
		_last_packet_ms = -100000
		state = NO_NEUTRAL
		level = OK
		has_neutral = false
	enabled_changed.emit(on)


## settings.json trunk_reference: "neutral" or "model". Saved and sent to the
## tracker now; either way the old neutral is dropped. "model" applies to the
## minisam3d methods only (with icp the tracker stays on a captured neutral).
func set_reference(value: String) -> void:
	Settings.set_value("trunk_reference", value)
	Settings.save()
	GlobalScript.send_tracker_config("trunk_reference", value)


## The angles come from minisam3d's own frame: no neutral needed. capture_neutral()
## then sets the zero ("Set zero") and has_neutral says whether one is set.
func model_frame() -> bool:
	return available() and reference == "model"


## Model frame: drop a "Set zero", back to the model's own rest pose.
func clear_zero() -> void:
	GlobalScript.send_trunk_command("zero_clear")


## (warn, compensating) per axis as Vector3s, from settings.json: the model
## frame has its own (trunk_model_*_deg), wider ones.
func thresholds() -> Array:
	var model := model_frame()
	return [_threshold("trunk_model_warn_deg" if model else "trunk_warn_deg", 15.0 if model else 8.0),
		_threshold("trunk_model_comp_deg" if model else "trunk_comp_deg", 25.0 if model else 15.0)]


static func _threshold(key: String, fallback: float) -> Vector3:
	var v = Settings.get_value(key, fallback)
	if v is Dictionary:
		return Vector3(float(v.get("flexion", fallback)), float(v.get("lateral", fallback)),
			float(v.get("axial", fallback)))
	return Vector3.ONE * float(v)


func capture_neutral() -> void:
	GlobalScript.send_trunk_command("neutral")


## Ask the tracker for the picker image; it arrives as snapshot_ready.
func request_snapshot() -> void:
	GlobalScript.send_trunk_command("snapshot")


## Follow person `index` of the last snapshot (-1 = the centre-most again). A new
## person has no neutral: has_neutral goes false and it must be captured again.
func select_person(index: int) -> void:
	GlobalScript.send_trunk_command("select=%d" % index)


## A SNAPSHOT payload, reassembled by the link (trunk/snapshot_packet.py).
func on_snapshot(blob: PackedByteArray) -> void:
	var meta_len := blob.decode_u16(0)
	var meta = JSON.parse_string(blob.slice(2, 2 + meta_len).get_string_from_utf8())
	var image := Image.new()
	if typeof(meta) != TYPE_DICTIONARY or image.load_jpg_from_buffer(blob.slice(2 + meta_len)) != OK:
		push_warning("[Trunk] bad snapshot")
		return
	var outlines := []
	for poly in meta.get("people", []):
		var pts := PackedVector2Array()
		for pt in poly:
			pts.append(Vector2(pt[0], pt[1]))
		outlines.append(pts)
	snapshot_ready.emit(ImageTexture.create_from_image(image), outlines, int(meta.get("locked", -1)))


## A TRUNK_STATUS payload, from GlobalScript.
func on_packet(text: String) -> void:
	var f := text.split(",")
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
	if f.size() >= 14:
		people = int(f[12])
		locked = f[13] == "1"
	if f.size() >= 20:
		q_how = f[14]
		q_rms_mm = float(f[15])
		q_frac = float(f[16])
		raw_pts = int(f[17])
		mask_px = int(f[18])
		held = f[19] == "1"
	if f.size() >= 22:
		hz = float(f[20])
		method = f[21]
	doubt = f[22] if f.size() >= 23 else ""
	reference = f[23] if f.size() >= 24 else "neutral"
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
	if not enabled():
		return ""
	if not available():
		return "Trunk tracking off"
	match state:
		NO_NEUTRAL:
			return "Trunk: capture neutral first"
		CAPTURING:
			return "Hold still... %d%%" % int(progress * 100)
		OCCLUDED:
			return "Tracked person lost: select again" if reason == "lost_subject" else "Trunk occluded"
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
