"""The app <-> tracker wire protocol, shared by the UDP and BLE transports.

Every message is one type byte and a payload (docs/PROTOCOL.md). The app's
commands carry a sequence number and are acknowledged; link.py does that part.
The Godot side is Main_screen/Scripts/link_protocol.gd; change the two together.
"""

import struct

VERSION = 3

NONE = 0x00

# App -> tracker. HEARTBEAT has no payload; the rest are [seq u16][body].
HEARTBEAT = 0x01
HELLO = 0x02          # version u8
SESSION = 0x03        # patient id
STOP = 0x04
CONFIG = 0x05         # "key=value"
TRUNK = 0x06          # "neutral" | "snapshot" | "select=<n>"
STORAGE = 0x07        # "list" | "delete=<path>"; answered later by STORAGE_LIST
RESTART = 0x08        # ACKed, then the tracker exits and systemd starts it again
RELIABLE = frozenset({HELLO, SESSION, STOP, CONFIG, TRUNK, STORAGE, RESTART})

# Tracker -> app
TRACKER_HEARTBEAT = 0x80  # state u8: what the cameras are doing (below)
POSITION = 0x81       # <BH9f: ref_id, centroid, rvec, tvec
ACK = 0x82            # seq u16, ok u8, detail
TRUNK_STATUS = 0x83   # CSV
SNAPSHOT = 0x84       # u16 json_len, json, jpeg
CHUNK = 0x85          # msg_id u8, index u8, total u8, part of another message
STORAGE_LIST = 0x86   # JSON: the board's recordings and disk (storage.py)

# TRACKER_HEARTBEAT state: the cameras are off until the app asks for tracking
# (CONFIG track=on), take a few seconds to come up, and go off again after it
# stops asking.
STATE_IDLE = 0
STATE_STARTING = 1
STATE_TRACKING = 2
STATE_FAILED = 3     # the cameras would not start; retried

_SEQ = struct.Struct("<H")
_ACK = struct.Struct("<BHB")
_POSITION = struct.Struct("<BH9f")
POSITION_SIZE = _POSITION.size        # 39
CHUNK_HEADER = 4


def encode(kind: int, payload: bytes | str = b"") -> bytes:
    if isinstance(payload, str):
        payload = payload.encode()
    return bytes([kind]) + payload


def decode(message: bytes) -> tuple[int, bytes]:
    """(type, payload); (NONE, b"") for an empty message."""
    if not message:
        return NONE, b""
    return message[0], message[1:]


def encode_reliable(kind: int, seq: int, body: bytes | str = b"") -> bytes:
    if isinstance(body, str):
        body = body.encode()
    return bytes([kind]) + _SEQ.pack(seq & 0xFFFF) + body


def split_seq(payload: bytes) -> tuple[int, bytes]:
    """A reliable message's payload -> (seq, body). ValueError if too short."""
    if len(payload) < _SEQ.size:
        raise ValueError("no sequence number")
    return _SEQ.unpack_from(payload)[0], payload[_SEQ.size:]


def encode_ack(seq: int, ok: bool, detail: str = "") -> bytes:
    return _ACK.pack(ACK, seq & 0xFFFF, 1 if ok else 0) + detail.encode()


def decode_ack(message: bytes) -> tuple[int, bool, str]:
    _, seq, ok = _ACK.unpack_from(message)
    return seq, bool(ok), message[_ACK.size:].decode(errors="replace")


def encode_position(ref_id: int, centroid, rvec, tvec) -> bytes:
    return _POSITION.pack(POSITION, int(ref_id), *centroid, *rvec, *tvec)


def decode_position(message: bytes):
    """-> (ref_id, centroid, rvec, tvec), for tools and tests."""
    _, ref_id, *f = _POSITION.unpack(message[:POSITION_SIZE])
    return ref_id, tuple(f[0:3]), tuple(f[3:6]), tuple(f[6:9])


def chunk(message: bytes, msg_id: int, max_size: int) -> list[bytes]:
    """Split a message that does not fit the transport into CHUNK messages."""
    step = max_size - CHUNK_HEADER
    parts = [message[i:i + step] for i in range(0, len(message), step)]
    if len(parts) > 255:
        raise ValueError(f"message of {len(message)} bytes needs {len(parts)} chunks")
    return [bytes([CHUNK, msg_id & 0xFF, i, len(parts)]) + p for i, p in enumerate(parts)]
