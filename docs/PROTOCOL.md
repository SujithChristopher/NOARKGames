# NOARK app ↔ tracker protocol (v2)

How the Godot app and `pyscripts/tracker.py` talk, over UDP or BLE. One
protocol; the transport only moves bytes.

| | Python (tracker) | Godot (app) |
|---|---|---|
| Wire format | `pyscripts/protocol.py` | `Main_screen/Scripts/link_protocol.gd` |
| Link (acks, retries, chunks, liveness) | `pyscripts/link.py` | `Main_screen/Scripts/tracker_link.gd` |
| UDP | `pyscripts/udp_streamer.py` | `Main_screen/Scripts/udp_transport.gd` |
| BLE | `pyscripts/ble_streamer.py` | `Main_screen/Scripts/ble_transport.gd` |

The transport is chosen in one place on each side (`_init_transport` in
tracker.py, `_start_link` in global_script.gd), from settings.json
`stream_type`. Change the two wire-format files together, bump `VERSION` in both
for an incompatible change, and update this file.

---

## 1. Lifecycle

The tracker is a long-running service (`noark-tracker`, systemd) over both
transports. The app never starts or stops it; it connects, runs sessions, and
goes. Cameras are brought up once, at boot — frame-sync alignment takes tens of
seconds, which an app launch no longer pays.

```
app                                  tracker
 │── HELLO(version) ───────────────▶ │  re-reads settings.json (live keys), ACK
 │◀─────────────────────────── ACK ──│
 │── SESSION(patient) ─────────────▶ │  opens logs / recordings, ACK
 │── CONFIG / TRUNK … ─────────────▶ │  applies, ACK(ok, detail)
 │◀── POSITION, TRUNK_STATUS, SNAPSHOT, TRACKER_HEARTBEAT …
 │── HEARTBEAT (every 0.1 s) ──────▶ │
 │── STOP ─────────────────────────▶ │  closes the session, ACK; keeps running
```

| Event | App | Tracker |
|---|---|---|
| Nothing from the other side for 3 s | link lost; HELLO again until answered, then SESSION again | session closed; waits for the next HELLO |
| Tracker restarted under a running app | its next command is refused with `no HELLO`, or 3 s of silence → reconnects as above | — |
| HELLO with another protocol version | refused; retries every 5 s and logs why | — |

`SESSION` with the id already open is a no-op; a different id closes the open
session first. `STOP` ends the session, not the tracker.

## 2. Transports

| | UDP | BLE |
|---|---|---|
| Typical setup | Godot and tracker on the board | Godot on an Android tablet, tracker on the board |
| Endpoint | tracker binds `127.0.0.1:<udp_port>` (8000); the app sends from an ephemeral port (`udp_host` to reach another machine) | GATT service `4e4f4152-4b00-…`, device `ble_device_name` |
| App → tracker | one datagram per message | one write per message to `…4b02…` |
| Tracker → app | one datagram per message | one notification per message on `…4b01…` |
| Largest message | 1400 bytes | 244 bytes (247 MTU) |

Over UDP the tracker answers whoever sent it the last message. Anything larger
than the transport takes is split into `CHUNK`s by the link and reassembled
before the app sees it.

## 3. Framing

