"""The subject-picker snapshot as one SNAPSHOT message (docs/PROTOCOL.md).

Payload: `u16 json_len | json | jpeg`, with json
`{"w", "h", "locked", "people": [[[x, y], ...], ...]}` in snapshot pixels. It is
a few kB, so the link sends it as CHUNKs; TrunkMonitor gets it whole.
"""

import json
import struct

from protocol import SNAPSHOT


def encode_snapshot(snap) -> bytes:
    meta = json.dumps({"w": snap.size[0], "h": snap.size[1], "locked": snap.locked,
                       "people": [[list(p) for p in poly] for poly in snap.people]},
                      separators=(",", ":")).encode()
    return bytes([SNAPSHOT]) + struct.pack("<H", len(meta)) + meta + snap.jpeg
