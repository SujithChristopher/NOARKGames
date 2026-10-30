extends RefCounted
## Pictures for the menu buttons, so a game is found by its look before its
## name is read. A game with sprites of its own shows one; the games drawn in
## code (Firefly Reach, Cannon Defense, Ping Pong) and the tools get an SVG
## drawn here. SVGs are rasterised at run time (Image.load_svg_from_string),
## so there is nothing to import. Each texture is built once per run and kept.
## Used as `const MenuIcons := preload("res://Main_screen/Scripts/menu_icons.gd")`.

const SIZE := 192   # px on the long side; mipmaps take it down to button size

const RANDOM_REACH := "res://Games/random_reach/Sprites/jet.png"
const FLY_THROUGH := "res://Assets/Plane/Fly (1).png"
const FRUIT_CATCHER := "res://Games/fruit_catcher/assets/fruits/strawberry.png"
const JUMPIFY := "res://Games/Jumpify/Assets/Spritesheet/platformerPack_character.png"
const JUMPIFY_FRAME := Rect2i(0, 0, 96, 96)

const SVGS := {
	# A firefly with its lamp lit, as in Firefly Reach.
	"firefly": """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
<defs><radialGradient id="g"><stop offset="0" stop-color="#F4FFE0"/>
<stop offset="0.35" stop-color="#C9FF6A" stop-opacity="0.85"/>
<stop offset="1" stop-color="#B4FF5A" stop-opacity="0"/></radialGradient></defs>
<circle cx="90" cy="76" r="38" fill="url(#g)"/>
<ellipse cx="58" cy="46" rx="12" ry="24" transform="rotate(-28 58 46)" fill="#ffffff" fill-opacity="0.85" stroke="#2b2d42" stroke-width="4"/>
<ellipse cx="76" cy="46" rx="12" ry="24" transform="rotate(22 76 46)" fill="#ffffff" fill-opacity="0.85" stroke="#2b2d42" stroke-width="4"/>
<ellipse cx="64" cy="74" rx="30" ry="15" fill="#4a3b2e" stroke="#2b2d42" stroke-width="4"/>
<ellipse cx="90" cy="76" rx="14" ry="13" fill="#E8FF8A" stroke="#2b2d42" stroke-width="4"/>
<circle cx="40" cy="72" r="13" fill="#E8613C" stroke="#2b2d42" stroke-width="4"/>
<circle cx="27" cy="74" r="9" fill="#2b2d42"/>
<circle cx="24" cy="72" r="2.5" fill="#ffffff"/>
<path d="M26 66 Q20 52 8 48 M32 64 Q32 48 24 40" fill="none" stroke="#2b2d42" stroke-width="4" stroke-linecap="round"/>
</svg>""",
	# The cannon aimed at a falling meteor, as in Cannon Defense.
	"cannon": """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
<path d="M90 34 L122 2 L127 10 L98 44 Z" fill="#FFB347" fill-opacity="0.85"/>
<circle cx="94" cy="38" r="13" fill="#9C5B3B" stroke="#2b2d42" stroke-width="4"/>
<circle cx="90" cy="34" r="4" fill="#C47A52"/>
<g transform="translate(52 82) rotate(-42)">
<rect x="-8" y="-15" width="60" height="30" rx="8" fill="#6B7487" stroke="#2b2d42" stroke-width="5"/>
<rect x="46" y="-19" width="13" height="38" rx="4" fill="#565E70" stroke="#2b2d42" stroke-width="5"/>
</g>
<circle cx="46" cy="96" r="22" fill="#B06D35" stroke="#2b2d42" stroke-width="5"/>
<path d="M46 76 V116 M26 96 H66 M32 82 L60 110 M60 82 L32 110" stroke="#7A4A22" stroke-width="4"/>
<circle cx="46" cy="96" r="7" fill="#2b2d42"/>
</svg>""",
	# A bat and ball, as in Ping Pong.
	"pingpong": """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
<g transform="translate(52 56) rotate(-35)">
<rect x="-10" y="24" width="20" height="46" rx="8" fill="#C68B59" stroke="#2b2d42" stroke-width="5"/>
<circle cx="0" cy="-4" r="36" fill="#E63946" stroke="#2b2d42" stroke-width="5"/>
<path d="M-22 -22 A28 28 0 0 1 8 -30" fill="none" stroke="#ffffff" stroke-opacity="0.45" stroke-width="6" stroke-linecap="round"/>
</g>
<path d="M76 16 L64 10 M82 30 L68 30" stroke="#ffffff" stroke-width="5" stroke-linecap="round"/>
<circle cx="100" cy="24" r="13" fill="#FFF4E0" stroke="#2b2d42" stroke-width="4"/>
</svg>""",
	# Reach scan: a target.
	"assessment": """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" fill="none" stroke="#ffffff" stroke-width="9" stroke-linecap="round">
<circle cx="64" cy="64" r="44"/><circle cx="64" cy="64" r="22"/>
<circle cx="64" cy="64" r="6" fill="#ffffff" stroke="none"/>
<path d="M64 6 V24 M64 104 V122 M6 64 H24 M104 64 H122"/>
</svg>""",
	# Results: a bar chart.
	"results": """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" fill="#ffffff">
<rect x="18" y="70" width="22" height="42" rx="5"/>
<rect x="53" y="46" width="22" height="66" rx="5"/>
<rect x="88" y="20" width="22" height="92" rx="5"/>
</svg>""",
	# Trunk angles: a trunk leaning from the upright, the angle marked.
	"trunk": """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" fill="none" stroke-linecap="round">
<path d="M64 108 V22" stroke="#ffffff" stroke-opacity="0.5" stroke-width="5" stroke-dasharray="8 8"/>
<path d="M64 108 L90 46" stroke="#ffffff" stroke-width="13"/>
<circle cx="97" cy="28" r="13" fill="#ffffff"/>
<path d="M40 110 H88" stroke="#ffffff" stroke-width="9"/>
<path d="M64 70 A38 38 0 0 1 78 73" stroke="#FFD54A" stroke-width="7"/>
</svg>""",
	"logout": """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" fill="none" stroke="#ffffff" stroke-width="10" stroke-linecap="round" stroke-linejoin="round">
<path d="M58 16 H22 V112 H58"/><path d="M50 64 H112 M90 42 L112 64 L90 86"/>
</svg>""",
	"power": """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" fill="none" stroke="#ffffff" stroke-width="11" stroke-linecap="round">
<path d="M42 32 A40 40 0 1 0 86 32"/><path d="M64 12 V60"/>
</svg>""",
	# 2D: flat shapes on a sheet.
	"flat": """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
<rect x="14" y="22" width="100" height="84" rx="12" fill="#ffffff" fill-opacity="0.3" stroke="#ffffff" stroke-width="7"/>
<circle cx="46" cy="64" r="18" fill="#ffffff"/>
<path d="M70 82 L86 46 L102 82 Z" fill="#ffffff"/>
</svg>""",
	# 3D: a cube.
	"cube": """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" stroke="#ffffff" stroke-width="5" stroke-linejoin="round">
<path d="M64 14 L110 38 L64 62 L18 38 Z" fill="#ffffff"/>
<path d="M18 38 L64 62 V114 L18 90 Z" fill="#ffffff" fill-opacity="0.7"/>
<path d="M110 38 L64 62 V114 L110 90 Z" fill="#ffffff" fill-opacity="0.4"/>
</svg>""",
}

static var _cache := {}


## One of SVGS by name.
static func svg(name: String) -> Texture2D:
	if not _cache.has(name):
		var img := Image.new()
		img.load_svg_from_string(SVGS[name], SIZE / 128.0)
		_cache[name] = _texture(img)
	return _cache[name]


## A game sprite (one frame of a sheet with region), trimmed to what is drawn,
## shrunk and centred on a square, so every tile's picture takes the same room
## and the names line up. Shrunk here because the sprites are imported without
## mipmaps: at button size the full-size image would shimmer.
static func art(path: String, region := Rect2i()) -> Texture2D:
	if not _cache.has(path):
		var img: Image = load(path).get_image()
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGBA8)
		if region.has_area():
			img = img.get_region(region)
		img = img.get_region(img.get_used_rect())
		var scale := float(SIZE) / maxi(img.get_width(), img.get_height())
		img.resize(maxi(1, roundi(img.get_width() * scale)),
				maxi(1, roundi(img.get_height() * scale)), Image.INTERPOLATE_LANCZOS)
		var square := Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RGBA8)
		square.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), (Vector2i(SIZE, SIZE) - img.get_size()) / 2)
		_cache[path] = _texture(square)
	return _cache[path]


static func _texture(img: Image) -> Texture2D:
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
