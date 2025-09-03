extends CanvasLayer

@onready var timer_label = $TimerLabel

func _process(delta):
    var time = GlobalTimer.get_time()
    var minutes = int(time) / 60
    var seconds = int(time) % 60
    timer_label.text = "%02d:%02d" % [minutes, seconds]
