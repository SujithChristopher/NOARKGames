extends Area2D
class_name Gem

const GameFx := preload("res://Main_screen/Scripts/game_fx.gd")
const INITIAL_SPEED: float = 200.0
## Every fruit's long side, in the game's own 1152x648 units. The stretch mode
## scales those to the screen, so a fruit takes the same share of any screen,
## whatever its size or DPI. The hit circle (fruit.tscn, radius 26) is the
## fruit's body, so what touches the basket on screen is what counts.
const SIZE: float = 64.0
const TEXTURE_SIZE: int = 192   # shrunk to this, then drawn at SIZE: sharp on big screens
var END_OF_SCREEN_Y: float
signal gem_off_screen
signal gem_collected  # Restored - might be needed for scoring/game logic
static var gem_count: int = 0

# Preloaded fruit textures — DirAccess cannot enumerate res:// inside an APK,
# so textures must be referenced explicitly to be included in the export.
# Each with the colour of its juice, for the splash when caught or missed.
const FRUITS: Array = [
	[preload("res://Games/fruit_catcher/assets/fruits/banana.png"), Color(1.0, 0.88, 0.3)],
	[preload("res://Games/fruit_catcher/assets/fruits/black-berry-light.png"), Color(0.5, 0.22, 0.6)],
	[preload("res://Games/fruit_catcher/assets/fruits/green-apple.png"), Color(0.6, 0.86, 0.3)],
	[preload("res://Games/fruit_catcher/assets/fruits/green-grape.png"), Color(0.72, 0.9, 0.35)],
	[preload("res://Games/fruit_catcher/assets/fruits/lemon.png"), Color(1.0, 0.92, 0.3)],
	[preload("res://Games/fruit_catcher/assets/fruits/lime.png"), Color(0.55, 0.86, 0.25)],
	[preload("res://Games/fruit_catcher/assets/fruits/orange.png"), Color(1.0, 0.6, 0.15)],
	[preload("res://Games/fruit_catcher/assets/fruits/peach.png"), Color(1.0, 0.66, 0.45)],
	[preload("res://Games/fruit_catcher/assets/fruits/pear.png"), Color(0.78, 0.86, 0.3)],
	[preload("res://Games/fruit_catcher/assets/fruits/plum.png"), Color(0.6, 0.22, 0.55)],
	[preload("res://Games/fruit_catcher/assets/fruits/raspberry.png"), Color(0.92, 0.22, 0.42)],
	[preload("res://Games/fruit_catcher/assets/fruits/red-apple.png"), Color(0.92, 0.2, 0.2)],
	[preload("res://Games/fruit_catcher/assets/fruits/red-cherry.png"), Color(0.86, 0.1, 0.2)],
	[preload("res://Games/fruit_catcher/assets/fruits/red-grape.png"), Color(0.62, 0.16, 0.36)],
	[preload("res://Games/fruit_catcher/assets/fruits/strawberry.png"), Color(0.95, 0.2, 0.25)],
	[preload("res://Games/fruit_catcher/assets/fruits/watermelon.png"), Color(0.95, 0.3, 0.36)],
]
const HALO := Color(1.0, 0.97, 0.82, 0.38)

@onready var sprite: Sprite2D = $Sprite2D

var is_collected: bool = false  # Flag to prevent multiple collections
var colour: Color = Color.WHITE  # juice colour of the fruit picked
var _sway: float = randf() * TAU

func _ready() -> void:
	gem_count += 1
	END_OF_SCREEN_Y = get_viewport_rect().end.y

	var fruit: Array = FRUITS[randi() % FRUITS.size()]
	colour = fruit[1]
	sprite.texture = GameFx.shrink(fruit[0], TEXTURE_SIZE)
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	sprite.scale = Vector2.ONE * SIZE / TEXTURE_SIZE

## A soft glow behind the fruit, so it stands out from the dark forest.
func _draw() -> void:
	draw_texture_rect(GameFx.soft_dot(), Rect2(Vector2.ONE * -SIZE * 0.9, Vector2.ONE * SIZE * 1.8), false, HALO)

func die() -> void:
	set_process(false)
	gem_count -= 1
	queue_free()

func _process(delta: float) -> void:
	# Don't move if collected (during animation)
	if is_collected:
		return

	position.y += INITIAL_SPEED * delta
	# A gentle sway as it falls; the picture only, the fruit falls straight.
	_sway += delta * 2.4
	sprite.rotation = sin(_sway) * 0.18

	if position.y > END_OF_SCREEN_Y:
		gem_off_screen.emit()
		die()

func _on_area_entered(area: Area2D) -> void:
	if area.name == "Player" or area.name == "Paddle":
		collect_gem(area)

## Splash, then drop behind the basket's rim and fade.
func collect_gem(basket: Area2D = null) -> void:
	if is_collected:
		return  # Prevent multiple collections

	is_collected = true
	set_process(false)  # Stop movement

	# Emit collection signal for game logic (scoring, etc.)
	gem_collected.emit()

	GameFx.burst(get_parent(), global_position, [colour, colour.lightened(0.45), GameFx.GOLD, Color.WHITE], 24, 240.0)
	if basket:
		# Drawn just before the basket, so it falls in behind the rim.
		get_parent().move_child.call_deferred(self, basket.get_index())
	var tw := create_tween()
	tw.tween_property(sprite, "position:y", 34.0, 0.22).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(sprite, "scale", sprite.scale * 0.55, 0.22)
	tw.parallel().tween_property(self, "modulate:a", 0.0, 0.22).set_delay(0.08)
	await tw.finished

	# Clean up - decrement counter since we're not calling die()
	gem_count -= 1
	queue_free()
