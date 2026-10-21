"""Wire format of the subject-picker snapshot (docs/PROTOCOL.md, SNAPSHOT_CHUNK).

The blob is `u16 json_len | json | jpeg`, with json
`{"w", "h", "locked", "people": [[[x, y], ...], ...]}` in snapshot pixels. It
goes out as SNAPSHOT_CHUNK messages, one notification / datagram each:

    SNAPSHOT_CHUNK | snap_id u8 | index u8 | total u8 | data

Chunks stay under the 244 bytes a 247 MTU allows.
"""

import json
import struct

from protocol import SNAPSHOT_CHUNK

CHUNK = 200


def encode_snapshot(snap, snap_id, chunk=CHUNK):
    meta = json.dumps({"w": snap.size[0], "h": snap.size[1], "locked": snap.locked,
                       "people": [[list(p) for p in poly] for poly in snap.people]},
                      separators=(",", ":")).encode()
    blob = struct.pack("<H", len(meta)) + meta + snap.jpeg
    parts = [blob[i:i + chunk] for i in range(0, len(blob), chunk)] or [b""]
    if len(parts) > 255:
        raise ValueError(f"snapshot needs {len(parts)} chunks")
    return [bytes([SNAPSHOT_CHUNK, snap_id & 0xFF, i, len(parts)]) + data
            for i, data in enumerate(parts)]
