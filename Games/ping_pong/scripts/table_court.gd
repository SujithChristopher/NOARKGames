extends Node2D
## Ping Pong's table seen from above: a blue top inside the four walls, white
## edge and centre lines and a net across the middle. It also dresses the bats
## (paddle_skin.gd) and the ball (ball_skin.gd), and lights up the goal line
## where a point is won (flash_goal, called through the "pp_court" group).
## Walls, bats and ball keep their collision; only their old sprites, the space
## picture and the tile border are hidden.

const PaddleSkin := preload("res://Games/ping_pong/scripts/paddle_skin.gd")
const BallSkin := preload("res://Games/ping_pong/scripts/ball_skin.gd")
const GameFx := preload("res://Main_screen/Scripts/game_fx.gd")
const COURT := Rect2(7, 23, 1142, 604)   # inside faces of the four walls
const TABLE := Color(0.11, 0.37, 0.66)
const RIM := Color(0.06, 0.2, 0.38)
const LINE := Color(1, 1, 1, 0.92)
const NET_Y := 325.0
## The score badge's ball is pink; turn pink pixels orange to match the ball.
const PINK_TO_ORANGE := """
shader_type canvas_item;
void fragment() {
	vec4 t = texture(TEXTURE, UV);
	float mx = max(t.r, max(t.g, t.b));
	float mn = min(t.r, min(t.g, t.b));
	// Pink/magenta: red high, blue above green
	float pink = smoothstep(0.02, 0.12, t.b - t.g) * step(0.2, mx - mn);
	// Same brightness, orange hue; the white highlight stays white
	vec3 orange = mix(vec3(1.0, 0.6, 0.18) * mx, vec3(1.0), smoothstep(0.3, 0.9, mn));
	COLOR = vec4(mix(t.rgb, orange, pink), t.a);
}
"""

var _goal: GoalFlash


func _ready() -> void:
    add_to_group("pp_court")
    var game := get_parent()
    game.move_child(self, game.get_node("BackGround").get_index() + 1)
    game.get_node("BackGround").hide()
    game.get_node("TileMapLayer").hide()

    var bat := PaddleSkin.new()
    bat.rubber = Color(0.86, 0.17, 0.2)
    bat.handle_down = true
    game.get_node("player").add_child(bat)
    bat = PaddleSkin.new()
    bat.rubber = Color(0.17, 0.17, 0.2)
    bat.handle_down = false
    game.get_node("computer").add_child(bat)
    game.get_node("Ball").add_child(BallSkin.new())
    var badge := ShaderMaterial.new()
    badge.shader = Shader.new()
    badge.shader.code = PINK_TO_ORANGE
    game.get_node("Ball_Image").material = badge

    _goal = GoalFlash.new()
    add_child(_goal)


## Light the end where the point was won: gold at the top when the player
## scores, red at the bottom when the computer does.
func flash_goal(player_scored: bool) -> void:
    _goal.top = player_scored
    _goal.colour = GameFx.GOLD if player_scored else Color(1.0, 0.35, 0.3)
    var tw := _goal.create_tween()
    tw.tween_method(_goal.set_strength, 1.0, 0.0, 0.7).set_ease(Tween.EASE_IN)


func _draw() -> void:
    var screen := get_viewport_rect()
    # Floor, then the table's dark rim and its top
    draw_polygon(PackedVector2Array([screen.position, Vector2(screen.end.x, 0), screen.end, Vector2(0, screen.end.y)]),
        PackedColorArray([Color(0.1, 0.11, 0.17), Color(0.1, 0.11, 0.17), Color(0.05, 0.06, 0.1), Color(0.05, 0.06, 0.1)]))
    draw_rect(COURT.grow(8), RIM)
    draw_rect(COURT, TABLE)
    # Soft light from above the centre
    var glow := Vector2(1500, 900)
    draw_texture_rect(GameFx.soft_dot(), Rect2(COURT.get_center() - glow / 2, glow), false, Color(1, 1, 1, 0.13))

    # Edge lines and the centre line
    draw_rect(COURT.grow(-5), LINE, false, 5.0)
    var cx := COURT.get_center().x
    draw_line(Vector2(cx, COURT.position.y + 5), Vector2(cx, COURT.end.y - 5), Color(LINE, 0.75), 3.0)

    # Net: shadow, mesh, white tape on top
    var left := COURT.position.x - 8
    var right := COURT.end.x + 8
    draw_rect(Rect2(left, NET_Y + 5, right - left, 10), Color(0, 0, 0, 0.22))
    draw_rect(Rect2(left, NET_Y - 5, right - left, 10), Color(0.08, 0.09, 0.12, 0.55))
    var x := left
    while x < right:
        draw_line(Vector2(x, NET_Y - 5), Vector2(x, NET_Y + 5), Color(1, 1, 1, 0.22), 1.0)
        x += 6.0
    draw_line(Vector2(left, NET_Y), Vector2(right, NET_Y), Color(1, 1, 1, 0.18), 1.0)
    draw_rect(Rect2(left, NET_Y - 7, right - left, 4), Color(0.97, 0.97, 0.97))


## A glow along one goal line that fades out after a point.
class GoalFlash extends Node2D:
    var top := true
    var colour := Color.WHITE
    var _strength := 0.0

    func set_strength(s: float) -> void:
        _strength = s
        queue_redraw()

    func _draw() -> void:
        if _strength <= 0.0:
            return
        var court := Rect2(7, 23, 1142, 604)
        var edge := court.position.y if top else court.end.y
        var inner := edge + (120.0 if top else -120.0)
        var c := Color(colour, 0.55 * _strength)
        var clear := Color(colour, 0.0)
        draw_polygon(PackedVector2Array([Vector2(court.position.x, edge), Vector2(court.end.x, edge),
            Vector2(court.end.x, inner), Vector2(court.position.x, inner)]),
            PackedColorArray([c, c, clear, clear]))
        draw_line(Vector2(court.position.x, edge), Vector2(court.end.x, edge), Color(colour, _strength), 6.0)
