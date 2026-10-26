extends Node2D
## FlyThrough scenery over the mountain picture: two layers of clouds and a row
## of pines that drift by slower than the pipes (parallax), and a grassy ground
## that moves with them. Each piece is drawn once; scrolling only moves nodes,
## by the pipes' own per-frame step while the game runs. The game's ground node
## keeps its collision; only its old striped sprite is hidden.

const TREE_PERIOD := 512.0
const GROUND_PERIOD := 384.0

var main: Control
var _clouds: Array[Cloud] = []
var _trees: Strip
var _ground: Strip
var _tree_x := 0.0
var _ground_x := 0.0
var _width := 1152.0


func _ready() -> void:
	main = get_parent()
	main.move_child(self, main.get_node("TextureRect").get_index() + 1)
	main.get_node("ground/Sprite2D").hide()
	_width = get_viewport_rect().size.x

	# Far clouds: small, faint, slow. Near clouds: bigger, brighter, faster.
	# Few, spread out and kept high, so the plane's flying band stays clear.
	for far in [true, false]:
		var count := 4 if far else 3
		for i in count:
			var c := Cloud.new()
			c.far = far
			c.scale = Vector2.ONE * (randf_range(0.5, 0.65) if far else randf_range(0.8, 1.0))
			c.position = Vector2((i + randf_range(0.1, 0.9)) * _width / count, _cloud_y(far))
			add_child(c)
			_clouds.append(c)

	_trees = Strip.new()
	_trees.period = TREE_PERIOD
	_trees.width = _width
	_trees.kind = "trees"
	add_child(_trees)

	_ground = Strip.new()
	_ground.period = GROUND_PERIOD
	_ground.width = _width
	_ground.kind = "ground"
	_ground.z_index = 1   # over the pipes' feet, as the old ground was
	add_child(_ground)


func _process(delta: float) -> void:
	var step: float = main.SCROLL_SPEED if main.game_running else 0.0
	for c in _clouds:
		c.position.x -= step * (0.12 if c.far else 0.3) + delta * (5.0 if c.far else 10.0)
		if c.position.x < -160.0:
			c.position = Vector2(_width + 160.0 + randf_range(0, 200), _cloud_y(c.far))
	_tree_x += step * 0.5
	_ground_x += step
	_trees.position.x = -fposmod(_tree_x, TREE_PERIOD)
	_ground.position.x = -fposmod(_ground_x, GROUND_PERIOD)


static func _cloud_y(far: bool) -> float:
	return randf_range(40, 200) if far else randf_range(50, 170)


## Opaque, so overlapping puffs show no seams; far ones are tinted to the sky.
class Cloud extends Node2D:
	const SKY := Color(0.36, 0.62, 0.88)
	var far := false

	func _draw() -> void:
		var white := Color.WHITE.lerp(SKY, 0.4 if far else 0.0)
		var shade := Color(0.82, 0.9, 1.0).lerp(SKY, 0.4 if far else 0.0)
		var puffs := [[Vector2(-44, 6), 22.0], [Vector2(-12, -10), 30.0], [Vector2(24, -4), 26.0], [Vector2(52, 8), 18.0]]
		for p in puffs:
			draw_circle(p[0] + Vector2(0, 6), p[1], shade)
		var base := StyleBoxFlat.new()
		base.bg_color = shade
		base.set_corner_radius_all(18)
		base.draw(get_canvas_item(), Rect2(-70, 4, 140, 30))
		base.bg_color = white
		base.draw(get_canvas_item(), Rect2(-70, -2, 140, 30))
		for p in puffs:
			draw_circle(p[0], p[1], white)


