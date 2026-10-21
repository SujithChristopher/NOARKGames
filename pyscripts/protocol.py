"""The app <-> tracker wire protocol, shared by the UDP and BLE transports.

Every message is one type byte and a payload (docs/PROTOCOL.md). The Godot side
is Main_screen/Scripts/link_protocol.gd; change the two together.
"""

import struct

NONE = 0x00

# App -> tracker
HEARTBEAT = 0x01
SESSION = 0x02        # patient id
STOP = 0x03
CONFIG = 0x04         # "key=value"
TRUNK = 0x05          # "neutral" | "snapshot" | "select=<n>"

# Tracker -> app
POSITION = 0x81
CONFIG_ACK = 0x82     # "key=value"
TRUNK_STATUS = 0x83   # CSV
SNAPSHOT_CHUNK = 0x84 # snap_id u8, index u8, total u8, data

STATUS_RUNNING, STATUS_STOPPING = 0, 1

_POSITION = struct.Struct("<BBH9f")   # type, status, ref_id, centroid, rvec, tvec
POSITION_SIZE = _POSITION.size        # 40


def encode(kind: int, payload: bytes | str = b"") -> bytes:
    if isinstance(payload, str):
        payload = payload.encode()
    return bytes([kind]) + payload


def decode(message: bytes) -> tuple[int, bytes]:
    """(type, payload); (NONE, b"") for an empty message."""
    if not message:
        return NONE, b""
    return message[0], message[1:]


def encode_position(status: int, ref_id: int, centroid, rvec, tvec) -> bytes:
    return _POSITION.pack(POSITION, status, int(ref_id), *centroid, *rvec, *tvec)


def decode_position(message: bytes):
    """-> (status, ref_id, centroid, rvec, tvec), for tools and tests."""
    _, status, ref_id, *f = _POSITION.unpack(message[:POSITION_SIZE])
    return status, ref_id, tuple(f[0:3]), tuple(f[3:6]), tuple(f[6:9])
