extends Node
## UDP to the tracker (docs/PROTOCOL.md): the tracker binds `udp_port`, this
## sends to it from an ephemeral port and reads its answers. Only moves bytes —
## tracker_link.gd says what they mean. Same interface as ble_transport.gd.

const LinkProtocol := preload("res://Main_screen/Scripts/link_protocol.gd")

## One message from the tracker.
signal received(message: PackedByteArray)

var _udp := PacketPeerUDP.new()
var _host: String
var _port: int
var _up := false


func _init(host: String, port: int) -> void:
	_host = host
	_port = port
	process_mode = Node.PROCESS_MODE_ALWAYS


func start() -> void:
	# Bound and addressed, not connect_to_host(): a connected socket takes the
	# ICMP port-unreachable that comes back while the tracker is not up yet as
	# an error on itself, and the link has to keep knocking until it is.
	var err := _udp.bind(0, "127.0.0.1" if _host in ["127.0.0.1", "localhost"] else "*")
	if err != OK:
		push_error("[UDP] Could not bind a local port: %s" % error_string(err))
		return
	_udp.set_dest_address(_host, _port)
	_up = true
	print("[UDP] Talking to the tracker at %s:%d" % [_host, _port])


func send(message: PackedByteArray) -> void:
	if _up:
		_udp.put_packet(message)


## UDP has no connection: it is up once bound. Whether a tracker answers is the
## link's business.
func status() -> int:
	return LinkProtocol.LinkStatus.CONNECTED if _up else LinkProtocol.LinkStatus.IDLE


func stop() -> void:
	_up = false
	_udp.close()


# Polled on the main thread, so nothing downstream needs to be thread-safe.
func _process(_delta: float) -> void:
	while _up and _udp.get_available_packet_count() > 0:
		var packet := _udp.get_packet()
		if _udp.get_packet_error() == OK:
			received.emit(packet)
