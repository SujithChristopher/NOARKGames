# Participant-screen art, "Night Forest" (approved mockup 2026-09-26, built
# 2026-09-28; before that "night fireflies" in yellow-green): golden fireflies
# over an ice-blue night, the Oxanium game font, rounded dark glass panels.
# Circles are drawn as radial-gradient textures, not polygons, so their edges
# stay smooth at any size. Everything here only draws; the catch zone and the
# hit test stay in table mm (table_space.gd).
# Consumers use:  const Art := preload("res://Games/firefly_reach/game_art.gd")

const INK := Color("EAF3FF")
const INK_SOFT := Color(0.86, 0.91, 1.0, 0.7)
const NAVY := Color("0B1026")
const ICE := Color("7CC4FF")
const ICE_HI := Color("BFE4FF")
const MUTED := Color("8EA4C6")
const VIOLET := Color("8C7CFF")

# The firefly: a golden light — pale core, warm body, bright gold rim.
const FF_CORE := Color("FFFBE6")
const FF_BODY := Color("FFE9A0")
const FF_MID := Color("FFD06A")
const FF_RIM := Color("FFE496")
const FF_GLOW := Color("FFCE60")

# A firefly's own light (since 2026-09-29: the target is a real-looking firefly,
# Photinus pyralis, whose lantern glows yellow-green; the UI keeps its gold).
const LAMP := Color("C9FF6A")
const LAMP_CORE := Color("F4FFE0")
const LAMP_GLOW := Color("B4FF5A")
const LAMP_OFF := Color("4A5A2A")

# Grades (calibration points): colour and word, as in osu!'s 300 / 100 / 50.
const GRADE_COL: Array = [Color("C9D1E6"), Color("D8E6FA"), Color("9FDBFF"), Color("FFE08A")]
const GRADE_WORD: Array = ["", "GOOD", "GREAT", "PERFECT"]

const GOLD := Color("FFE08A")
const GOOD := Color("6CEBAA")
const MISS := Color("8A93A8")

static var _bold: Font = null
static var _glow: GradientTexture2D = null
static var _disc: GradientTexture2D = null
static var _orb: GradientTexture2D = null


# The game font: Oxanium ExtraBold (fonts/), else Nunito ExtraBold.
static func font() -> Font:
	if _bold == null:
		var ox := "res://Games/firefly_reach/fonts/Oxanium-Variable.ttf"
		var nunito := "res://Games/firefly_reach/fonts/Nunito-ExtraBold.ttf"
		if FileAccess.file_exists(ox):
			var f := FontFile.new()
			if f.load_dynamic_font(ox) == OK:
				var v := FontVariation.new()
				v.base_font = f
				v.variation_opentype = {"weight": 800}
				v.spacing_glyph = 1
				_bold = v
		if _bold == null and FileAccess.file_exists(nunito):
			var f := FontFile.new()
			if f.load_dynamic_font(nunito) == OK:
				_bold = f
		if _bold == null:
			_bold = ThemeDB.fallback_font
	return _bold


static func _radial(offsets: Array, colors: Array) -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(offsets)
	g.colors = PackedColorArray(colors)
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	# 512 px so targets are drawn without magnifying their edges (a glow has no
	# edge, so magnifying it does not show).
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 512
	t.height = 512
	return t


# Soft light: bright centre fading to nothing.
static func glow() -> Texture2D:
	if _glow == null:
		_glow = _radial([0.0, 0.18, 0.5, 1.0],
			[Color(1, 1, 1, 1), Color(1, 1, 1, 0.55), Color(1, 1, 1, 0.14), Color(1, 1, 1, 0)])
	return _glow


