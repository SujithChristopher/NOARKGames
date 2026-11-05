extends RefCounted
## The black sheep's "he-he-he", synthesized like Cannon Defense's sounds (no audio
## file, no editor import). Each "he" is a puff of breath, then a voice shaped into an
## "e" by three formants, with a fast quaver that makes it a bleat and not a person.

const RATE := 22050
# Each "he": start (s), length (s), pitch (Hz). Falling, and the last one drawn out.
const SYLLABLES := [[0.0, 0.13, 470.0], [0.2, 0.13, 440.0], [0.4, 0.24, 400.0]]
const LENGTH_S := 0.66
const BREATH_S := 0.035
const QUAVER_HZ := 24.0
# The vowel "e": centre (Hz), bandwidth (Hz), gain.
const FORMANTS := [[550.0, 90.0, 1.0], [1900.0, 150.0, 0.6], [2700.0, 200.0, 0.3]]
const PEAK := 0.8

static var _stream: AudioStreamWAV = null   # built once per app run, shared by every visit


static func stream() -> AudioStreamWAV:
	if _stream == null:
		_stream = _wav(_shape(_source()))
	return _stream


## Voice and breath, before the formants.
static func _source() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(int(LENGTH_S * RATE))
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for syllable in SYLLABLES:
		var phase := 0.0
		var first := int(syllable[0] * RATE)
		var count := int(syllable[1] * RATE)
		for i in count:
			var t := float(i) / RATE
			var quaver := sin(TAU * QUAVER_HZ * t)
			var pitch: float = syllable[2] * (1.0 - 0.1 * t / syllable[1]) * (1.0 + 0.03 * quaver)
			phase = fmod(phase + pitch / RATE, 1.0)
			var voice := (2.0 * phase - 1.0) * (0.75 + 0.25 * quaver) \
				* clampf((t - BREATH_S * 0.5) / 0.015, 0.0, 1.0) \
				* clampf((syllable[1] - t) / 0.03, 0.0, 1.0)
			var breath := rng.randf_range(-1.0, 1.0) * 0.5 * clampf(1.0 - t / BREATH_S, 0.0, 1.0)
			out[first + i] = voice + breath
	return out


## Parallel two-pole resonators, one per formant, scaled to PEAK.
static func _shape(source: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(source.size())
	for formant in FORMANTS:
		var r: float = exp(-PI * formant[1] / RATE)
		var b1: float = 2.0 * r * cos(TAU * formant[0] / RATE)
		var b2 := -r * r
		var gain: float = (1.0 - r) * formant[2]
		var y1 := 0.0
		var y2 := 0.0
		for i in source.size():
			var y: float = gain * source[i] + b1 * y1 + b2 * y2
			y2 = y1
			y1 = y
			out[i] += y
	var top := 0.0
	for sample in out:
		top = maxf(top, absf(sample))
	for i in out.size():
		out[i] *= PEAK / top
	return out


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
