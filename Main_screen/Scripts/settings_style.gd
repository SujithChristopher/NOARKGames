extends RefCounted
## How the Settings screen looks: one Theme for the screen and its tabs, so a tab says
## what a thing is ("Card", "Helper", "PrimaryButton") and never how it looks.
##
## It is modelled on a bedside monitor, not on the games: a quiet ground, and colour only
## where it means something. Blue is something you can press; green, amber and red say how
## a reading stands. The typeface is Atkinson Hyperlegible, drawn for low-vision readers.
##
## Sizes are in the project's 1152x648 canvas. Icons are SVGs rasterised at run time, as
## in menu_icons.gd, so there is nothing to import.
## Used as `const Style := preload("res://Main_screen/Scripts/settings_style.gd")`.

const FONT := preload("res://Assets/Fonts/AtkinsonHyperlegibleNext-Variable.ttf")

const GROUND := Color("14252e")
const RAIL := Color("0f1d25")
const CARD := Color("1b303b")
const RAISED := Color("27414f")     # a control on a card
const RAISED_HOVER := Color("315060")
const TRACK := Color("3d5a69")      # slider and scrollbar tracks, switch outlines
const LINE := Color("2c4553")       # hairlines
const WELL := Color("0a1419")       # behind a camera picture
const TEXT := Color("eaf2f4")
const MUTED := Color("a2b6bf")
const FAINT := Color("6f8591")      # disabled text
const ACCENT := Color("56bdea")
const ACCENT_HOVER := Color("7bcdf0")
const ON_ACCENT := Color("06212e")
const GOOD := Color("62d993")
const WARN := Color("f4bc52")
const DANGER := Color("f0695d")

const SIZE_BODY := 17
const SIZE_SMALL := 14
const SIZE_VALUE := 18
const SIZE_TITLE := 26
const WEIGHT_BODY := 400
const WEIGHT_STRONG := 600
const RADIUS_CARD := 10
const RADIUS_CONTROL := 8
const ICON_RASTER := 3.0            # px per canvas unit: stays sharp on a large screen

# name: [size on the canvas, size of the drawing, the drawing]. {x} are colours.
const _LINE := '<g fill="none" stroke="#ffffff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">%s</g>'
const ICONS := {
	"tracker": [22, 24, '<circle cx="12" cy="12" r="7"/><circle cx="12" cy="12" r="2.2"/><path d="M12 2.5v4M12 17.5v4M2.5 12h4M17.5 12h4"/>'],
	"camera": [22, 24, '<path d="M4 8h3l1.6-2.5h6.8L17 8h3a1.5 1.5 0 0 1 1.5 1.5v8A1.5 1.5 0 0 1 20 19H4a1.5 1.5 0 0 1-1.5-1.5v-8A1.5 1.5 0 0 1 4 8z"/><circle cx="12" cy="13" r="3.4"/>'],
	"calibration": [22, 24, '<rect x="3.5" y="3.5" width="17" height="17" rx="2"/><path d="M8 8h3v3H8zM13 13h3v3h-3zM13 8h3M8 16h3"/>'],
	"storage": [22, 24, '<rect x="3" y="4" width="18" height="7" rx="1.8"/><rect x="3" y="13" width="18" height="7" rx="1.8"/><path d="M7 7.5h.01M7 16.5h.01"/>'],
	"back": [18, 24, '<path d="M15 5l-7 7 7 7"/>'],
	"close": [16, 24, '<path d="M6 6l12 12M18 6L6 18"/>'],
}
const SHAPES := {
	"switch_on": [Vector2i(48, 28), '<rect width="48" height="28" rx="14" fill="{accent}"/><circle cx="34" cy="14" r="10.5" fill="#ffffff"/>'],
	"switch_off": [Vector2i(48, 28), '<rect x=".75" y=".75" width="46.5" height="26.5" rx="13.25" fill="{raised}" stroke="{track}" stroke-width="1.5"/><circle cx="14" cy="14" r="9.5" fill="{muted}"/>'],
	"arrow_down": [Vector2i(16, 16), '<path d="M3.5 6l4.5 4.5L12.5 6" fill="none" stroke="{muted}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>'],
	"arrow_right": [Vector2i(16, 16), '<path d="M6 3.5L10.5 8 6 12.5" fill="none" stroke="{muted}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>'],
	"box_off": [Vector2i(20, 20), '<rect x="1.5" y="1.5" width="17" height="17" rx="4.5" fill="none" stroke="{muted}" stroke-width="1.6"/>'],
	"box_on": [Vector2i(20, 20), '<rect x="1" y="1" width="18" height="18" rx="5" fill="{accent}"/><path d="M5.5 10.5l3 3 6-7" fill="none" stroke="{on_accent}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>'],
	"box_some": [Vector2i(20, 20), '<rect x="1" y="1" width="18" height="18" rx="5" fill="{accent}"/><path d="M6 10h8" fill="none" stroke="{on_accent}" stroke-width="2.2" stroke-linecap="round"/>'],
	"grabber": [Vector2i(22, 22), '<circle cx="11" cy="11" r="8.5" fill="{text}" stroke="{accent}" stroke-width="2.5"/>'],
	"grabber_hover": [Vector2i(22, 22), '<circle cx="11" cy="11" r="9.5" fill="#ffffff" stroke="{accent_hover}" stroke-width="3"/>'],
	"grabber_off": [Vector2i(22, 22), '<circle cx="11" cy="11" r="7" fill="{track}"/>'],
	"tick": [Vector2i(16, 16), '<path d="M3 8.5l3.2 3.2L13 4.5" fill="none" stroke="{accent}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>'],
	"tick_none": [Vector2i(16, 16), '<rect width="16" height="16" fill="#ffffff" fill-opacity="0"/>'],
}

