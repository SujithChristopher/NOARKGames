extends Node
## The Camera tab's pictures over the board's hotspot, when the app is on BLE
## (docs/PROTOCOL.md; pyscripts/picture_link.py is the other end). Says PICTURE_HELLO
## about once a second to keep them coming, and hands each whole picture on. One way
## and best effort: a lost picture is replaced 0.2 s later.

const LinkProtocol := preload("res://Main_screen/Scripts/link_protocol.gd")
const ChunkAssembler := preload("res://Main_screen/Scripts/chunk_assembler.gd")

const HELLO_EVERY_S := 1.0   ## the tracker stops sending after 3 s without one

signal picture(jpeg: PackedByteArray)

var _udp: PacketPeerUDP
var _assembler: ChunkAssembler
var _hello_wait := 0.0


func start(ip: String, port: int) -> void:
	stop()
	_udp = PacketPeerUDP.new()
	var err := _udp.bind(0, "*")
	if err != OK:
		push_warning("[Pictures] Could not bind a local port: %s" % error_string(err))
		_udp = null
		return
	_udp.set_dest_address(ip, port)
	_assembler = ChunkAssembler.new()
	_hello_wait = 0.0


func stop() -> void:
	if _udp != null:
		_udp.close()
	_udp = null


func running() -> bool:
	return _udp != null


func _exit_tree() -> void:
	stop()


func _process(delta: float) -> void:
	if _udp == null:
		return
	_hello_wait -= delta
	if _hello_wait <= 0.0:
		_hello_wait = HELLO_EVERY_S
		_udp.put_packet(PackedByteArray([LinkProtocol.PICTURE_HELLO]))
	while _udp.get_available_packet_count() > 0:
		_on_message(_udp.get_packet())


func _on_message(msg: PackedByteArray) -> void:
	match LinkProtocol.kind_of(msg):
		LinkProtocol.CHUNK:
			var whole := _assembler.add(msg)
			if not whole.is_empty():
				_on_message(whole)
		LinkProtocol.PREVIEW:
			picture.emit(msg.slice(1))
