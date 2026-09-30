extends Node

# Sounds of the clinic game (feedback design 2026-09-26: graded catches as in
# osu!, a soft miss, a pluck when a hold starts, stars; 2026-09-29: the night,
# the bat and the firefly — see below).
# Synthesized at start-up like app/platform/audio_manager.gd (no audio files,
# no editor import), with players of their own so the patient app's
# AudioManager is left alone.
#
# Since 2026-09-29:
#   - night:   a looping stereo bed of crickets (four, each with its own pitch,
#              rhythm and place left-right) over a soft wind;
#   - bat:     generated live (AudioStreamGenerator), so it follows the bat
#              exactly: echolocation clicks at the bat's click rate (up to the
#              ~180/s "feeding buzz"), leathery wingbeats about 11 times a
#              second, panned to where the bat is on screen (bat.gd);
#   - firefly: a glimmer where it lights up (panned); caught = a glass clink in
#              the jar plus a note that climbs a pentatonic scale with each catch
#              in a row; missed = the bat's whoosh and snap, and the old soft
#              falling note;
#   - the bat giving up (a hold started): a soft whoosh, a squeak now and then.
# Nothing plays while the hand holds a firefly (the pluck and a rising tone
# did until 2026-09-29: about 50 times a round, they grated).

const RATE := 22050
const NIGHT_S := 4.0                 # night loop length; every cricket rhythm divides it
const PENTA: Array = [1.0, 1.125, 1.25, 1.5, 1.667, 2.0, 2.25, 2.5, 3.0, 3.333]   # major pentatonic

# Built once per app run (synthesis takes a moment), shared by every visit.
static var _bell: AudioStreamWAV = null    # one bell; pitch sets the grade
static var _chord: AudioStreamWAV = null   # "Perfect": bell plus a fifth and an octave
static var _miss: AudioStreamWAV = null
static var _night: AudioStreamWAV = null
static var _glimmer: AudioStreamWAV = null
static var _clink: AudioStreamWAV = null
static var _whoosh: AudioStreamWAV = null
static var _snatch: AudioStreamWAV = null
static var _squeak: AudioStreamWAV = null

var _players: Array = []
var _next: int = 0
var _panned: Array = []              # AudioStreamPlayer2D, for sounds placed on screen
var _pnext: int = 0
var _night_player: AudioStreamPlayer
var _streak: int = 0

# The bat's live voice.
var _bat_player: AudioStreamPlayer
var _bat_pb: AudioStreamGeneratorPlayback = null
var _bat_on := false
var _want := {"rate": 3.0, "click": 0.0, "wing": 0.0, "pan": 0.0}
var _rate := 3.0
var _click_g := 0.0
var _wing_g := 0.0
var _pan := 0.0
var _click_timer := 0.0
var _click_t := 1.0
var _click_ph := 0.0
var _wing_ph := 0.0
var _lp := 0.0
var _st := 0.0


func _ready() -> void:
	for i in 6:
		var p := AudioStreamPlayer.new()
		p.volume_db = -2.0
		add_child(p)
		_players.append(p)
	for i in 4:
		var p := AudioStreamPlayer2D.new()
		p.attenuation = 0.0          # no fall-off with distance: position only pans
		p.max_distance = 100000.0
		add_child(p)
		_panned.append(p)
	if _bell == null:
		_bell = _make_bell([1.0], 0.9)
		_chord = _make_bell([1.0, 1.5, 2.0], 1.1)
		_miss = _make_miss()
		_night = _make_night()
		_glimmer = _make_glimmer()
		_clink = _make_clink()
		_whoosh = _make_whoosh(0.4, false)
		_snatch = _make_whoosh(0.5, true)
		_squeak = _make_squeak()
	_night_player = AudioStreamPlayer.new()
	_night_player.stream = _night
	_night_player.volume_db = -13.0
	add_child(_night_player)
	_night_player.play()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = RATE
	gen.buffer_length = 0.12
	_bat_player = AudioStreamPlayer.new()
	_bat_player.stream = gen
	_bat_player.volume_db = -6.0
	add_child(_bat_player)
	_bat_player.play()
	_bat_pb = _bat_player.get_stream_playback() as AudioStreamGeneratorPlayback