static var _icons := {}     # name -> ImageTexture, built once per run


static func make_theme() -> Theme:
	var t := Theme.new()
	t.default_font = font(WEIGHT_BODY)
	t.default_font_size = SIZE_BODY
	_labels(t)
	_panels(t)
	_buttons(t)
	_pickers(t)
	_sliders(t)
	_fields(t)
	_tree(t)
	_scrollbars(t)
	_dialogs(t)
	return t


static func font(weight: int) -> FontVariation:
	var f := FontVariation.new()
	f.base_font = FONT
	f.variation_opentype = {"weight": weight}
	f.fallbacks = [ThemeDB.fallback_font]   # the typeface has no µ, and a board may have no system font to lend one
	return f


## An icon by name. The line icons are white, for a Button's icon colours to tint.
static func icon(icon_name: String) -> Texture2D:
	if _icons.has(icon_name):
		return _icons[icon_name]
	var image := Image.new()
	if image.load_svg_from_string(_icon_svg(icon_name), ICON_RASTER) != OK:
		push_error("[Settings] Bad icon: %s" % icon_name)
	image.generate_mipmaps()
	var texture := ImageTexture.create_from_image(image)
	texture.set_size_override(Vector2i(Vector2(image.get_size()) / ICON_RASTER))
	_icons[icon_name] = texture
	return texture


static func _icon_svg(icon_name: String) -> String:
	var size: Vector2i
	var view: Vector2i
	var drawing: String
	if ICONS.has(icon_name):
		var spec: Array = ICONS[icon_name]
		size = Vector2i(spec[0], spec[0])
		view = Vector2i(spec[1], spec[1])
		drawing = _LINE % spec[2]
	else:
		var spec: Array = SHAPES[icon_name]
		size = spec[0]
		view = spec[0]
		drawing = String(spec[1]).format({
			"accent": _hex(ACCENT), "accent_hover": _hex(ACCENT_HOVER), "on_accent": _hex(ON_ACCENT),
			"raised": _hex(RAISED), "track": _hex(TRACK), "muted": _hex(MUTED), "text": _hex(TEXT),
		})
	return '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">%s</svg>' % [
		size.x, size.y, view.x, view.y, drawing]


static func _hex(colour: Color) -> String:
	return "#" + colour.to_html(false)


# ── Parts a tab builds with ───────────────────────────────────────────────────

static func label(text: String, variation: String = "") -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = variation
	return l


## A label that wraps to its width: messages, help and sentences that say how things stand.
static func wrapped(text: String, variation: String = "") -> Label:
	var l := label(text, variation)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


## Takes part in a scroll: a drag that starts on a card must still scroll what it is in.
static func card(content: Control, padded: bool = true) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.theme_type_variation = "CardPadded" if padded else "Card"
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.add_child(content)
	return panel


## The small round light beside a state.
static func dot(colour: Color = MUTED) -> Panel:
	var light := Panel.new()
	light.custom_minimum_size = Vector2(10, 10)
	light.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	light.mouse_filter = Control.MOUSE_FILTER_IGNORE
	light.add_theme_stylebox_override("panel", _box(colour, 5, 0, 0))
	return light


static func set_dot(light: Panel, colour: Color) -> void:
	var box: StyleBoxFlat = light.get_theme_stylebox("panel")
	if box.bg_color != colour:
		box.bg_color = colour


