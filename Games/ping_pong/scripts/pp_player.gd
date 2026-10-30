extends CharacterBody2D

# Constants
const POSITION_LERP_SPEED: float = 0.8
const PLAYER_Y_POSITION: float = 610.0
const GAME_NAME: String = "PingPong"
const GameFx := preload("res://Main_screen/Scripts/game_fx.gd")
const GameSession := preload("res://Main_screen/Scripts/game_session.gd")
const COLUMNS := [
    'score', 'status', 'error_status', 'packets',
    'device_x', 'device_y', 'device_z', 'target_x', 'target_y', 'target_z',
    'player_x', 'player_y', 'player_z', 'ball_x', 'ball_y', 'ball_z', 'pause_state',
]

# Movement and positioning
var network_position: Vector2 = Vector2.ZERO
var zero_offset: Vector2 = Vector2.ZERO
var centre: Vector2 = Vector2.ZERO
var use_origin_offset: bool = true

# Game state
var session: GameSession
var game_started: bool = false
var pause_state: int = 1

# Position tracking
var pos_x: float
var pos_y: float
var pos_z: float
var target_x: float
var target_y: float
var target_z: float = 0.0
var game_x: float
var game_y: float = 0.0
var game_z: float
var ball_x: float
var ball_y: float
var ball_z: float

# Game logging
var status: String = ""
var error_status: String = ""
var packets: String = ""

# Settings
@onready var debug_mode = Settings.is_debug()

# Game objects
@onready var ball: Node = $"../Ball"

# UI Labels
@onready var countdown_display: Control = $"../CircularTimer"
@onready var top_score_label: Label = $"../CanvasLayer/TextureRect/TopScoreLabel"
@onready var paused_screen: TextureRect = $"../Paused"
@onready var current_score: Label =$"../Gameover/CurrentScore"
@onready var high_score: Label =$"../Gameover/HighScore"

# UI Panels
@onready var game_over_label: TextureRect = $"../Gameover"

# UI Buttons - organized by functionality
@onready var _game_buttons: Dictionary = {
    "pause": $"../CanvasLayer/PauseButton",
}

func _ready() -> void:
    get_parent().add_child.call_deferred(preload("res://Games/ping_pong/scripts/table_court.gd").new())
    _setup_ui()
    _connect_signals()
    session = GameSession.new(GAME_NAME, COLUMNS, _log_row, countdown_display)
    session.started.connect(_start_game)
    session.time_up.connect(show_game_over)
    add_child(session)
    update_top_score_display()

func _setup_ui() -> void:
    game_over_label.hide()
    GameFx.dim_behind(paused_screen)
    GameFx.dim_behind(game_over_label)

func _connect_signals() -> void:
    # Game control buttons
    _game_buttons.pause.pressed.connect(_on_pause_button_pressed)
    GlobalSignals.origin_set.connect(_on_origin_set)

## The best so far, this game's score included (ball.gd calls it on a point).
func update_top_score_display() -> void:
    top_score_label.text = str(maxi(session.best_score(), ball.player_score))

func _start_game() -> void:
    game_started = true
    pause_state = 1
    ball.game_started = true

func _physics_process(delta: float) -> void:
    if not game_started:
        return

    _update_network_position()
    _update_player_position()
    _update_game_data()

func _update_network_position() -> void:
    if debug_mode:
        network_position = get_global_mouse_position()
    else:
        network_position = GlobalScript.network_position

func _on_origin_set() -> void:
    if use_origin_offset:
        zero_offset = GlobalScript.network_position

func _update_player_position() -> void:
    if network_position != Vector2.ZERO:
        var adjusted := network_position - (zero_offset if use_origin_offset else Vector2.ZERO) + centre
        position = position.lerp(adjusted, POSITION_LERP_SPEED)

    position.y = PLAYER_Y_POSITION

func _update_game_data() -> void:
    if not ball.game_started:
        return

    # Update position data
    pos_x = GlobalScript.raw_x
    pos_y = GlobalScript.raw_y
    pos_z = GlobalScript.raw_z

    # Update target data
    target_x = (GlobalSignals.ball_position.x - GlobalScript.X_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_X
    target_y = (GlobalSignals.ball_position.y - GlobalScript.Y_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_Z
    ball_x = target_x
    ball_y = target_y
    ball_z = target_z

    # Update game state
    status = ball.status
    session.score = ball.player_score
    error_status = "null"
    packets = "null"

    # Update player position data
    _calculate_player_game_position()

func _calculate_player_game_position() -> void:
    game_x = (position.x - GlobalScript.X_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_X
    game_z = (position.y - GlobalScript.Y_SCREEN_OFFSET) / GlobalScript.PLAYER_POS_SCALER_Z

func _on_pause_button_pressed() -> void:
    paused_screen.show()
    _pause_game()

func _pause_game() -> void:
    session.pause()
    ball.game_started = false
    pause_state = 0

func _resume_game() -> void:
    session.resume()
    ball.game_started = true
    pause_state = 1

func show_game_over() -> void:
    ball.game_started = false
    session.score = ball.player_score
    var best := session.finish()
    current_score.text = "CURRENT SCORE - " + str(session.score)
    high_score.text = str(best)
    game_over_label.visible = true

## One raw CSV row, in COLUMNS order (GameSession adds epochtime).
func _log_row() -> Array:
    return [
        session.score, status, error_status, packets,
        pos_x, pos_y, pos_z, target_x, target_y, target_z,
        game_x, game_y, game_z, ball_x, ball_y, ball_z, pause_state,
    ]

func _on_logout_button_pressed() -> void:
    session.to_menu()

func _on_retry_button_pressed() -> void:
    get_tree().paused = false
    game_over_label.hide()
    game_started = false
    ball.reset_scores()   # the next trial starts from 0, not from this one's score
    session.retry()
    update_top_score_display()

func _on_logout_pressed() -> void:
    MusicManager.play_music("main")
    session.to_menu()

func _on_home_pressed() -> void:
    session.to_menu()

func _on_resume_pressed() -> void:
    paused_screen.hide()
    _resume_game()

func _on_restart_pressed() -> void:
    paused_screen.hide()
    get_tree().reload_current_scene()