func _play(stream: AudioStream, pitch: float = 1.0, db: float = 0.0) -> void:
	var p: AudioStreamPlayer = _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = stream
	p.pitch_scale = pitch
	p.volume_db = -2.0 + db
	p.play()


# A sound placed at a screen position: it pans left-right with it.
func _play_at(stream: AudioStream, pos: Vector2, db: float = 0.0, pitch: float = 1.0) -> void:
	var p: AudioStreamPlayer2D = _panned[_pnext]
	_pnext = (_pnext + 1) % _panned.size()
	p.stream = stream
	p.global_position = pos
	p.pitch_scale = pitch
	p.volume_db = -2.0 + db
	p.play()


# grade 3 / 2 / 1 in the warm-up (points); 0 = a timed catch: a clink in the
# jar and the next note of the streak.
func caught(grade: int) -> void:
	_play(_clink, randf_range(0.97, 1.03), -4.0)
	match grade:
		3:
			_play(_chord, 1.0, 1.0)
		2:
			_play(_bell, 0.84)
		1:
			_play(_bell, 0.67, -3.0)
		_:
			_play(_bell, 0.75 * float(PENTA[mini(_streak, PENTA.size() - 1)]), -2.0)
			_streak += 1


# pos: where the firefly was (the bat's snatch is heard there).
func missed(pos: Vector2 = Vector2(-1.0, -1.0)) -> void:
	_streak = 0
	if pos.x >= 0.0:
		_play_at(_snatch, pos, -3.0)
	_play(_miss, 1.0, -9.0)


func firefly_appears(pos: Vector2) -> void:
	_play_at(_glimmer, pos, -8.0, randf_range(0.94, 1.06))


# Soft, since it comes with most holds: a whoosh, and a squeak one time in three.
func bat_gives_up(pos: Vector2) -> void:
	_play_at(_whoosh, pos, -13.0)
	if randf() < 0.33:
		_play_at(_squeak, pos, -17.0, randf_range(0.9, 1.1))


func round_started() -> void:
	_streak = 0


func star(i: int) -> void:
	_play(_bell, 1.0 + 0.125 * float(i), -4.0)


# The bat's voice, set every frame from bat.gd; on = false silences it.
func bat(on: bool, rate: float, click: float, wing: float, pan: float) -> void:
	_bat_on = on
	_want = {"rate": rate, "click": click, "wing": wing, "pan": pan}


func _process(_delta: float) -> void:
	if _bat_pb == null:
		return
	var n := _bat_pb.get_frames_available()
	if n <= 0:
		return
	# Glide towards the wanted values so nothing jumps.
	var on := 1.0 if _bat_on else 0.0
	_rate = lerpf(_rate, float(_want["rate"]), 0.3)
	_click_g = lerpf(_click_g, float(_want["click"]) * on, 0.25)
	_wing_g = lerpf(_wing_g, float(_want["wing"]) * on, 0.25)
	_pan = lerpf(_pan, float(_want["pan"]), 0.25)
	var frames := PackedVector2Array()
	frames.resize(n)
	if _click_g < 0.001 and _wing_g < 0.001:
		_bat_pb.push_buffer(frames)   # silence
		return
	var inv := 1.0 / RATE
	var th := (_pan + 1.0) * PI * 0.25   # equal-power pan
	var gl := cos(th) * 0.6
	var gr := sin(th) * 0.6
	var period := 1.0 / maxf(_rate, 1.0)
	for i in n:
		var v := 0.0
		# Echolocation click: a 6 ms tick falling from 3.4 to 1.8 kHz.
		_click_timer -= inv
		if _click_timer <= 0.0:
			_click_timer += period
			_click_t = 0.0
		if _click_t < 0.006:
			_click_ph += (3400.0 - 1600.0 * _click_t / 0.006) * inv
			v += sin(TAU * _click_ph) * exp(-_click_t / 0.0012) * _click_g
			_click_t += inv
		# Wingbeat: a burst of soft rustle and a faint thump on each downstroke.
		_wing_ph += 11.0 * inv
		var w := sin(TAU * _wing_ph)
		if w > 0.0:
			var e := w * w * w * w * w * w
			_lp += 0.09 * (randf() * 2.0 - 1.0 - _lp)
			v += (_lp * 3.0 + 0.3 * sin(TAU * 95.0 * _st)) * e * _wing_g
		_st += inv
		frames[i] = Vector2(v * gl, v * gr)
	_bat_pb.push_buffer(frames)