## The dark ground behind a camera picture: the picture is letterboxed on it. A child of the
## picture, so showing and hiding the picture takes this along.
static func picture_well(picture: TextureRect) -> void:
	var well := Panel.new()
	well.show_behind_parent = true
	well.mouse_filter = Control.MOUSE_FILTER_IGNORE
	well.add_theme_stylebox_override("panel", _box(WELL, RADIUS_CONTROL, 0, 0))
	picture.add_child(well)
	well.set_anchors_preset(Control.PRESET_FULL_RECT)


## A stack of rows in one card, with a hairline between them.
static func add_row(rows: VBoxContainer, row: Control) -> void:
	if rows.get_child_count() > 0:
		rows.add_child(HSeparator.new())
	rows.add_child(row)


# ── The theme ─────────────────────────────────────────────────────────────────

static func _box(bg: Color, radius: int = RADIUS_CONTROL, pad_x: int = 14, pad_y: int = 8,
		border: Color = Color.TRANSPARENT) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.corner_detail = 8
	sb.content_margin_left = pad_x
	sb.content_margin_right = pad_x
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y
	if border.a > 0.0:
		sb.set_border_width_all(1)
		sb.border_color = border
	return sb


static func _empty(pad_x: int = 0, pad_y: int = 0) -> StyleBoxEmpty:
	var sb := StyleBoxEmpty.new()
	sb.content_margin_left = pad_x
	sb.content_margin_right = pad_x
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y
	return sb


static func _label_type(t: Theme, type: String, size: int, colour: Color, weight: int) -> void:
	t.set_type_variation(type, "Label")
	t.set_font_size("font_size", type, size)
	t.set_color("font_color", type, colour)
	if weight != WEIGHT_BODY:
		t.set_font("font", type, font(weight))


static func _labels(t: Theme) -> void:
	t.set_color("font_color", "Label", TEXT)
	_label_type(t, "Helper", SIZE_SMALL, MUTED, WEIGHT_BODY)
	_label_type(t, "TableHead", SIZE_SMALL, MUTED, WEIGHT_BODY)
	_label_type(t, "SectionTitle", SIZE_BODY, MUTED, WEIGHT_STRONG)
	_label_type(t, "Value", SIZE_VALUE, TEXT, WEIGHT_STRONG)
	_label_type(t, "Title", SIZE_TITLE, TEXT, WEIGHT_STRONG)


static func _panels(t: Theme) -> void:
	t.set_type_variation("Card", "PanelContainer")
	t.set_stylebox("panel", "Card", _box(CARD, RADIUS_CARD, 0, 0))
	t.set_type_variation("CardPadded", "PanelContainer")
	t.set_stylebox("panel", "CardPadded", _box(CARD, RADIUS_CARD, 16, 12))
	var rail := _box(RAIL, 0, 12, 16)
	rail.border_width_right = 1
	rail.border_color = LINE
	t.set_type_variation("Rail", "PanelContainer")
	t.set_stylebox("panel", "Rail", rail)
	t.set_stylebox("panel", "TabContainer", _empty())
	var line := StyleBoxLine.new()
	line.color = LINE
	line.thickness = 1
	t.set_stylebox("separator", "HSeparator", line)
	t.set_constant("separation", "HSeparator", 1)


# Every state of a button: its boxes and the colour of its words and icon.
static func _button_type(t: Theme, type: String, normal: StyleBox, hover: StyleBox, pressed: StyleBox,
		disabled: StyleBox, colour: Color, hover_colour: Color, pressed_colour: Color) -> void:
	if type != "Button":
		t.set_type_variation(type, "Button")
	t.set_stylebox("normal", type, normal)
	t.set_stylebox("hover", type, hover)
	t.set_stylebox("pressed", type, pressed)
	t.set_stylebox("hover_pressed", type, pressed)
	t.set_stylebox("disabled", type, disabled)
	t.set_stylebox("focus", type, _empty())
	for item in ["font_color", "font_focus_color", "icon_normal_color", "icon_focus_color"]:
		t.set_color(item, type, colour)
	for item in ["font_hover_color", "icon_hover_color"]:
		t.set_color(item, type, hover_colour)
	for item in ["font_pressed_color", "font_hover_pressed_color", "icon_pressed_color", "icon_hover_pressed_color"]:
		t.set_color(item, type, pressed_colour)
	for item in ["font_disabled_color", "icon_disabled_color"]:
		t.set_color(item, type, FAINT)


