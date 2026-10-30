extends Node2D

# Constants
const GAME_NAME: String = "FruitCatcher"
const GEM = preload("res://Games/fruit_catcher/Scenes/Fruits/fruit.tscn")
const GameFx := preload("res://Main_screen/Scripts/game_fx.gd")
const GameSession := preload("res://Main_screen/Scripts/game_session.gd")
const MARGIN: float = 70.0
const COLUMNS := [
	'score', 'status', 'pause_state',
	'device_x', 'device_y', 'device_z',
	'paddle_x', 'paddle_y', 'gem_x', 'gem_y',
	'countdown_time', 'gems_caught', 'gems_missed',
]

# Screen boundaries
var START_OF_SCREEN_X: float
var END_OF_SCREEN_X: float

# Game state
var session: GameSession
var current_gem: Gem = null
var game_active: bool = false
var pause_state: int = 1
var missed_gems := 0

# Position tracking for logging
var paddle_x: float = 0.0
var paddle_y: float = 615.0
var gem_x: float = 0.0
var gem_y: float = 0.0
var device_x: float = 0.0
var device_y: float = 0.0
var device_z: float = 0.0
var status: String = "waiting"

var scenery: Node2D

# Node references
@onready var spawn_timer: Timer = $SpawnTimer
@onready var paddle: Area2D = $Paddle
@onready var score_sound: AudioStreamPlayer2D = $ScoreSound
@onready var sound: AudioStreamPlayer = $Sound
@onready var score_label: Label = $Fruit_Score/ScoreLabel
@onready var game_over_label: TextureRect =$Gameover
@onready var countdown_display: Control = $CircularTimer
@onready var top_score_label: Label = $Highscore_/TopScoreLabel
@onready var pause_screen: TextureRect = $Paused
@onready var current_score: Label = $Gameover/CurrentScore
@onready var high_score: Label = $Gameover/HighScore

# Button nodes (cleaned up)
@onready var button_nodes = {
	"pause_button": $PauseButton,
}

func _ready() -> void:
	scenery = preload("res://Games/fruit_catcher/Scenes/Game/forest_scenery.gd").new()
	add_child(scenery)
	setup_screen_boundaries()
	spawn_timer.stop()
	setup_ui()
	session = GameSession.new(GAME_NAME, COLUMNS, _log_row, countdown_display)
	session.started.connect(start_game)
	session.time_up.connect(end_game)
	add_child(session)
	update_top_score_display()

func setup_screen_boundaries() -> void:
	START_OF_SCREEN_X = get_viewport_rect().position.x
	END_OF_SCREEN_X = get_viewport_rect().end.x

func setup_ui() -> void:
	game_over_label.visible = false
	button_nodes.pause_button.hide()
	score_label.text = "0"
	GameFx.dim_behind(pause_screen)
	GameFx.dim_behind(game_over_label)

func update_top_score_display() -> void:
	top_score_label.text = str(maxi(session.best_score(), session.score))

func _process(_delta: float) -> void:
	if game_active:
		update_tracking_data()

func update_tracking_data() -> void:
	# Update paddle position
	paddle_x = paddle.position.x
	paddle_y = paddle.position.y

	# Update gem position
	if current_gem and is_instance_valid(current_gem):
		gem_x = current_gem.position.x
		gem_y = current_gem.position.y
	else:
		gem_x = 0.0
		gem_y = 0.0

	# Update device position
	device_x = GlobalScript.raw_x
	device_y = GlobalScript.raw_y
	device_z = GlobalScript.raw_z

func start_game() -> void:
	game_active = true
	pause_state = 1
	status = "playing"
	button_nodes.pause_button.show()
	spawn_gem()

# Game Logic Functions
func spawn_gem() -> void:
	if current_gem != null or not game_active:
		return

	var new_gem: Gem = GEM.instantiate()
	var x_pos: float = randf_range(
		START_OF_SCREEN_X + MARGIN,
		END_OF_SCREEN_X - MARGIN
	)
	new_gem.position = Vector2(x_pos, -MARGIN)
	new_gem.gem_off_screen.connect(_on_gem_off_screen)

	current_gem = new_gem
	add_child(new_gem)
	status = "gem_spawned"

func _on_gem_off_screen() -> void:
	if not game_active:
		return
	# A small splash of juice where it fell
	if current_gem:
		var c: Color = current_gem.colour
		GameFx.burst(self, Vector2(current_gem.position.x, get_viewport_rect().end.y - 10),
			[c, c.darkened(0.25)], 10, 150.0, 0.4, 320.0)
	MusicManager.play_sound_effect("fruit_missed")
	current_gem = null
	status = "gem_missed"
	missed_gems += 1
	SessionLog.miss()

	await get_tree().create_timer(0.5).timeout
	if game_active:
		spawn_gem()

func _on_paddle_area_entered(area: Area2D) -> void:
	if area == current_gem and game_active:
		GameFx.float_text(self, area.global_position + Vector2(0, -50), "+1")
		scenery.bounce_basket()

		session.score += 1
		SessionLog.hit()
		score_label.text = str(session.score)
		GameFx.pop(score_label.get_parent())
		status = "gem_caught"
		update_top_score_display()
		if not score_sound.playing:
			score_sound.position = area.position
			score_sound.play()

		current_gem = null

		await get_tree().create_timer(0.5).timeout
		if game_active:
			spawn_gem()

func _on_pause_button_pressed() -> void:
	pause_screen.show()
	pause_game()

func pause_game() -> void:
	session.pause()
	game_active = false
	paddle.set_process(false)
	if current_gem and is_instance_valid(current_gem):
		current_gem.set_process(false)
	pause_state = 0
	status = "paused"

func resume_game() -> void:
	session.resume()
	game_active = true
	paddle.set_process(true)
	if current_gem and is_instance_valid(current_gem):
		current_gem.set_process(true)
	pause_state = 1
	status = "playing"

func end_game() -> void:
	game_active = false
	status = "game_over"

	# Stop all game elements
	if current_gem and is_instance_valid(current_gem):
		current_gem.set_process(false)
	paddle.set_process(false)

	var best := session.finish()
	sound.play()

	# Show game over UI
	game_over_label.visible = true
	current_score.text = "CURRENT SCORE - " + str(session.score)
	high_score.text = str(best)

func reset_game() -> void:
	# Clean up current gem
	if current_gem and is_instance_valid(current_gem):
		current_gem.queue_free()
	current_gem = null

	# Reset game state
	game_active = false
	pause_state = 1
	status = "waiting"
	missed_gems = 0
	session.retry()
	score_label.text = "0"

	# Reset UI
	game_over_label.visible = false
	button_nodes.pause_button.hide()
	paddle.set_process(true)
	update_top_score_display()

## One raw CSV row, in COLUMNS order (GameSession adds epochtime).
func _log_row() -> Array:
	return [
		session.score, status, pause_state,
		device_x, device_y, device_z,
		paddle_x, paddle_y, gem_x, gem_y,
		session.time_left,
		session.score,  # gems_caught (same as score)
		missed_gems,
	]

func _on_retry_button_pressed() -> void:
	reset_game()

func _on_logout_button_pressed() -> void:
	MusicManager.play_music("main")
	session.to_menu()

func _on_gameover_logout_pressed() -> void:
	session.to_menu()

func _on_home_pressed() -> void:
	session.to_menu()

func _on_resume_pressed() -> void:
	pause_screen.hide()
	resume_game()

func _on_restart_pressed() -> void:
	pause_screen.hide()
	reset_game()
