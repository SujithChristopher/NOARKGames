extends Node

const TableFit := preload("res://Main_screen/Scripts/table_fit.gd")
const LinkProtocol := preload("res://Main_screen/Scripts/link_protocol.gd")
const TrackerLink := preload("res://Main_screen/Scripts/tracker_link.gd")
const UdpTransport := preload("res://Main_screen/Scripts/udp_transport.gd")
const BleTransport := preload("res://Main_screen/Scripts/ble_transport.gd")

# ── screen bounds ─────────────────────────────────────────────────────────────
var X_SCREEN_OFFSET: int
var Y_SCREEN_OFFSET: int
var Y_SCREEN_OFFSET3D: int

var current_score: int = 0

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

## Where the tracker link is, for the status indicator (LinkProtocol.LinkStatus).
var link_status: int:
	get:
		return link.status() if link else LinkProtocol.LinkStatus.IDLE

# ── origin / local-coordinate state ──────────────────────────────────────────
var _origin_set:       bool   = false
var _origin_basis:     Basis  = Basis.IDENTITY
var _origin_ref_point: Vector3 = Vector3.ZERO

# last ref-marker data received (used by set_origin())
var _last_rvec:     Vector3 = Vector3.ZERO
var _last_centroid: Vector3 = Vector3.ZERO
var _last_ref_id:   int     = -1

# ── table frame ──────────────────────────────────────────────────────────────
# Defined on the main screen ("Define Table"): the hand is put on the four table
# corners, which fixes the zero, the axis directions and the px-per-metre scale
# in one go, so set_origin() is not needed. While set, it replaces the origin
# lock in _apply_position. Persisted in table.json next to settings.json.
var table_set:    bool        = false
var table_k:      float       = 0.0            # screen px per real metre
var table_r:      Vector2     = Vector2.ZERO   # hand, real metres from the table centre
var _table_basis: Transform2D = Transform2D.IDENTITY   # camera x-z -> screen-aligned unit axes
var _table_centre: Vector2    = Vector2.ZERO   # camera x-z of the table centre (m)
var _table_y0:    float       = 0.0

# ── tracker link ──────────────────────────────────────────────────────────────
## The app's end of the link to the tracker (tracker_link.gd), over the
## transport settings.json `stream_type` picks — the one place that choice is
## made (_start_link).
var link: Node
var _transport: Node
## The link's own signals, re-emitted here: restart_link() replaces the link,
## and whoever listens should not have to connect again.
signal link_connected_changed(connected: bool)
signal link_command_done(kind: int, ok: bool, detail: String)

# ── python launcher ───────────────────────────────────────────────────────────
@onready var interpreter_path: String
const SENDER_SCRIPT := "sender_raspberryPI.py"
var _quitting := false   # the close request is being handled (it waits for the upload)

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
var last_packet_ms: int = 0   # Time.get_ticks_msec() of the latest position packet; 0 = none yet
var _packet_count: int = 0
var _pps_accum_time: float = 0.0

# ── smoothed positions (lerped each frame — use these in games) ───────────────
@export var smooth_factor: float = 0.25
var smooth_network_position: Vector2   = Vector2.ZERO
var smooth_network_position3D: Vector2 = Vector2.ZERO
var smooth_workspace: Vector2          = Vector2.ZERO
var smooth_scaled_network_position: Vector2   = Vector2.ZERO
var smooth_scaled_network_position3D: Vector2 = Vector2.ZERO

@onready var debug: bool


func _ready() -> void:
	debug           = Settings.get_value("debug", false)
	_pin_to_cpus(Settings.get_value("game_cpus", ""))

	load_table()

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

	GlobalSignals.SignalBus.connect(handle_quit_request)
	get_tree().set_auto_accept_quit(false)

	var root := _project_root()
	if OS.get_name() == "Windows":
		interpreter_path = root.path_join(".venv/Scripts/python.exe")
	else:
		interpreter_path = root.path_join(".venv/bin/python")

	_start_link()

	print(MAX_X, " " + str(MAX_Y))


# ── tracker link ──────────────────────────────────────────────────────────────

