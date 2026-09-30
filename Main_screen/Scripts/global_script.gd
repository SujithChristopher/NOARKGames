extends Node

# ── session state ─────────────────────────────────────────────────────────────
var session_id: int = 1
var current_date: String = ""
var trial_counts: Dictionary = {}

# ── screen bounds ─────────────────────────────────────────────────────────────
var X_SCREEN_OFFSET: int
var Y_SCREEN_OFFSET: int
var Y_SCREEN_OFFSET3D: int

var current_score: int = 0
var path = "res://settings.json"

# 2D position scalers
@export var PLAYER_POS_SCALER_X: int = 20 * 100
@export var PLAYER_POS_SCALER_Z: int = 20 * 100

# 3D position scalers
@export var PLAYER3D_POS_SCALER_X: int = 20 * 100
@export var PLAYER3D_POS_SCALER_Y: int = 30 * 100

var screen_size: Vector2 = Vector2.ZERO
var MIN_X: int = 10
var MAX_X: int = 1900
var MIN_Y: int = 10
var MAX_Y: int = 1060

var clamp_vector_x = Vector2(MIN_X, MIN_Y)
var clamp_vector_y = Vector2(MAX_X, MAX_Y)

enum BLEStatus { IDLE, SCANNING, CONNECTING, CONNECTED }

var ble_status: BLEStatus:
	get:
		if connected:
			return BLEStatus.CONNECTED
		if _ble_connecting:
			return BLEStatus.CONNECTING
		if _ble_scan_active:
			return BLEStatus.SCANNING
		return BLEStatus.IDLE

# ── origin / local-coordinate state ──────────────────────────────────────────
var _origin_set:       bool   = false
var _origin_basis:     Basis  = Basis.IDENTITY
var _origin_ref_point: Vector3 = Vector3.ZERO

# last ref-marker data received (used by set_origin())
var _last_rvec:     Vector3 = Vector3.ZERO
var _last_centroid: Vector3 = Vector3.ZERO
var _last_ref_id:   int     = -1

# ── transport settings ────────────────────────────────────────────────────────
var stream_type: String = "udp"
var ble_device_name: String = "NOARK_Tracker"
var udp_port: int = 8000

const BLE_SERVICE_UUID  = "4e4f4152-4b00-0000-0000-000000000000"
const BLE_POSITION_UUID = "4e4f4152-4b01-0000-0000-000000000000"
const BLE_COMMAND_UUID  = "4e4f4152-4b02-0000-0000-000000000000"

# ── UDP ───────────────────────────────────────────────────────────────────────
@onready var udp: PacketPeerUDP = PacketPeerUDP.new()
@onready var thread_network = Thread.new()
@onready var thread_python = Thread.new()
@onready var thread_path_check = Thread.new()

# ── BLE ───────────────────────────────────────────────────────────────────────
var _ble_manager = null          # BluetoothManager instance (gdble GDExtension — Windows/Linux)
var _ble_android_plugin = null   # GdAndroidBLE singleton (Android plugin)
var ble_device = null            # BleDevice instance (gdble only)
var _ble_target_address: String = ""
var _ble_connecting: bool = false
var _ble_can_write_command: bool = false
var _ble_command_with_response: bool = false
var _ble_scan_active: bool = false
var _ble_services_requested: bool = false
var _ble_subscription_ready: bool = false
var _ble_shutting_down: bool = false

# ── connection state ──────────────────────────────────────────────────────────
@onready var connected: bool = false
@onready var disconnected: bool = false
@onready var reset_position: bool = false

# ── python launcher ───────────────────────────────────────────────────────────
@onready var interpreter_path: String
@onready var pyscript_path: String
@onready var pypath_checker_path: String
@export var endgame: bool = false

# ── networked position (raw) ──────────────────────────────────────────────────
var net_x: float
var net_y: float
var net_z: float
var net_a: float
var raw_x: float
var raw_y: float
var raw_z: float

