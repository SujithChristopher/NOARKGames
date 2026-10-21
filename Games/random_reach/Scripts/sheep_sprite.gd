extends AnimatedSprite2D
## Generated black sheep visitor. The player keeps its original scene artwork.

@export_range(0, 1) var coat_row: int = 1
const SHEET = preload("res://Games/random_reach/Sprites/sheep_walk.png")
var _phase := 0.0

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var frames := SpriteFrames.new()
	frames.remove_animation(&"default")
	var cell := Vector2(SHEET.get_width() / 4.0, SHEET.get_height() / 2.0)
	for animation_name in [&"walk", &"idle", &"eat"]:
		frames.add_animation(animation_name)
		frames.set_animation_speed(animation_name, 9.0 if animation_name == &"walk" else 5.0)
		for column in range(4 if animation_name != &"idle" else 1):
			var frame := AtlasTexture.new()
			frame.atlas = SHEET
			frame.region = Rect2(Vector2(column, coat_row) * cell, cell)
			frames.add_frame(animation_name, frame)
	sprite_frames = frames
	scale = Vector2.ONE * (32.0 / cell.x)
	play(&"idle")

func _process(delta: float) -> void:
	_phase += delta
	# Gentle breathing at rest and a visible nibble while eating.
	if animation == &"eat":
		rotation = sin(_phase * 16.0) * 0.12
	elif animation == &"idle":
		rotation = sin(_phase * 2.5) * 0.015
	else:
		rotation = 0.0
