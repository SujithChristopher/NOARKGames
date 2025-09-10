extends Area2D

# Constants
const POSITION_LERP_SPEED: float = 0.8
const MOVEMENT_THRESHOLD: float = 2.0

# Network positioning
var network_position: Vector2 = Vector2.ZERO
var last_network_position: Vector2 = Vector2.ZERO
var zero_offset: Vector2 = Vector2.ZERO
var centre: Vector2 = Vector2(120, 200)

# Boundaries
var MIN_X_VALUE: float
var MAX_X_VALUE: float

# Settings
@onready var adapt_toggle: bool = false
@onready var debug_mode = DebugSettings.debug_mode
@onready var game: Node2D = $".."


func _ready() -> void:
    print("Paddle:: _ready")
    _setup_boundaries()

func _setup_boundaries() -> void:
    # Get paddle width for proper boundary calculation
    var paddle_width: float = 0.0
    if has_node("CollisionShape2D") and $CollisionShape2D.shape:
        var shape = $CollisionShape2D.shape
        if shape is RectangleShape2D:
            paddle_width = shape.size.x
        elif shape is CapsuleShape2D:
            paddle_width = shape.radius * 2
        elif shape is CircleShape2D:
            paddle_width = shape.radius * 2
        else:
            paddle_width = 100.0  # Default fallback
    else:
        paddle_width = 100.0  # Default fallback
    
    MIN_X_VALUE = get_viewport_rect().position.x + paddle_width/2
    MAX_X_VALUE = get_viewport_rect().end.x - paddle_width/2

func _physics_process(delta: float) -> void:
    _update_network_position()
    _update_paddle_position()

func _update_network_position() -> void:
    if debug_mode:
        network_position = get_global_mouse_position()
    elif adapt_toggle:
        network_position = GlobalScript.scaled_network_position
    else:
        network_position = GlobalScript.network_position

func _update_paddle_position() -> void:
    if network_position != Vector2.ZERO:
        # Check if there's significant movement to reduce jitter
        var movement_distance = network_position.distance_to(last_network_position)
    
        if movement_distance > MOVEMENT_THRESHOLD:
            # Apply offset and center adjustment
            var adjusted_position = network_position - zero_offset + centre
    
            # Smooth lerp to the adjusted position
            position.x = lerp(position.x, adjusted_position.x, POSITION_LERP_SPEED)
            
            # Update last position
            last_network_position = network_position
    
    # Clamp to boundaries and set fixed Y position
    position.x = clampf(position.x, MIN_X_VALUE, MAX_X_VALUE)
    position.y = 615.0

func _on_adapt_prom_toggled(toggled_on: bool) -> void:
    if toggled_on and not GlobalSignals.assessment_done:
        game._button_nodes.adapt_prom.button_pressed = false
        game._button_nodes.warning_window.visible = true
        return
    adapt_toggle = toggled_on