static func _buttons(t: Theme) -> void:
	t.set_constant("h_separation", "Button", 10)
	_button_type(t, "Button", _box(RAISED), _box(RAISED_HOVER), _box(TRACK), _box(Color(RAISED, 0.45)),
		TEXT, TEXT, TEXT)

	var strong := font(WEIGHT_STRONG)
	_button_type(t, "PrimaryButton", _box(ACCENT), _box(ACCENT_HOVER), _box(ACCENT.darkened(0.12)),
		_box(Color(RAISED, 0.45)), ON_ACCENT, ON_ACCENT, ON_ACCENT)
	t.set_font("font", "PrimaryButton", strong)

	# Quiet until it has something to delete, and then not something to press by accident.
	_button_type(t, "DangerButton", _box(Color.TRANSPARENT, RADIUS_CONTROL, 14, 8, DANGER),
		_box(Color(DANGER, 0.16), RADIUS_CONTROL, 14, 8, DANGER), _box(Color(DANGER, 0.3), RADIUS_CONTROL, 14, 8, DANGER),
		_box(Color.TRANSPARENT, RADIUS_CONTROL, 14, 8, LINE), DANGER, DANGER.lightened(0.2), TEXT)
	t.set_font("font", "DangerButton", strong)

	_button_type(t, "QuietButton", _empty(10, 8), _box(Color(TEXT, 0.07), RADIUS_CONTROL, 10, 8),
		_box(Color(TEXT, 0.12), RADIUS_CONTROL, 10, 8), _empty(10, 8), MUTED, TEXT, TEXT)
	t.set_constant("h_separation", "QuietButton", 4)

	# The rail: the tab in view is tinted, its icon in the accent.
	_button_type(t, "NavButton", _empty(12, 11), _box(Color(TEXT, 0.06), RADIUS_CONTROL, 12, 11),
		_box(Color(ACCENT, 0.16), RADIUS_CONTROL, 12, 11), _empty(12, 11), MUTED, TEXT, TEXT)
	t.set_color("icon_pressed_color", "NavButton", ACCENT)
	t.set_color("icon_hover_pressed_color", "NavButton", ACCENT)
	t.set_constant("h_separation", "NavButton", 12)


static func _pickers(t: Theme) -> void:
	# A switch is its picture: no box behind it.
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		t.set_stylebox(state, "CheckButton", _empty())
	t.set_icon("checked", "CheckButton", icon("switch_on"))
	t.set_icon("unchecked", "CheckButton", icon("switch_off"))
	t.set_icon("checked_disabled", "CheckButton", icon("switch_on"))
	t.set_icon("unchecked_disabled", "CheckButton", icon("switch_off"))

	t.set_icon("arrow", "OptionButton", icon("arrow_down"))
	t.set_constant("arrow_margin", "OptionButton", 12)
	t.set_constant("modulate_arrow", "OptionButton", 0)

	var panel := _box(RAISED, RADIUS_CARD, 6, 6, TRACK)
	panel.shadow_color = Color(0, 0, 0, 0.4)
	panel.shadow_size = 12
	panel.shadow_offset = Vector2(0, 4)
	t.set_stylebox("panel", "PopupMenu", panel)
	t.set_stylebox("hover", "PopupMenu", _box(Color(ACCENT, 0.2), 6, 8, 4))
	t.set_color("font_color", "PopupMenu", TEXT)
	t.set_color("font_hover_color", "PopupMenu", TEXT)
	t.set_constant("v_separation", "PopupMenu", 12)
	t.set_constant("h_separation", "PopupMenu", 10)
	t.set_constant("item_start_padding", "PopupMenu", 10)
	t.set_constant("item_end_padding", "PopupMenu", 14)
	t.set_icon("radio_checked", "PopupMenu", icon("tick"))
	t.set_icon("radio_unchecked", "PopupMenu", icon("tick_none"))


static func _sliders(t: Theme) -> void:
	var track := _box(TRACK, 3, 0, 3)
	var filled := _box(ACCENT, 3, 0, 3)
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", filled)
	t.set_stylebox("grabber_area_highlight", "HSlider", filled)
	t.set_icon("grabber", "HSlider", icon("grabber"))
	t.set_icon("grabber_highlight", "HSlider", icon("grabber_hover"))
	t.set_icon("grabber_disabled", "HSlider", icon("grabber_off"))

	t.set_stylebox("background", "ProgressBar", _box(TRACK, 5, 0, 0))
	t.set_stylebox("fill", "ProgressBar", _box(ACCENT, 5, 0, 0))


