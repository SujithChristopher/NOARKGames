# NOARK app ↔ tracker protocol (v2)

How the Godot app and `pyscripts/tracker.py` talk, over UDP or BLE. One protocol;
the transport only moves bytes. Single sources of truth:

- Python: `pyscripts/protocol.py`
- Godot: `Main_screen/Scripts/link_protocol.gd` (`LinkProtocol`)

Change both together, and this file with them.

---

## 1. Transports

| | UDP | BLE |
|---|---|---|
| Selected by | settings.json `"stream_type": "udp"` | `"stream_type": "ble"` |
| Typical setup | Godot and tracker on the board | Godot on an Android tablet, tracker on the board |
| Endpoint | tracker binds `127.0.0.1:<udp_port>` (8000) | GATT service `4e4f4152-4b00-…`, device `ble_device_name` |
| App → tracker | one datagram per message | one write per message to `…4b02…` |
| Tracker → app | one datagram per message | one notification per message on `…4b01…` |
| Max message | 1024 bytes (receive buffer) | 244 bytes (247 MTU − 3) |

A transport's interface is the same on both sides: send one message (bytes),
poll for the messages that arrived. `udp_streamer.py` / `ble_streamer.py` and the
UDP / BLE branches in `global_script.gd` do nothing else — no parsing, no packing.

Over UDP the tracker answers whoever sent it the last message, so it sends
nothing until the app's first message arrives.

## 2. Framing

Every message is **one type byte, then the payload**. Messages are told apart
by the type byte only — never by size or text prefix. Multi-byte numbers are
little-endian. Text payloads are UTF-8, with no terminator.

`0x00` is reserved as "nothing" and is ignored by both sides (the BLE position
characteristic's initial value).

## 3. App → tracker

| Type | Name | Payload | Effect |
|---|---|---|---|
| `0x01` | `HEARTBEAT` | — | Liveness only |
| `0x02` | `SESSION` | patient id (text) | Opens the session for that patient (logs, recordings). Repeating the same id is a no-op; a **different** id closes the current session and opens a new one |
| `0x03` | `STOP` | — | UDP: the tracker exits. BLE: the session closes and the tracker waits for the next connection |
| `0x04` | `CONFIG` | `key=value` (text) | Live tuning; answered by `CONFIG_ACK`. Keys: `solver`, `refine`, `camera`, `deadband`, `trunk` (`on`/`off`), `trunk_method` (`icp`/`msam_r18`/`msam_v3rot`) |
| `0x05` | `TRUNK` | `neutral` \| `snapshot` \| `select=<n>` (text) | Capture neutral; send the subject picker's image; follow person n (−1 = centre-most) |

Every message also counts as a heartbeat. The tracker drains everything that
arrived each frame, so a command never waits behind a backlog.

## 4. Tracker → app

| Type | Name | Payload |
|---|---|---|
| `0x81` | `POSITION` | see below, 40 bytes |
| `0x82` | `CONFIG_ACK` | `key=value` (text) as applied |
| `0x83` | `TRUNK_STATUS` | CSV text, fields below |
| `0x84` | `SNAPSHOT_CHUNK` | `snap_id u8 · index u8 · total u8 · data` |

**POSITION** (`<BBH9f`, 40 bytes):

| Offset | Field | |
|---|---|---|
| 0 | type `0x81` | |
| 1 | status u8 | `0` running, `1` stopping (the app quits on it, UDP) |
| 2 | ref_id u16 | reference tag / rigid-body id |
| 4 | centroid xyz f32 ×3 | tracked point, metres, camera frame |
| 16 | rvec f32 ×3 | Rodrigues rotation of the reference tag / rigid body |
| 28 | tvec f32 ×3 | its translation |

Sent once per frame in which a pose was solved. No marker in view → no
POSITION.

**TRUNK_STATUS** fields, in order:
`state, level, lvl_flex, lvl_lat, lvl_axi, flex, lat, axi, progress, has_neutral,
reason, capture_result, people, locked, q_how, q_rms_mm, q_frac, raw_pts, mask_px, held`
(meanings in `pyscripts/trunk/tracker.py` `TrunkStatus` and `trunk_monitor.gd`).

**SNAPSHOT_CHUNK**: the subject picker's image, `u16 json_len · json · jpeg`
split into ≤ 200-byte pieces (`pyscripts/trunk/snapshot_packet.py`), reassembled
by `TrunkMonitor` when all `total` pieces of one `snap_id` are in.

## 5. Liveness and lifecycle (as of step 1)

| | UDP | BLE |
|---|---|---|
| Tracker process | Spawned by Godot (`.venv/bin/python pyscripts/tracker.py --settings …`); Godot restarts it if it dies | systemd service `noark-tracker`, outlives the app |
| App heartbeat | every 0.1 s: `SESSION(id)` once logged in, else `HEARTBEAT` | same |
| 3 s with no message | tracker exits | session closes, tracker waits for the next central |
| `STOP` | tracker answers with POSITION status 1 and exits | session closes |

## 6. Roadmap

The cleanup is done in steps; each leaves UDP and BLE working.

1. **Done** — this framing: a type byte on every message, one protocol module
   per side, transports that only move bytes. Dropped: the 44-byte size guess,
   the `IMG:` padding hack, the control code inside the position floats, the
   unused `RESET` / `CHANGE:` commands, the 30-byte command limit, and the
   app's reply to every position packet over UDP.
2. Heartbeat carries nothing but liveness; `SESSION` / `CONFIG` / `TRUNK` are
   sent once with a sequence number and retried until `ACK(seq)`. A `HELLO`
   with the protocol version opens each connection. Generic chunking for any
   message over the transport's limit.
3. The tracker runs as the service for UDP too: Godot connects instead of
   spawning it, and the spawn / watchdog / startup-STOP code goes. `STOP` ends
   the session over both transports.
4. Remove the remaining `stream_type` branches; the transport is chosen in one
   place on each side.
