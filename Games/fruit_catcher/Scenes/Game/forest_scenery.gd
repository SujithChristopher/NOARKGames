extends Node2D
## Fruit Catcher scenery over the forest picture: shafts of sunlight through
## the canopy, specks of light drifting in them, a shadow under the basket and
## one under the falling fruit that firms up as it nears the ground. It also
## dresses the basket (a sharp, shrunk copy of its picture, standing on the
## bottom edge) and squashes it when a fruit lands in it (bounce_basket).
## Decoration only: the basket's and the fruit's collision, speed and timing
## are the game's own.

const GameFx := preload("res://Main_screen/Scripts/game_fx.gd")
const BASKET := preload("res://Games/fruit_catcher/assets/fruit_basket.png")
const BASKET_WIDTH := 172.0
const BASE_Y := 31.0     # basket's base under the paddle's origin (paddle y 615 -> 646)
const GROUND_Y := 640.0
const SHADOW := Color(0.06, 0.03, 0.0)

var _game: Node2D
var _paddle: Area2D
var _basket: Sprite2D
var _basket_scale: Vector2


func _ready() -> void:
	_game = get_parent()
	_game.move_child(self, _game.get_node("Sprite2D").get_index() + 1)
	_paddle = _game.get_node("Paddle")
	_dress_basket()
	var beams := Sunbeams.new()
	beams.material = _additive()
	add_child(beams)
	add_child(_motes())


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	_shadow(Vector2(_paddle.position.x + 3, GROUND_Y), 92.0, 0.38)
	var gem = _game.current_gem
	if gem and is_instance_valid(gem) and not gem.is_collected:
		var near := clampf(gem.position.y / GROUND_Y, 0.0, 1.0)
		_shadow(Vector2(gem.position.x, GROUND_Y), lerpf(12.0, 34.0, near), lerpf(0.05, 0.4, near))


## A quick squash and stretch as a fruit lands, about the basket's base.
func bounce_basket() -> void:
	var tw := _basket.create_tween()
	tw.tween_property(_basket, "scale", _basket_scale * Vector2(1.08, 0.88), 0.07)
	tw.tween_property(_basket, "scale", _basket_scale, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _dress_basket() -> void:
	_basket = _paddle.get_node("Sprite2D")
	_basket.texture = GameFx.shrink(BASKET, int(BASKET_WIDTH * 2))
	_basket.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var s := BASKET_WIDTH / _basket.texture.get_width()
	_basket_scale = Vector2(s, s)
	_basket.scale = _basket_scale
	# Origin on the base, so the squash keeps it standing on the ground.
	_basket.offset = Vector2(0, -_basket.texture.get_height() / 2.0)
	_basket.position = Vector2(3, BASE_Y)


func _shadow(at: Vector2, half_width: float, alpha: float) -> void:
	var half := Vector2(half_width, half_width * 0.26)
	draw_texture_rect(GameFx.soft_dot(), Rect2(at - half, half * 2), false, Color(SHADOW, alpha))


## Specks of warm light drifting slowly up through the beams.
func _motes() -> CPUParticles2D:
	var size := get_viewport_rect().size
	var p := CPUParticles2D.new()
	p.texture = GameFx.soft_dot()
	p.amount = 28
	p.lifetime = 9.0
	p.preprocess = 9.0
	p.position = Vector2(size.x / 2, size.y * 0.42)
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.emission_rect_extents = Vector2(size.x / 2, size.y * 0.4)
	p.direction = Vector2.UP
	p.spread = 180.0
	p.gravity = Vector2(0, -4)
	p.initial_velocity_min = 4.0
	p.initial_velocity_max = 14.0
	p.scale_amount_min = 0.14
	p.scale_amount_max = 0.32
	p.color = Color(1.0, 0.95, 0.65, 0.6)
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.2, 0.8, 1.0])
	fade.colors = PackedColorArray([Color(1, 1, 1, 0), Color.WHITE, Color.WHITE, Color(1, 1, 1, 0)])
	p.color_ramp = fade
	p.material = _additive()
	return p


static func _additive() -> CanvasItemMaterial:
	var m := CanvasItemMaterial.new()
	m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	return m


## Light falling through gaps in the canopy, each shaft slowly brightening and
## fading on its own rhythm (a cycle of about ten seconds, nothing flickers).
class Sunbeams extends Node2D:
	# Top x, top width, phase
	const BEAMS := [[250.0, 46.0, 0.0], [540.0, 70.0, 2.1], [800.0, 44.0, 4.0], [1030.0, 60.0, 1.2]]
	const SLANT := -170.0
	const BOTTOM := 590.0
	const LIGHT := Color(1.0, 0.94, 0.7)
	var _t := 0.0

	func _process(delta: float) -> void:
		_t += delta
		queue_redraw()

	func _draw() -> void:
		for b in BEAMS:
			var a := 0.085 + 0.045 * sin(_t * 0.6 + b[2])
			var x: float = b[0]
			var w: float = b[1]
			draw_polygon(PackedVector2Array([Vector2(x, -10), Vector2(x + w, -10),
					Vector2(x + w * 3.4 + SLANT, BOTTOM), Vector2(x + SLANT, BOTTOM)]),
					PackedColorArray([Color(LIGHT, a), Color(LIGHT, a), Color(LIGHT, 0), Color(LIGHT, 0)]))