Every message is **one type byte, then the payload**; told apart by that byte
alone. Little-endian. Text is UTF-8 without a terminator. `0x00` is "nothing"
and is ignored (the BLE characteristic's initial value).

App commands carry a sequence number: `type · seq u16 · body`. The tracker
answers each with an `ACK` for that `seq`. The app keeps **one command in
flight**, re-sending it every 0.3 s until its ACK (10 tries; HELLO for as long as
it takes) — which also keeps Android from refusing overlapping BLE writes. The
tracker remembers the last `seq` it handled: a retry of it gets the same ACK
again and is not applied twice.

## 4. App → tracker

| Type | Name | Body | ACK detail |
|---|---|---|---|
| `0x01` | `HEARTBEAT` | (no seq, no body) | — |
| `0x02` | `HELLO` | version u8 (2) | `v2`, or why refused |
| `0x03` | `SESSION` | patient id | the id |
| `0x04` | `STOP` | — | — |
| `0x05` | `CONFIG` | `key=value` | `key=value` as applied, or why refused |
| `0x06` | `TRUNK` | `neutral` \| `snapshot` \| `select=<n>` | the command, or why refused |
| `0x07` | `STORAGE` | `list` \| `delete=<path>` | `listing` / `deleting <path>`, or why refused |

STORAGE (`pyscripts/storage.py`, the app's Settings > Storage tab) works on the
board's camera recordings: `<patient>/<session>/Video/rec_*` and
`<patient>/<session>/MovementData/recordings/rec_*` under the data directory,
`<path>` relative to it. The tracker refuses anything else and the recording
being written now. Listing and deleting run on a worker thread, so the ACK only
says the job was taken; each finished job answers with a `STORAGE_LIST`.

CONFIG keys (tracker.py `_apply_setting`): `solver` (joint/ransac), `refine`
(crop/contour/subpix/none), `camera` (both/cam0/cam1), `deadband` (px),
`trunk` (on/off), `trunk_method` (icp/msam_r18/msam_v3rot), `recording`
(on/off), `recording_fps`, `recording_scale` (0–1], `recording_chunk_frames` —
the recording ones from the next session. At each HELLO the tracker applies the
same keys from its own settings.json (`tracker_solver`, `tracker_refine`,
`tracker_camera`, `corner_deadband_px`, `trunk_enabled`, `trunk_method`,
`recording*`). Everything else in settings.json needs
`sudo systemctl restart noark-tracker`.

## 5. Tracker → app

| Type | Name | Payload |
|---|---|---|
| `0x80` | `TRACKER_HEARTBEAT` | — ; sent when nothing else went out for 0.5 s |
| `0x81` | `POSITION` | `<BH9f`, 39 bytes, below |
| `0x82` | `ACK` | `seq u16 · ok u8 · detail` |
| `0x83` | `TRUNK_STATUS` | CSV, below |
| `0x84` | `SNAPSHOT` | `u16 json_len · json · jpeg` (`trunk/snapshot_packet.py`) |
| `0x85` | `CHUNK` | `msg_id u8 · index u8 · total u8 · part`, of a message too big for the transport |
| `0x86` | `STORAGE_LIST` | JSON, below; after each STORAGE job |

**POSITION**, one per frame with a solved pose (no marker in view → none; the
heartbeat still shows the tracker is alive):

| Offset | Field | |
|---|---|---|
| 0 | type `0x81` | |
| 1 | ref_id u16 | reference tag / rigid-body id |
| 3 | centroid f32 ×3 | tracked point, metres, camera frame |
| 15 | rvec f32 ×3 | Rodrigues rotation of the reference tag / rigid body |
| 27 | tvec f32 ×3 | its translation |

**TRUNK_STATUS** fields, in order:
`state, level, lvl_flex, lvl_lat, lvl_axi, flex, lat, axi, progress, has_neutral,
reason, capture_result, people, locked, q_how, q_rms_mm, q_frac, raw_pts, mask_px, held,
hz, method` (hz: trunk updates per second; method: icp / msam_r18 / msam_v3rot)
(`TrunkStatus` in `pyscripts/trunk/tracker.py`; `trunk_monitor.gd`).

**SNAPSHOT** json: `{"w", "h", "locked", "people": [[[x, y], ...], ...]}` in
snapshot pixels — the subject picker's image and one outline per person.

**STORAGE_LIST** json: `{"total", "free", "event", "recordings": [{"path",
"patient", "session", "name", "bytes", "active"}]}` — disk bytes, what the job
did (`""` for a list, `deleted <path>`, `error: …`), and every recording
(`active`: being written, cannot be deleted).

## 6. Tools

- `uv run pyscripts/ble_test.py` — a BLE peripheral with the tracker's service
  and link, no cameras, streaming a fake hand circle.
- `pyscripts/tests/test_ble_receiver.py`, `test_btplug_connect.py` — minimal BLE
  centrals (HELLO, print what arrives, STOP).
