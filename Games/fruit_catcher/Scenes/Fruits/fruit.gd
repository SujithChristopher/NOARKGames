extends Area2D
class_name Gem

const INITIAL_SPEED: float = 200.0 
var END_OF_SCREEN_Y: float
signal gem_off_screen
signal gem_collected  # Restored - might be needed for scoring/game logic
static var gem_count: int = 0

# Directory containing fruit images
const FRUITS_DIR = "res://Games/fruit_catcher/assets/fruits/"
# Cache for loaded textures to improve performance
static var fruit_textures: Array[Texture2D] = []
static var textures_loaded: bool = false

# References to both nodes
@onready var sprite: Sprite2D = get_node("Sprite2D")
@onready var animated_sprite: AnimatedSprite2D = get_node("AnimatedSprite2D")

var is_collected: bool = false  # Flag to prevent multiple collections

func _ready() -> void:
	gem_count += 1
	END_OF_SCREEN_Y = get_viewport_rect().end.y
	
	# Hide the animated sprite initially (show only the fruit sprite)
	if animated_sprite:
		animated_sprite.visible = false
	
	# Load textures only once
	if not textures_loaded:
		load_fruit_textures()
	
	# Set random fruit texture
	set_random_fruit_texture()

func load_fruit_textures() -> void:
	"""Load all fruit textures once and cache them"""
	var fruit_files = get_fruit_files()
	fruit_textures.clear()
	
	for file_name in fruit_files:
		var texture_path = FRUITS_DIR + file_name
		var texture = load(texture_path) as Texture2D
		if texture:
			fruit_textures.append(texture)
	
	textures_loaded = true

func set_random_fruit_texture() -> void:
	"""Set a random fruit texture from the cached textures"""
	if fruit_textures.size() > 0:
		if sprite:
			var random_index = randi() % fruit_textures.size()
			sprite.texture = fruit_textures[random_index]

func get_fruit_files() -> Array[String]:
	var fruit_files: Array[String] = []
	var dir = DirAccess.open(FRUITS_DIR)
	
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		
		while file_name != "":
			# Check if it's an image file
			if file_name.ends_with(".jpg") or file_name.ends_with(".png") or file_name.ends_with(".jpeg"):
				fruit_files.append(file_name)
			file_name = dir.get_next()
		
		dir.list_dir_end()
	else:
		push_error("Failed to access directory: " + FRUITS_DIR)
	
	return fruit_files

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