var network_position: Vector2   = Vector2.ZERO
var network_position3D: Vector2 = Vector2.ZERO
var workspace: Vector2          = Vector2.ZERO

var scaled_x: float
var scaled_y: float
var scaled_z: float
var scaled_network_position: Vector2   = Vector2.ZERO
var scaled_network_position3D: Vector2 = Vector2.ZERO

# ── packet rate (position packets/sec, UDP + BLE) ──────────────────────────────
var packets_per_second: int = 0
var _packet_count: int = 0
var _pps_accum_time: float = 0.0

# ── smoothed positions (lerped each frame — use these in games) ───────────────
@export var smooth_factor: float = 0.25
var smooth_network_position: Vector2   = Vector2.ZERO
var smooth_network_position3D: Vector2 = Vector2.ZERO
var smooth_workspace: Vector2          = Vector2.ZERO
var smooth_scaled_network_position: Vector2   = Vector2.ZERO
var smooth_scaled_network_position3D: Vector2 = Vector2.ZERO

# ── messaging ─────────────────────────────────────────────────────────────────
var quit_request: bool = false
@export var delay_time = 0.1
@onready var message_timer: Timer = Timer.new()
var _outgoing_message = "CONNECTED"
var _incoming_message: float

@onready var debug: bool


func _ready() -> void:
	var settings = JSON.parse_string(FileAccess.get_file_as_string(path))
	debug           = settings.get("debug", false)
	stream_type     = settings.get("stream_type", "udp")
	ble_device_name = settings.get("ble_device_name", "NOARK_Tracker")
	udp_port        = settings.get("udp_port", 8000)
	_pin_to_cpus(settings.get("game_cpus", ""))

	current_date = get_date_string()
	load_session_info()

	# Use the actual rendered viewport area — correct on all platforms including
	# Android tablets where screen_get_size() can return physical pixels before
	# DPI scaling, system UI (nav bar / status bar), and stretch mode are applied.
	screen_size       = get_viewport().get_visible_rect().size
	MAX_X             = int(screen_size.x - screen_size.x * 0.15)
	MAX_Y             = int(screen_size.y - screen_size.y * 0.15)
	clamp_vector_x    = Vector2(MIN_X, MIN_Y)
	clamp_vector_y    = Vector2(MAX_X, MAX_Y)

	X_SCREEN_OFFSET   = int(screen_size.x / 2)
	Y_SCREEN_OFFSET   = int(screen_size.y / 2)
	Y_SCREEN_OFFSET3D = int(screen_size.y / 1.75)

	message_timer.autostart = true
	message_timer.wait_time = delay_time
	message_timer.one_shot  = false
	message_timer.timeout.connect(_on_heartbeat_tick)
	add_child(message_timer)

	GlobalSignals.SignalBus.connect(handle_quit_request)
	get_tree().set_auto_accept_quit(false)

	var root := _project_root()
	if OS.get_name() == "Windows":
		interpreter_path = root.path_join(".venv/Scripts/python.exe")
	else:
		interpreter_path = root.path_join(".venv/bin/python")
	pyscript_path       = root.path_join("pyscripts/tracker.py")
	pypath_checker_path = root.path_join("pyscripts/file_integrity.py")

	match stream_type:
		"udp":
			_init_udp()
		"ble":
			_init_ble()
		_:
			push_error("Unknown stream_type '%s' — falling back to UDP" % stream_type)
			stream_type = "udp"
			_init_udp()

	print(MAX_X, " " + str(MAX_Y))


# ── UDP ───────────────────────────────────────────────────────────────────────

func _init_udp() -> void:
	udp.connect_to_host("127.0.0.1", udp_port)
	thread_python.start(python_thread, Thread.PRIORITY_HIGH)
	thread_network.start(network_thread)


func network_thread() -> void:
	while true:
		if udp.get_available_packet_count() > 0:
			handle_udp_packet()
		else:
			# Idle-sleep instead of busy-spinning a full core while waiting for
			# the next packet; camera frames arrive every ~16-33ms, so this is
			# well under one frame period and doesn't add perceptible latency.
			OS.delay_usec(500)
		if disconnected:
			break


