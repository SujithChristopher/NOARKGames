extends Node2D
## The jet-pack sheep's extras, in screen space under it: a soft shadow on the
## grass, smoke from the jet while playing, a lean into the direction of travel
## and a slow hover bob. Only the sprite turns and bobs; the body, its collision
## and its position (what gets logged) are untouched.

const GameFx := preload("res://Main_screen/Scripts/game_fx.gd")
const NOZZLE := Vector2(-34, 22)   # flame tip in jet.png, from the body's centre on screen

var player: CharacterBody2D
var _sprite: AnimatedSprite2D
var _smoke: CPUParticles2D
var _base_y := 0.0
var _last := Vector2.ZERO
var _vel := Vector2.ZERO
var _t := 0.0


func _ready() -> void:
	top_level = true
	z_as_relative = false
	z_index = 1
	_sprite = player.get_node("Sprite2D")
	_base_y = _sprite.position.y
	_last = player.global_position

	_smoke = CPUParticles2D.new()
	_smoke.texture = GameFx.soft_dot()
	_smoke.amount = 18
	_smoke.lifetime = 0.55
	_smoke.local_coords = false
	_smoke.direction = Vector2(-0.4, 1)
	_smoke.spread = 18.0
	_smoke.initial_velocity_min = 50.0
	_smoke.initial_velocity_max = 90.0
	_smoke.damping_min = 60.0
	_smoke.damping_max = 90.0
	_smoke.gravity = Vector2(0, -25)
	_smoke.scale_amount_min = 0.3
	_smoke.scale_amount_max = 0.45
	var grow := Curve.new()
	grow.add_point(Vector2(0, 0.35))
	grow.add_point(Vector2(1, 1.0))
	_smoke.scale_amount_curve = grow
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.25, 1.0])
	fade.colors = PackedColorArray([Color(1, 0.9, 0.5, 0.9), Color(1, 0.6, 0.25, 0.6), Color(0.85, 0.85, 0.85, 0)])
	_smoke.color_ramp = fade
	_smoke.emitting = false
	add_child(_smoke)


func _process(delta: float) -> void:
	_t += delta
	var pos := player.global_position
	if delta > 0.0:
		_vel = _vel.lerp((pos - _last) / delta, 1.0 - exp(-8.0 * delta))
	_last = pos

	var lean := clampf(_vel.x * 0.0005, -0.22, 0.22)
	_sprite.rotation = lerp_angle(_sprite.rotation, lean, 1.0 - exp(-10.0 * delta))
	_sprite.position.y = _base_y + sin(_t * 4.0) * 1.2

	var facing := -1.0 if _sprite.flip_h else 1.0
	_smoke.global_position = pos + Vector2(NOZZLE.x * facing, NOZZLE.y)
	_smoke.direction = Vector2(-0.4 * facing, 1)
	_smoke.emitting = player.game_started and _sprite.animation == &"jet"
	queue_redraw()


func _draw() -> void:
	# The shadow sits lower than the sheep: it is flying.
	var at := player.global_position + Vector2(0, 54)
	var bob := sin(_t * 4.0) * 0.06
	draw_set_transform(at, 0.0, Vector2(1.0, 0.32))
	draw_circle(Vector2.ZERO, 26.0 * (1.0 - bob), Color(0.05, 0.12, 0.04, 0.2))
	draw_set_transform(Vector2.ZERO)
