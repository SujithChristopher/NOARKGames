extends Area2D
class_name Gem

const INITIAL_SPEED: float = 200.0 
var END_OF_SCREEN_Y: float
signal gem_off_screen
signal gem_collected  # Restored - might be needed for scoring/game logic
static var gem_count: int = 0

# Preloaded fruit textures — DirAccess cannot enumerate res:// inside an APK,
# so textures must be referenced explicitly to be included in the export.
const FRUIT_TEXTURES_LIST: Array = [
	preload("res://Games/fruit_catcher/assets/fruits/banana.png"),
	preload("res://Games/fruit_catcher/assets/fruits/black-berry-light.png"),
	preload("res://Games/fruit_catcher/assets/fruits/green-apple.png"),
	preload("res://Games/fruit_catcher/assets/fruits/green-grape.png"),
	preload("res://Games/fruit_catcher/assets/fruits/lemon.png"),
	preload("res://Games/fruit_catcher/assets/fruits/lime.png"),
	preload("res://Games/fruit_catcher/assets/fruits/orange.png"),
	preload("res://Games/fruit_catcher/assets/fruits/peach.png"),
	preload("res://Games/fruit_catcher/assets/fruits/pear.png"),
	preload("res://Games/fruit_catcher/assets/fruits/plum.png"),
	preload("res://Games/fruit_catcher/assets/fruits/raspberry.png"),
	preload("res://Games/fruit_catcher/assets/fruits/red-apple.png"),
	preload("res://Games/fruit_catcher/assets/fruits/red-cherry.png"),
	preload("res://Games/fruit_catcher/assets/fruits/red-grape.png"),
	preload("res://Games/fruit_catcher/assets/fruits/strawberry.png"),
	preload("res://Games/fruit_catcher/assets/fruits/watermelon.png"),
]

# References to both nodes
@onready var sprite: Sprite2D = get_node("Sprite2D")
@onready var animated_sprite: AnimatedSprite2D = get_node("AnimatedSprite2D")

var is_collected: bool = false  # Flag to prevent multiple collections

func _ready() -> void:
	gem_count += 1
	END_OF_SCREEN_Y = get_viewport_rect().end.y

	# Scale fruit to a fixed physical size (~25 mm) using the screen's actual DPI.
	# This keeps the fruit the same real-world size on every device — high-DPI
	# tablets (e.g. OnePlus Pad 3 at 315 PPI) and desktop monitors alike.
	# Without a base resolution in project.godot, canvas_items does NOT auto-scale,
	# so a viewport-pixel approach produces tiny fruits on high-DPI screens.
	var dpi: float = float(DisplayServer.screen_get_dpi())
	if dpi <= 0:
		dpi = 96.0  # safe fallback for desktop/unknown
	const TARGET_MM: float = 2.0  # desired fruit diameter in millimetres
	var target_px: float = (TARGET_MM / 25.4) * dpi
	var collision_base_size: float = 35.3553  # matches CollisionShape2D size
	scale = Vector2.ONE * (target_px / collision_base_size)

	# Hide the animated sprite initially (show only the fruit sprite)
	if animated_sprite:
		animated_sprite.visible = false

	# Pick a random fruit texture from the preloaded list
	if sprite:
		sprite.texture = FRUIT_TEXTURES_LIST[randi() % FRUIT_TEXTURES_LIST.size()]

func die() -> void:
	set_process(false)
	gem_count -= 1
	queue_free()

func _process(delta: float) -> void:
	# Don't move if collected (during animation)
	if is_collected:
		return
		
	position.y += INITIAL_SPEED * delta
	
	if position.y > END_OF_SCREEN_Y:
		gem_off_screen.emit()
		die()

func _on_area_entered(area: Area2D) -> void:
	# Check if it's the player/paddle and not already collected
	if area.name == "Player" or area.name == "Paddle" and not is_collected:
		collect_gem()

func collect_gem() -> void:
	"""Handle gem collection with animation"""
	if is_collected:
		return  # Prevent multiple collections
	
	is_collected = true
	set_process(false)  # Stop movement
	
	# Emit collection signal for game logic (scoring, etc.)
	gem_collected.emit()
	
	# Hide the fruit sprite and show the animation sprite
	if sprite:
		sprite.visible = false
	if animated_sprite:
		animated_sprite.visible = true
	
	# Play collection animation if AnimatedSprite2D exists and has "collected" animation
	if animated_sprite and animated_sprite.sprite_frames and animated_sprite.sprite_frames.has_animation("collected"):
		animated_sprite.play("collected")
		await animated_sprite.animation_finished
	
	# Clean up - decrement counter since we're not calling die()
	gem_count -= 1
	queue_free()