signal tracker_config_applied(text: String)


func handle_udp_packet() -> void:
	var packet    = udp.get_packet()
	# Text ack from the tracker for a CFG command (position packets are 44 bytes).
	if packet.size() != 44 and packet.slice(0, 4).get_string_from_ascii() == "CFG:":
		tracker_config_applied.emit.call_deferred(packet.get_string_from_ascii().substr(4))
		return
	var my_floats = PackedByteArray(packet).to_float32_array()
	udp.put_packet(_outgoing_message.to_utf8_buffer())
	_apply_position_packet(my_floats)


# ── BLE ───────────────────────────────────────────────────────────────────────

func _init_ble() -> void:
	if OS.get_name() == "Android":
		await _init_ble_android()
	else:
		_init_ble_gdextension()


func _init_ble_android() -> void:
	if not Engine.has_singleton("GdAndroidBLE"):
		push_error("[BLE] GdAndroidBLE plugin singleton not found. Enable the plugin in Project Settings.")
		return

	OS.request_permission("android.permission.BLUETOOTH_SCAN")
	OS.request_permission("android.permission.BLUETOOTH_CONNECT")
	OS.request_permission("android.permission.ACCESS_FINE_LOCATION")
	await get_tree().create_timer(1.0).timeout

	_ble_android_plugin = Engine.get_singleton("GdAndroidBLE")
	_ble_android_plugin.connect("adapter_initialized",   Callable(self, "_on_ble_adapter_initialized"))
	_ble_android_plugin.connect("device_discovered",     Callable(self, "_on_ble_android_device_discovered"))
	_ble_android_plugin.connect("scan_stopped",          Callable(self, "_on_ble_scan_stopped"))
	_ble_android_plugin.connect("device_connected",      Callable(self, "_on_ble_device_connected"))
	_ble_android_plugin.connect("device_disconnected",   Callable(self, "_on_ble_device_disconnected"))
	_ble_android_plugin.connect("connection_failed",     Callable(self, "_on_ble_connection_failed"))
	_ble_android_plugin.connect("services_discovered",   Callable(self, "_on_ble_android_services_discovered"))
	_ble_android_plugin.connect("characteristic_notified", Callable(self, "_on_ble_characteristic_notified"))
	_ble_android_plugin.connect("operation_failed",      Callable(self, "_on_ble_operation_failed"))
	_ble_android_plugin.connect("manager_error",         Callable(self, "_on_ble_manager_error"))
	_ble_android_plugin.initialize()


func _init_ble_gdextension() -> void:
	if not ClassDB.class_exists("BluetoothManager"):
		push_error("[BLE] BluetoothManager class not found. Check the GDBLE addon installation.")
		return

	_ble_manager = ClassDB.instantiate("BluetoothManager")
	if _ble_manager == null:
		push_error("[BLE] Failed to instantiate BluetoothManager")
		return

	add_child(_ble_manager)

	_ble_manager.adapter_initialized.connect(_on_ble_adapter_initialized)
	_ble_manager.device_discovered.connect(_on_ble_device_discovered)
	_ble_manager.scan_stopped.connect(_on_ble_scan_stopped)
	_ble_manager.error_occurred.connect(_on_ble_manager_error)

	if _ble_manager.has_method("set_debug_mode"):
		_ble_manager.set_debug_mode(debug)

	_ble_manager.initialize()


func _ble_start_scan(timeout_seconds: float = 10.0) -> void:
	if ble_device != null or _ble_connecting or _ble_scan_active:
		return
	if _ble_android_plugin == null and _ble_manager == null:
		return

	_ble_scan_active = true
	_ble_target_address = ""
	print("[BLE] Starting scan for %.1f seconds…" % timeout_seconds)
	if _ble_android_plugin:
		_ble_android_plugin.start_scan(timeout_seconds)
	else:
		_ble_manager.start_scan(timeout_seconds)


