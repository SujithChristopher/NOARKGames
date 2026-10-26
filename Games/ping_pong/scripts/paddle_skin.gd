extends Node2D
## A table tennis bat seen from above, sized to its paddle's collision box: a
## rubber face on a wooden blade, a handle pointing at its player, and a shadow
## on the table. bump() squashes it for a moment when the ball hits it.

var rubber := Color(0.86, 0.17, 0.2)
var handle_down := true
var _size := Vector2(118, 20)

const WOOD := Color(0.8, 0.6, 0.38)
const WOOD_DARK := Color(0.55, 0.38, 0.22)


func _ready() -> void:
    name = "Skin"
    var paddle := get_parent()
    _size = paddle.get_node("CollisionShape2D").shape.size
    paddle.get_node("Sprite2D").hide()


func bump() -> void:
    scale = Vector2(1.06, 0.7)
    create_tween().tween_property(self, "scale", Vector2.ONE, 0.2) \
        .set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _draw() -> void:
    var face := Rect2(-_size / 2, _size)
    var handle := Rect2(-8, face.end.y - 2, 16, 18) if handle_down else Rect2(-8, face.position.y - 16, 16, 18)

    _box(face.grow(3), Color(0, 0, 0, 0.28), Vector2(3, 6), int(_size.y / 2) + 3)
    _box(handle, Color(0, 0, 0, 0.28), Vector2(3, 6), 4)
    _box(handle, WOOD, Vector2.ZERO, 4)
    for i in 3:
        var y := handle.position.y + 4 + i * 4
        draw_line(Vector2(handle.position.x + 2, y), Vector2(handle.end.x - 2, y), WOOD_DARK, 1.5)
    _box(face.grow(3), WOOD, Vector2.ZERO, int(_size.y / 2) + 3)
    _box(face, rubber, Vector2.ZERO, int(_size.y / 2))
    # Sheen along the face
    _box(Rect2(face.position + Vector2(8, 3), Vector2(face.size.x - 16, face.size.y * 0.3)),
        Color(1, 1, 1, 0.22), Vector2.ZERO, int(_size.y * 0.15))


func _box(r: Rect2, colour: Color, offset: Vector2, radius: int) -> void:
    var sb := StyleBoxFlat.new()
    sb.bg_color = colour
    sb.set_corner_radius_all(radius)
    sb.anti_aliasing = true
    sb.draw(get_canvas_item(), Rect2(r.position + offset, r.size))
