extends Node2D

# The moving part of the night backdrop: twinkling stars and a few fireflies
# drifting low near the sides (never where targets appear, never target-sized).
# Drawn behind its parent, above forest_scene.gd. `flare` (0..1, decays by itself)
# brightens everything for a moment; nothing raises it since the catch streak
# was removed as distracting (2026-09-26).

const Art := preload("res://Games/firefly_reach/game_art.gd")

var flare: float = 0.0
var _vp: Vector2
var _stars: Array = []           # [pos, size, speed, phase]
var _flies: Array = []           # [anchor, radius, speed, phase]
var _t: float = 0.0


func _ready() -> void:
	show_behind_parent = true
	_vp = get_viewport_rect().size
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 70:
		_stars.append([Vector2(rng.randf() * _vp.x, rng.randf() * _vp.y * 0.6),
			rng.randf_range(2.0, 5.0), rng.randf_range(0.6, 1.6), rng.randf() * TAU])
	for i in 12:
		var x: float = rng.randf_range(0.03, 0.28) if i % 2 == 0 else rng.randf_range(0.72, 0.97)
		_flies.append([Vector2(x * _vp.x, rng.randf_range(0.72, 0.92) * _vp.y),
			rng.randf_range(10.0, 26.0), rng.randf_range(0.3, 0.7), rng.randf() * TAU])


func _process(delta: float) -> void:
	_t += delta
	flare = maxf(0.0, flare - delta * 0.8)
	queue_redraw()


func _draw() -> void:
	var tex := Art.glow()
	for s in _stars:
		var a: float = 0.35 + 0.35 * sin(_t * float(s[2]) + float(s[3])) + 0.3 * flare
		Art.blit(self, tex, s[0], Vector2.ONE * float(s[1]) * (2.2 + flare), Color(1, 1, 1, clampf(a, 0.05, 1.0)))
	for f in _flies:
		var sp: float = f[2]
		var ph: float = f[3]
		var p: Vector2 = f[0] + Vector2(sin(_t * sp + ph), cos(_t * sp * 0.7 + ph)) * float(f[1])
		var blink: float = 0.25 + 0.25 * sin(_t * sp * 3.0 + ph * 2.0) + 0.5 * flare
		Art.blit(self, tex, p, Vector2.ONE * (18.0 + 14.0 * flare), Color(Art.LAMP_GLOW, clampf(blink, 0.05, 0.9)))