func _ble_connect_once(signal_ref: Signal, method_name: String) -> void:
	var callable := Callable(self, method_name)
	if not signal_ref.is_connected(callable):
		signal_ref.connect(callable)


func _on_ble_adapter_initialized(success: bool, error: String) -> void:
	if not success:
		push_error("[BLE] Failed to initialise Bluetooth adapter: " + error)
		return

	print("[BLE] Adapter ready — starting scan…")
	_ble_start_scan(10.0)


func _on_ble_device_discovered(device_info: Dictionary) -> void:
	if ble_device != null or _ble_connecting or _ble_target_address != "":
		return

	var dname := str(device_info.get("name", ""))
	var daddr := str(device_info.get("address", ""))
	print("[BLE] Device: '%s'  addr=%s" % [dname, daddr])

	if dname == ble_device_name and daddr != "":
		_ble_target_address = daddr
		print("[BLE] Target found — stopping scan…")
		_ble_manager.stop_scan()


func _on_ble_scan_stopped() -> void:
	_ble_scan_active = false

	if disconnected or endgame:
		return

	if ble_device != null or _ble_connecting:
		return

	var target_address := _ble_target_address
	_ble_target_address = ""

	if target_address == "":
		print("[BLE] Target not found — rescanning…")
		_ble_start_scan(10.0)
		return

	_ble_connect_to_target(target_address)


func _ble_connect_to_target(address: String) -> void:
	if address == "" or _ble_connecting:
		return
	if _ble_android_plugin == null and ble_device != null:
		return

	_ble_connecting = true
	_ble_can_write_command = false
	_ble_command_with_response = false
	_ble_services_requested = false
	_ble_subscription_ready = false

	print("[BLE] Connecting to %s…" % address)

	if _ble_android_plugin:
		_ble_android_plugin.connect_device(address)
		return

	ble_device = _ble_manager.connect_device(address)
	if ble_device == null:
		_ble_connecting = false
		push_error("[BLE] Failed to create device handle for " + address)
		_ble_target_address = ""
		_ble_start_scan(10.0)
		return

	_ble_connect_once(ble_device.connected, "_on_ble_device_connected")
	_ble_connect_once(ble_device.disconnected, "_on_ble_device_disconnected")
	_ble_connect_once(ble_device.connection_failed, "_on_ble_connection_failed")
	_ble_connect_once(ble_device.services_discovered, "_on_ble_services_discovered")
	_ble_connect_once(ble_device.characteristic_notified, "_on_ble_characteristic_notified")
	_ble_connect_once(ble_device.operation_failed, "_on_ble_operation_failed")
	ble_device.connect_async()


func _on_ble_device_connected() -> void:
	if _ble_services_requested:
		return
	if _ble_android_plugin == null and ble_device == null:
		return

	_ble_connecting = false
	_ble_services_requested = true
	print("[BLE] Device connected — discovering services…")
	if _ble_android_plugin:
		_ble_android_plugin.discover_services()
	else:
		ble_device.discover_services()


func _on_ble_connection_failed(error: String) -> void:
	_ble_connecting = false
	connected = false
	_ble_services_requested = false
	_ble_subscription_ready = false
	_ble_can_write_command = false
	push_error("[BLE] Connection failed: " + error)
	ble_device = null
	_ble_target_address = ""
	_ble_start_scan(10.0)


func _on_ble_device_disconnected() -> void:
	connected = false
	_ble_connecting = false
	_ble_can_write_command = false
	_ble_scan_active = false
	_ble_services_requested = false
	_ble_subscription_ready = false
	ble_device = null
	_ble_target_address = ""

	if _ble_shutting_down or disconnected or endgame:
		print("[BLE] Device disconnected during shutdown")
		return

	print("[BLE] Device disconnected — rescanning…")
	if not disconnected and not endgame:
		_ble_start_scan(10.0)


func _on_ble_android_device_discovered(dev_name: String, dev_address: String) -> void:
	_on_ble_device_discovered({"name": dev_name, "address": dev_address})


