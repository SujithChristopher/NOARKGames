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
            "top":
                player_score += 1
                ScoreManager.update_top_score(GlobalSignals.current_patient_id, "PingPong", player_score)
                var top_score = ScoreManager.get_top_score(GlobalSignals.current_patient_id, "PingPong")
                top_score_label.text = str(top_score)
                status = "top"
                GlobalSignals.hit_top = collision_point
                print("Hit top at:", collision_point)
            "left":
                status = "left"
                GlobalSignals.hit_left = collision_point
                print("Hit left at:", collision_point)
            "right":
                status = "right"
                GlobalSignals.hit_right = collision_point
                print("Hit right at:", collision_point)
            "player":
                status = "player"
                GlobalSignals.hit_player = collision_point
                print("Hit player at:", collision_point)
            "computer":
                status = "computer"
                GlobalSignals.hit_computer = collision_point
                print("Hit computer at:", collision_point)
        

            
        player_score_label.text = "Player " + str(player_score)
        computer_score_label.text = "Computer " + str(computer_score)
        velocity =  velocity.bounce(collision.get_normal()) * speed_multiplier
    else:
        status = "moving"
    
    GlobalSignals.ball_position = position
    

func _on_ready():
    start_ball() 
    
    
func start_ball():
    randomize()
    velocity.x = [-1, 1][randi() % 2] * INITIAL_BALL_SPEED
    velocity.y = [-.8, .8][randi() % 2] * INITIAL_BALL_SPEED
    
