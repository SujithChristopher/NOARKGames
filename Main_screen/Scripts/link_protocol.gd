extends RefCounted
## The app <-> tracker wire protocol, the same over UDP and BLE: one type byte,
## then the payload (docs/PROTOCOL.md). The Python side is pyscripts/protocol.py;
## change the two together. Used as `const LinkProtocol := preload(...)`.

const NONE := 0x00

# App -> tracker
const HEARTBEAT := 0x01
const SESSION := 0x02         # patient id
const STOP := 0x03
const CONFIG := 0x04          # "key=value"
const TRUNK := 0x05           # "neutral" | "snapshot" | "select=<n>"

# Tracker -> app
const POSITION := 0x81
const CONFIG_ACK := 0x82      # "key=value"
const TRUNK_STATUS := 0x83    # CSV
const SNAPSHOT_CHUNK := 0x84  # snap_id u8, index u8, total u8, data

const STATUS_RUNNING := 0
const STATUS_STOPPING := 1
const POSITION_SIZE := 40     # <BBH9f


static func encode(kind: int, text: String = "") -> PackedByteArray:
	var out := PackedByteArray([kind])
	out.append_array(text.to_utf8_buffer())
	return out


static func kind_of(message: PackedByteArray) -> int:
	return message[0] if message.size() > 0 else NONE


static func payload_text(message: PackedByteArray) -> String:
	return message.slice(1).get_string_from_utf8()


## A POSITION message -> {status, ref_id, centroid, rvec, tvec}, or {} if short.
static func decode_position(message: PackedByteArray) -> Dictionary:
	if message.size() < POSITION_SIZE:
		return {}
	return {
		"status": message[1],
		"ref_id": message.decode_u16(2),
		"centroid": _vec3(message, 4),
		"rvec": _vec3(message, 16),
		"tvec": _vec3(message, 28),
	}


static func _vec3(m: PackedByteArray, offset: int) -> Vector3:
	return Vector3(m.decode_float(offset), m.decode_float(offset + 4), m.decode_float(offset + 8))