func _on_ble_android_services_discovered(services_json: String) -> void:
	var services = JSON.parse_string(services_json)
	if typeof(services) == TYPE_ARRAY:
		_on_ble_services_discovered(services)
	else:
		push_error("[BLE] Failed to parse services JSON")


func _on_ble_services_discovered(services: Array) -> void:
	if _ble_subscription_ready:
		return
	if _ble_android_plugin == null and ble_device == null:
		return

	var found_position := false
	var found_command := false

	print("[BLE] Discovered %d service(s)" % services.size())
	for service in services:
		var service_uuid := str(service.get("uuid", "")).to_lower()
		if service_uuid != BLE_SERVICE_UUID:
			continue

		for characteristic in service.get("characteristics", []):
			var char_uuid := str(characteristic.get("uuid", "")).to_lower()
			var properties: Dictionary = characteristic.get("properties", {})

			if char_uuid == BLE_POSITION_UUID:
				found_position = true
			elif char_uuid == BLE_COMMAND_UUID:
				var can_write := bool(properties.get("write", false))
				var can_write_without_response := bool(
					properties.get("write_without_response", properties.get("write_no_response", false))
				)
				found_command = true
				_ble_command_with_response = can_write and not can_write_without_response

	_ble_can_write_command = found_command

	if not found_position:
		push_error("[BLE] Position characteristic not found")
		return

	_ble_subscription_ready = true
	if _ble_android_plugin:
		_ble_android_plugin.subscribe_characteristic(BLE_SERVICE_UUID, BLE_POSITION_UUID)
	else:
		ble_device.subscribe_characteristic(BLE_SERVICE_UUID, BLE_POSITION_UUID)
	connected = true
	print("[BLE] Connected and subscribed — streaming position data")

	if not found_command:
		push_error("[BLE] Command characteristic not writable")


func _on_ble_characteristic_notified(char_uuid: String, data: PackedByteArray) -> void:
	if char_uuid.to_lower() != BLE_POSITION_UUID:
		return

	if data.size() < 44 or (data.size() % 4) != 0:
		push_error("[BLE] Unexpected position payload size: %d" % data.size())
		return

	_apply_position_packet(data.to_float32_array())


func _on_ble_manager_error(error_message: String) -> void:
	push_error("[BLE] Manager error: " + error_message)


func _on_ble_operation_failed(operation: String, error: String) -> void:
	push_error("[BLE] %s failed: %s" % [operation, error])

	if operation == "write_characteristic" and error.to_lower().contains("closed"):
		print("[BLE] Characteristic handle was closed — resetting BLE connection")
		_on_ble_device_disconnected()


# ── shared position update (UDP + BLE) ───────────────────────────────────────

func set_origin() -> void:
	# The tracked point is taken straight from the packet rather than rebuilt
	# from a marker-offset table on this side.
	#
	# That table had to be kept in step with Python's by hand, and it had
	# already drifted (tag 4 differed by 9 cm) before the rigid body was
	# calibrated at all. Since the pose now arrives in the reference tag's
	# frame, rebuilding the point here would just recompute what Python already
	# sent in floats 1-3 — and get it wrong for any marker the table predates.
	if _last_ref_id < 0:
		push_error("set_origin: no marker data received yet")
		return
	var angle := _last_rvec.length()
	var axis  := _last_rvec.normalized() if angle > 0.0001 else Vector3.UP
	_origin_basis     = Basis(axis, angle)
	_origin_ref_point = _last_centroid
	_origin_set       = true
	GlobalSignals.origin_set.emit()


