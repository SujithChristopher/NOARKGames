extends Node

# Constants for screen bounds and scaling
var session_id: int = 1
var current_date: String = ""
var trial_counts: Dictionary = {}

# 2D offsets
var X_SCREEN_OFFSET: int
var Y_SCREEN_OFFSET: int

#3D offsets
var Y_SCREEN_OFFSET3D: int


var current_score: int = 0
var json = JSON.new()
var path = "res://debug.json"


# 2D Game positions
@export var PLAYER_POS_SCALER_X: int = 20 * 100
@export var PLAYER_POS_SCALER_Z: int = 20 * 100


# 3D Game positions
@export var PLAYER3D_POS_SCALER_X: int = 20 * 100
@export var PLAYER3D_POS_SCALER_Y: int = 30 * 100

var screen_size = DisplayServer.screen_get_size()
var MIN_X: int = 10
var MAX_X: int = int(screen_size.x - screen_size.x * .15)
var MIN_Y: int = 10
var MAX_Y: int = int(screen_size.y - screen_size.y * .15)

var clamp_vector_x = Vector2(MIN_X, MIN_Y)
var clamp_vector_y = Vector2(MAX_X, MAX_Y)

# UDP and threading
@onready var udp: PacketPeerUDP = PacketPeerUDP.new()
@onready var thread_network = Thread.new()
@onready var thread_python = Thread.new()
@onready var thread_path_check = Thread.new()

@onready var connected: bool = false
@onready var disconnected: bool = false
@onready var reset_position: bool = false

# Paths and platform-specific variables
@onready var interpreter_path: String
@onready var pyscript_path: String
@onready var pypath_checker_path : String
@export var endgame:bool = false

# Networked position
var net_x: float
var net_y: float
var net_z: float
var net_a: float
var raw_x: float
var raw_y: float
var raw_z: float

#2D Game network position
var network_position: Vector2 = Vector2.ZERO

#3D Game network position
var network_position3D: Vector2 = Vector2.ZERO

#Workspace network position
var workspace: Vector2 = Vector2.ZERO

# scaled position
var scaled_x: float
var scaled_y: float
var scaled_z: float

# 2D Game scaled
var scaled_network_position: Vector2 = Vector2.ZERO

#3D Game scaled
var scaled_network_position3D: Vector2 = Vector2.ZERO

var quit_request:bool = false
@export var delay_time = 0.1
@onready var message_timer:Timer = Timer.new()
var _outgoing_message = "CONNECTED"
var _incoming_message: float

@onready var debug:bool

func _ready():

	debug = JSON.parse_string(FileAccess.get_file_as_string(path))['debug']
	current_date = get_date_string()
	load_session_info()


	# Bind to port 8000 to RECEIVE UDP packets from MOBBO
	var bind_result = udp.bind(8000, "127.0.0.1")
	if bind_result == OK:
		print("✅ UDP socket bound to port 8000 - ready to receive CoP data")
	else:
		print("❌ Failed to bind UDP socket to port 8000 - Error code: %d" % bind_result)

	thread_python.start(python_thread, Thread.PRIORITY_HIGH)
	thread_network.start(network_thread)
	

	print(MAX_X, " " + str(MAX_Y))
	
#   2D Game offsets  
	X_SCREEN_OFFSET = int(screen_size.x/4)
	Y_SCREEN_OFFSET = int(screen_size.y/4)
	
#    3D Game offsets
	Y_SCREEN_OFFSET3D = int(screen_size.y/1.75)

	
	message_timer.autostart = true
	message_timer.wait_time = delay_time
	message_timer.one_shot = false
	# message_timer.timeout.connect(send_dummy_packet)
	add_child(message_timer)
	GlobalSignals.SignalBus.connect(handle_quit_request)
	get_tree().set_auto_accept_quit(false)
	
	if OS.get_name() == "Windows":
		pyscript_path = "E:\\mobbo_works\\mobbo_3d_env_full_version\\main.py"
		pypath_checker_path = "E:\\CMC\\pyprojects\\programs_rpi\\rpi_python\\file_integrity.py"
		interpreter_path = "C:\\Users\\Pintu\\miniconda3\\envs\\mpy11\\python.exe"
	else:
		pyscript_path = "/home/sujith/Documents/rpi_python/stream_optimize.py"
		pypath_checker_path = "/home/sujith/Documents/rpi_python/file_integrity.py"
		interpreter_path = "/home/sujith/Documents/rpi_python/venv/bin/python"
	
func _process(_delta: float) -> void:
	if not thread_python.is_alive() and not endgame and not debug:
		thread_python = Thread.new()
		thread_python.start(python_thread, Thread.PRIORITY_HIGH)
		
	match _incoming_message:
		-99.0:
			disconnected = true
			endgame = true
			thread_network.wait_to_finish()
			thread_python.wait_to_finish()
			get_tree().quit()
		2.0:
			connected = true
		5.0:
			reset_position = true

func _path_checker():
	var output = []
	OS.execute(interpreter_path, [pypath_checker_path], output)
	print(output)

func network_thread():
	while true:
		if udp.get_available_packet_count() > 0:
			print("Packet received")
			handle_udp_packet()
		if disconnected:
			break
func handle_quit_request():
	_outgoing_message = "STOP"
	print("Camera closed properly")
	udp.put_packet(_outgoing_message.to_utf8_buffer())

