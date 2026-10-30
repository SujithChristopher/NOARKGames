extends RefCounted
## Chunky game-menu buttons: a coloured face on a darker lip that the face sinks
## into when pressed, a glossy highlight, a soft drop shadow and a small bounce
## on hover. `GameButton.apply(button, color)` restyles a Button already in a
## scene, so layouts stay in the .tscn. Used as
## `const GameButton := preload("res://Main_screen/Scripts/game_button.gd")`.

const FONT := preload("res://Assets/Fonts/Bungee-Regular.ttf")
const RADIUS := 18
const LIP := 8            # px of lip under the face
const PRESSED_LIP := 2
const PAD := 8
const HOVER_SCALE := 1.04

const GREEN := Color("41b94f")
const BLUE := Color("2f8fe0")
const ORANGE := Color("f0941c")
const PURPLE := Color("8a5bd6")
const RED := Color("e0464a")
const TEAL := Color("1c9e93")
const PINK := Color("e0559a")
const SLATE := Color("5a6e94")   # tools and navigation, so games stand out


static func apply(button: Button, color: Color, font_size: int = 24) -> void:
	button.add_theme_stylebox_override("normal", _face(color, LIP))
	button.add_theme_stylebox_override("hover", _face(color.lightened(0.12), LIP))
	button.add_theme_stylebox_override("pressed", _face(color.darkened(0.05), PRESSED_LIP))
	button.add_theme_stylebox_override("hover_pressed", _face(color, PRESSED_LIP))
	button.add_theme_stylebox_override("disabled", _face(Color(0.55, 0.57, 0.6), LIP))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	button.add_theme_font_override("font", FONT)
	button.add_theme_font_size_override("font_size", font_size)
	for state in ["font_color", "font_hover_color", "font_pressed_color",
			"font_hover_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(state, Color.WHITE)
	button.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.75))
	button.add_theme_color_override("font_outline_color", color.darkened(0.55))
	button.add_theme_constant_override("outline_size", max(4, font_size / 4))

	_add_shine(button)
	_add_bounce(button)


## Face and lip. The lip is the bottom border; pressed, it shrinks and the face
## moves down by as much, with the text, so the button looks pushed in.
static func _face(color: Color, lip: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	var sink := LIP - lip
	sb.bg_color = color
	sb.border_color = color.darkened(0.42)
	sb.border_width_bottom = lip
	sb.set_corner_radius_all(RADIUS)
	sb.corner_detail = 10
	sb.expand_margin_top = -sink
	sb.shadow_color = Color(0, 0, 0, 0.35 if lip == LIP else 0.2)
	sb.shadow_size = 6 if lip == LIP else 3
	sb.shadow_offset = Vector2(0, 4 if lip == LIP else 1)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = PAD + sink
	sb.content_margin_bottom = PAD + lip
	sb.anti_aliasing = true
	return sb


## A pale band over the top of the face, the gloss of a candy button. It moves
## with the face when pressed and never takes input.
static func _add_shine(button: Button) -> void:
	var shine := Panel.new()
	shine.name = "Shine"
	shine.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.22)
	sb.set_corner_radius_all(RADIUS - 6)
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	shine.add_theme_stylebox_override("panel", sb)
	button.add_child(shine)
	var place := func() -> void:
		var sink := LIP - PRESSED_LIP if button.button_pressed or _held(button) else 0
		var face_h := button.size.y - LIP
		shine.position = Vector2(10, 4 + sink)
		shine.size = Vector2(max(0.0, button.size.x - 20), min(face_h * 0.38, 40.0))
	button.resized.connect(place)
	button.button_down.connect(func(): button.set_meta("held", true); place.call())
	button.button_up.connect(func(): button.set_meta("held", false); place.call())
	place.call_deferred()


static func _held(button: Button) -> bool:
	return button.get_meta("held", false)


## Grow a little under the pointer, settle back when it leaves.
static func _add_bounce(button: Button) -> void:
	var centre := func() -> void: button.pivot_offset = button.size / 2
	button.resized.connect(centre)
	centre.call_deferred()
	var to := func(s: float) -> void:
		if button.disabled:
			s = 1.0
		var t := button.create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		t.tween_property(button, "scale", Vector2(s, s), 0.18)
	button.mouse_entered.connect(to.bind(HOVER_SCALE))
	button.mouse_exited.connect(to.bind(1.0))


## The patient box to match: rounded, dark glass, a bright rim when focused.
static func style_line_edit(edit: LineEdit, font_size: int = 22) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.06, 0.12, 0.08, 0.72)
	normal.set_border_width_all(3)
	normal.border_color = Color(1, 1, 1, 0.35)
	normal.set_corner_radius_all(RADIUS)
	normal.content_margin_left = 22
	normal.content_margin_right = 22
	normal.shadow_color = Color(0, 0, 0, 0.3)
	normal.shadow_size = 6
	normal.shadow_offset = Vector2(0, 3)
	var focus: StyleBoxFlat = normal.duplicate()
	focus.border_color = Color("ffd54a")
	edit.add_theme_stylebox_override("normal", normal)
	edit.add_theme_stylebox_override("focus", focus)
	edit.add_theme_font_override("font", FONT)
	edit.add_theme_font_size_override("font_size", font_size)
	edit.add_theme_color_override("font_color", Color.WHITE)
	edit.add_theme_color_override("font_placeholder_color", Color(1, 1, 1, 0.5))
	edit.add_theme_color_override("caret_color", Color("ffd54a"))


## The cards a menu is laid out on: rounded dark glass, so the background shows
## through without fighting the buttons on it. Small radius and pad make a chip.
static func style_card(panel: PanelContainer, radius: int = 24, pad: int = 20,
		opacity: float = 0.55) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.07, 0.12, opacity)
	sb.set_border_width_all(2)
	sb.border_color = Color(1, 1, 1, 0.18)
	sb.set_corner_radius_all(radius)
	sb.corner_detail = 10
	sb.set_content_margin_all(pad)
	sb.shadow_color = Color(0, 0, 0, 0.25)
	sb.shadow_size = 8
	sb.shadow_offset = Vector2(0, 4)
	sb.anti_aliasing = true
	panel.add_theme_stylebox_override("panel", sb)


## A picture on the button: above the text on a tile, before it on a wide
## button. It scales with the button, up to max_width.
static func set_icon(button: Button, icon: Texture2D, above_text: bool, max_width: int = 0) -> void:
	button.icon = icon
	button.expand_icon = true
	button.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	if above_text:
		button.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
		button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		# The gloss would wash out the top of the picture.
		var shine := button.get_node_or_null("Shine")
		if shine:
			shine.modulate.a = 0.45
	else:
		button.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.add_theme_constant_override("h_separation", 12)
	if max_width > 0:
		button.add_theme_constant_override("icon_max_width", max_width)


## Titles and chips in the buttons' font, white on a dark outline.
static func style_label(label: Label, font_size: int = 22) -> void:
	label.add_theme_font_override("font", FONT)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	label.add_theme_constant_override("outline_size", max(4, font_size / 4))
