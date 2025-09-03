extends Node2D


@export var PLAYER_POS_SCALER_X: int = 1500 
@export var PLAYER_POS_SCALER_Y: int = 1500

@onready var points = []
@onready var convex_hull_points = PackedVector2Array()
@onready var active_workspace = []
@onready var mouse_pos
@onready var inflated_workspace
@onready var mouse_pressed:bool = false
@onready var mouse_current_first:bool = false
@onready var mouse_current_pos
@onready var mouse_previous_pos
@onready var _lines := $Lines
@onready var start_pressed:bool = true
@onready var current_index = 0
@onready var sprite_positions
@onready var player_offset = Vector2.ZERO
@onready var active_pols
@onready var training_pols
@onready var axdir
@onready var azdir
@onready var aydir
@onready var txdir
@onready var tzdir
@onready var tydir
@onready var rect_points
@onready var button_focus:bool = false
@onready var workspace_file


@onready var workspace_2d = $VBoxContainer
@onready var workspace_3d = $"3D_workspace"

var received_message
var thread: Thread
var the_message : String
var connected = false
var network_position
var _temp_message
var _presssed = false 
var _current_line : Line2D
var current_polyline: Line2D
var start_drawing : bool
var message = 'connected'
var json = JSON.new()
var hull


func process_workspace_areas(patient_dir_path: String) -> void:
	var dir = DirAccess.open(patient_dir_path)
	if dir == null:
		print("Failed to open directory:", patient_dir_path)
		return

	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".json"):
			var file_path = patient_dir_path + "/" + file_name
			var file = FileAccess.open(file_path, FileAccess.READ)
			if file:
				var content = file.get_as_text()
				var data = JSON.parse_string(content)
				if typeof(data) == TYPE_DICTIONARY:
					var active_str = data.get("active_workspace", "")
					var inflated_str = data.get("inflated_workspace", "")

					var active_area = parse_and_calculate_area(active_str)
					var inflated_area = parse_and_calculate_area(inflated_str)

					print("File:", file_name)
					print("  Active Area: ", active_area)
					print("  Inflated Area: ", inflated_area)
			else:
				print("Failed to open file:", file_path)
		file_name = dir.get_next()
	dir.list_dir_end()
	
	
	
func parse_and_calculate_area(polygon_str: String) -> float:
	if polygon_str == "":
		return 0.0
	
	# Remove the brackets and spaces
	var clean_str = polygon_str.strip_edges().replace("[", "").replace("]", "")
	var point_strs = clean_str.split("), (")
	
	var points = []
	for p_str in point_strs:
		p_str = p_str.replace("(", "").replace(")", "")
		var xy = p_str.split(",")
		if xy.size() == 2:
			var x = float(xy[0])
			var y = float(xy[1])
			points.append(Vector2(x, y))
	
	# Calculate area using shoelace formula
	var area = 0.0
	for i in range(points.size()):
		var j = (i + 1) % points.size()
		area += points[i].x * points[j].y
		area -= points[j].x * points[i].y
	area = abs(area) * 0.5
	return area
	
func _ready():
	GlobalSignals.assessment_done = false
	# Generate 100 random points for demonstration
	for i in range(100):
		active_workspace.append(Vector2(randi() % 400 + 350, randi() % 400 + 200))
		
	active_workspace = PackedVector2Array(Geometry2D.convex_hull(active_workspace))
	inflated_workspace = Geometry2D.convex_hull(inflate_polygon(active_workspace, -20))
	
	var offset_y = -85
	for i in range(active_workspace.size()):
		active_workspace[i].y += offset_y
	for i in range(inflated_workspace.size()):
		inflated_workspace[i].y += offset_y
	
	_current_line = Line2D.new()
	add_child(_current_line)
	
	
func _process(delta: float) -> void:

	if _presssed:
		message = 'close'

	if _temp_message == 'saved':
		message = 'connect'

	if _temp_message == "starting":
		start_drawing = true
		
	if GlobalSignals.selected_game_mode == "2D":
		network_position = GlobalScript.network_position
	else:
		network_position = GlobalScript.workspace

	if network_position != Vector2.ZERO and start_drawing:
		_current_line.width = 5
		_current_line.default_color = Color.RED
		_current_line.add_point(network_position + Vector2(100,200) - player_offset)
		
	if network_position != Vector2.ZERO:
		$Player.position = network_position  + Vector2(100,200) - player_offset
		
	if Input.is_action_just_released("mouse_left"):
		mouse_current_first = false
		mouse_pressed = false
		
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		mouse_pressed = true
		if not mouse_current_first:
			mouse_previous_pos = get_viewport().get_mouse_position()
			mouse_current_first = true
			
	if mouse_pressed:
		mouse_pos = (get_viewport().get_mouse_position() - mouse_previous_pos).length()
		if Geometry2D.is_point_in_polygon(get_viewport().get_mouse_position(), inflated_workspace) and not button_focus:
			inflated_workspace = Geometry2D.convex_hull(inflate_polygon(active_workspace, -mouse_pos))
		queue_redraw()
	get_xy_cm()

