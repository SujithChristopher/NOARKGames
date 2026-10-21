extends RefCounted
## The app <-> tracker wire protocol, the same over UDP and BLE: one type byte,
## then the payload (docs/PROTOCOL.md). The Python side is pyscripts/protocol.py;
## change the two together. Used as `const LinkProtocol := preload(...)`.

const VERSION := 2

const NONE := 0x00

# App -> tracker. HEARTBEAT has no payload; the rest are [seq u16][body] and
# are answered by an ACK (tracker_link.gd).
const HEARTBEAT := 0x01
const HELLO := 0x02           # version u8
const SESSION := 0x03         # patient id
const STOP := 0x04
const CONFIG := 0x05          # "key=value"
const TRUNK := 0x06           # "neutral" | "snapshot" | "select=<n>"
const STORAGE := 0x07         # "list" | "delete=<path>"; answered later by STORAGE_LIST

# Tracker -> app
const TRACKER_HEARTBEAT := 0x80
const POSITION := 0x81        # <BH9f: ref_id, centroid, rvec, tvec
const ACK := 0x82             # seq u16, ok u8, detail
const TRUNK_STATUS := 0x83    # CSV
const SNAPSHOT := 0x84        # u16 json_len, json, jpeg
const CHUNK := 0x85           # msg_id u8, index u8, total u8, part of another message
const STORAGE_LIST := 0x86    # JSON: the board's recordings and disk

const POSITION_SIZE := 39
const ACK_SIZE := 4

## What the app's end of the link is doing, for the status indicator.
enum LinkStatus { IDLE, SCANNING, CONNECTING, CONNECTED }


static func encode(kind: int) -> PackedByteArray:
	return PackedByteArray([kind])


static func encode_reliable(kind: int, seq: int, body: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray([kind, seq & 0xFF, (seq >> 8) & 0xFF])
	out.append_array(body)
	return out


static func kind_of(message: PackedByteArray) -> int:
	return message[0] if message.size() > 0 else NONE


static func payload_text(message: PackedByteArray) -> String:
	return message.slice(1).get_string_from_utf8()


## An ACK -> {seq, ok, detail}, or {} if short.
static func decode_ack(message: PackedByteArray) -> Dictionary:
	if message.size() < ACK_SIZE:
		return {}
	return {
		"seq": message.decode_u16(1),
		"ok": message[3] != 0,
		"detail": message.slice(ACK_SIZE).get_string_from_utf8(),
	}


## A POSITION -> {ref_id, centroid, rvec, tvec}, or {} if short.
static func decode_position(message: PackedByteArray) -> Dictionary:
	if message.size() < POSITION_SIZE:
		return {}
	return {
		"ref_id": message.decode_u16(1),
		"centroid": _vec3(message, 3),
		"rvec": _vec3(message, 15),
		"tvec": _vec3(message, 27),
	}


static func _vec3(m: PackedByteArray, offset: int) -> Vector3:
	return Vector3(m.decode_float(offset), m.decode_float(offset + 4), m.decode_float(offset + 8))
