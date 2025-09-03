extends CharacterBody2D

var network_position = Vector2.ZERO
var zero_offset = Vector2.ZERO
@onready var flappy = $".."

@onready var adapt_toggle:bool = false
@onready var flash: AnimationPlayer = $AnimatedSprite2D/Flash
@onready var animated_sprite_2d: AnimatedSprite2D = $AnimatedSprite2D
@onready var debug_mode = DebugSettings.debug_mode

const PLAYER_RADIUS = 70
const MIN_BOUNDS = Vector2(PLAYER_RADIUS, PLAYER_RADIUS)
var MAX_BOUNDS = Vector2.ZERO


func _ready() -> void:
    get_parent().flash_animation.connect(anim_change)
    get_parent().plane_crashed.connect(plane_anim_change)
    get_parent().game_started.connect(pilot_refresh)
    var screen_size = get_viewport_rect().size
    var ground_y = get_parent().get_node("ground").global_position.y
    MAX_BOUNDS = Vector2(screen_size.x, ground_y) - Vector2(PLAYER_RADIUS, PLAYER_RADIUS)

func _physics_process(delta: float) -> void:
    
    if debug_mode:
        network_position = get_global_mouse_position()
    elif adapt_toggle:
        if flappy.is_3d_mode:
           network_position = GlobalScript.scaled_network_position3D
        else:
            network_position = GlobalScript.scaled_network_position
    else:
        network_position = GlobalScript.network_position3D if flappy.is_3d_mode else GlobalScript.network_position

    if network_position != Vector2.ZERO:
        network_position = network_position - zero_offset  + Vector2(600, 100)  
        position = position.lerp(network_position, 0.8)
    position.x = 100
    position.y = clamp(position.y, MIN_BOUNDS.y, MAX_BOUNDS.y)
    
    
    
        
func pilot_refresh():
    animated_sprite_2d.animation = 'default'

func plane_anim_change():
    animated_sprite_2d.animation = 'dead'
    
func anim_change():
    flash.play('flash')
    
func _on_adapt_rom_toggled(toggled_on: bool) -> void:
     if toggled_on and not GlobalSignals.assessment_done:
        flappy._button_nodes.adapt_prom.button_pressed = false
        flappy._ui_nodes.warning_window.visible = true
        return
     adapt_toggle = false