## A strip that repeats every `period` px, drawn wide enough to cover the
## screen at any scroll offset: pines on a hill, or the ground.
class Strip extends Node2D:
	const GROUND_TOP := 551.0   # top of the old ground strip, where the plane bottoms out
	const TREES := Color(0.13, 0.27, 0.37)
	var period := 512.0
	var width := 1152.0
	var kind := "ground"

	func _draw() -> void:
		var copies := int(ceil(width / period)) + 1
		for k in copies:
			if kind == "trees":
				_draw_trees(k * period)
			else:
				_draw_ground(k * period)

	func _draw_trees(x0: float) -> void:
		var hill := PackedVector2Array()
		for i in 33:
			var x := period * i / 32.0
			hill.append(Vector2(x0 + x, 515.0 + 12.0 * sin(x * TAU * 2.0 / period) + 6.0 * sin(x * TAU * 5.0 / period + 2.0)))
		hill.append(Vector2(x0 + period, 600))
		hill.append(Vector2(x0, 600))
		draw_colored_polygon(hill, TREES)
		var rng := RandomNumberGenerator.new()
		rng.seed = 11
		for i in 9:
			var x := rng.randf_range(0, period)
			var h := rng.randf_range(48, 96)
			var base := Vector2(x0 + x, 530.0 + 12.0 * sin(x * TAU * 2.0 / period))
			draw_rect(Rect2(base + Vector2(-3, -10), Vector2(6, 14)), TREES.darkened(0.2))
			for tier in 3:
				var w := h * (0.42 - tier * 0.09)
				var bottom := base.y - 6 - h * 0.28 * tier
				draw_colored_polygon(PackedVector2Array([
					Vector2(base.x - w, bottom), Vector2(base.x + w, bottom),
					Vector2(base.x, bottom - h * 0.48)]), TREES)

	func _draw_ground(x0: float) -> void:
		var top := GROUND_TOP
		var light := Color(0.5, 0.78, 0.33)
		var dark := Color(0.33, 0.6, 0.25)
		var soil_top := Color(0.56, 0.41, 0.27)
		var soil_bottom := Color(0.36, 0.26, 0.18)
		# Soil, darker with depth
		draw_polygon(PackedVector2Array([Vector2(x0, top + 10), Vector2(x0 + period, top + 10),
			Vector2(x0 + period, 700), Vector2(x0, 700)]),
			PackedColorArray([soil_top, soil_top, soil_bottom, soil_bottom]))
		# Grass band with a wavy top and a scalloped lower edge
		var upper := PackedVector2Array()
		var lower := PackedVector2Array()
		for i in 49:
			var x := period * i / 48.0
			upper.append(Vector2(x0 + x, top + 2.0 + 1.5 * sin(x * TAU * 6.0 / period)))
			lower.append(Vector2(x0 + x, top + 17.0 + 3.0 * sin(x * TAU * 12.0 / period + 1.0)))
		var band := upper.duplicate()
		var colours := PackedColorArray()
		colours.resize(upper.size())
		colours.fill(light)
		for i in range(lower.size() - 1, -1, -1):
			band.append(lower[i])
			colours.append(dark)
		draw_polygon(band, colours)
		draw_polyline(lower, Color(0.25, 0.18, 0.12, 0.5), 3.0)
		draw_polyline(upper, Color(0.2, 0.42, 0.17), 2.0)
		var rng := RandomNumberGenerator.new()
		rng.seed = 5
		# Blades along the top edge
		for i in 46:
			var x := rng.randf_range(0, period)
			var y := top + 2.0 + 1.5 * sin(x * TAU * 6.0 / period)
			var h := rng.randf_range(5, 11)
			var lean := rng.randf_range(-3, 3)
			draw_colored_polygon(PackedVector2Array([Vector2(x0 + x - 2.5, y + 1), Vector2(x0 + x + 2.5, y + 1),
				Vector2(x0 + x + lean, y - h)]), light.lightened(rng.randf_range(0.0, 0.15)))
		# Pebbles in the soil
		for i in 14:
			var at := Vector2(x0 + rng.randf_range(8, period - 8), rng.randf_range(top + 28, 640))
			var r := rng.randf_range(3, 7)
			draw_set_transform(at, 0.0, Vector2(1.0, 0.65))
			draw_circle(Vector2.ZERO, r, soil_bottom.darkened(0.15) if i % 2 else soil_top.lightened(0.12))
			draw_circle(Vector2(-r * 0.3, -r * 0.3), r * 0.35, Color(1, 1, 1, 0.18))
			draw_set_transform(Vector2.ZERO)