func calculate_polygon_area(points: Array) -> float:
	var area = 0.0
	var n = points.size()
	for i in range(n):
		var j = (i + 1) % n
		area += points[i].x * points[j].y
		area -= points[j].x * points[i].y
	return (abs(area) * 0.5)/ GlobalScript.PLAYER_POS_SCALER_X * 100
	
func get_xy_cm():
	active_pols = get_rect(active_workspace)
	
	if GlobalSignals.selected_game_mode == "2D":
		axdir = abs(active_pols[0][0]-active_pols[1][0]) / GlobalScript.PLAYER_POS_SCALER_X*100
		azdir = abs(active_pols[0][1]-active_pols[1][1]) / GlobalScript.PLAYER_POS_SCALER_Z*100

		training_pols = get_rect(inflated_workspace)
		txdir = abs(training_pols[0][0]-training_pols[1][0]) / GlobalScript.PLAYER_POS_SCALER_X*100
		tzdir = abs(training_pols[0][1]-training_pols[1][1]) / GlobalScript.PLAYER_POS_SCALER_Z*100
	  
		workspace_3d.hide()
		workspace_2d.visible = true
		$VBoxContainer/HBoxContainer/axval.text = String("%.2f cm" % axdir)
		$VBoxContainer/HBoxContainer3/azval.text = String("%.2f cm" % azdir)
		$VBoxContainer/HBoxContainer2/txval.text = String("%.2f cm" % txdir)
		$VBoxContainer/HBoxContainer4/tzval.text = String("%.2f cm" % tzdir)
	  
	
	else:
		axdir = abs(active_pols[0][0]-active_pols[1][0]) / GlobalScript.PLAYER_POS_SCALER_X*100
		aydir = abs(active_pols[0][1]-active_pols[1][1]) / GlobalScript.PLAYER3D_POS_SCALER_Y*100

		training_pols = get_rect(inflated_workspace)
		txdir = abs(training_pols[0][0]-training_pols[1][0]) / GlobalScript.PLAYER_POS_SCALER_X*100
		tydir = abs(training_pols[0][1]-training_pols[1][1]) / GlobalScript.PLAYER3D_POS_SCALER_Y*100

		workspace_2d.hide()
		workspace_3d.visible = true
		$"3D_workspace/HBoxContainer/axval".text = String("%.2f cm" % axdir)
		$"3D_workspace/HBoxContainer3/ayval".text = String("%.2f cm" % aydir)
		$"3D_workspace/HBoxContainer2/txval".text = String("%.2f cm" % txdir)
		$"3D_workspace/HBoxContainer4/tyval".text = String("%.2f cm" % tydir)
	
func inflate_polygon(polygon: Array, distance: float) -> Array:
	var inflated_polygon = []
	var length = polygon.size()


	for i in range(length):
		var current_point = polygon[i]
		var next_point = polygon[(i + 1) % length]

		# Compute the edge direction
		var edge_dir = (next_point - current_point).normalized()

		# Compute the perpendicular direction to the edge (outward)
		var perp_dir = Vector2(-edge_dir.y, edge_dir.x)

		# Offset the points by the distance along the perpendicular direction
		inflated_polygon.append(current_point + perp_dir * distance)
		inflated_polygon.append(next_point + perp_dir * distance)

	return inflated_polygon

func _draw() -> void:
	var hull_colors = PackedColorArray()
	hull_colors.append(Color(0.5, 0.5, 1.0, 0.8))
	
	var colors = PackedColorArray()
	colors.append(Color(0.5, 0.5, 1.0, 0.5)) 
	
	draw_polygon(active_workspace, hull_colors)
	draw_polygon(inflated_workspace, colors)
	
	rect_points = get_aabb(inflated_workspace)
	
	if rect_points:
		draw_rect(rect_points, Color(0.0, 0.5, 1.0, 0.8), false, 2)

