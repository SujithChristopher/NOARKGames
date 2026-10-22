extends Node
## BLE to the tracker (docs/PROTOCOL.md): finds the GATT peripheral named
## `ble_device_name`, subscribes to its notify characteristic and writes to its
## command characteristic, reconnecting whenever the link drops. Only moves
## bytes — tracker_link.gd says what they mean. Same interface as udp_transport.gd.
##
## Two backends: the GdAndroidBLE plugin on Android, the gdble GDExtension
## (BluetoothManager) elsewhere. See CLAUDE.md for the Android permission and
## export gotchas.

const LinkProtocol := preload("res://Main_screen/Scripts/link_protocol.gd")

## One message from the tracker.
signal received(message: PackedByteArray)

const SERVICE_UUID  = "4e4f4152-4b00-0000-0000-000000000000"
const TO_APP_UUID   = "4e4f4152-4b01-0000-0000-000000000000"   # notify
const TO_TRACKER_UUID = "4e4f4152-4b02-0000-0000-000000000000" # write

var _device_name: String
var _debug: bool

var _manager = null          # BluetoothManager (gdble GDExtension — Windows/Linux)
var _android = null          # GdAndroidBLE singleton (Android plugin)
var _device = null           # BleDevice (gdble only)
var _target_address := ""
var _connecting := false
var _can_write := false
var _write_with_response := false
var _scanning := false
var _services_requested := false
var _subscribed := false
var _up := false             # subscribed and writable: messages flow both ways
var _stopping := false


func _init(device_name: String, debug: bool) -> void:
	_device_name = device_name
	_debug = debug
	process_mode = Node.PROCESS_MODE_ALWAYS


func start() -> void:
	if OS.get_name() == "Android":
		await _init_android()
	else:
		_init_gdextension()


func send(message: PackedByteArray) -> void:
	if not _up or not _can_write:
		return
	if _android:
		_android.write_characteristic(SERVICE_UUID, TO_TRACKER_UUID, message, _write_with_response)
	elif _device != null and _device.is_connected():
		_device.write_characteristic(SERVICE_UUID, TO_TRACKER_UUID, message, _write_with_response)


func status() -> int:
	if _up:
		return LinkProtocol.LinkStatus.CONNECTED
	if _connecting:
		return LinkProtocol.LinkStatus.CONNECTING
	if _scanning:
		return LinkProtocol.LinkStatus.SCANNING
	return LinkProtocol.LinkStatus.IDLE


func stop() -> void:
	_stopping = true
	_scanning = false
	_target_address = ""
	_up = false
	if _android:
		_android.stop_scan()
		_android.disconnect_device()
	else:
		if _device != null:
			_device.disconnect()
		if _manager != null:
			_manager.stop_scan()


# ── backends ──────────────────────────────────────────────────────────────────

func _init_android() -> void:
	if not Engine.has_singleton("GdAndroidBLE"):
		push_error("[BLE] GdAndroidBLE plugin singleton not found. Enable the plugin in Project Settings.")
		return

	OS.request_permission("android.permission.BLUETOOTH_SCAN")
	OS.request_permission("android.permission.BLUETOOTH_CONNECT")
	OS.request_permission("android.permission.ACCESS_FINE_LOCATION")
	await get_tree().create_timer(1.0).timeout

	_android = Engine.get_singleton("GdAndroidBLE")
	_android.connect("adapter_initialized",   Callable(self, "_on_adapter_initialized"))
	_android.connect("device_discovered",     Callable(self, "_on_android_device_discovered"))
	_android.connect("scan_stopped",          Callable(self, "_on_scan_stopped"))
	_android.connect("device_connected",      Callable(self, "_on_device_connected"))
	_android.connect("device_disconnected",   Callable(self, "_on_device_disconnected"))
	_android.connect("connection_failed",     Callable(self, "_on_connection_failed"))
	_android.connect("services_discovered",   Callable(self, "_on_android_services_discovered"))
	_android.connect("characteristic_notified", Callable(self, "_on_characteristic_notified"))
	_android.connect("operation_failed",      Callable(self, "_on_operation_failed"))
	_android.connect("manager_error",         Callable(self, "_on_manager_error"))
	_android.initialize()


func _init_gdextension() -> void:
	if not ClassDB.class_exists("BluetoothManager"):
		push_error("[BLE] BluetoothManager class not found. Check the GDBLE addon installation.")
		return

	_manager = ClassDB.instantiate("BluetoothManager")
	if _manager == null:
		push_error("[BLE] Failed to instantiate BluetoothManager")
		return

	add_child(_manager)

	_manager.adapter_initialized.connect(_on_adapter_initialized)
	_manager.device_discovered.connect(_on_device_discovered)
	_manager.scan_stopped.connect(_on_scan_stopped)
	_manager.error_occurred.connect(_on_manager_error)

	if _manager.has_method("set_debug_mode"):
		_manager.set_debug_mode(_debug)

	_manager.initialize()


# ── scan and connect ──────────────────────────────────────────────────────────

func _start_scan(timeout_seconds: float = 10.0) -> void:
	if _device != null or _connecting or _scanning or _stopping:
		return
	if _android == null and _manager == null:
		return

	_scanning = true
	_target_address = ""
	print("[BLE] Starting scan for %.1f seconds…" % timeout_seconds)
	if _android:
		_android.start_scan(timeout_seconds)
	else:
		_manager.start_scan(timeout_seconds)