func handle_udp_packet():
	var packet = udp.get_packet()
	var my_floats = PackedByteArray(packet).to_float32_array()

	udp.put_packet(_outgoing_message.to_utf8_buffer())

	_incoming_message = my_floats[0]

	raw_x = my_floats[1]
	raw_y = my_floats[2]
	raw_z = my_floats[3]

	print(raw_x, raw_y)

	# Debug: Print GCoP values every 50 packets to avoid spam
	if Engine.get_process_frames() % 50 == 0:
		#print("=" * 50)
		print("🎮 MOBBO GCoP Data Received:")
		print("  Message Code: %.1f %s" % [_incoming_message, "(Connected)" if _incoming_message == 2.0 else ""])
		print("  Raw GCoP X: %.4f m %s" % [raw_x, "(Available)" if abs(raw_x) > 0.0001 else "(Zero/Not Available)"])
		print("  Raw GCoP Y: %.4f m %s" % [raw_y, "(Available)" if abs(raw_y) > 0.0001 else "(Zero/Not Available)"])
		print("  Raw GCoP Z: %.4f m %s" % [raw_z, "(Available)" if abs(raw_z) > 0.0001 else "(Zero/Not Available)"])
		#print("=" * 50)

	net_x = my_floats[1]*PLAYER_POS_SCALER_X + X_SCREEN_OFFSET
	net_y = my_floats[2]*PLAYER3D_POS_SCALER_Y + Y_SCREEN_OFFSET3D
	net_z = my_floats[3]*PLAYER_POS_SCALER_Z + Y_SCREEN_OFFSET
	net_a = my_floats[2]*PLAYER3D_POS_SCALER_Y + Y_SCREEN_OFFSET
 
	network_position = Vector2(net_x, net_z)
	network_position3D = Vector2(net_x, net_y)
	workspace = Vector2(net_x, net_a)
	
	scaled_x = my_floats[1]*PLAYER_POS_SCALER_X * GlobalSignals.global_scalar_x + X_SCREEN_OFFSET
	scaled_y = my_floats[2]*PLAYER3D_POS_SCALER_Y * GlobalSignals.global_scalar_y + Y_SCREEN_OFFSET3D
	scaled_z = my_floats[3]*PLAYER_POS_SCALER_Z * GlobalSignals.global_scalar_y + Y_SCREEN_OFFSET
	
	scaled_network_position = Vector2(scaled_x, scaled_z)
	scaled_network_position3D = Vector2(scaled_x, scaled_y)
	
	
func change_patient():
	_outgoing_message = 'USER:' + PatientDB.current_patient_id

func send_dummy_packet():
	 udp.put_packet(_outgoing_message.to_utf8_buffer())
	

func python_thread():
	if not debug:
		print("🐍 Python thread started with real-time output pipe...")

		# Use execute_with_pipe for real-time output
		var result = OS.execute_with_pipe(interpreter_path, [pyscript_path])
		

		# Check if we got the process info
		if result.has("stdio"):
			# stdio is an array: [stdin, stdout, stderr]
			var stdout = result["stdio"]  # Index 1 is stdout
			#var stderr = result["stdio"][1]  # Index 2 is stderr

			print("✅ MOBBO process started (PID: %d)" % result["pid"])
			while not endgame:
				# Read from stdout
				
				#print(stdout)
			
				var stdout_chunk = stdout.get_line()
				print(stdout_chunk)
				OS.delay_msec(50)  # Small delay to avoid busy waiting

		else:
			print("❌ Failed to start MOBBO process - no stdio in result")
			print("Result keys: ", result.keys())

		print("🛑 Python process ended.")
	else:
		print("Debugging...")

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		endgame = true
		handle_quit_request()
		thread_python.wait_to_finish()
		get_tree().quit()
		
func get_date_string() -> String:
	var time = Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d" % [time.year, time.month, time.day]

func start_new_session_if_needed():
	var today = get_date_string()
	if today != current_date:
		current_date = today
		session_id = 1
		trial_counts.clear()
		save_session_info()
	else:
		session_id += 1
		trial_counts.clear()
		save_session_info()

func get_next_trial_id(game_name: String) -> int:
	if not trial_counts.has(game_name):
		trial_counts[game_name] = 1
	else:
		trial_counts[game_name] += 1
	save_session_info()
	return trial_counts[game_name]
	
func load_session_info():
	if FileAccess.file_exists("user://session.json"):
		var file = FileAccess.open("user://session.json", FileAccess.READ)
		var data = JSON.parse_string(file.get_as_text())
		if typeof(data) == TYPE_DICTIONARY:
			current_date = data.get("current_date", get_date_string())
			session_id = data.get("session_id", 1)
			trial_counts = data.get("trial_counts", {})
			

func save_session_info():
	var data = {
		"current_date": current_date,
		"session_id": session_id,
		"trial_counts": trial_counts
	}
	var file = FileAccess.open("user://session.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(data))



#TODO: change this to file sorting functions and use for loops for finishing the job
func get_top_score_for_game(game_name: String, p_id: String) -> int:
	var top_score := 0
	var folder_path = GlobalSignals.data_path + "/" + p_id + "/GameData"
	

	if DirAccess.dir_exists_absolute(folder_path):
		
		print('inside')
		var dir = DirAccess.open(folder_path)
		dir.list_dir_begin()
		var file_name = dir.get_next()

		while file_name != "":
			if file_name.ends_with(".csv") and file_name.begins_with(game_name):
				var file_path = folder_path + "/" + file_name
				var file = FileAccess.open(file_path, FileAccess.READ)

				if file:
					var is_first_line = true
					while not file.eof_reached():
						var line = file.get_line()
						if is_first_line:
							is_first_line = false  # Skip header
							continue
						var fields = line.split(",")
						if fields.size() > 0:
							var score_str = fields[0].strip_edges()
							if score_str.is_valid_int():
								var score = int(score_str)
								if score > top_score:
									top_score = score
								

					file.close()
			file_name = dir.get_next()

	return top_score
