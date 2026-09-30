extends Node2D

# Paints the night forest (the approved mockup "Night Forest Screens",
# 2026-09-26): sky, stars, the moon with its halo and rays, a far ridge, four
# layers of pines with mist between them, and dark ground with grass. About
# 1,200 antialiased shapes, so it is not shown directly: forest_scene.gd
# renders it once into an image (drawn directly, every frame, it cost the game
# ~20 fps on the board, 2026-09-28). The Compatibility renderer has no 2D
# MSAA, so each filled shape also gets a thin antialiased outline in its own
# colour to smooth its edge. Sizes are tuned for 1080 px of height.
# forest_scene.gd sets the fields below (see there) before adding it.

var size_px: Vector2
var seed_value: int = 23
var moon: Vector2 = Vector2(0.86, 0.13)
var dim: float = 0.28
var clear: Vector2 = Vector2.ZERO

var _size: Vector2
var _rng := RandomNumberGenerator.new()
# The gradient images must live until the painting has been rendered: a
# texture freed after _draw is rendered as plain white (the white screen of
# 2026-09-28).
var _halo: GradientTexture2D
var _disc: GradientTexture2D
var _vig: GradientTexture2D


func _ready() -> void:
	_size = size_px
	_halo = radial([0.0, 0.25, 1.0], [Color(0.63, 0.8, 1.0, 0.34), Color(0.47, 0.67, 0.94, 0.12),
		Color(0.47, 0.67, 0.94, 0.0)])
	# The moon's limb: clear in the middle, darker towards the edge.
	_disc = radial([0.0, 0.62, 0.97, 1.0], [Color(0.45, 0.55, 0.7, 0.0), Color(0.45, 0.55, 0.7, 0.0),
		Color(0.4, 0.5, 0.66, 0.42), Color(0.4, 0.5, 0.66, 0.0)])
	_vig = radial([0.0, 0.38, 1.0], [Color(0.0, 0.0, 0.03, 0.0), Color(0.0, 0.0, 0.03, 0.0),
		Color(0.0, 0.0, 0.03, 0.6)])


func r() -> float:
	return _rng.randf()


static func radial(offsets: Array, colors: Array) -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(offsets)
	g.colors = PackedColorArray(colors)
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 512
	t.height = 512
	return t


# A full-width band from y0 to y1, colour c0 at the top fading to c1.
func _band(y0: float, y1: float, c0: Color, c1: Color) -> void:
	draw_polygon(PackedVector2Array([Vector2(0.0, y0), Vector2(_size.x, y0), Vector2(_size.x, y1), Vector2(0.0, y1)]),
		PackedColorArray([c0, c0, c1, c1]))


# A filled polygon with a 1 px antialiased outline in the same colour.
func _shape(pts: PackedVector2Array, c: Color) -> void:
	if Geometry2D.triangulate_polygon(pts).is_empty():
		return
	draw_colored_polygon(pts, c)
	var ring := pts.duplicate()
	ring.append(pts[0])
	draw_polyline(ring, c, 1.0, true)