func _apply_position_packet(my_floats: PackedFloat32Array) -> void:
	_incoming_message = my_floats[0]
	_packet_count += 1

	# Cache what set_origin() needs: the board orientation, and the id that
	# says a packet has been seen at all. The board translation in floats 7-9
	# is not cached — the tracked point itself arrives in floats 1-3.
	_last_rvec   = Vector3(my_floats[4], my_floats[5], my_floats[6])
	_last_ref_id = int(my_floats[10])

	# Compute local coordinates (rotation + translation relative to origin)
	var centroid := Vector3(my_floats[1], my_floats[2], my_floats[3])
	_last_centroid = centroid
	var local: Vector3
	if _origin_set:
		local = _origin_basis.transposed() * (_origin_ref_point - centroid)
	else:
		local = centroid

	raw_x = local.x
	raw_y = local.y
	raw_z = local.z

	net_x = local.x * PLAYER_POS_SCALER_X  + X_SCREEN_OFFSET
	net_y = local.y * PLAYER3D_POS_SCALER_Y + Y_SCREEN_OFFSET3D
	net_z = local.z * PLAYER_POS_SCALER_Z   + Y_SCREEN_OFFSET
	net_a = local.y * PLAYER3D_POS_SCALER_Y + Y_SCREEN_OFFSET

	network_position   = Vector2(net_x, net_z)
	network_position3D = Vector2(net_x, net_y)
	workspace          = Vector2(net_x, net_a)

	scaled_x = local.x * PLAYER_POS_SCALER_X  * GlobalSignals.global_scalar_x + X_SCREEN_OFFSET
	scaled_y = local.y * PLAYER3D_POS_SCALER_Y * GlobalSignals.global_scalar_y + Y_SCREEN_OFFSET3D
	scaled_z = local.z * PLAYER_POS_SCALER_Z   * GlobalSignals.global_scalar_y + Y_SCREEN_OFFSET

	scaled_network_position   = Vector2(scaled_x, scaled_z)
	scaled_network_position3D = Vector2(scaled_x, scaled_y)


# Live tracker tuning (tracker.py _apply_config). Datagrams are capped at 30 bytes.
func send_tracker_config(key: String, value: String) -> void:
	_send_transport_message("CFG:%s=%s" % [key, value])


# ── transport send ────────────────────────────────────────────────────────────

func _send_transport_message(message: String) -> void:
	match stream_type:
		"udp":
			udp.put_packet(message.to_utf8_buffer())
		"ble":
			if _ble_android_plugin:
				if connected and _ble_can_write_command:
					_ble_android_plugin.write_characteristic(
						BLE_SERVICE_UUID, BLE_COMMAND_UUID,
						message.to_utf8_buffer(), _ble_command_with_response)
			elif ble_device != null and ble_device.is_connected() and _ble_can_write_command:
				ble_device.write_characteristic(
					BLE_SERVICE_UUID, BLE_COMMAND_UUID,
					message.to_utf8_buffer(), _ble_command_with_response)


func _on_heartbeat_tick() -> void:
	_send_transport_message(_outgoing_message)


# ── process ───────────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	# UDP: watchdog to restart Python if it crashes
	if stream_type == "udp" and not thread_python.is_alive() and not endgame and not debug:
		thread_python = Thread.new()
		thread_python.start(python_thread, Thread.PRIORITY_HIGH)

	# Packet rate: tally the running counter into packets_per_second once a second
	_pps_accum_time += _delta
	if _pps_accum_time >= 1.0:
		packets_per_second = _packet_count
		_packet_count      = 0
		_pps_accum_time   -= 1.0

	# Smooth raw network positions toward latest received value
	var t := smooth_factor
	smooth_network_position        = smooth_network_position.lerp(network_position, t)
	smooth_network_position3D      = smooth_network_position3D.lerp(network_position3D, t)
	smooth_workspace               = smooth_workspace.lerp(workspace, t)
	smooth_scaled_network_position = smooth_scaled_network_position.lerp(scaled_network_position, t)
	smooth_scaled_network_position3D = smooth_scaled_network_position3D.lerp(scaled_network_position3D, t)

	match _incoming_message:
		-99.0:
			disconnected = true
			endgame      = true
			if stream_type == "udp":
				thread_network.wait_to_finish()
				thread_python.wait_to_finish()
			get_tree().quit()
		2.0:
			connected = true
		5.0:
			reset_position = true


# ── UDP threads ───────────────────────────────────────────────────────────────

