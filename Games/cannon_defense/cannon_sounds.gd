extends Node

# Cannon Defense's sounds, synthesized at start-up like firefly_reach/sounds.gd
# (no audio files, no editor import), on players of their own so overlapping
# shots and blasts do not cut each other off as MusicManager's one player would.
#   fire  — a low thump from the barrel
#   boom  — a meteor blown up: noise rumble over a falling low tone
#   miss  — a meteor reaching the dome: a soft falling note
#   step  — a calibration pose captured: a bell

const RATE := 22050

static var _sounds: Dictionary = {}   # built once per app run, shared by every visit

var _players: Array = []
var _next := 0


func _ready() -> void:
	for i in 6:
		var p := AudioStreamPlayer.new()
		p.volume_db = -4.0
		add_child(p)
		_players.append(p)
	if _sounds.is_empty():
		_sounds = {"fire": _make_fire(), "boom": _make_boom(), "miss": _make_miss(), "step": _make_bell()}


func play(sound: String, pitch: float = 1.0) -> void:
	var p: AudioStreamPlayer = _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = _sounds[sound]
	p.pitch_scale = pitch
	p.play()


static func _make_fire() -> AudioStreamWAV:
	var n := int(0.22 * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var ph := 0.0
	for i in n:
		var t := float(i) / RATE
		ph += TAU * lerpf(140.0, 45.0, t / 0.22) / RATE
		var click := rng.randf_range(-1.0, 1.0) * exp(-t * 60.0) * 0.5
		out[i] = (sin(ph) * exp(-t * 14.0) + click) * 0.8
	return _wav(out)


static func _make_boom() -> AudioStreamWAV:
	var n := int(0.7 * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var lp := 0.0
	var ph := 0.0
	for i in n:
		var t := float(i) / RATE
		# One-pole low-pass that closes as the blast dies: crack first, rumble after.
		lp += (rng.randf_range(-1.0, 1.0) - lp) * lerpf(0.5, 0.04, minf(t / 0.3, 1.0))
		ph += TAU * lerpf(90.0, 35.0, t / 0.7) / RATE
		out[i] = (lp * 1.6 * exp(-t * 5.0) + sin(ph) * 0.6 * exp(-t * 7.0)) * 0.8
	return _wav(out)


static func _make_miss() -> AudioStreamWAV:
	var n := int(0.45 * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var ph := 0.0
	for i in n:
		var t := float(i) / RATE
		ph += TAU * lerpf(330.0, 140.0, t / 0.45) / RATE
		out[i] = sin(ph) * minf(t * 40.0, 1.0) * exp(-t * 5.0) * 0.5
	return _wav(out)


static func _make_bell() -> AudioStreamWAV:
	var n := int(0.6 * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / RATE
		var s := sin(TAU * 880.0 * t) + 0.4 * sin(TAU * 1320.0 * t) + 0.25 * sin(TAU * 1760.0 * t)
		out[i] = s * minf(t * 200.0, 1.0) * exp(-t * 6.0) * 0.35
	return _wav(out)


static func _wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.data = data
	return w
