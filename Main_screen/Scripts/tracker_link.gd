extends Node
## The app's end of the tracker link (docs/PROTOCOL.md), the same over UDP and
## BLE — the transport only moves bytes:
##
## * HELLO first, retried until the tracker answers; then the session (if a
##   patient is logged in) is sent again, so a reconnect picks up where it was;
## * commands (SESSION, STOP, CONFIG, TRUNK) go one at a time and are re-sent
##   until their ACK arrives — one in flight also keeps Android from refusing
##   overlapping BLE writes;
## * HEARTBEAT every 0.1 s; nothing from the tracker for 3 s = link lost;
## * CHUNKs reassembled into the message they carry.
##
## Owned by GlobalScript, which picks the transport.

const LinkProtocol := preload("res://Main_screen/Scripts/link_protocol.gd")

## A message for the app: POSITION, TRUNK_STATUS or SNAPSHOT (whole message).
signal message(kind: int, msg: PackedByteArray)
## A command's ACK arrived (ok) or was refused / never came (not ok).
signal command_done(kind: int, ok: bool, detail: String)
signal connected_changed(connected: bool)

const HEARTBEAT_S := 0.1
const RETRY_S := 0.3
const MAX_TRIES := 10          # 3 s; HELLO retries for as long as it takes
const SILENCE_S := 3.0         # the tracker sends at least every 0.5 s

var connected := false
var _transport: Node
var _session_id := ""
## The patient the session is for ("" if none), sent again after a reconnect.
var session_id: String:
	get:
		return _session_id
var _seq := randi() & 0xFFFF
var _queue: Array[Dictionary] = []    # {kind, body}
var _in_flight: Dictionary = {}       # {kind, seq, msg, sent_ms, tries}
var _last_heard_ms := 0
var _heartbeat_acc := 0.0
var _hello_refused_until_ms := 0
# msg_id -> {index: part}; two chunked messages (a snapshot and a storage list)
# can be on the way at once.
var _chunks: Dictionary = {}


func _init(transport: Node) -> void:
	_transport = transport
	process_mode = Node.PROCESS_MODE_ALWAYS   # keeps running while the quit waits


func _ready() -> void:
	_transport.received.connect(_on_received)


## Where the link is, for the status indicator.
func status() -> int:
	var t: int = _transport.status()
	if t != LinkProtocol.LinkStatus.CONNECTED:
		return t
	return LinkProtocol.LinkStatus.CONNECTED if connected else LinkProtocol.LinkStatus.CONNECTING


## Queue a command; it goes once the link is up, after anything queued before.
func send_command(kind: int, text: String = "") -> void:
	_queue.append({"kind": kind, "body": text.to_utf8_buffer()})


## The logged-in patient: sent now, and again after every reconnect.
func set_session(patient_id: String) -> void:
	_session_id = patient_id
	if connected:
		send_command(LinkProtocol.SESSION, patient_id)


## Close the session at the tracker and wait (at most `timeout_s`) for it to
## say so. For quitting: the tracker keeps running for the next app.
func stop_session(timeout_s: float = 1.0) -> bool:
	_session_id = ""
	if not connected:
		return false
	_queue.clear()
	_queue.append({"kind": LinkProtocol.STOP, "body": PackedByteArray()})
	var result := {"done": false, "ok": false}
	var on_done := func(kind: int, ok: bool, _detail: String) -> void:
		if kind == LinkProtocol.STOP:
			result.done = true
			result.ok = ok
	command_done.connect(on_done)
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000)
	while not result.done and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	command_done.disconnect(on_done)
	return result.ok


## One STOP now, unacknowledged: for a quit that cannot wait a frame.
func stop_now() -> void:
	_session_id = ""
	if connected:
		_seq = (_seq + 1) & 0xFFFF
		_transport.send(LinkProtocol.encode_reliable(LinkProtocol.STOP, _seq, PackedByteArray()))


## The app is going: no more reconnecting, and the transport shuts down.
func close() -> void:
	set_process(false)
	_set_connected(false)
	_transport.stop()