static func _fields(t: Theme) -> void:
	t.set_stylebox("normal", "LineEdit", _box(RAISED, RADIUS_CONTROL, 12, 8, TRACK))
	t.set_stylebox("focus", "LineEdit", _box(Color.TRANSPARENT, RADIUS_CONTROL, 12, 8, ACCENT))
	t.set_stylebox("read_only", "LineEdit", _box(CARD, RADIUS_CONTROL, 12, 8, LINE))
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_placeholder_color", "LineEdit", FAINT)
	t.set_color("caret_color", "LineEdit", ACCENT)
	t.set_color("selection_color", "LineEdit", Color(ACCENT, 0.35))


static func _tree(t: Theme) -> void:
	t.set_stylebox("panel", "Tree", _box(CARD, RADIUS_CARD, 8, 8))
	t.set_stylebox("focus", "Tree", _empty())
	for state in ["selected", "selected_focus"]:
		t.set_stylebox(state, "Tree", _box(Color(TEXT, 0.05), 6, 0, 0))
	for state in ["cursor", "cursor_unfocused"]:
		t.set_stylebox(state, "Tree", _empty())
	# The column titles sit on the card: words, not buttons, since they do nothing.
	for state in ["title_button_normal", "title_button_hover", "title_button_pressed"]:
		t.set_stylebox(state, "Tree", _empty(8, 6))
	t.set_font("title_button_font", "Tree", font(WEIGHT_BODY))
	t.set_font_size("title_button_font_size", "Tree", SIZE_SMALL)
	t.set_color("title_button_color", "Tree", MUTED)
	t.set_color("font_color", "Tree", TEXT)
	t.set_color("font_selected_color", "Tree", TEXT)
	t.set_color("font_disabled_color", "Tree", MUTED)
	t.set_constant("v_separation", "Tree", 10)
	t.set_constant("h_separation", "Tree", 8)
	t.set_constant("item_margin", "Tree", 22)
	t.set_constant("inner_item_margin_left", "Tree", 8)
	t.set_constant("inner_item_margin_right", "Tree", 8)
	t.set_constant("draw_guides", "Tree", 0)
	t.set_constant("draw_relationship_lines", "Tree", 0)
	t.set_icon("arrow", "Tree", icon("arrow_down"))
	t.set_icon("arrow_collapsed", "Tree", icon("arrow_right"))
	t.set_icon("arrow_collapsed_mirrored", "Tree", icon("arrow_right"))
	t.set_icon("checked", "Tree", icon("box_on"))
	t.set_icon("unchecked", "Tree", icon("box_off"))
	t.set_icon("indeterminate", "Tree", icon("box_some"))
	t.set_icon("checked_disabled", "Tree", icon("box_on"))
	t.set_icon("unchecked_disabled", "Tree", icon("box_off"))
	t.set_icon("indeterminate_disabled", "Tree", icon("box_some"))


static func _scrollbars(t: Theme) -> void:
	var track := _box(Color(TRACK, 0.25), 4, 4, 4)
	var grabber := _box(TRACK, 4, 4, 4)
	var hover := _box(MUTED, 4, 4, 4)
	for type in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", type, track)
		t.set_stylebox("scroll_focus", type, track)
		t.set_stylebox("grabber", type, grabber)
		t.set_stylebox("grabber_highlight", type, hover)
		t.set_stylebox("grabber_pressed", type, hover)


static func _dialogs(t: Theme) -> void:
	var title_height := 44
	var frame := _box(CARD, RADIUS_CARD, 0, 0, TRACK)
	frame.expand_margin_left = 10
	frame.expand_margin_right = 10
	frame.expand_margin_bottom = 10
	frame.expand_margin_top = title_height
	frame.shadow_color = Color(0, 0, 0, 0.45)
	frame.shadow_size = 18
	frame.shadow_offset = Vector2(0, 6)
	t.set_stylebox("embedded_border", "Window", frame)
	t.set_stylebox("embedded_unfocused_border", "Window", frame)
	t.set_constant("title_height", "Window", title_height)
	t.set_font("title_font", "Window", font(WEIGHT_STRONG))
	t.set_font_size("title_font_size", "Window", SIZE_VALUE)
	t.set_color("title_color", "Window", TEXT)
	t.set_icon("close", "Window", icon("close"))
	t.set_icon("close_pressed", "Window", icon("close"))
	t.set_constant("close_h_offset", "Window", 26)
	t.set_constant("close_v_offset", "Window", 30)
	var dialog := _box(CARD, 0, 10, 6)
	dialog.set_expand_margin_all(2)   # or the window's grey clear colour shows along an edge on a scaled screen
	t.set_stylebox("panel", "AcceptDialog", dialog)
	t.set_constant("buttons_separation", "AcceptDialog", 10)
	t.set_constant("buttons_min_height", "AcceptDialog", 40)
	t.set_constant("buttons_min_width", "AcceptDialog", 110)
