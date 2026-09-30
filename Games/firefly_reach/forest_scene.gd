extends Node2D

# The painted night forest behind the clinic screens (the approved mockup
# "Night Forest Screens", 2026-09-26). Replaces the flat night meadow
# (night_sky.gd). The painting itself is forest_painter.gd.
#
# It never moves, so it is painted once: a SubViewport renders the painter a
# single time, the result is copied into an ImageTexture, and from then on the
# forest is one texture draw per frame (drawing its ~1,200 shapes every frame
# cost ~20 fps on the board). The texture is kept for the app's run, one per
# option set, so later screens and visits reuse it. Until the first painting
# is ready (a frame or two) it shows plain night blue. Drawn behind its parent
# (show_behind_parent).
#
# Set before adding the node:
#   seed_value  which forest (the same seed always paints the same trees)
#   moon        the moon's position, as a fraction of the screen
#   dim         0..1, a dark veil over it all (the game uses it so targets stand out)
#   clear       an x range in px kept free of the two nearest tree layers
#               (room for something in front); Vector2.ZERO = none

const Painter := preload("res://Games/firefly_reach/forest_painter.gd")

var seed_value: int = 23
var moon: Vector2 = Vector2(0.86, 0.13)
var dim: float = 0.28
var clear: Vector2 = Vector2.ZERO

static var _cache: Dictionary = {}   # option set -> painted ImageTexture
var _tex: Texture2D = null
var _size: Vector2


func _ready() -> void:
	show_behind_parent = true
	_size = get_viewport_rect().size
	var key: String = "%d %s %.2f %s %s" % [seed_value, moon, dim, clear, _size]
	if _cache.has(key):
		_tex = _cache[key]
		return
	var sub := SubViewport.new()
	sub.size = Vector2i(_size)
	sub.transparent_bg = false
	sub.render_target_update_mode = SubViewport.UPDATE_ONCE
	var p := Painter.new()
	p.size_px = _size
	p.seed_value = seed_value
	p.moon = moon
	p.dim = dim
	p.clear = clear
	sub.add_child(p)
	add_child(sub)
	# The SubViewport renders during the next frame's drawing; copy it after.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	if not is_instance_valid(sub):
		return
	_tex = ImageTexture.create_from_image(sub.get_texture().get_image())
	_cache[key] = _tex
	sub.queue_free()
	queue_redraw()


func _draw() -> void:
	if _tex:
		draw_texture(_tex, Vector2.ZERO)
	else:
		draw_rect(Rect2(Vector2.ZERO, _size), Color("0A1630"))
