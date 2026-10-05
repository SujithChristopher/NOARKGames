extends Node
## Trunk posture from the tracker (pyscripts/trunk/): neutral capture, angles
## from neutral and a per-axis compensation level.
##
## tracker.py sends a text datagram per trunk update (~10 Hz), which
## GlobalScript hands to on_packet():
##   TRK:state,level,lvl_flex,lvl_lat,lvl_axi,flex,lat,axi,progress,has_neutral,
##       reason,capture_result,people,locked,q_how,q_rms_mm,q_frac,raw_pts,mask_px,held
## (the last six describe this frame's own quality, for the raw log)
## The thresholds, hysteresis and dwell are applied in Python
## (settings.json trunk_warn_deg / trunk_comp_deg); this only reports them.
##
## Angle signs: flexion + = leaning forward, lateral + = leaning to the
## patient's left, axial + = turning to the patient's right.

signal updated
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
var capture_result := ""            # "", "ok", "moving", "not_visible"
var people := 0                     # torsos the tracker sees
var locked := false                 # following a picked person
var q_how := ""                     # this frame: direct/odometry/failed/gated/no_torso/...
var q_rms_mm := NAN                 # this frame's ICP residual
var q_frac := NAN                   # share of the cloud that matched
var raw_pts := 0                    # shell points before the cloud cap
var mask_px := 0                    # torso mask area
var held := false                   # angles are the last good ones, not this frame's
var _last_packet_ms := -100000

var _beep: AudioStreamPlayer
# Snapshot chunks being collected: "IMG:" id index total data (trunk/snapshot_packet.py)
var _snap_id := -1
var _snap_total := 0
var _snap_chunks := {}


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


## Ask the tracker for the picker image; it arrives as snapshot_ready.
func request_snapshot() -> void:
	GlobalScript._send_transport_message("TRUNK:snapshot")


## Follow person `index` of the last snapshot (-1 = the centre-most again). A new
## person has no neutral: has_neutral goes false and it must be captured again.
func select_person(index: int) -> void:
	GlobalScript._send_transport_message("TRUNK:select=%d" % index)


## One chunk of a snapshot. Called (deferred) from GlobalScript.
func on_image_chunk(packet: PackedByteArray) -> void:
	if packet.size() < 8:
		return
	var id := packet[4]
	var index := packet[5]
	var total := packet[6]
	if id != _snap_id:
		_snap_id = id
		_snap_total = total
		_snap_chunks.clear()
	_snap_chunks[index] = packet.slice(7)
	if _snap_chunks.size() < _snap_total:
		return
	var blob := PackedByteArray()
	for i in _snap_total:
		if not _snap_chunks.has(i):
			return
		blob.append_array(_snap_chunks[i])
	_snap_id = -1
	_snap_chunks.clear()
	_decode_snapshot(blob)


func _decode_snapshot(blob: PackedByteArray) -> void:
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