# ── Synthesis ─────────────────────────────────────────────────────────────────

func _wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = bytes
	return wav


func _wav_stereo(l: PackedFloat32Array, r: PackedFloat32Array) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(l.size() * 4)
	for i in l.size():
		bytes.encode_s16(i * 4, int(clampf(l[i], -1.0, 1.0) * 32767.0))
		bytes.encode_s16(i * 4 + 2, int(clampf(r[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = true
	wav.data = bytes
	return wav


# Glassy bell at 1046.5 Hz (C6) times each ratio: inharmonic partials with
# staggered decays give the shimmer; a fast attack keeps it crisp.
func _make_bell(ratios: Array, dur: float) -> AudioStreamWAV:
	var n := int(RATE * dur)
	var s := PackedFloat32Array()
	s.resize(n)
	var gain := 0.5 / float(ratios.size())
	for i in n:
		var t := float(i) / RATE
		var v := 0.0
		for k in ratios.size():
			var f: float = 1046.5 * float(ratios[k])
			var tk := t - 0.035 * float(k)       # the chord's notes roll in
			if tk < 0.0:
				continue
			v += (sin(TAU * f * tk) * exp(-tk * 4.5)
				+ 0.4 * sin(TAU * f * 2.76 * tk) * exp(-tk * 9.0)
				+ 0.15 * sin(TAU * f * 5.4 * tk) * exp(-tk * 15.0)) * minf(tk * 500.0, 1.0)
		s[i] = v * gain
	return _wav(s)


# Soft, low, falling note — noticeable, never punishing.
func _make_miss() -> AudioStreamWAV:
	var dur := 0.55
	var n := int(RATE * dur)
	var s := PackedFloat32Array()
	s.resize(n)
	var phase := 0.0
	for i in n:
		var t := float(i) / RATE
		var f := 330.0 * pow(247.0 / 330.0, minf(t / 0.35, 1.0))
		phase += f / RATE
		var env := minf(t * 60.0, 1.0) * exp(-t * 5.5)
		s[i] = (sin(TAU * phase) + 0.2 * sin(TAU * phase * 2.0)) * 0.45 * env
	return _wav(s)


# The night: four crickets and a soft wind, NIGHT_S long, looping. A cricket's
# chirp is a few 22 ms pulses of one high tone, 45 ms apart; each cricket has
# its own pitch, pulses per chirp, chirp period (dividing NIGHT_S, so the loop
# joins) and place left-right. The wind is low-passed noise; its end is
# cross-faded into its start so the join does not click.
func _make_night() -> AudioStreamWAV:
	var n := int(RATE * NIGHT_S)
	var x := int(RATE * 0.4)
	var l := PackedFloat32Array()
	var r := PackedFloat32Array()
	l.resize(n + x)
	r.resize(n + x)
	# [pitch Hz, pulses, period s, offset s, gain, pan -1..1]
	var crickets: Array = [[4700.0, 3, 0.8, 0.10, 0.10, -0.7], [4300.0, 4, 1.0, 0.37, 0.08, 0.6],
		[5100.0, 2, 0.5, 0.21, 0.05, 0.1], [3900.0, 5, 2.0, 0.90, 0.045, -0.2]]
	var wind := 0.0
	for i in n + x:
		var t := float(i) / RATE
		wind += 0.004 * (randf() * 2.0 - 1.0 - wind)
		var wv := wind * 0.9 * (1.0 + 0.5 * sin(TAU * t / NIGHT_S))
		var lv := wv
		var rv := wv
		for c in crickets:
			var tc := fmod(t + float(c[3]), float(c[2]))
			var k := int(tc / 0.045)
			if k < int(c[1]):
				var tp := tc - 0.045 * float(k)
				if tp < 0.022:
					var v := sin(TAU * float(c[0]) * t) * sin(PI * tp / 0.022) * float(c[4])
					var th := (float(c[5]) + 1.0) * PI * 0.25
					lv += v * cos(th)
					rv += v * sin(th)
		l[i] = lv
		r[i] = rv
	for i in x:   # cross-fade the tail into the head
		var a := float(i) / float(x)
		l[i] = l[i] * a + l[n + i] * (1.0 - a)
		r[i] = r[i] * a + r[n + i] * (1.0 - a)
	l.resize(n)
	r.resize(n)
	var wav := _wav_stereo(l, r)
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = n
	return wav


# A firefly lighting up: three high glints rolling in.
func _make_glimmer() -> AudioStreamWAV:
	var dur := 0.5
	var n := int(RATE * dur)
	var s := PackedFloat32Array()
	s.resize(n)
	var notes: Array = [2637.0, 3136.0, 3951.0]
	for i in n:
		var t := float(i) / RATE
		var v := 0.0
		for k in notes.size():
			var tk := t - 0.05 * float(k)
			if tk >= 0.0:
				v += sin(TAU * float(notes[k]) * tk) * exp(-tk * 12.0) * minf(tk * 400.0, 1.0)
		s[i] = v * 0.22
	return _wav(s)


# A firefly landing in the glass jar: an inharmonic clink and a faint second tap.
func _make_clink() -> AudioStreamWAV:
	var dur := 0.45
	var n := int(RATE * dur)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t := float(i) / RATE
		var v := 0.0
		for tap: float in [0.0, 0.07]:
			var tk := t - tap
			if tk < 0.0:
				continue
			var g := 1.0 if tap == 0.0 else 0.35
			v += g * (sin(TAU * 2350.0 * tk) * exp(-tk * 18.0) + 0.6 * sin(TAU * 3140.0 * tk) * exp(-tk * 25.0)
				+ 0.3 * sin(TAU * 4870.0 * tk) * exp(-tk * 40.0)) * minf(tk * 900.0, 1.0)
		s[i] = v * 0.28
	return _wav(s)


# Air rushing past a wing: noise through a resonant band that sweeps up and
# down. With snap = true a short crack at 0.16 s (the bat taking the firefly).
func _make_whoosh(dur: float, snap: bool) -> AudioStreamWAV:
	var n := int(RATE * dur)
	var s := PackedFloat32Array()
	s.resize(n)
	var low := 0.0
	var band := 0.0
	for i in n:
		var t := float(i) / RATE
		var u := t / dur
		var fc := 450.0 + 1300.0 * sin(PI * u)                 # centre of the band, Hz
		var f := 2.0 * sin(PI * fc / RATE)
		var high := (randf() * 2.0 - 1.0) - low - 0.5 * band   # state-variable filter, q = 2
		band += f * high
		low += f * band
		var v := band * 0.9 * sin(PI * u)
		if snap and t > 0.16 and t < 0.2:
			var ts := t - 0.16
			v += (randf() * 2.0 - 1.0) * exp(-ts * 90.0) * 0.7
		s[i] = v
	return _wav(s)


# A bat's squeak: a short call falling from 3 to 1.7 kHz with a fast warble.
func _make_squeak() -> AudioStreamWAV:
	var dur := 0.12
	var n := int(RATE * dur)
	var s := PackedFloat32Array()
	s.resize(n)
	var ph := 0.0
	for i in n:
		var t := float(i) / RATE
		var f := 3000.0 - 1300.0 * (t / dur) + 150.0 * sin(TAU * 45.0 * t)
		ph += f / RATE
		s[i] = sin(TAU * ph) * minf(t * 300.0, 1.0) * exp(-t * 14.0) * 0.35
	return _wav(s)
