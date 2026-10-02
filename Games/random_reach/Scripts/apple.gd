extends Area2D
signal apple_eaten
signal apple_missed   # its timer ran out before it was eaten
@onready var anim = $Sprite2D
@onready var timer_circle = $TimerCircle
@onready var score_label = Label.new()
@onready var progress_bar = ProgressBar.new()

var collection_timer = 0.0
var is_eaten = false
var player_node = null
var apple_lifetime = 0.0

const COLLECTION_TIME = 1.0
const TIMER_DURATION = 10.0

# Breathing variables
var breath_time = 0.0
const BREATH_SPEED = 5.0  
const BREATH_AMOUNT = 5.0

func _ready():
	if timer_circle:
		timer_circle.visible = false
		if timer_circle.material:
			timer_circle.material.set_shader_parameter("progress", 0.0)
	
	# Setup +1 label
	score_label.text = "+1"
	score_label.add_theme_font_size_override("font_size", 25)
	var font = load("res://Assets/Fonts/Bungee-Regular.ttf")
	score_label.add_theme_font_override("font", font)
	score_label.modulate = Color(0, 0, 0, 1)  
	score_label.visible = false
	score_label.position = Vector2(-20, -50)
	add_child(score_label)
	
	# Setup progress bar
	progress_bar.position = Vector2(-50, -50)  # Above the apple
	progress_bar.custom_minimum_size = Vector2(90, 20)  # Small rectangular bar
	progress_bar.show_percentage = false
	progress_bar.max_value = TIMER_DURATION
	progress_bar.value = TIMER_DURATION
	
	# Style the progress bar fill
	var stylebox = StyleBoxFlat.new()
	stylebox.bg_color = Color(0, 1, 0)  # Green color
	stylebox.corner_radius_top_left = 2
	stylebox.corner_radius_top_right = 2
	stylebox.corner_radius_bottom_left = 2
	stylebox.corner_radius_bottom_right = 2
	stylebox.content_margin_left = 0
	stylebox.content_margin_right = 0
	stylebox.content_margin_top = 0
	stylebox.content_margin_bottom = 0
	progress_bar.add_theme_stylebox_override("fill", stylebox)
	
	# Style the background (dark/transparent)
	var bg_stylebox = StyleBoxFlat.new()
	bg_stylebox.bg_color = Color(0.2, 0.2, 0.2, 0.8)  # Dark background
	bg_stylebox.corner_radius_top_left = 2
	bg_stylebox.corner_radius_top_right = 2
	bg_stylebox.corner_radius_bottom_left = 2
	bg_stylebox.corner_radius_bottom_right = 2
	progress_bar.add_theme_stylebox_override("background", bg_stylebox)
	
	add_child(progress_bar)

func _process(delta):
	if is_eaten:
		return
	
	# Breathing animation
	breath_time += delta * BREATH_SPEED
	anim.position.y = sin(breath_time) * BREATH_AMOUNT
	
	# Update apple lifetime and progress bar
	apple_lifetime += delta
	var time_left = TIMER_DURATION - apple_lifetime
	progress_bar.value = time_left
	
	# Change color based on time (green -> yellow -> red)
	var stylebox = progress_bar.get_theme_stylebox("fill")
	if time_left > 6:
		stylebox.bg_color = Color(0, 1, 0)  # Green
	elif time_left > 3:
		stylebox.bg_color = Color(1, 1, 0)  # Yellow
	else:
		stylebox.bg_color = Color(1, 0, 0)  # Red
	
	# Check if player is overlapping
	var is_overlapping = player_node and is_instance_valid(player_node) and overlaps_body(player_node)
	
	if is_overlapping:
		# Show circle and increment timer
		if timer_circle and not timer_circle.visible:
			timer_circle.visible = true
		
		# Hide progress bar when eating
		progress_bar.visible = false
		
		collection_timer += delta
		
		# Update progress
		var progress = clamp(collection_timer / COLLECTION_TIME, 0.0, 1.0)
		if timer_circle and timer_circle.material:
			timer_circle.material.set_shader_parameter("progress", progress)
		
		# Eat apple after collection time
		if collection_timer >= COLLECTION_TIME:
			_eat_apple()
	else:
		# Hide circle and reset
		if timer_circle and timer_circle.visible:
			timer_circle.visible = false
			if timer_circle.material:
				timer_circle.material.set_shader_parameter("progress", 0.0)
		collection_timer = 0.0
		
		# Show progress bar when not eating
		progress_bar.visible = true

func _eat_apple():
	if is_eaten:
		return
	
	is_eaten = true
	
	if timer_circle:
		timer_circle.visible = false
	
	# Hide progress bar
	progress_bar.visible = false
	
	# Show +1 animation
	score_label.visible = true
	var tween = create_tween()
	tween.tween_property(score_label, "position:y", score_label.position.y - 50, 0.5)
	tween.parallel().tween_property(score_label, "modulate:a", 0.0, 0.5)
	
	apple_eaten.emit()
	
	if anim:
		anim.animation = "collected"
		await anim.animation_finished
	
	queue_free()

func _on_body_entered(body: Node2D):
	if body.name == "Player":
		player_node = body

func _on_body_exited(body: Node2D):
	if body.name == "Player":
		player_node = null

func _on_timer_timeout():
	if not is_eaten:
		apple_missed.emit()
		queue_free()
