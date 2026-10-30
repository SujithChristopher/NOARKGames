extends RefCounted
## Small, cheap feedback effects shared by the games: a burst of soft particles,
## a word that floats up and fades, a pulse on a HUD item, outlined text and a
## dim backdrop for a panel. Nothing here flashes faster than a few times a
## second. Used as `const GameFx := preload("res://Main_screen/Scripts/game_fx.gd")`.

const FONT := preload("res://Assets/Fonts/Bungee-Regular.ttf")
const GOLD := Color(1.0, 0.84, 0.3)
const FX_Z := 20

static var _dot: Texture2D
static var _shrunk := {}


## A soft round dot, white in the middle fading to clear: the particle sprite.
static func soft_dot() -> Texture2D:
	if _dot == null:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
		g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.85), Color(1, 1, 1, 0)])
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(1.0, 0.5)
		t.width = 32
		t.height = 32
		_dot = t
	return _dot


## A big sprite cut to what is drawn and shrunk so its long side is `longest`
## px, with mipmaps (draw it with TEXTURE_FILTER_LINEAR_WITH_MIPMAPS). Sprites
## imported without mipmaps shimmer when drawn small and moving. Built once per
## texture and size, then kept.
static func shrink(texture: Texture2D, longest: int) -> Texture2D:
	var key := "%s@%d" % [texture.resource_path, longest]
	if not _shrunk.has(key):
		var img := texture.get_image()
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGBA8)
		img = img.get_region(img.get_used_rect())
		var scale := float(longest) / maxi(img.get_width(), img.get_height())
		img.resize(maxi(1, roundi(img.get_width() * scale)),
				maxi(1, roundi(img.get_height() * scale)), Image.INTERPOLATE_LANCZOS)
		img.generate_mipmaps()
		_shrunk[key] = ImageTexture.create_from_image(img)
	return _shrunk[key]


## One-shot burst at a global position, under `parent` (usually the scene root),
## freed when done. `colors` are picked from at random per particle.
static func burst(parent: Node, at: Vector2, colors: Array, amount := 22,
		speed := 220.0, size := 0.45, gravity := 260.0, z := FX_Z) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var p := CPUParticles2D.new()
	p.texture = soft_dot()
	p.one_shot = true
	p.explosiveness = 0.95
	p.amount = amount
	p.lifetime = 0.7
	p.local_coords = false
	p.direction = Vector2.UP
	p.spread = 180.0
	p.initial_velocity_min = speed * 0.45
	p.initial_velocity_max = speed
	p.damping_min = speed * 0.6
	p.damping_max = speed * 0.9
	p.gravity = Vector2(0, gravity)
	p.scale_amount_min = size * 0.6
	p.scale_amount_max = size * 1.2
	p.scale_amount_curve = _fade_curve()
	# Each particle starts as one of `colors`, each colour an equal share.
	var ramp := Gradient.new()
	var offsets := PackedFloat32Array()
	for i in colors.size():
		offsets.append(float(i) / colors.size())
	ramp.offsets = offsets
	ramp.colors = PackedColorArray(colors)
	ramp.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CONSTANT
	p.color_initial_ramp = ramp
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.6, 1.0])
	fade.colors = PackedColorArray([Color.WHITE, Color(1, 1, 1, 0.8), Color(1, 1, 1, 0)])
	p.color_ramp = fade
	p.z_index = z
	p.z_as_relative = false
	parent.add_child(p)
	p.global_position = at
	p.emitting = true
	parent.get_tree().create_timer(p.lifetime + 0.3).timeout.connect(p.queue_free)


## A word that rises from a global position and fades out.
static func float_text(parent: Node, at: Vector2, text: String,
		color := GOLD, font_size := 34) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var l := Label.new()
	l.text = text
	l.label_settings = text_style(font_size, color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.size = Vector2(300, font_size * 1.6)
	l.pivot_offset = l.size / 2
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.z_index = FX_Z + 1
	l.z_as_relative = false
	parent.add_child(l)
	l.global_position = at - l.size / 2
	l.scale = Vector2(0.4, 0.4)
	var tw := l.create_tween()
	tw.tween_property(l, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(l, "position:y", l.position.y - 70, 0.9).set_ease(Tween.EASE_OUT)
	tw.tween_property(l, "modulate:a", 0.0, 0.3)
	tw.tween_callback(l.queue_free)


## A quick grow-and-settle on a HUD item, about its centre.
static func pop(item: CanvasItem, amount := 1.22) -> void:
	if item == null:
		return
	if item is Control:
		item.pivot_offset = item.size / 2
	var tw := item.create_tween()
	tw.tween_property(item, "scale", Vector2.ONE * amount, 0.08)
	tw.tween_property(item, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## Bungee in `color` with a dark outline and a soft shadow, readable on anything.
static func text_style(font_size: int, color := Color.WHITE) -> LabelSettings:
	var s := LabelSettings.new()
	s.font = FONT
	s.font_size = font_size
	s.font_color = color
	s.outline_size = maxi(4, font_size / 5)
	s.outline_color = Color(0.1, 0.07, 0.05, 0.85)
	s.shadow_color = Color(0, 0, 0, 0.3)
	s.shadow_offset = Vector2(0, 3)
	s.shadow_size = 2
	return s


## Outline an existing label without touching its font or size.
static func outline(label: Label, size := 6, color := Color(0.1, 0.07, 0.05, 0.85)) -> void:
	label.add_theme_color_override("font_outline_color", color)
	label.add_theme_constant_override("outline_size", size)


## Darkens the whole screen behind `panel` while it is shown. The backdrop is
## a child drawn behind the panel, so it shows and hides with it and lets clicks
## through. The panel is raised over the game's sprites (which sit at z 1-2).
static func dim_behind(panel: Control, alpha := 0.45) -> void:
	panel.z_index = maxi(panel.z_index, 10)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.06, alpha)
	dim.show_behind_parent = true
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(dim)
	var screen := panel.get_viewport_rect().size
	dim.position = -panel.position - Vector2(60, 60)
	dim.size = screen + Vector2(120, 120)


static func _fade_curve() -> Curve:
	var c := Curve.new()
	c.add_point(Vector2(0, 0.6))
	c.add_point(Vector2(0.2, 1.0))
	c.add_point(Vector2(1, 0.0))
	return c
