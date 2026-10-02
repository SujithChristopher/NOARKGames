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
@onready var player_score_label = $"../Ball_Image/PlayerScore"
@onready var computer_score_label: Label = $"../ComputerScore"
@onready var top_score_label = $"../CanvasLayer/TextureRect/TopScoreLabel"

# Add these variables for score display
@onready var score_display_label: Label = $"../CanvasLayer/ScoreDisplayLabel"
var score_display_timer: Timer
var starting_timer: Timer
var initial_position: Vector2
var show_starting_next: bool = false

# Trajectory prediction
var trajectory_line: Line2D
var show_trajectory: bool = true
var max_trajectory_points: int = 50
var trajectory_time_step: float = 0.016  # 60 FPS simulation

var ball_speed = INITIAL_BALL_SPEED
var collision_point = Vector2.ZERO

# Variables to track side wall bouncing to prevent infinite back-and-forth bouncing
var side_wall_hit_count: int = 0
var last_side_hit: String = ""
@export var max_side_hits: int = 3  # Reset ball if it hits side walls more than this many times

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
                SessionLog.miss()
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
                _handle_side_wall_hit("left")
                status = "left"
                GlobalSignals.hit_left = collision_point
                print("Hit left at:", collision_point)
                velocity = velocity.bounce(collision.get_normal()) * speed_multiplier
                
            "right":
                _handle_side_wall_hit("right")
                status = "right"
                GlobalSignals.hit_right = collision_point
                print("Hit right at:", collision_point)
                velocity = velocity.bounce(collision.get_normal()) * speed_multiplier
                
            "player":
                SessionLog.hit()
                MusicManager.play_sound_effect("ball")
                _reset_side_hit_counter()
                status = "player"
                GlobalSignals.hit_player = collision_point
                print("Hit player at:", collision_point)
                velocity = velocity.bounce(collision.get_normal()) * speed_multiplier
                
            "computer":
                MusicManager.play_sound_effect("ball")
                _reset_side_hit_counter()
                status = "computer"
                GlobalSignals.hit_computer = collision_point
                print("Hit computer at:", collision_point)
                velocity = velocity.bounce(collision.get_normal()) * speed_multiplier
        
        # Update score labels
        player_score_label.text = str(player_score)
        computer_score_label.text = "Computer " + str(computer_score)
        
    else:
        status = "moving"
    
    # Update trajectory prediction
    if show_trajectory and game_started:
        _update_trajectory()
    
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
    
    # Setup trajectory line
    _setup_trajectory_line()
    
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
    
    # Hide trajectory during reset
    if trajectory_line:
        trajectory_line.visible = false
    
    # Reset position to center
    position = initial_position
    
    # Reset side hit tracking
    _reset_side_hit_counter()
    
    # Wait 2 seconds for text display (1s score + 1s starting)
    await get_tree().create_timer(2.0).timeout
    
    # Restart ball with new random direction
    start_ball()
    game_started = true

func _handle_side_wall_hit(side: String) -> void:
    """Handle side wall hits and check if ball is stuck bouncing back and forth between walls"""
    # Always increment counter for any side wall hit
    side_wall_hit_count += 1
    last_side_hit = side
    
    print("Side wall hit: ", side, " - Total side hits: ", side_wall_hit_count)
    
    # Check if ball is stuck bouncing back and forth between side walls
    if side_wall_hit_count > max_side_hits:
        print("Ball stuck bouncing back and forth between side walls (", side_wall_hit_count, " hits), resetting position")
        _reset_ball_position()

func _reset_side_hit_counter() -> void:
    """Reset the side hit counter when ball hits player, computer, top, or bottom"""
    side_wall_hit_count = 0
    last_side_hit = ""

func _reset_ball_position() -> void:
    """Reset ball to center position and give it a new random direction"""
    # Stop the ball temporarily
    game_started = false
    
    # Hide trajectory during reset
    if trajectory_line:
        trajectory_line.visible = false
    
    # Reset position to center
    position = initial_position
    
    # Reset side hit tracking
    _reset_side_hit_counter()
    
    # Wait a brief moment then restart
    await get_tree().create_timer(0.5).timeout
    
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

func _update_trajectory() -> void:
    """Update the trajectory line to show where the ball will go"""
    if not trajectory_line:
        print("Trajectory line not found, creating it...")
        _setup_trajectory_line()
        return
    
    trajectory_line.clear_points()
    
    var sim_position = position
    var sim_velocity = velocity * ball_speed
    var points = []
    
    # Get screen boundaries (you may need to adjust these values)
    var screen_size = get_viewport().get_visible_rect().size
    var left_wall = 0
    var right_wall = screen_size.x
    var top_wall = 0
    var bottom_wall = screen_size.y
    
    for i in range(max_trajectory_points):
        # Add current position to trajectory
        points.append(sim_position)
        
        # Calculate next position
        sim_position += sim_velocity * trajectory_time_step
        
        # Check for wall collisions and bounce
        
        # Left wall collision
        if sim_position.x <= left_wall:
            sim_position.x = left_wall
            sim_velocity.x = -sim_velocity.x
        
        # Right wall collision
        if sim_position.x >= right_wall:
            sim_position.x = right_wall
            sim_velocity.x = -sim_velocity.x
        
        # Top wall collision
        if sim_position.y <= top_wall:
            sim_position.y = top_wall
            sim_velocity.y = -sim_velocity.y
        
        # Bottom wall collision
        if sim_position.y >= bottom_wall:
            sim_position.y = bottom_wall
            sim_velocity.y = -sim_velocity.y
        
        # Stop if ball goes off screen or hits too many walls
        if sim_position.y > bottom_wall + 100 or sim_position.y < top_wall - 100:
            break
    
    # Set the trajectory points
    trajectory_line.points = points
    
    # Debug output
    if points.size() > 0:
        print("Trajectory updated with ", points.size(), " points")

func _setup_trajectory_line() -> void:
    """Setup the trajectory line appearance"""
    # Create the Line2D node if it doesn't exist
    if not trajectory_line:
        trajectory_line = Line2D.new()
        get_parent().add_child(trajectory_line)
        trajectory_line.name = "TrajectoryLine"
    
    # Configure the line appearance
    trajectory_line.width = 3.0  # Make it thicker for better visibility
    trajectory_line.default_color = Color(1.0, 1.0, 0.0, 0.8)  # Brighter yellow with more opacity
    trajectory_line.antialiased = true
    trajectory_line.visible = show_trajectory
    
    print("Trajectory line created and configured. Visible: ", trajectory_line.visible)