## A CONFIG was applied by the tracker ("key=value"); the Tune panel shows it.
signal tracker_config_applied(text: String)
## The board's recordings and disk, after a STORAGE command (storage.py):
## {total, free, event, recordings: [{path, patient, session, name, bytes, active}]}.
signal storage_listed(info: Dictionary)


# The tracker runs on its own (the noark-tracker service on the board); the app
# connects to it over UDP when they share the board, BLE from a tablet.
func _start_link() -> void:
	match Settings.get_value("stream_type", "ble"):
		"udp":
			_transport = UdpTransport.new(Settings.get_value("udp_host", "127.0.0.1"),
				int(Settings.get_value("udp_port", 8000)))
		var other:
			if other != "ble":
				push_error("Unknown stream_type '%s' — using BLE" % other)
			_transport = BleTransport.new(Settings.get_value("ble_device_name", "NOARK_Tracker"), debug)
	add_child(_transport)
	link = TrackerLink.new(_transport)
	add_child(link)
	link.message.connect(_on_tracker_message)
	link.command_done.connect(_on_command_done)
	link.command_done.connect(link_command_done.emit)
	link.connected_changed.connect(link_connected_changed.emit)
	_transport.start()


## stream_type changed (Settings): end this link — and its session at the
## tracker — and connect again over the transport settings.json now names.
func restart_link() -> void:
	var session_id: String = link.session_id
	link.stop_now()
	link.close()
	link.queue_free()
	_transport.queue_free()
	_start_link()
	if not session_id.is_empty():
		link.set_session(session_id)


func _on_tracker_message(kind: int, msg: PackedByteArray) -> void:
	match kind:
		LinkProtocol.POSITION:
			var pos := LinkProtocol.decode_position(msg)
			if pos.is_empty():
				push_error("[LINK] Short POSITION: %d bytes" % msg.size())
				return
			_apply_position(pos)
		LinkProtocol.TRUNK_STATUS:
			TrunkMonitor.on_packet(LinkProtocol.payload_text(msg))
		LinkProtocol.SNAPSHOT:
			TrunkMonitor.on_snapshot(msg.slice(1))
		LinkProtocol.STORAGE_LIST:
			var info = JSON.parse_string(LinkProtocol.payload_text(msg))
			if info is Dictionary:
				storage_listed.emit(info)
			else:
				push_error("[LINK] Unreadable STORAGE_LIST")
		_:
			push_warning("[LINK] Unexpected message type 0x%02x" % kind)


func _on_command_done(kind: int, ok: bool, detail: String) -> void:
	if kind == LinkProtocol.CONFIG and ok:
		tracker_config_applied.emit(detail)


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


# Hand position as the tracker reports it, before any origin or table (camera frame, m).
func hand_camera() -> Vector3:
	return _last_centroid


# corners: camera (x, z) of the hand at TL, TR, BL, BR of the table, in metres.
# Fits the affine that stretches them onto the screen corners, then keeps its
# rotation and centre but one scale (the smaller), so the table fits and a
# circle on the table stays a circle on screen. Returns false if degenerate.
func set_table(corners: Array, y0: float) -> bool:
	if corners.size() < 4:
		return false
	var sz := screen_size if screen_size.x > 0.0 else get_viewport().get_visible_rect().size
	var dst: Array = [Vector2(0, 0), Vector2(sz.x, 0), Vector2(0, sz.y), Vector2(sz.x, sz.y)]
	var fit = TableFit.fit(corners, dst)
	if fit == null:
		return false
	var fr: Dictionary = TableFit.frame(fit)
	var k: float = fr["k"]
	if k < 1.0:
		return false
	var centre: Vector2 = fit.affine_inverse() * (sz * 0.5)
	_table_basis = fr["basis"]
	_table_centre = centre
	_table_y0 = y0
	table_k = k
	table_set = true
	save_table()
	return true


func clear_table() -> void:
	table_set = false
	table_r = Vector2.ZERO
	if FileAccess.file_exists(_table_path()):
		DirAccess.remove_absolute(_table_path())


func _table_path() -> String:
	return Settings.path.get_base_dir().path_join("table.json")