func python_thread() -> void:
	if not debug:
		var output = []
		print("Python thread started.")
		OS.execute(interpreter_path, [pyscript_path], output)
		print(output)
	else:
		print("Debugging…")


func _path_checker() -> void:
	var output = []
	print(output)


# ── quit / patient change ─────────────────────────────────────────────────────

func handle_quit_request() -> void:
	disconnected = true
	endgame = true
	_ble_shutting_down = true
	_ble_scan_active = false
	_ble_target_address = ""
	connected = false

	if is_instance_valid(message_timer):
		message_timer.stop()

	_outgoing_message = "STOP"
	print("Camera closed properly")
	_send_transport_message(_outgoing_message)


func change_patient() -> void:
	_outgoing_message = "USER:" + PatientDB.current_patient_id


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		handle_quit_request()
		if stream_type == "udp":
			thread_python.wait_to_finish()
		elif stream_type == "ble":
			if _ble_android_plugin:
				_ble_android_plugin.stop_scan()
				_ble_android_plugin.disconnect_device()
			else:
				if ble_device != null:
					ble_device.disconnect()
				if _ble_manager != null:
					_ble_manager.stop_scan()
		get_tree().quit()


# ── path helpers ─────────────────────────────────────────────────────────────

func _pin_to_cpus(spec: String) -> void:
	# Keep the game off the cores the tracker needs. This board is 4+3+1:
	# cpu0-3 are the little cores, cpu4-6 the big ones and cpu7 the prime, and
	# left alone the scheduler will happily put marker detection on a little
	# core while the game holds a big one.
	#
	# Godot exposes no affinity call, so this goes through taskset. -a covers
	# every thread, not just the main one, since the rendering and audio
	# threads are the point. Done before the tracker is spawned, and the
	# tracker sets its own mask, so it does not inherit this one.
	if spec.is_empty() or OS.get_name() != "Linux":
		return
	var output := []
	var code := OS.execute("taskset", ["-a", "-pc", spec, str(OS.get_process_id())],
		output, true)
	if code == 0:
		print("[CPU] Game pinned to cores %s" % spec)
	else:
		push_warning("[CPU] Could not pin the game to %s: %s" % [spec, output])


func _project_root() -> String:
	# In the editor res:// maps to the project directory on disk.
	# In an exported build it maps to the PCK, so we use the executable's
	# directory instead — Python scripts must be deployed alongside the binary.
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://")
	return OS.get_executable_path().get_base_dir()


# ── session helpers ───────────────────────────────────────────────────────────

func get_date_string() -> String:
	var time = Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d" % [time.year, time.month, time.day]


func start_new_session_if_needed() -> void:
	var today = get_date_string()
	if today != current_date:
		current_date = today
		session_id   = 1
		trial_counts.clear()
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


func load_session_info() -> void:
	if FileAccess.file_exists("user://session.json"):
		var file = FileAccess.open("user://session.json", FileAccess.READ)
		var data = JSON.parse_string(file.get_as_text())
		if typeof(data) == TYPE_DICTIONARY:
			current_date = data.get("current_date", get_date_string())
			session_id   = data.get("session_id", 1)
			trial_counts = data.get("trial_counts", {})


func save_session_info() -> void:
	var data = {
		"current_date": current_date,
		"session_id":   session_id,
		"trial_counts": trial_counts,
	}
	var file = FileAccess.open("user://session.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(data))


func get_top_score_for_game(game_name: String, p_id: String) -> int:
	var top_score := 0
	var folder_path = GlobalSignals.data_path + "/" + p_id + "/GameData"

	if DirAccess.dir_exists_absolute(folder_path):
		print("inside")
		var dir = DirAccess.open(folder_path)
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if file_name.ends_with(".csv") and file_name.begins_with(game_name):
				var file = FileAccess.open(folder_path + "/" + file_name, FileAccess.READ)
				if file:
					var is_first_line = true
					while not file.eof_reached():
						var line = file.get_line()
						if is_first_line:
							is_first_line = false
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
