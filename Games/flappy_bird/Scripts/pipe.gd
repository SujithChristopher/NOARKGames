extends Area2D
## A pair of sandstone pillars with a gold hoop in the gap between them: the
## hoop is where to fly. It bursts when the gap is cleared (celebrate) and turns
## red and fades when the plane hits a pillar (missed). The drawing follows the
## collision boxes in pipe.tscn, which are unchanged: a 70 px column with a 78 px
## ledge at the gap, the gap itself from y -77 to 86.

signal hit
signal scored

const GameFx := preload("res://Main_screen/Scripts/game_fx.gd")
const GAP_TOP := -77.0
const GAP_BOTTOM := 86.0
const LEDGE_H := 36.0
const ROCK_LIGHT := Color(0.94, 0.66, 0.43)
const ROCK_DARK := Color(0.76, 0.45, 0.3)
const ROCK_EDGE := Color(0.38, 0.21, 0.15)
const MOSS := Color(0.43, 0.72, 0.3)

var _hoop: Node2D
var _pulse: Tween
var _edges := {}   # jagged column outlines, made once so every redraw matches


func _ready() -> void:
    $upper.hide()
    $lower.hide()
    _hoop = Hoop.new()
    _hoop.position = Vector2(0, (GAP_TOP + GAP_BOTTOM) / 2.0)
    add_child(_hoop)
    _pulse = _hoop.create_tween().set_loops()
    _pulse.tween_property(_hoop, "scale", Vector2(1.08, 1.08), 0.7).set_trans(Tween.TRANS_SINE)
    _pulse.tween_property(_hoop, "scale", Vector2.ONE, 0.7).set_trans(Tween.TRANS_SINE)
    # Fade in, in case the pipe appears on screen rather than off it
    modulate.a = 0.0
    create_tween().tween_property(self, "modulate:a", 1.0, 0.3)


func celebrate() -> void:
    _pulse.kill()
    GameFx.burst(get_tree().current_scene, _hoop.global_position,
        [GameFx.GOLD, Color.WHITE, Color(1.0, 0.95, 0.6)], 26, 260.0, 0.45, 120.0)
    var tw := _hoop.create_tween().set_parallel()
    tw.tween_property(_hoop, "scale", Vector2(1.8, 1.8), 0.35).set_ease(Tween.EASE_OUT)
    tw.tween_property(_hoop, "modulate:a", 0.0, 0.35)


func missed() -> void:
    _pulse.kill()
    var tw := _hoop.create_tween()
    tw.tween_property(_hoop, "modulate", Color(1.0, 0.35, 0.3, 0.9), 0.1)
    tw.tween_property(_hoop, "modulate:a", 0.0, 0.5)


func _draw() -> void:
    _pillar(-700.0, GAP_TOP - LEDGE_H, GAP_TOP - LEDGE_H, false)
    _pillar(GAP_BOTTOM + LEDGE_H, 700.0, GAP_BOTTOM, true)


