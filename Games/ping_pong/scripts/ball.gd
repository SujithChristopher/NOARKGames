extends CharacterBody2D
class_name Ball
# Get the gravity from the project settings to be synced with RigidBody nodes.
var gravity = ProjectSettings.get_setting("physics/2d/default_gravity")
var game_started: bool = false
var player_score = 0
var computer_score = 0
var status = ""
@export var INITIAL_BALL_SPEED = 15
@export var speed_multiplier = 1
@onready var player_score_label = $"../PlayerScore"
@onready var computer_score_label: Label = $"../ComputerScore"
@onready var top_score_label = $"../CanvasLayer/TextureRect/TopScoreLabel"

# Add these variables for score display
@onready var score_display_label: Label = $"../CanvasLayer/ScoreDisplayLabel"
var score_display_timer: Timer
var starting_timer: Timer
var initial_position: Vector2
var show_starting_next: bool = false

var ball_speed = INITIAL_BALL_SPEED
var collision_point = Vector2.ZERO

func _physics_process(delta):
    if not game_started:
        return
    var collision = move_and_collide(velocity * ball_speed * delta)
    if(collision):
        var collider_name = collision.get_collider().name
        collision_point = collision.get_position()
        
        match collider_name:
            "bottom":
                computer_score += 1
                status = "ground"
                GlobalSignals.hit_ground = collision_point
                print("Hit bottom at:", collision_point)
                # Show Computer +1 first, then starting
                show_score_display("Computer +1")
                reset_ball_after_score()
                
            "top":
                player_score += 1
                ScoreManager.update_top_score(GlobalSignals.current_patient_id, "PingPong", player_score)
                var top_score = ScoreManager.get_top_score(GlobalSignals.current_patient_id, "PingPong")
                top_score_label.text = str(top_score)
                status = "top"
                GlobalSignals.hit_top = collision_point
                print("Hit top at:", collision_point)
                # Show Player +1 first, then starting
                show_score_display("Player +1")
                reset_ball_after_score()
                
            "left":
                status = "left"
                GlobalSignals.hit_left = collision_point
                print("Hit left at:", collision_point)
                velocity = velocity.bounce(collision.get_normal()) * speed_multiplier
                
            "right":
                status = "right"
                GlobalSignals.hit_right = collision_point
                print("Hit right at:", collision_point)
                velocity = velocity.bounce(collision.get_normal()) * speed_multiplier
                
            "player":
                status = "player"
                GlobalSignals.hit_player = collision_point
                print("Hit player at:", collision_point)
                velocity = velocity.bounce(collision.get_normal()) * speed_multiplier
                
            "computer":
                status = "computer"
                GlobalSignals.hit_computer = collision_point
                print("Hit computer at:", collision_point)
                velocity = velocity.bounce(collision.get_normal()) * speed_multiplier
        
        # Update score labels
        player_score_label.text = "Player " + str(player_score)
        computer_score_label.text = "Computer " + str(computer_score)
        
    else:
        status = "moving"
    
    GlobalSignals.ball_position = position

func _on_ready():
    # Store initial position for resets
    initial_position = position
    
    # Create and setup score display timer
    score_display_timer = Timer.new()
    score_display_timer.wait_time = 1.0  
    score_display_timer.one_shot = true
    score_display_timer.timeout.connect(_on_score_display_timeout)
    add_child(score_display_timer)
    
    # Create and setup starting timer
    starting_timer = Timer.new()
    starting_timer.wait_time = 1.0  
    starting_timer.one_shot = true
    starting_timer.timeout.connect(_on_starting_timeout)
    add_child(starting_timer)
    
    # Hide score display initially
    if score_display_label:
        score_display_label.visible = false
    
    start_ball() 

func show_score_display(text: String):
    """Show the score display (+1 text) first"""
    if score_display_label:
        score_display_label.text = text
        score_display_label.visible = true
        show_starting_next = true
        score_display_timer.start()

func _on_score_display_timeout():
    """After showing score, show starting text"""
    if show_starting_next and score_display_label:
        score_display_label.text = "Starting..."
        starting_timer.start()
        show_starting_next = false

func _on_starting_timeout():
    """Hide the starting text"""
    if score_display_label:
        score_display_label.visible = false

func reset_ball_after_score():
    """Reset ball to center and restart with new random direction"""
    # Stop the ball temporarily
    game_started = false
    
    # Reset position to center
    position = initial_position
    
    # Wait 2 seconds for text display (1s score + 1s starting)
    await get_tree().create_timer(2.0).timeout
    
    # Restart ball with new random direction
    start_ball()
    game_started = true

func start_ball():
    randomize()
    # Ensure minimum angle to avoid too horizontal movement
    var min_y_speed = 0.5  # Minimum vertical speed
    velocity.x = [-1, 1][randi() % 2] * INITIAL_BALL_SPEED
    
    # Generate a more controlled Y velocity to avoid zig-zag issues
    var y_direction = [-.8, .8][randi() % 2]
    # Ensure Y velocity has minimum value to avoid too shallow angles
    if abs(y_direction) < min_y_speed:
        y_direction = min_y_speed if y_direction > 0 else -min_y_speed
    
    velocity.y = y_direction * INITIAL_BALL_SPEED
    
    # Limit the angle to prevent too steep or too shallow trajectories
    var angle = atan2(velocity.y, velocity.x)
    var max_angle = deg_to_rad(60)  # Maximum 60 degrees from horizontal
    var min_angle = deg_to_rad(15)  # Minimum 15 degrees from horizontal
    
    # Clamp the angle
    if abs(angle) > max_angle:
        angle = max_angle if angle > 0 else -max_angle
    elif abs(angle) < min_angle:
        angle = min_angle if angle > 0 else -min_angle
    
    # Recalculate velocity with clamped angle
    var speed = velocity.length()
    velocity.x = cos(angle) * speed * sign(velocity.x)
    velocity.y = sin(angle) * speed
