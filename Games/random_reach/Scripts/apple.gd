extends Area2D
signal apple_eaten
signal apple_missed   # its timer ran out before it was eaten

const GameFx := preload("res://Main_screen/Scripts/game_fx.gd")

@onready var anim = $Sprite2D
@onready var score_label = Label.new()

var collection_timer = 0.0
var is_eaten = false
var player_node = null
var apple_lifetime = 0.0

const COLLECTION_TIME = 1.0
const TIMER_DURATION = 5.0
var black_sheep: AnimatedSprite2D
var flock: Node2D

# Breathing variables
var breath_time = 0.0
const BREATH_SPEED = 5.0
const BREATH_AMOUNT = 5.0

# Rings drawn round the apple: the time left (green, amber, red, emptying
# clockwise) and, while the player holds on it, the eating progress in gold.
# A faint ring grows out of the apple now and then to catch the eye.
const RING_RADIUS = 40.0
const GREEN = Color(0.32, 0.84, 0.42)
const AMBER = Color(1.0, 0.74, 0.2)
const RED = Color(0.95, 0.3, 0.25)
const BEACON_PERIOD = 1.6
var _beacon := 0.0
var _anim_scale: Vector2
var _shadow := 1.0   # shrinks with the apple once it is eaten


func _ready():
	# Message above the apple: +1, missed, the black sheep's snack
	score_label.text = "+1"
	score_label.label_settings = GameFx.text_style(32, GameFx.GOLD)
	score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	score_label.size = Vector2(320, 48)
	score_label.position = Vector2(-160, -92)
	score_label.visible = false
	add_child(score_label)

	# Pop in
	_anim_scale = anim.scale
	anim.scale = Vector2.ZERO
	create_tween().tween_property(anim, "scale", _anim_scale, 0.35) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _process(delta):
	if is_eaten:
		return

	# Breathing animation
	breath_time += delta * BREATH_SPEED
	anim.position.y = sin(breath_time) * BREATH_AMOUNT
	_beacon = fmod(_beacon + delta / BEACON_PERIOD, 1.0)

	# Update apple lifetime
	apple_lifetime += delta
	var time_left = get_time_left()
	if time_left <= 0.0:
		_on_timer_timeout()
		return

	# Check if player is overlapping
	var is_overlapping = player_node and is_instance_valid(player_node) and overlaps_body(player_node)

	if is_overlapping:
		collection_timer += delta
		# Swell and wobble a little while being eaten
		var progress = clamp(collection_timer / COLLECTION_TIME, 0.0, 1.0)
		anim.scale = _anim_scale * (1.0 + 0.12 * progress)
		anim.rotation = sin(breath_time * 6.0) * 0.08 * progress

		# Eat apple after collection time
		if collection_timer >= COLLECTION_TIME:
			_eat_apple()
	elif collection_timer > 0.0:
		collection_timer = 0.0
		anim.scale = _anim_scale
		anim.rotation = 0.0
	queue_redraw()


func _draw():
	# Shadow on the grass, a little smaller when the apple bobs up
	var low: float = (anim.position.y + BREATH_AMOUNT) / (2.0 * BREATH_AMOUNT)
	draw_set_transform(Vector2(0, 34), 0.0, Vector2(1.0, 0.3))
	draw_circle(Vector2.ZERO, (20.0 + 4.0 * low) * _shadow, Color(0.05, 0.12, 0.04, 0.22))
	draw_set_transform(Vector2.ZERO)
	if is_eaten:
		return

	if collection_timer > 0.0:
		var eaten: float = clamp(collection_timer / COLLECTION_TIME, 0.0, 1.0)
		draw_arc(Vector2.ZERO, RING_RADIUS, 0, TAU, 48, Color(1, 1, 1, 0.45), 10.0, true)
		draw_arc(Vector2.ZERO, RING_RADIUS, -PI / 2, -PI / 2 + TAU * eaten, 48, GameFx.GOLD, 10.0, true)
		return

	draw_arc(Vector2.ZERO, RING_RADIUS + 28.0 * _beacon, 0, TAU, 48,
		Color(1, 1, 1, 0.45 * (1.0 - _beacon)), 3.0, true)
	var left: float = get_time_left() / TIMER_DURATION
	var colour := GREEN.lerp(AMBER, 1.0 - (left - 0.5) * 2.0) if left > 0.5 else AMBER.lerp(RED, 1.0 - left * 2.0)
	draw_arc(Vector2.ZERO, RING_RADIUS, 0, TAU, 48, Color(0, 0, 0, 0.22), 7.0, true)
	draw_arc(Vector2.ZERO, RING_RADIUS, -PI / 2, -PI / 2 + TAU * left, 48, colour, 7.0, true)


func _eat_apple():
	if is_eaten:
		return

	is_eaten = true
	$Timer.stop()
	anim.rotation = 0.0

	# Behind the sheep (z 1), so it reads as a ring of sparkles round it
	GameFx.burst(get_tree().current_scene, global_position,
		[GameFx.GOLD, Color.WHITE, Color(1.0, 0.95, 0.6), Color(0.95, 0.25, 0.2), Color(0.45, 0.78, 0.3)],
		28, 340.0, 0.45, 160.0, 1)

	# Show +1 animation
	score_label.visible = true
	var tween = create_tween()
	tween.tween_property(score_label, "position:y", score_label.position.y - 50, 0.5)
	tween.parallel().tween_property(score_label, "modulate:a", 0.0, 0.5)

	apple_eaten.emit()

	if anim:
		var squash := create_tween()
		squash.tween_property(anim, "scale", _anim_scale * 1.3, 0.08)
		squash.tween_property(anim, "scale", Vector2.ZERO, 0.27)
		squash.parallel().tween_method(_set_shadow, 1.0, 0.0, 0.27)
	await tween.finished

	queue_free()


func _set_shadow(k: float) -> void:
	_shadow = k
	queue_redraw()


func _on_body_entered(body: Node2D):
	if body.name == "Player":
		player_node = body


func _on_body_exited(body: Node2D):
	if body.name == "Player":
		player_node = null


func _on_timer_timeout():
	if is_eaten:
		return
	# Reserve the apple immediately; the resident sheep cannot award a player point.
	is_eaten = true
	$Timer.stop()
	anim.rotation = 0.0
	anim.scale = _anim_scale
	queue_redraw()
	apple_missed.emit()
	score_label.text = "Apple missed"
	score_label.label_settings = GameFx.text_style(24, Color.WHITE)
	score_label.show()
	if is_instance_valid(flock):
		black_sheep = flock.claim_apple(self)
	if not is_instance_valid(black_sheep):
		queue_free()


func eat_by_black_sheep() -> void:
	score_label.text = "Black sheep's snack!"
	GameFx.burst(get_tree().current_scene, global_position,
		[Color(0.95, 0.2, 0.18), Color(0.45, 0.78, 0.3)], 10, 140.0, 0.35)
	var snack := create_tween()
	snack.tween_property(anim, "scale", Vector2.ZERO, 0.35)
	snack.parallel().tween_method(_set_shadow, 1.0, 0.0, 0.35)
	snack.tween_interval(0.3)
	snack.tween_callback(queue_free)


func get_time_left() -> float:
	return maxf(TIMER_DURATION - apple_lifetime, 0.0)
