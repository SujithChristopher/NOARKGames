extends Node2D
## Random Reach scenery. In 2D the field's grass is recoloured to a softer green
## with mowing stripes and a vignette, and dotted with flowers; in 3D clouds
## drift over the background's sky. Both get a wooden frame where the brick
## border was (the bricks' tiles stay, undrawn, so nothing about collision
## changes). Decoration only, drawn once: it never moves a target or the player.

const GRASS_SHADER := """
shader_type canvas_item;
uniform vec3 light_grass : source_color = vec3(0.50, 0.76, 0.31);
uniform vec3 dark_grass : source_color = vec3(0.27, 0.52, 0.19);

void fragment() {
	vec4 t = texture(TEXTURE, UV);
	float lum = dot(t.rgb, vec3(0.299, 0.587, 0.114));
	vec3 c = mix(dark_grass, light_grass, smoothstep(0.45, 0.72, lum));
	// Broad, faint blotches so the field is not one flat colour
	float n = sin(UV.x * 23.0 + sin(UV.y * 11.0) * 2.0) * sin(UV.y * 17.0 + sin(UV.x * 7.0) * 3.0);
	c *= 1.0 + 0.035 * n;
	// Mowing stripes
	c *= 0.975 + 0.05 * smoothstep(-0.25, 0.25, sin((UV.x + UV.y * 0.6) * 22.0));
	// Darker towards the edges
	vec2 d = UV - 0.5;
	c *= 1.0 - 0.45 * dot(d, d);
	COLOR = vec4(c, t.a);
}
"""
## The 3D background's lime grass, moved to the same greens; the sky and the
## fence (not green-dominant) are left alone.
const GRADE_SHADER := """
shader_type canvas_item;
uniform vec3 light_grass : source_color = vec3(0.50, 0.76, 0.31);
uniform vec3 dark_grass : source_color = vec3(0.27, 0.52, 0.19);

void fragment() {
	vec4 t = texture(TEXTURE, UV);
	float lum = dot(t.rgb, vec3(0.299, 0.587, 0.114));
	float lime = smoothstep(0.0, 0.08, t.g - t.r) * smoothstep(0.15, 0.35, t.g - t.b);
	vec3 grass = mix(dark_grass, light_grass, smoothstep(0.4, 0.72, lum));
	grass *= 0.975 + 0.05 * smoothstep(-0.25, 0.25, sin((UV.x + UV.y * 0.6) * 22.0));
	COLOR = vec4(mix(t.rgb, grass, lime), t.a);
}
"""
const FRAME := 24.0
const PETALS := [Color(1, 1, 0.96), Color(1, 0.93, 0.55), Color(1, 0.76, 0.84), Color(0.86, 0.8, 1)]

var is_3d := false
var _size: Vector2


func _ready() -> void:
	var game := get_parent()
	game.move_child(self, game.get_node("2DRR").get_index() + 1)
	game.get_node("TileMap").self_modulate.a = 0.0
	# In the game root's coordinates (it is scaled a hair over 1).
	_size = get_viewport_rect().size / game.scale
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = GRADE_SHADER if is_3d else GRASS_SHADER
	game.get_node("3DRR" if is_3d else "2DRR").material = mat
	if is_3d:
		_add_clouds()
	var frame := Frame.new()
	frame.size = _size
	add_child(frame)


func _draw() -> void:
	if is_3d:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var field := Rect2(Vector2(FRAME + 20, FRAME + 20), _size - Vector2(FRAME + 20, FRAME + 20) * 2)
	# Darker clover patches
	for i in 26:
		var at := Vector2(rng.randf_range(field.position.x, field.end.x), rng.randf_range(field.position.y, field.end.y))
		for j in 3:
			var leaf := at + Vector2.from_angle(TAU * j / 3.0 + rng.randf()) * 5.0
			draw_circle(leaf, rng.randf_range(4.0, 6.0), Color(0.16, 0.36, 0.12, 0.22))
	# Flower clusters, kept out from under the score, timer and buttons
	var hud := [Rect2(0, 0, 320, 150), Rect2(_size.x - 220, 0, 220, 150),
		Rect2(0, _size.y - 110, 150, 110), Rect2(_size.x - 150, _size.y - 110, 150, 110)]
	for i in 16:
		var at := Vector2(rng.randf_range(field.position.x, field.end.x), rng.randf_range(field.position.y, field.end.y))
		if hud.any(func(r): return r.grow(24).has_point(at)):
			continue
		var petal: Color = PETALS[rng.randi() % PETALS.size()]
		for j in rng.randi_range(3, 6):
			_flower(at + Vector2(rng.randf_range(-22, 22), rng.randf_range(-14, 14)), petal, rng.randf() * TAU)