func _connect_once(signal_ref: Signal, method_name: String) -> void:
	var callable := Callable(self, method_name)
	if not signal_ref.is_connected(callable):
		signal_ref.connect(callable)


func _on_adapter_initialized(success: bool, error: String) -> void:
	if not success:
		push_error("[BLE] Failed to initialise Bluetooth adapter: " + error)
		return

	print("[BLE] Adapter ready — starting scan…")
	_start_scan(10.0)


func _on_device_discovered(device_info: Dictionary) -> void:
	if _device != null or _connecting or _target_address != "":
		return

	var dname := str(device_info.get("name", ""))
	var daddr := str(device_info.get("address", ""))
	print("[BLE] Device: '%s'  addr=%s" % [dname, daddr])

	if dname == _device_name and daddr != "":
		_target_address = daddr
		print("[BLE] Target found — stopping scan…")
		if _android:
			_android.stop_scan()
		else:
			_manager.stop_scan()


func _on_scan_stopped() -> void:
	_scanning = false

	if _stopping or _device != null or _connecting:
		return

	var target_address := _target_address
	_target_address = ""

	if target_address == "":
		print("[BLE] Target not found — rescanning…")
		_start_scan(10.0)
		return

	_connect_to_target(target_address)


func _connect_to_target(address: String) -> void:
	if address == "" or _connecting:
		return
	if _android == null and _device != null:
		return

	_connecting = true
	_can_write = false
	_write_with_response = false
	_services_requested = false
	_subscribed = false

	print("[BLE] Connecting to %s…" % address)

	if _android:
		_android.connect_device(address)
		return

	_device = _manager.connect_device(address)
	if _device == null:
		_connecting = false
		push_error("[BLE] Failed to create device handle for " + address)
		_target_address = ""
		_start_scan(10.0)
		return

	_connect_once(_device.connected, "_on_device_connected")
	_connect_once(_device.disconnected, "_on_device_disconnected")
	_connect_once(_device.connection_failed, "_on_connection_failed")
	_connect_once(_device.services_discovered, "_on_services_discovered")
	_connect_once(_device.characteristic_notified, "_on_characteristic_notified")
	_connect_once(_device.operation_failed, "_on_operation_failed")
	_device.connect_async()


func _on_device_connected() -> void:
	if _services_requested:
		return
	if _android == null and _device == null:
		return

	_connecting = false
	_services_requested = true
	print("[BLE] Device connected — discovering services…")
	if _android:
		_android.discover_services()
	else:
		_device.discover_services()


func _on_connection_failed(error: String) -> void:
	_connecting = false
	_up = false
	_services_requested = false
	_subscribed = false
	_can_write = false
	push_error("[BLE] Connection failed: " + error)
	_device = null
	_target_address = ""
	_start_scan(10.0)


func _on_device_disconnected() -> void:
	_up = false
	_connecting = false
	_can_write = false
	_scanning = false
	_services_requested = false
	_subscribed = false
	_device = null
	_target_address = ""

	if _stopping:
		print("[BLE] Device disconnected during shutdown")
		return

	print("[BLE] Device disconnected — rescanning…")
	_start_scan(10.0)


func _on_android_device_discovered(dev_name: String, dev_address: String) -> void:
	_on_device_discovered({"name": dev_name, "address": dev_address})


func _on_android_services_discovered(services_json: String) -> void:
	var services = JSON.parse_string(services_json)
	if typeof(services) == TYPE_ARRAY:
		_on_services_discovered(services)
	else:
		push_error("[BLE] Failed to parse services JSON")


func _on_services_discovered(services: Array) -> void:
	if _subscribed:
		return
	if _android == null and _device == null:
		return

	var found_to_app := false
	var found_to_tracker := false

	print("[BLE] Discovered %d service(s)" % services.size())
	for service in services:
		var service_uuid := str(service.get("uuid", "")).to_lower()
		if service_uuid != SERVICE_UUID:
			continue

		for characteristic in service.get("characteristics", []):
			var char_uuid := str(characteristic.get("uuid", "")).to_lower()
			var properties: Dictionary = characteristic.get("properties", {})

			if char_uuid == TO_APP_UUID:
				found_to_app = true
			elif char_uuid == TO_TRACKER_UUID:
				var can_write := bool(properties.get("write", false))
				var can_write_without_response := bool(
					properties.get("write_without_response", properties.get("write_no_response", false))
				)
				found_to_tracker = true
				_write_with_response = can_write and not can_write_without_response

	_can_write = found_to_tracker

	if not found_to_app:
		push_error("[BLE] Notify characteristic not found")
		return

	_subscribed = true
	if _android:
		_android.subscribe_characteristic(SERVICE_UUID, TO_APP_UUID)
	else:
		_device.subscribe_characteristic(SERVICE_UUID, TO_APP_UUID)
	_up = true
	print("[BLE] Connected and subscribed")

	if not found_to_tracker:
		push_error("[BLE] Command characteristic not writable")


func _on_characteristic_notified(char_uuid: String, data: PackedByteArray) -> void:
	if char_uuid.to_lower() == TO_APP_UUID:
		received.emit(data)


func _on_manager_error(error_message: String) -> void:
	push_error("[BLE] Manager error: " + error_message)


func _on_operation_failed(operation: String, error: String) -> void:
	push_error("[BLE] %s failed: %s" % [operation, error])

	if operation == "write_characteristic" and error.to_lower().contains("closed"):
		print("[BLE] Characteristic handle was closed — resetting BLE connection")
		_on_device_disconnected()
