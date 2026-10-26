extends CharacterBody2D

var network_position = Vector2.ZERO
var zero_offset = Vector2.ZERO
@onready var flappy = $".."

@onready var flash: AnimationPlayer = $AnimatedSprite2D/Flash
@onready var animated_sprite_2d: AnimatedSprite2D = $AnimatedSprite2D
@onready var debug_mode = DebugSettings.debug_mode

const PLAYER_RADIUS = 70
const MIN_BOUNDS = Vector2(PLAYER_RADIUS, PLAYER_RADIUS)
var MAX_BOUNDS = Vector2.ZERO

# Looks only: the sprite tilts nose-up when climbing and nose-down when diving,
# and a trail streams from the tail while playing. Position is untouched.
const GameFx := preload("res://Main_screen/Scripts/game_fx.gd")
const TAIL := Vector2(-50, 4)   # behind the plane, on screen
var _trail: CPUParticles2D
var _last_y := 0.0
var _vy := 0.0


func _ready() -> void:
    get_parent().flash_animation.connect(anim_change)
    get_parent().plane_crashed.connect(plane_anim_change)
    get_parent().game_started.connect(pilot_refresh)
    var screen_size = get_viewport_rect().size
    var ground_y = get_parent().get_node("ground").global_position.y
    MAX_BOUNDS = Vector2(screen_size.x, ground_y) - Vector2(PLAYER_RADIUS, PLAYER_RADIUS)
    _last_y = position.y
    _setup_trail()

func _physics_process(delta: float) -> void:
    
    if debug_mode:
        network_position = get_global_mouse_position()
    else:
        network_position = GlobalScript.network_position3D if flappy.is_3d_mode else GlobalScript.network_position

    if network_position != Vector2.ZERO:
        network_position = network_position - zero_offset  + Vector2(600, 100)  
        position = position.lerp(network_position, 0.8)
    position.x = 100
    position.y = clamp(position.y, MIN_BOUNDS.y, MAX_BOUNDS.y)
    _update_look(delta)
    
    
    
        
func pilot_refresh():
    animated_sprite_2d.animation = 'default'

func plane_anim_change():
    animated_sprite_2d.animation = 'dead'
    
func anim_change():
    flash.play('flash')


func _setup_trail() -> void:
    _trail = CPUParticles2D.new()
    _trail.top_level = true
    _trail.texture = GameFx.soft_dot()
    _trail.amount = 40
    _trail.lifetime = 0.8
    _trail.local_coords = false
    _trail.direction = Vector2.LEFT
    _trail.spread = 6.0
    _trail.gravity = Vector2.ZERO
    _trail.initial_velocity_min = 220.0
    _trail.initial_velocity_max = 280.0
    _trail.scale_amount_min = 0.7
    _trail.scale_amount_max = 0.9
    var grow := Curve.new()
    grow.add_point(Vector2(0, 0.45))
    grow.add_point(Vector2(1, 1.0))
    _trail.scale_amount_curve = grow
    var fade := Gradient.new()
    fade.offsets = PackedFloat32Array([0.0, 1.0])
    fade.colors = PackedColorArray([Color(1, 1, 1, 0.45), Color(1, 1, 1, 0)])
    _trail.color_ramp = fade
    _trail.emitting = false
    add_child(_trail)
    move_child(_trail, 0)   # under the plane sprite


func _update_look(delta: float) -> void:
    if delta > 0.0:
        _vy = lerpf(_vy, (position.y - _last_y) / delta, 1.0 - exp(-12.0 * delta))
    _last_y = position.y
    var tilt := clampf(_vy * 0.0012, -0.32, 0.32)
    animated_sprite_2d.rotation = lerp_angle(animated_sprite_2d.rotation, tilt, 1.0 - exp(-8.0 * delta))
    _trail.global_position = global_position + TAIL
    _trail.emitting = flappy.game_running