func _draw() -> void:
	_rng.seed = seed_value
	var w := _size.x
	var h := _size.y

	# Sky: four colour stops top to bottom.
	var ys: Array = [0.0, 0.42, 0.62, 1.0]
	var cs: Array = [Color("040A1A"), Color("0B1C3B"), Color("173462"), Color("0A1630")]
	for i in 3:
		_band(h * float(ys[i]), h * float(ys[i + 1]), cs[i], cs[i + 1])

	# Stars, denser near the top.
	for i in 320:
		var sy := pow(r(), 1.5) * h * 0.58
		var a := 0.25 + r() * 0.7
		var sz := 2.2 if r() < 0.08 else 1.2
		draw_circle(Vector2(r() * w, sy), sz * (0.6 + r() * 0.6), Color(0.88, 0.93, 1.0, a), true, -1.0, true)

	# The moon's halo and a few soft rays falling away from it.
	var m := Vector2(moon.x * w, moon.y * h)
	draw_texture_rect(_halo, Rect2(m - Vector2(620.0, 620.0), Vector2(1240.0, 1240.0)), false)
	var side := -0.55 if moon.x < 0.5 else 0.55
	var ray := Color(0.67, 0.82, 1.0, 0.10)
	var ray_end := Color(0.67, 0.82, 1.0, 0.0)
	for i in 6:
		var ang := PI * 0.5 + side + (r() - 0.5) * 0.9
		var half := 0.02 + r() * 0.04
		draw_polygon(PackedVector2Array([m, m + Vector2.from_angle(ang - half) * 1900.0,
			m + Vector2.from_angle(ang + half) * 1900.0]), PackedColorArray([ray, ray_end, ray_end]))

	# The moon (full): a tight glow, a crisp pale disc, the dark "seas" roughly
	# where they are on the real moon, bright Tycho with its rays, a few small
	# craters, and a limb darkening towards the edge.
	var mr := 58.0
	for k in 6:
		draw_circle(m, mr + 6.0 + 7.0 * float(k), Color(0.85, 0.92, 1.0, 0.05), true, -1.0, true)
	draw_circle(m, mr, Color("E9EFF7"), true, -1.0, true)
	# Seas: [x, y, rx, ry, angle] in moon radii.
	var seas: Array = [[-0.36, -0.30, 0.27, 0.21, 0.3], [0.08, -0.36, 0.17, 0.15, 0.0],
		[0.29, -0.08, 0.22, 0.17, -0.4], [-0.52, 0.06, 0.22, 0.38, 0.1], [-0.16, 0.42, 0.19, 0.13, 0.2],
		[0.5, 0.16, 0.13, 0.17, 0.0], [0.64, -0.3, 0.09, 0.07, 0.0], [0.0, 0.05, 0.12, 0.1, 0.5]]
	for s in seas:
		var at := m + Vector2(float(s[0]), float(s[1])) * mr
		for layer in 2:   # a soft edge: a wider faint ellipse under a stronger one
			var grow := 1.18 if layer == 0 else 1.0
			draw_set_transform(at, float(s[4]), Vector2(float(s[2]), float(s[3])) * mr * grow)
			draw_circle(Vector2.ZERO, 1.0, Color(0.52, 0.6, 0.73, 0.2 if layer == 0 else 0.3), true, -1.0, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var tycho := m + Vector2(-0.08, 0.7) * mr
	for i in 9:
		var ang := TAU * float(i) / 9.0 + 0.3
		draw_line(tycho, tycho + Vector2.from_angle(ang) * mr * (0.35 + 0.25 * float(i % 3) / 2.0),
			Color(1.0, 1.0, 1.0, 0.18), 1.2, true)
	draw_circle(tycho, 3.2, Color(1.0, 1.0, 1.0, 0.9), true, -1.0, true)
	for c in [Vector3(0.36, 0.5, 0.06), Vector3(-0.62, -0.5, 0.05), Vector3(0.18, 0.72, 0.045), Vector3(0.7, 0.45, 0.05)]:
		draw_arc(m + Vector2(c.x, c.y) * mr, c.z * mr, 0.0, TAU, 16, Color(0.5, 0.58, 0.7, 0.45), 1.2, true)
	draw_texture_rect(_disc, Rect2(m - Vector2(mr, mr), Vector2(mr, mr) * 2.0), false)
	draw_arc(m, mr, 0.0, TAU, 96, Color(0.93, 0.96, 1.0, 0.9), 1.2, true)

	# The far ridge.
	var ph: Array = [r() * 6.0, r() * 6.0, r() * 6.0]
	var ridge := PackedVector2Array()
	var x := 0.0
	while x <= w:
		ridge.append(Vector2(x, h * 0.55 + sin(x / 310.0 + ph[0]) * 38.0 + sin(x / 127.0 + ph[1]) * 16.0
			+ sin(x / 53.0 + ph[2]) * 6.0))
		x += 30.0
	draw_polyline(ridge, Color("16305A"), 1.0, true)
	ridge.append(Vector2(w, h))
	ridge.append(Vector2(0.0, h))
	draw_colored_polygon(ridge, Color("16305A"))

	# Four layers of pines, far to near: each darker and taller, with its
	# ground below and a band of mist in front of the farther three.
	var base: Array = [0.61, 0.69, 0.79, 0.93]
	var tall: Array = [Vector2(110, 210), Vector2(170, 310), Vector2(250, 450), Vector2(430, 720)]
	var gap: Array = [34.0, 56.0, 92.0, 170.0]
	var col: Array = [Color("183258"), Color("10264B"), Color("091A38"), Color("040C1F")]
	var mist: Array = [0.17, 0.13, 0.09]
	for L in 4:
		var range_h: Vector2 = tall[L]
		var layer_col: Color = col[L]
		var base_y: float = h * float(base[L])
		var tx := -40.0
		while tx < w + 60.0:
			var kept: bool = clear == Vector2.ZERO or L < 2 or tx <= clear.x or tx >= clear.y
			var th := range_h.x + r() * (range_h.y - range_h.x)
			var jitter := r() * 14.0
			var wide := 0.3 + r() * 0.12
			if kept:
				_pine(tx, base_y + jitter, th, th * wide, layer_col)
			tx += float(gap[L]) * (0.7 + r() * 0.6)
		draw_rect(Rect2(0.0, base_y + 8.0, w, h), layer_col)
		if L < 3:
			var fog_a: float = mist[L]
			var none := Color(0.47, 0.67, 0.92, 0.0)
			var thick := Color(0.47, 0.67, 0.92, fog_a)
			_band(base_y - 150.0, base_y - 10.0, none, thick)
			_band(base_y - 10.0, base_y + 50.0, thick, none)

	# Grass along the bottom edge (thinned inside `clear`).
	for i in 700:
		var bx := r() * w
		var by := h - r() * 30.0
		var bh := 18.0 + r() * 60.0
		var lean := (r() - 0.5) * 40.0
		var thin := 2.0 + r() * 2.0
		if clear != Vector2.ZERO and bx > clear.x + 40.0 and bx < clear.y - 40.0 and r() < 0.6:
			continue
		var p0 := Vector2(bx, by)
		var ctrl := Vector2(bx + lean * 0.3, by - bh * 0.6)
		var p1 := Vector2(bx + lean, by - bh)
		var blade := PackedVector2Array()
		for s in 5:
			var t := float(s) / 4.0
			blade.append(p0.lerp(ctrl, t).lerp(ctrl.lerp(p1, t), t))
		draw_polyline(blade, Color("030917"), thin, true)

	if dim > 0.0:
		draw_rect(Rect2(Vector2.ZERO, _size), Color(0.012, 0.027, 0.07, dim))
	# Vignette: dark towards the corners.
	draw_texture_rect(_vig, Rect2(_size * 0.5 - Vector2(1250.0, 1250.0), Vector2(2500.0, 2500.0)), false)


# One pine: a trunk and jagged tiers, as a single polygon.
func _pine(cx: float, base_y: float, h: float, w: float, c: Color) -> void:
	var n := 9 + int(r() * 4.0)
	var top := base_y - h
	var right: Array[Vector2] = []
	for k in range(1, n + 1):
		var t := float(k) / float(n)
		var y := top + t * h * 0.9
		var hw := w * 0.5 * pow(t, 0.85)
		right.append(Vector2(hw * (0.9 + r() * 0.2), y))
		right.append(Vector2(hw * (0.5 + r() * 0.1), y + h * 0.9 / float(n) * 0.35))
	var pts := PackedVector2Array([Vector2(cx, top)])
	for p in right:
		pts.append(Vector2(cx + p.x, p.y))
	pts.append(Vector2(cx + w * 0.05, base_y))
	pts.append(Vector2(cx - w * 0.05, base_y))
	for i in range(right.size() - 1, -1, -1):
		pts.append(Vector2(cx - right[i].x * (0.92 + r() * 0.16), right[i].y))
	_shape(pts, c)
