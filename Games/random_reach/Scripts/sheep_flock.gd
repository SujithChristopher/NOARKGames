extends Node2D
## Resident sheep wander and graze; the nearest one claims an expired apple.
## No physics bodies: scenery sheep cannot collect targets or block the player.

const SheepSprite = preload("res://Games/random_reach/Scripts/sheep_sprite.gd")
const FLOCK_SIZE := 2
const WALK_SPEED := 45.0
const SNACK_SPEED := 380.0
const TARGET_CLEARANCE := 125.0
const FIELD := Rect2(85.0, 170.0, 970.0, 390.0)

var player: Node2D
var sheep: Array[Dictionary] = []
var current_apple: Node2D

func _ready() -> void:
	name = "BlackSheepFlock"
	z_index = 1
	for index in FLOCK_SIZE:
		var sprite := AnimatedSprite2D.new()
		sprite.set_script(SheepSprite)
		add_child(sprite)
		sprite.scale *= 2.7
		sprite.position = Vector2(135.0 + index * 420.0, 220.0 + index * 130.0)
		sheep.append({"sprite": sprite, "state": "graze", "wait": randf_range(0.5, 2.0),
			"goal": sprite.position, "apple": null})
		sprite.play(&"eat")

func watch_apple(apple: Node2D) -> void:
	current_apple = apple
	# Choose fresh destinations so walkers give the new target room.
	for animal in sheep:
		if animal.state == "walk":
			animal.goal = _grazing_point()

func claim_apple(apple: Node2D) -> AnimatedSprite2D:
	var nearest: Dictionary = {}
	var best_distance := INF
	for animal in sheep:
		if animal.state in ["approach", "snack"]:
			continue
		var distance: float = animal.sprite.global_position.distance_squared_to(apple.global_position)
		if distance < best_distance:
			nearest = animal
			best_distance = distance
	if nearest.is_empty():
		return null
	var sprite: AnimatedSprite2D = nearest.sprite
	var from_left := sprite.global_position.x <= apple.global_position.x
	nearest.goal = to_local(apple.global_position + Vector2(-30.0 if from_left else 30.0, 0.0))
	nearest.apple = apple
	nearest.state = "approach"
	sprite.flip_h = not from_left
	sprite.play(&"walk")
	return sprite

func reset() -> void:
	current_apple = null
	for animal in sheep:
		animal.state = "graze"
		animal.apple = null
		animal.wait = randf_range(0.5, 2.0)
		animal.sprite.play(&"eat")
	process_mode = Node.PROCESS_MODE_INHERIT

func _grazing_point() -> Vector2:
	var point := FIELD.get_center()
	for attempt in 16:
		point = Vector2(randf_range(FIELD.position.x, FIELD.end.x),
			randf_range(FIELD.position.y, FIELD.end.y))
		if is_instance_valid(current_apple) \
				and to_global(point).distance_to(current_apple.global_position) < TARGET_CLEARANCE:
			continue
		if is_instance_valid(player) and to_global(point).distance_to(player.global_position) < 95.0:
			continue
		break
	return point

func _process(delta: float) -> void:
	for animal in sheep:
		var sprite: AnimatedSprite2D = animal.sprite
		match animal.state:
			"graze", "snack":
				animal.wait -= delta
				if animal.wait <= 0.0:
					animal.state = "walk"
					animal.goal = _grazing_point()
					sprite.play(&"walk")
			"walk":
				var direction: Vector2 = (animal.goal - sprite.position).normalized()
				if is_instance_valid(current_apple):
					var away: Vector2 = sprite.global_position - current_apple.global_position
					var influence := clampf(1.0 - away.length() / TARGET_CLEARANCE, 0.0, 1.0)
					direction = (direction + away.normalized() * influence * 3.0).normalized()
				sprite.position += direction * minf(WALK_SPEED * delta, sprite.position.distance_to(animal.goal))
				sprite.position = sprite.position.clamp(FIELD.position, FIELD.end)
				if absf(direction.x) > 0.05:
					sprite.flip_h = direction.x < 0.0
				if sprite.position.distance_to(animal.goal) < 5.0:
					animal.state = "graze"
					animal.wait = randf_range(1.5, 3.5)
					sprite.play(&"eat")
			"approach":
				if not is_instance_valid(animal.apple) or animal.apple.is_queued_for_deletion():
					animal.state = "graze"
					animal.wait = 0.5
					animal.apple = null
					sprite.play(&"eat")
					continue
				sprite.position = sprite.position.move_toward(animal.goal, SNACK_SPEED * delta)
				if sprite.position.distance_to(animal.goal) < 1.0:
					animal.state = "snack"
					animal.wait = 1.0
					sprite.play(&"eat")
					animal.apple.eat_by_black_sheep()
					animal.apple = null
	queue_redraw()

func _draw() -> void:
	for animal in sheep:
		draw_set_transform(animal.sprite.position + Vector2(0.0, 29.0), 0.0, Vector2(1.0, 0.3))
		draw_circle(Vector2.ZERO, 25.0, Color(0.12, 0.18, 0.1, 0.18))
	draw_set_transform(Vector2.ZERO)
