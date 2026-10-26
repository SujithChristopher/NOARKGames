extends Control

@onready var time_label := Label.new()
var progress := 1.0
var max_time := 60

func _ready() -> void:
    custom_minimum_size = Vector2(85, 120)
    
    # Setup and center label
    time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    time_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    time_label.set_anchors_preset(Control.PRESET_CENTER)
    time_label.position = Vector2(-60, -20)
    time_label.size = Vector2(120, 40)
    
    # Apply styling
    time_label.add_theme_font_size_override("font_size", 20)
    time_label.add_theme_color_override("font_color", Color(0.13, 0.14, 0.2))
    var font = load("res://Assets/Fonts/Bungee-Regular.ttf")
    if font:
        time_label.add_theme_font_override("font", font)
    
    add_child(time_label)

func set_time(time: int) -> void:
    max_time = time
    progress = 1.0
    time_label.text = "%d:%02d" % [time / 60, time % 60]
    queue_redraw()

func update_time(time_left: int) -> void:
    progress = float(time_left) / float(max_time)
    time_label.text = "%d:%02d" % [time_left / 60, time_left % 60]
    queue_redraw()

func _draw() -> void:
    var center := size / 2
    var radius: float = min(size.x, size.y) / 2.0 - 10.0

    # White face with a soft shadow, so the time reads on any background
    draw_circle(center + Vector2(0, 3), radius + 9.0, Color(0, 0, 0, 0.2))
    draw_circle(center, radius + 7.0, Color(1, 1, 1, 0.94))
    # Track, then the time left: green, amber in the last 30%, red in the last 15%
    draw_arc(center, radius, 0, TAU, 64, Color(0.1, 0.12, 0.2, 0.12), 8.0, true)
    var color := Color(0.22, 0.74, 0.42) if progress > 0.3 else (Color(1.0, 0.65, 0.15) if progress > 0.15 else Color(0.93, 0.26, 0.24))
    draw_arc(center, radius, -PI/2, -PI/2 - TAU * progress, 64, color, 8.0, true)
    # Round ends on the arc
    if progress > 0.0:
        draw_circle(center + Vector2(0, -radius), 4.0, color)
        draw_circle(center + Vector2.from_angle(-PI/2 - TAU * progress) * radius, 4.0, color)
