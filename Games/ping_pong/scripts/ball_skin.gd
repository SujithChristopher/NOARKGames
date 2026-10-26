extends Node2D
## The ball as an orange ping pong ball: shaded, with a shadow on the table and
## a short fading trail while it is in play.

const RADIUS := 15.0
const TRAIL := 9
const ORANGE := Color(1.0, 0.58, 0.16)

var _trail: Array[Vector2] = []


func _ready() -> void:
    get_parent().get_node("Sprite2D").hide()


func _process(_delta: float) -> void:
    var ball := get_parent()
    var at: Vector2 = ball.global_position
    # Put back in the centre after a point: no streak across the table
    if not _trail.is_empty() and _trail[-1].distance_to(at) > 120.0:
        _trail.clear()
    if ball.game_started:
        _trail.append(at)
        if _trail.size() > TRAIL:
            _trail.pop_front()
    elif not _trail.is_empty():
        _trail.pop_front()
    queue_redraw()


func _draw() -> void:
    var me := global_position
    for i in _trail.size():
        var k := float(i + 1) / (_trail.size() + 1)
        draw_circle(_trail[i] - me, RADIUS * (0.35 + 0.55 * k), Color(1.0, 0.82, 0.55, 0.35 * k))
    draw_set_transform(Vector2(5, 8), 0.0, Vector2(1.0, 0.75))
    draw_circle(Vector2.ZERO, RADIUS, Color(0, 0, 0, 0.3))
    draw_set_transform(Vector2.ZERO)
    draw_circle(Vector2.ZERO, RADIUS, Color(0.88, 0.4, 0.05))
    draw_circle(Vector2(-1.5, -1.5), RADIUS - 2.0, ORANGE)
    draw_circle(Vector2(-5, -5), 4.5, Color(1, 1, 1, 0.75))
    draw_arc(Vector2.ZERO, RADIUS, 0, TAU, 32, Color(0.5, 0.22, 0.03, 0.6), 1.5, true)
