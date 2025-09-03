extends Area2D
signal apple_eaten
signal time_remaining(value)

@onready var anim = $Sprite2D

func _process(delta):
    pass
    
func _on_body_entered(body:Node2D):
    if body.name == "Player":
        apple_eaten.emit()
        anim.animation = "collected"
        await anim.animation_finished
        queue_free()

func _on_timer_timeout():
    queue_free() 
