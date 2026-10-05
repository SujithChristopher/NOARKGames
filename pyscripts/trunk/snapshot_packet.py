"""Wire format of the subject-picker snapshot, shared by BLE and UDP.

The blob is `u16 json_len | json | jpeg`, with json
`{"w", "h", "locked", "people": [[[x, y], ...], ...]}` in snapshot pixels. It
goes out as chunks, each one notification / datagram:

    "IMG:" | snap_id u8 | index u8 | total u8 | data

Godot tells these from the 44-byte position packet by prefix, but its size check
runs first, so a chunk is never allowed to be exactly 44 bytes: the last one is
padded with a zero, which the JPEG decoder ignores after the end-of-image marker.
Chunks stay under the 244 bytes a 247 MTU allows.
"""

import json
import struct

PREFIX = b"IMG:"
CHUNK = 200
POSITION_SIZE = 44


def encode_snapshot(snap, snap_id, chunk=CHUNK):
    meta = json.dumps({"w": snap.size[0], "h": snap.size[1], "locked": snap.locked,
                       "people": [[list(p) for p in poly] for poly in snap.people]},
                      separators=(",", ":")).encode()
    blob = struct.pack("<H", len(meta)) + meta + snap.jpeg
    parts = [blob[i:i + chunk] for i in range(0, len(blob), chunk)] or [b""]
    if len(parts) > 255:
        raise ValueError(f"snapshot needs {len(parts)} chunks")
    out = []
    for i, data in enumerate(parts):
        pkt = PREFIX + bytes([snap_id & 0xFF, i, len(parts)]) + data
        if len(pkt) == POSITION_SIZE:
            pkt += b"\0"
        out.append(pkt)
    return out