# Solid disc with a thin soft edge (the texture's radius is 1.0 of fill_to).
# The edge is the last 2.5 % of the radius: ~2 px on a 150 px disc, enough to
# smooth it without the blur a wider fade gave.
static func disc() -> Texture2D:
	if _disc == null:
		_disc = _radial([0.0, 0.975, 1.0], [Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	return _disc


# The firefly's body: its edge is the catch circle.
static func orb() -> Texture2D:
	if _orb == null:
		_orb = _radial([0.0, 0.38, 0.72, 0.975, 1.0],
			[FF_CORE, FF_BODY, FF_MID, FF_RIM, Color(FF_RIM, 0.0)])
	return _orb


# A texture centred on c, size (w, h) — w != h draws the ellipse the table
# circle becomes when the screen mapping scales x and y differently.
static func blit(ci: CanvasItem, tex: Texture2D, c: Vector2, size: Vector2, col: Color = Color.WHITE) -> void:
	ci.draw_texture_rect(tex, Rect2(c - size * 0.5, size), false, col)


# A firefly seen from above, length L px, head towards `ang` + 90° (local -y),
# at c: orange shield with a black spot, dark wing covers edged pale yellow,
# see-through wings fluttering when `flying`, and the lantern at the tail,
# lit by `lamp` (0 = dark, 1 = full). The glow is drawn by the caller
# (lamp_pos) so it can sit under or over other things.
static func draw_firefly(ci: CanvasItem, c: Vector2, L: float, ang: float, lamp: float, t: float,
		flying: bool) -> void:
	var xf := Transform2D(ang, c)
	if flying:
		for s: float in [-1.0, 1.0]:
			var wing := Transform2D(ang + s * (0.9 + 0.35 * sin(t * 90.0)), c)
			_ellipse(ci, wing, Vector2(s * L * 0.05, -L * 0.25), Vector2(L * 0.13, L * 0.42), Color(0.82, 0.88, 1.0, 0.24))
	for s: float in [-1.0, 1.0]:   # wing covers, slightly open in flight
		var half := Transform2D(ang + s * (0.18 if flying else 0.0), c)
		var pts := PackedVector2Array()
		var a := Vector2(0.0, -L * 0.18)
		var p1 := Vector2(s * L * 0.22, -L * 0.14)
		var b := Vector2(s * L * 0.19, L * 0.30)
		var p2 := Vector2(s * L * 0.08, L * 0.40)
		var e := Vector2(0.0, L * 0.34)
		for i in 9:
			var u := float(i) / 8.0
			pts.append(half * a.lerp(p1, u).lerp(p1.lerp(b, u), u))
		for i in range(1, 9):
			var u := float(i) / 8.0
			pts.append(half * b.lerp(p2, u).lerp(p2.lerp(e, u), u))
		ci.draw_colored_polygon(pts, Color("2B2419"))
		var edge := pts.duplicate()
		edge.append(pts[0])
		ci.draw_polyline(edge, Color("D9C27A"), maxf(1.0, L * 0.035), true)
	_ellipse(ci, xf, Vector2(0.0, L * 0.40), Vector2(L * 0.11, L * 0.10), LAMP_OFF.lerp(LAMP, lamp))
	_ellipse(ci, xf, Vector2(0.0, -L * 0.27), Vector2(L * 0.19, L * 0.13), Color("F0D98A"))
	_ellipse(ci, xf, Vector2(0.0, -L * 0.27), Vector2(L * 0.17, L * 0.11), Color("E0714F"))
	_ellipse(ci, xf, Vector2(0.0, -L * 0.27), Vector2(L * 0.06, L * 0.08), Color("1A1410"))
	_ellipse(ci, xf, Vector2(0.0, -L * 0.42), Vector2(L * 0.07, L * 0.05), Color("1A1410"))
	for s: float in [-1.0, 1.0]:   # antennae
		var ant := PackedVector2Array()
		for i in 7:
			var u := float(i) / 6.0
			var p0 := Vector2(s * L * 0.03, -L * 0.45)
			var pc := Vector2(s * L * 0.12, -L * 0.60)
			var pe := Vector2(s * L * 0.20, -L * 0.62)
			ant.append(xf * p0.lerp(pc, u).lerp(pc.lerp(pe, u), u))
		ci.draw_polyline(ant, Color("1A1410"), maxf(1.0, L * 0.025), true)


# Where the lantern is, for its glow.
static func lamp_pos(c: Vector2, L: float, ang: float) -> Vector2:
	return Transform2D(ang, c) * Vector2(0.0, L * 0.40)


# A filled ellipse (centre and radii in xf's local space), with a 1 px
# antialiased outline in its own colour for a smooth edge.
static func _ellipse(ci: CanvasItem, xf: Transform2D, centre: Vector2, radii: Vector2, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 20:
		var a := TAU * float(i) / 20.0
		pts.append(xf * (centre + Vector2(cos(a) * radii.x, sin(a) * radii.y)))
	ci.draw_colored_polygon(pts, col)
	pts.append(pts[0])
	ci.draw_polyline(pts, col, 1.0, true)


# Text centred on pos (pos.y = the visual middle of the line); optional soft halo.
static func text(ci: CanvasItem, pos: Vector2, s: String, size: int, col: Color,
		halo: Color = Color(0, 0, 0, 0)) -> void:
	var f := font()
	var w := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var base := pos + Vector2(-w * 0.5, f.get_ascent(size) * 0.5 - f.get_descent(size) * 0.3)
	if halo.a > 0.0:
		ci.draw_string_outline(f, base, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, maxi(4, size / 4), halo)
	ci.draw_string(f, base, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


# Text starting at x = pos.x, its visual middle at pos.y.
static func text_left(ci: CanvasItem, pos: Vector2, s: String, size: int, col: Color,
		halo: Color = Color(0, 0, 0, 0)) -> void:
	text(ci, pos + Vector2(text_width(s, size) * 0.5, 0.0), s, size, col, halo)


# Text ending at x = pos.x, its visual middle at pos.y.
static func text_right(ci: CanvasItem, pos: Vector2, s: String, size: int, col: Color,
		halo: Color = Color(0, 0, 0, 0)) -> void:
	text(ci, pos - Vector2(text_width(s, size) * 0.5, 0.0), s, size, col, halo)


static func text_width(s: String, size: int) -> float:
	return font().get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


# A small diamond (points left, status): gold with a glow when on, an outline when off.
static func draw_diamond(ci: CanvasItem, c: Vector2, half: float, on: bool, col: Color = GOLD) -> void:
	var pts := PackedVector2Array([c + Vector2(0, -half), c + Vector2(half, 0), c + Vector2(0, half), c + Vector2(-half, 0)])
	if on:
		blit(ci, glow(), c, Vector2.ONE * half * 5.0, Color(col, 0.55))
		ci.draw_colored_polygon(pts, col)
	else:
		var ring := pts.duplicate()
		ring.append(pts[0])
		ci.draw_polyline(ring, Color(ICE_HI, 0.4), 1.5, true)


# A rounded bar: dim track, a glowing fill for frac of it.
static func draw_bar(ci: CanvasItem, rect: Rect2, frac: float, col: Color) -> void:
	var r := int(rect.size.y * 0.5)
	ci.draw_style_box(_box(Color(0.55, 0.75, 1.0, 0.14), r), rect)
	var f := clampf(frac, 0.0, 1.0)
	if f > 0.0:
		var fill := Rect2(rect.position, Vector2(maxf(rect.size.y, rect.size.x * f), rect.size.y))
		blit(ci, glow(), fill.get_center(), Vector2(fill.size.x * 1.1, rect.size.y * 4.0), Color(col, 0.25))
		ci.draw_style_box(_box(col, r), fill)


# A hexagon badge with rounded corners (the round number on the rest screen).
static func draw_hex(ci: CanvasItem, c: Vector2, r: float) -> void:
	var corners: Array[Vector2] = []
	for i in 6:
		corners.append(c + Vector2.from_angle(-PI * 0.5 + TAU * float(i) / 6.0) * r)
	var pts := PackedVector2Array()
	var cut := r * 0.2
	for i in 6:
		var p: Vector2 = corners[i]
		var a := p + (corners[(i + 5) % 6] - p).normalized() * cut
		var b := p + (corners[(i + 1) % 6] - p).normalized() * cut
		for s in 7:   # rounded corner: a quadratic curve through the corner
			var t := float(s) / 6.0
			pts.append(a.lerp(p, t).lerp(p.lerp(b, t), t))
	var cols := PackedColorArray()
	for p in pts:
		cols.append(Color("27437A").lerp(Color("101E3E"), clampf((p.y - c.y + r) / (2.0 * r), 0.0, 1.0)))
	blit(ci, glow(), c, Vector2.ONE * r * 3.2, Color(ICE, 0.18))
	ci.draw_polygon(pts, cols)
	var ring := pts.duplicate()
	ring.append(pts[0])
	ci.draw_polyline(ring, ICE_HI, 3.0, true)


static func _box(bg: Color, radius: int, border: Color = Color(0, 0, 0, 0), bw: int = 0,
		shadow: float = 0.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.anti_aliasing = true
	if shadow > 0.0:
		sb.shadow_size = int(shadow)
		sb.shadow_color = Color(0.0, 0.0, 0.05, 0.45)
	return sb


# Dark glass pill / panel (HUD), a thin ice edge.
static func draw_glass(ci: CanvasItem, rect: Rect2, radius: int = 16) -> void:
	ci.draw_style_box(_box(Color(0.03, 0.07, 0.16, 0.78), radius, Color(0.55, 0.75, 1.0, 0.16), 1), rect)


# Big card (complete, pause): deep night glass, ice edge, soft shadow.
static func draw_card(ci: CanvasItem, rect: Rect2) -> void:
	ci.draw_style_box(_box(Color(0.055, 0.118, 0.235, 0.92), 22, Color(0.55, 0.75, 1.0, 0.22), 1, 34.0), rect)


static func draw_pill(ci: CanvasItem, rect: Rect2, col: Color) -> void:
	ci.draw_style_box(_box(col, int(rect.size.y * 0.5)), rect)


static func star_points(c: Vector2, r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 10:
		var a := -PI * 0.5 + PI * float(i) / 5.0
		pts.append(c + Vector2(cos(a), sin(a)) * (r if i % 2 == 0 else r * 0.46))
	return pts


# A star: gold with a glow when earned, a faint outline when not.
static func draw_star(ci: CanvasItem, c: Vector2, r: float, filled: bool) -> void:
	var pts := star_points(c, r)
	var closed := pts.duplicate()
	closed.append(pts[0])
	if filled:
		blit(ci, glow(), c, Vector2(r, r) * 4.2, Color(GOLD, 0.35))
		var cols := PackedColorArray()
		for p in pts:
			cols.append(Color("FFF6C8").lerp(Color("FFC23D"), clampf((p.y - c.y + r) / (2.0 * r), 0.0, 1.0)))
		ci.draw_polygon(pts, cols)
		ci.draw_polyline(closed, Color("FFB020"), 1.5, true)
	else:
		ci.draw_colored_polygon(pts, Color(1, 1, 1, 0.06))
		ci.draw_polyline(closed, Color(1, 1, 1, 0.28), 1.5, true)
