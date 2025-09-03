extends CanvasLayer
@onready var flappy_main: Control = $".."
@onready var game_over: CanvasLayer = $"."
@onready var time_remaining: Label = $TimeRemaining
@onready var restart_timer: Timer = $RestartTimer
signal restart_games

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
    flappy_main.game_over_signal.connect(start_timer)


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
    if game_over.visible:
        time_remaining.text = "Restarting game in " + str(int(restart_timer.time_left))
    
func start_timer():
    restart_timer.start()
    game_over.show()


func _on_restart_timer_timeout() -> void:
    game_over.hide()
    restart_games.emit()