## A column from top to bottom with its ledge at the gap: below it for the upper
## pillar (moss hanging into the gap), above it for the lower one (grass on top).
func _pillar(top: float, bottom: float, ledge_y: float, ledge_above: bool) -> void:
    var key := int(top)
    if not _edges.has(key):
        _edges[key] = _jagged(top, bottom)
    var edge: Dictionary = _edges[key]
    draw_colored_polygon(edge.body, ROCK_DARK)
    draw_colored_polygon(edge.lit, ROCK_LIGHT)
    for s in edge.strata:
        draw_line(s[0], s[1], Color(ROCK_EDGE, 0.35), 2.0)
    draw_polyline(edge.outline, ROCK_EDGE, 3.0, true)
    # Shade cast by the ledge onto the lower pillar's column
    if ledge_above:
        draw_rect(Rect2(-35, ledge_y + LEDGE_H, 70, 12), Color(ROCK_EDGE, 0.3))

    var ledge := Rect2(-39, ledge_y, 78, LEDGE_H)
    var slab := StyleBoxFlat.new()
    slab.bg_color = ROCK_LIGHT.lightened(0.05)
    slab.set_corner_radius_all(9)
    slab.set_border_width_all(3)
    slab.border_color = ROCK_EDGE
    slab.draw(get_canvas_item(), ledge)
    draw_rect(Rect2(ledge.position + Vector2(8, ledge.size.y * 0.55), Vector2(62, 6)), Color(ROCK_DARK, 0.5))

    if ledge_above:
        # Grass on the lower pillar's top
        var y := ledge.position.y
        draw_rect(Rect2(-39, y - 1, 78, 8), MOSS)
        for i in 9:
            var x := -36.0 + i * 9.0
            draw_colored_polygon(PackedVector2Array([Vector2(x - 3, y + 2), Vector2(x + 3, y + 2),
                Vector2(x + (i % 3 - 1) * 2.0, y - 6.0 - (i % 2) * 3.0)]), MOSS.lightened(0.1 * (i % 2)))
        draw_line(Vector2(-39, y + 7), Vector2(39, y + 7), MOSS.darkened(0.3), 2.0)
    else:
        # Moss hanging from the upper pillar's ledge
        var y := ledge.end.y
        draw_rect(Rect2(-39, y - 8, 78, 9), MOSS)
        for i in 7:
            var x := -32.0 + i * 10.7
            draw_circle(Vector2(x, y + 1), 4.0 + (i % 2) * 1.5, MOSS)
        draw_line(Vector2(-39, y - 8), Vector2(39, y - 8), MOSS.darkened(0.3), 2.0)


func _jagged(top: float, bottom: float) -> Dictionary:
    var rng := RandomNumberGenerator.new()
    rng.seed = int(top) + 1000
    var left := PackedVector2Array()
    var ridge := PackedVector2Array()
    var right := PackedVector2Array()
    var strata := []
    var y := top
    while y <= bottom:
        left.append(Vector2(-35.0 + rng.randf_range(-2.0, 3.5), y))
        ridge.append(Vector2(8.0 + rng.randf_range(-6, 6), y))
        right.append(Vector2(35.0 + rng.randf_range(-3.5, 2.0), y))
        if rng.randf() < 0.6:
            # A crack: a short line with a kink
            var a := Vector2(rng.randf_range(-28, 6), y + rng.randf_range(4, 20))
            var b := a + Vector2(rng.randf_range(8, 16), rng.randf_range(-4, 4))
            strata.append([a, b])
            strata.append([b, b + Vector2(rng.randf_range(6, 12), rng.randf_range(3, 7))])
        y += 24.0
    left.append(Vector2(-35, bottom))
    ridge.append(Vector2(8, bottom))
    right.append(Vector2(35, bottom))
    var body := left.duplicate()
    var lit := left.duplicate()
    right.reverse()
    ridge.reverse()
    body.append_array(right)
    lit.append_array(ridge)
    var outline := body.duplicate()
    outline.append(body[0])
    return {"body": body, "outline": outline, "lit": lit, "strata": strata}


func _on_body_entered(body: Node2D) -> void:
    if body.name == "pilot":
        hit.emit()


func _on_score_area_body_entered(body: Node2D) -> void:
    if body.name == "pilot":
        scored.emit()


## The hoop: a gold ellipse with a soft glow, standing in the gap.
class Hoop extends Node2D:
    func _draw() -> void:
        var ring := PackedVector2Array()
        for i in 41:
            ring.append(Vector2.from_angle(TAU * i / 40.0) * Vector2(16, 62))
        draw_polyline(ring, Color(1.0, 0.85, 0.35, 0.25), 14.0, true)
        draw_polyline(ring, Color(0.85, 0.55, 0.1), 7.0, true)
        draw_polyline(ring, Color(1.0, 0.86, 0.32), 4.0, true)
        for i in 41:
            ring[i] = ring[i] * 0.97 + Vector2(-1.5, -1.5)
        draw_polyline(ring.slice(22, 34), Color(1, 1, 1, 0.8), 1.5, true)