func reduce_to_seven_points(hull):
	var step = hull.size() / 7
	var reduced_hull = []
	for i in range(7):
		reduced_hull.append(hull[int(i * step)])
	return reduced_hull


func _on_start_pressed() -> void:
	message = 'start'
	start_pressed = !start_pressed
	
	if start_pressed:
		start_drawing = false
		start_pressed = true
		$start.text = "Start"
	else:
		start_drawing = true
		start_pressed = false
		$start.text = "Stop"


func _on_set_orgin_pressed() -> void:
	message = 'set_orgin'


func _on_clear_pressed() -> void:
	_current_line.clear_points()


func _on_select_game_pressed() -> void:
	GlobalSignals.inflated_workspace = inflated_workspace
	if GlobalSignals.selected_game_mode == "2D":
		get_tree().change_scene_to_file("res://Main_screen/Scenes/select_game.tscn")
	else:
		get_tree().change_scene_to_file("res://Main_screen/Scenes/3d_games.tscn")
	
func get_rect(points):
	var min_x = points[0].x
	var max_x = points[0].x
	var min_y = points[0].y
	var max_y = points[0].y

	for point in points:
		min_x = min(min_x, point.x)
		max_x = max(max_x, point.x)
		min_y = min(min_y, point.y)
		max_y = max(max_y, point.y)
	var pac: PackedVector2Array = []
	pac.append(Vector2(min_x, min_y))
	pac.append(Vector2(max_x - min_x, max_y - min_y))
	return pac
	
func get_aabb(points):
	var min_x = points[0].x
	var max_x = points[0].x
	var min_y = points[0].y
	var max_y = points[0].y

	for point in points:
		min_x = min(min_x, point.x)
		max_x = max(max_x, point.x)
		min_y = min(min_y, point.y)
		max_y = max(max_y, point.y)

	return Rect2(Vector2(min_x, min_y), Vector2(max_x - min_x, max_y - min_y))	

func _on_stop_button_pressed() -> void:
	var aabb = get_aabb(_current_line.points)
	rect_points = aabb
	active_workspace = Geometry2D.convex_hull(_current_line.points)
	inflated_workspace = Geometry2D.convex_hull(inflate_polygon(active_workspace, -20))
	var prom_size = get_aabb(inflated_workspace).size
	GlobalSignals.global_scalar_x = get_viewport_rect().size.x /prom_size.x 
	GlobalSignals.global_scalar_y = get_viewport_rect().size.y /prom_size.y
	queue_redraw()

func _on_enter_mouse_entered() -> void:
	button_focus = true

func _on_enter_mouse_exited() -> void:
	button_focus = false

func _on_start_mouse_entered() -> void:
	button_focus = true

func _on_start_mouse_exited() -> void:
	button_focus = false

func _on_stop_button_mouse_entered() -> void:
	button_focus = true

func _on_stop_button_mouse_exited() -> void:
	button_focus = false

func _on_clear_mouse_entered() -> void:
	button_focus = true

func _on_clear_mouse_exited() -> void:
	button_focus = false

func _on_select_game_mouse_entered() -> void:
	button_focus = true

func _on_select_game_mouse_exited() -> void:
	button_focus = false


func _on_close_button_pressed() -> void:
	$SaveDialogBox.hide()

func _on_enter_pressed() -> void:
	var aabb = get_aabb(_current_line.points)
	rect_points = aabb
	active_workspace = Geometry2D.convex_hull(_current_line.points)
	var prom_size = get_aabb(inflated_workspace).size
	GlobalSignals.global_scalar_x = get_viewport_rect().size.x /prom_size.x 
	GlobalSignals.global_scalar_y = get_viewport_rect().size.y /prom_size.y
	GlobalSignals.assessment_done = true
	$SaveDialogBox.show()
	
	# GlobalSignals.current_patient_id
	var ws_path = 'workspace-' + Time.get_datetime_string_from_system().split('T')[0] + '.json'
	
	
	var new_workspace_file = FileAccess.open(GlobalSignals.data_path + '//' + GlobalSignals.current_patient_id + '//' + ws_path, FileAccess.WRITE)
	var store_dict = {'active_workspace':active_workspace, 'inflated_workspace': inflated_workspace, 
					'azdir':azdir, 'axdir':axdir, 'tzdir':tzdir, 'txdir':txdir}
	new_workspace_file.store_string(json.stringify(store_dict))
	new_workspace_file.close()

func _on_close_button_mouse_entered() -> void:
	button_focus = true

func _on_close_button_mouse_exited() -> void:
	button_focus = false