func _process(delta: float) -> void:
	var now := Time.get_ticks_msec()
	if _transport.status() != LinkProtocol.LinkStatus.CONNECTED:
		if connected or not _in_flight.is_empty():
			_lost("transport down")
		return

	_heartbeat_acc += delta
	if _heartbeat_acc >= HEARTBEAT_S:
		_heartbeat_acc = 0.0
		_transport.send(LinkProtocol.encode(LinkProtocol.HEARTBEAT))

	if connected and now - _last_heard_ms > SILENCE_S * 1000:
		_lost("tracker silent for %.0f s" % SILENCE_S)

	if not _in_flight.is_empty():
		if now - _in_flight.sent_ms < RETRY_S * 1000:
			return
		if _in_flight.kind != LinkProtocol.HELLO and _in_flight.tries >= MAX_TRIES:
			var gave_up: int = _in_flight.kind
			_in_flight = {}
			push_warning("[LINK] No answer to command 0x%02x" % gave_up)
			command_done.emit(gave_up, false, "no answer")
			return
		_in_flight.tries += 1
		_in_flight.sent_ms = now
		_transport.send(_in_flight.msg)
		return

	if not connected:
		if now >= _hello_refused_until_ms:
			_send_now(LinkProtocol.HELLO, PackedByteArray([LinkProtocol.VERSION]))
	elif not _queue.is_empty():
		var next: Dictionary = _queue.pop_front()
		_send_now(next.kind, next.body)


func _send_now(kind: int, body: PackedByteArray) -> void:
	_seq = (_seq + 1) & 0xFFFF
	var msg := LinkProtocol.encode_reliable(kind, _seq, body)
	_in_flight = {"kind": kind, "seq": _seq, "msg": msg,
		"sent_ms": Time.get_ticks_msec(), "tries": 1}
	_transport.send(msg)


func _on_received(msg: PackedByteArray) -> void:
	_last_heard_ms = Time.get_ticks_msec()
	match LinkProtocol.kind_of(msg):
		LinkProtocol.ACK:
			_on_ack(LinkProtocol.decode_ack(msg))
		LinkProtocol.CHUNK:
			_on_chunk(msg)
		LinkProtocol.TRACKER_HEARTBEAT, LinkProtocol.NONE:
			pass
		var kind:
			if connected:
				message.emit(kind, msg)


func _on_ack(ack: Dictionary) -> void:
	# A repeat ACK for a retry, or one for a command already given up on.
	if ack.is_empty() or _in_flight.is_empty() or ack.seq != _in_flight.seq:
		return
	var kind: int = _in_flight.kind
	_in_flight = {}
	if kind == LinkProtocol.HELLO:
		if ack.ok:
			_set_connected(true)
			if not _session_id.is_empty():
				_queue.push_front({"kind": LinkProtocol.SESSION, "body": _session_id.to_utf8_buffer()})
		else:
			push_error("[LINK] Tracker refused HELLO: %s" % ack.detail)
			_hello_refused_until_ms = Time.get_ticks_msec() + 5000
	elif not ack.ok and ack.detail == "no HELLO":
		_lost("tracker restarted")   # it lost our HELLO; the next one restores the session
	elif not ack.ok:
		push_warning("[LINK] Tracker refused command 0x%02x: %s" % [kind, ack.detail])
	command_done.emit(kind, ack.ok, ack.detail)


func _on_chunk(msg: PackedByteArray) -> void:
	if msg.size() < 4:
		return
	var id := msg[1]
	var total := msg[3]
	if msg[2] == 0 or not _chunks.has(id):   # a new message under this id
		_chunks[id] = {}
	var parts: Dictionary = _chunks[id]
	parts[msg[2]] = msg.slice(4)
	if parts.size() < total:
		return
	var whole := PackedByteArray()
	for i in total:
		if not parts.has(i):
			return
		whole.append_array(parts[i])
	_chunks.erase(id)
	_on_received(whole)


func _lost(why: String) -> void:
	if connected:
		print("[LINK] Lost the tracker: %s" % why)
	# Whoever waits on a command hears that it will not be answered.
	var dropped: Array[int] = []
	if not _in_flight.is_empty() and _in_flight.kind != LinkProtocol.HELLO:
		dropped.append(_in_flight.kind)
	for c in _queue:
		dropped.append(c.kind)
	_in_flight = {}
	_queue.clear()
	_set_connected(false)
	for kind in dropped:
		command_done.emit(kind, false, "link lost")


func _set_connected(on: bool) -> void:
	if on == connected:
		return
	connected = on
	if on:
		print("[LINK] Connected to the tracker")
	connected_changed.emit(on)