func save_table() -> void:
	var d := {
		"k": table_k, "y0": _table_y0,
		"centre": [_table_centre.x, _table_centre.y],
		"basis": [_table_basis.x.x, _table_basis.x.y, _table_basis.y.x, _table_basis.y.y],
	}
	DirAccess.make_dir_recursive_absolute(_table_path().get_base_dir())
	var f := FileAccess.open(_table_path(), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(d))


func load_table() -> void:
	if not FileAccess.file_exists(_table_path()):
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(_table_path()))
	if not d is Dictionary or not d.has("basis") or not d.has("centre"):
		return
	var b: Array = d["basis"]
	var c: Array = d["centre"]
	if b.size() != 4 or c.size() != 2 or float(d.get("k", 0.0)) < 1.0:
		return
	_table_basis = Transform2D(Vector2(b[0], b[1]), Vector2(b[2], b[3]), Vector2.ZERO)
	_table_centre = Vector2(c[0], c[1])
	_table_y0 = float(d.get("y0", 0.0))
	table_k = float(d["k"])
	table_set = true


func _apply_position(pos: Dictionary) -> void:
	_packet_count += 1
	last_packet_ms = Time.get_ticks_msec()

	# Cache what set_origin() needs: the board orientation, and the id that
	# says a packet has been seen at all. The board translation is not cached —
	# the tracked point itself arrives as the centroid.
	_last_rvec   = pos["rvec"]
	_last_ref_id = pos["ref_id"]

	# Compute local coordinates (rotation + translation relative to origin)
	var centroid: Vector3 = pos["centroid"]
	_last_centroid = centroid
	var local: Vector3
	if table_set:
		# Real metres from the table centre, axes aligned with the screen; the
		# px-per-metre scale is folded in so the usual `local * SCALER` lands on
		# the table-fitted pixel.
		table_r = _table_basis * (Vector2(centroid.x, centroid.z) - _table_centre)
		local = Vector3(table_r.x * table_k / PLAYER_POS_SCALER_X, centroid.y - _table_y0,
			table_r.y * table_k / PLAYER_POS_SCALER_Z)
	elif _origin_set:
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


# Live tracker tuning (tracker.py _apply_setting); applied ones come back as
# tracker_config_applied.
func send_tracker_config(key: String, value: String) -> void:
	link.send_command(LinkProtocol.CONFIG, "%s=%s" % [key, value])


# Trunk commands (TrunkMonitor): "neutral", "snapshot", "select=<n>".
func send_trunk_command(arg: String) -> void:
	link.send_command(LinkProtocol.TRUNK, arg)


# The board's recordings (Settings > Storage): "list", "delete=<path>". Each
# answer comes as storage_listed; a refused one as link.command_done.
func send_storage_command(arg: String) -> void:
	link.send_command(LinkProtocol.STORAGE, arg)


# ── process ───────────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
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


# ── quit / patient change ─────────────────────────────────────────────────────

# GlobalSignals.SignalBus: a screen is about to quit at once (main_window). The
# STOP goes out now, without waiting for its ACK; the tracker would close the
# session 3 s later anyway.
func handle_quit_request() -> void:
	if link:
		link.stop_now()


# Opens the tracker's session for this patient (its logs and recordings); a
# different id than before closes the previous session first.
func change_patient() -> void:
	link.set_session(PatientDB.current_patient_id)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if _quitting:
			return
		_quitting = true
		# The tracker keeps running for the next app: only the session ends.
		await link.stop_session()
		link.close()
		# The last trial's row goes to the server before the app goes.
		SessionLog.end_trial()
		if SessionLog.is_uploading():
			get_tree().paused = true
			_show_upload_notice()
			await SessionLog.uploads_finished
		get_tree().quit()


func _show_upload_notice() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 128
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.75)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(shade)
	var label := Label.new()
	label.text = "Saving the session to the server..."
	label.add_theme_font_size_override("font_size", 36)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.add_child(label)
	add_child(layer)


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


## The Python that runs the helper scripts: the project's venv, else python3.
func python() -> String:
	return interpreter_path if FileAccess.file_exists(interpreter_path) else "python3"


## sender_raspberryPI.py: patient sync (--sync) and session upload (--upload).
func sender_path() -> String:
	return _project_root().path_join(SENDER_SCRIPT)


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
