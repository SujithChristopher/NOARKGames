extends Area2D

signal coin_missed

@export var amplitude := 4
@export var frequency := 5

var time_passed = 0
var initial_position := Vector2.ZERO
var spawn_timer = 0.0
var spawn_interval = 10.0

# Spawn boundaries
var spawn_x_min = 124
var spawn_x_max = 1115
var spawn_y_min = 192
var spawn_y_max = 420

func _ready():
	spawn_coin() # Spawn first coin immediately
	
func _process(delta):
	coin_hover(delta)
	handle_spawn_timer(delta)

# Coin Hover Animation
func coin_hover(delta):
	time_passed += delta
	var new_y = initial_position.y + amplitude * sin(frequency * time_passed)
	position.y = new_y

# Handle spawn timer
func handle_spawn_timer(delta):
	spawn_timer += delta
	if spawn_timer >= spawn_interval:
		coin_missed.emit()  # This line was missing!
		spawn_new_coin()
		
# Spawn coin at random location
func spawn_coin():
	var random_x = randf_range(spawn_x_min, spawn_x_max)
	var random_y = randf_range(spawn_y_min, spawn_y_max)
	position = Vector2(random_x, random_y)
	initial_position = position
	reset_coin_properties()

# Spawn new coin and remove old one
func spawn_new_coin():
	spawn_coin()
	spawn_timer = 0.0

# Reset coin properties when spawning
func reset_coin_properties():
	time_passed = 0
	scale = Vector2.ONE
	visible = true

# Coin collected
func _on_body_entered(body):
	if body.is_in_group("Player2D"):
		AudioManager.coin_pickup_sfx.play()
		body.on_coin_collected()  # This calls the new scoring function
		var tween = create_tween()
		tween.tween_property(self, "scale", Vector2.ZERO, 0.1)
		await tween.finished
		spawn_new_coin()