func _flower(at: Vector2, petal: Color, turn: float) -> void:
	draw_circle(at + Vector2(1, 2), 6.0, Color(0.1, 0.25, 0.08, 0.18))
	for k in 5:
		draw_circle(at + Vector2.from_angle(turn + TAU * k / 5.0) * 3.4, 3.0, petal)
	draw_circle(at, 2.1, Color(1.0, 0.72, 0.2))


func _add_clouds() -> void:
	# The 3D background's sky is its top strip, above the fence.
	for i in 4:
		var c := Cloud.new()
		c.position = Vector2(80 + i * 290 + randf_range(-40, 40), randf_range(48, 110))
		c.scale = Vector2.ONE * randf_range(0.6, 1.0)
		c.speed = randf_range(7.0, 13.0)
		c.right = _size.x
		add_child(c)


class Cloud extends Node2D:
	var speed := 10.0
	var right := 1152.0

	func _process(delta: float) -> void:
		position.x += speed * delta
		if position.x > right + 90.0:
			position.x = -90.0

	func _draw() -> void:
		var shade := Color(0.86, 0.92, 1.0)
		var white := Color.WHITE
		for p in [[Vector2(-34, 4), 18.0], [Vector2(0, -6), 26.0], [Vector2(34, 4), 19.0]]:
			draw_circle(p[0] + Vector2(0, 4), p[1], shade)
		var base := StyleBoxFlat.new()
		base.bg_color = white
		base.set_corner_radius_all(16)
		base.draw(get_canvas_item(), Rect2(-56, 0, 112, 26))
		for p in [[Vector2(-34, 4), 18.0], [Vector2(0, -6), 26.0], [Vector2(34, 4), 19.0]]:
			draw_circle(p[0], p[1], white)


## Wooden planks round the edge of the screen, with posts at the corners and a
## soft shadow cast onto the field.
class Frame extends Node2D:
	const WOOD := Color(0.6, 0.4, 0.23)
	const WOOD_DARK := Color(0.42, 0.26, 0.14)
	var size := Vector2(1152, 648)

	func _draw() -> void:
		var f := 24.0
		var sides := [Rect2(0, 0, size.x, f), Rect2(0, size.y - f, size.x, f),
			Rect2(0, 0, f, size.y), Rect2(size.x - f, 0, f, size.y)]
		# Shadow on the field, just inside the frame
		for i in 8:
			var a := 0.16 * (1.0 - i / 8.0)
			draw_rect(Rect2(Vector2(f + i, f + i), size - Vector2(f + i, f + i) * 2), Color(0, 0, 0, a), false, 1.0)
		for r in sides:
			draw_rect(r, WOOD)
		# Grain along each side and seams between planks
		var rng := RandomNumberGenerator.new()
		rng.seed = 3
		for r in sides:
			var along_x: bool = r.size.x > r.size.y
			var length: float = r.size.x if along_x else r.size.y
			for k in [0.33, 0.66]:
				var a: Vector2 = r.position + (Vector2(0, f * k) if along_x else Vector2(f * k, 0))
				var b: Vector2 = a + (Vector2(length, 0) if along_x else Vector2(0, length))
				draw_line(a, b, Color(WOOD_DARK, 0.35), 1.5)
			var at := rng.randf_range(40, 100)
			while at < length:
				var p: Vector2 = r.position + (Vector2(at, 0) if along_x else Vector2(0, at))
				draw_line(p, p + (Vector2(0, f) if along_x else Vector2(f, 0)), Color(WOOD_DARK, 0.8), 2.0)
				at += rng.randf_range(90, 150)
		# Light top edge and dark inner edge, for depth
		draw_rect(Rect2(Vector2(1, 1), size - Vector2(2, 2)), Color(1, 0.85, 0.6, 0.35), false, 2.0)
		draw_rect(Rect2(Vector2(f, f), size - Vector2(f, f) * 2), WOOD_DARK, false, 2.5)
		# Corner posts
		for c in [Vector2(0, 0), Vector2(size.x - f, 0), Vector2(0, size.y - f), Vector2(size.x - f, size.y - f)]:
			var post := Rect2(c - Vector2(3, 3), Vector2(f + 6, f + 6))
			draw_rect(post, WOOD_DARK)
			draw_rect(post.grow(-4), Color(0.7, 0.5, 0.3))
			draw_circle(post.get_center(), 2.5, WOOD_DARK)
