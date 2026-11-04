# NOARK app ↔ tracker protocol (v4)

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
goes. The cameras are **off until the app asks for tracking** (`CONFIG
track=position` or `track=rotation`, sent while a game or a screen that shows
the hand / trunk is open),
come up on their own thread in 2–5 s (the link keeps answering meanwhile), and
go off again `camera_idle_off_s` (20 s) after the app asks for `track=off` or
goes. Every HELLO starts the app idle. Session recordings cover only the tracked
stretches. `RESTART` makes the tracker exit non-zero, and systemd
(`Restart=on-failure`) starts it again 5 s later.

```
app                                  tracker
 │── HELLO(version) ───────────────▶ │  re-reads settings.json (live keys), ACK
 │◀─────────────────────────── ACK ──│
 │── SESSION(patient) ─────────────▶ │  opens logs / recordings, ACK
 │── CONFIG / TRUNK … ─────────────▶ │  applies, ACK(ok, detail)
 │◀── POSITION or ROTATION, TRUNK_STATUS, SNAPSHOT, TRACKER_HEARTBEAT …
 │── HEARTBEAT (every 0.5 s) ──────▶ │
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
| `0x01` | `HEARTBEAT` | (no seq, no body); every 0.5 s | — |
| `0x02` | `HELLO` | version u8 (4) | `v4`, or why refused |
| `0x03` | `SESSION` | patient id | the id |
| `0x04` | `STOP` | — | — |
| `0x05` | `CONFIG` | `key=value` | `key=value` as applied, or why refused |
| `0x06` | `TRUNK` | `neutral` (model frame: set zero) \| `zero_clear` \| `snapshot` \| `select=<n>` | the command, or why refused |
| `0x07` | `STORAGE` | `list` \| `delete=<path>` | `listing` / `deleting <path>`, or why refused |
| `0x08` | `RESTART` | — | `restarting`; then the tracker exits and systemd restarts it |
| `0x0A` | `BODY` | `status` \| `start` \| `finish` \| `cancel` \| `save` \| `restore` | below, or why refused |

STORAGE (`pyscripts/storage.py`, the app's Settings > Storage tab) works on the
board's camera recordings: `<patient>/<session>/Video/rec_*` and
`<patient>/<session>/MovementData/recordings/rec_*` under the data directory,
`<path>` relative to it. The tracker refuses anything else and the recording
being written now. Listing and deleting run on a worker thread, so the ACK only
says the job was taken; each finished job answers with a `STORAGE_LIST`.

CONFIG keys (tracker.py `_apply_setting`): `track` (off/position/rotation: the
app wants tracking now, and which of POSITION or ROTATION to send — a game uses
one, never both; not a setting, never in settings.json), `solver` (joint/ransac), `refine`
(crop/contour/subpix/none), `camera` (both/cam0/cam1), `deadband` (px),
`trunk` (on/off), `trunk_method` (icp/msam_r18/msam_v3rot), `trunk_reference`
(neutral/model), `exposure` (µs, above 0; the sensor caps it at the frame period)
and `gain` (1–16) — on the running cameras at once, otherwise when they next
start, `preview` (on/off: the app's Camera tab is open; over BLE it also runs the
board's hotspot, section 5; not a setting, never in settings.json, and off again at
every HELLO), `recording`
(on/off), `recording_fps`, `recording_scale` (0–1], `recording_chunk_frames` —
the recording ones from the next session. At each HELLO the tracker applies the
same keys from its own settings.json (`tracker_solver`, `tracker_refine`,
`tracker_camera`, `corner_deadband_px`, `camera_exposure_us`, `camera_gain`,
`trunk_enabled`, `trunk_method`, `trunk_reference`, `recording*`). Everything else
in settings.json is read at start: the app's Settings screen sends `RESTART` after saving it.

The ACK for `exposure` / `gain` means the value was accepted, not that the sensor
has it: with the ISP on, rcam writes the sensor when the next frame comes in.
`CAMERA_STATUS` is what shows what it took. Over BLE the tracker also writes what the
app changed into its own settings.json when the tab closes: a tablet cannot reach that
file, and exposure and gain belong to the board's room. Over UDP the app writes it.

## 5. Tracker → app

| Type | Name | Payload |
|---|---|---|
| `0x80` | `TRACKER_HEARTBEAT` | state u8: 0 idle (cameras off), 1 cameras starting, 2 tracking, 3 cameras failed (retried in 5 s); sent when nothing else went out for 0.5 s, and at once on a change |
| `0x81` | `POSITION` | `<B3f`, 13 bytes, below; while `track=position` |
| `0x82` | `ACK` | `seq u16 · ok u8 · detail` |
| `0x83` | `TRUNK_STATUS` | CSV, below |
| `0x84` | `SNAPSHOT` | `u16 json_len · json · jpeg` (`trunk/snapshot_packet.py`) |
| `0x85` | `CHUNK` | `msg_id u8 · index u8 · total u8 · part`, of a message too big for the transport |
| `0x86` | `STORAGE_LIST` | JSON, below; after each STORAGE job |
| `0x87` | `ROTATION` | `<B3f`, 13 bytes, below; while `track=rotation` |
| `0x88` | `CAMERA_STATUS` | JSON, below; every 0.5 s while `preview=on` and tracking |
| `0x89` | `PREVIEW` | JPEG, below; every 0.2 s while `preview=on` and tracking. Over UDP on the link, over BLE on the hotspot |
| `0x8A` | `BODY_STATUS` | JSON, below; after `status` or a change, and every 0.5 s during a take or a solve |

**POSITION** / **ROTATION**, one per frame with a solved pose (no marker in
view → none; the heartbeat still shows the tracker is alive, and the app reads
"a pose arrived recently" as "the handle is in view"). Which one is the app's
choice (`track=`); the rest of the pose stays on the tracker.

| Offset | Field | |
|---|---|---|
| 0 | type `0x81` / `0x87` | |
| 1 | f32 ×3 | POSITION: the tracked point (the device tip), metres, camera frame. ROTATION: Rodrigues rotation of the rigid body, camera frame |

13 bytes fit one BLE link-layer packet even without Data Length Extension
(27-byte payload); v3's 39-byte POSITION (ref_id, point, rvec, tvec) took two.

**TRUNK_STATUS** fields, in order:
`state, level, lvl_flex, lvl_lat, lvl_axi, flex, lat, axi, progress, has_neutral,
reason, capture_result, people, locked, q_how, q_rms_mm, q_frac, raw_pts, mask_px, held,
hz, method, doubt, reference` (hz: trunk updates per second; method: icp / msam_r18 / msam_v3rot;
doubt: "" or why this reading is less trusted, `low_conf` / `arm_over_chest`;
reference: `neutral` = angles from the captured neutral, `model` = from minisam3d's own frame;
in the model frame has_neutral = a zero has been set)
(`TrunkStatus` in `pyscripts/trunk/tracker.py`; `trunk_monitor.gd`).

**SNAPSHOT** json: `{"w", "h", "locked", "people": [[[x, y], ...], ...]}` in
snapshot pixels — the subject picker's image and one outline per person.

**STORAGE_LIST** json: `{"total", "free", "event", "recordings": [{"path",
"patient", "session", "name", "bytes", "active"}]}` — disk bytes, what the job
did (`""` for a list, `deleted <path>`, `error: …`), and every recording
(`active`: being written, cannot be deleted).

**CAMERA_STATUS** json (`pyscripts/camera_view.py`; `camera_tab.gd`):
`{"ask": [exposure_us, gain], "exposure": [a, b], "gain": [a, b], "level": [a, b],
"blown": [a, b], "tags": [a, b], "fps": f}`. `ask` is what is in force, which the
sensors may have capped; `[a, b]` is the left and right picture of the `PREVIEW`:
the exposure (µs) and gain read back from the sensor (`null` if the read failed),
mean image level 0–255, % of pixels blown out, tags found. `fps` is tracking's rate
since the last status (0 in the first). Over BLE it also has `wifi`, what the hotspot is
doing: `{"state": "starting"}`, `{"state": "on", "ssid", "ip", "port", "bssid"}` or
`{"state": "failed", "reason"}`. It fits one BLE message.

**PREVIEW** is both cameras side by side, 640×200, JPEG quality 50, with the tags
found outlined. Measured on the board: 3–11 kB by how bright the scene is, so 3–9
CHUNKs over UDP. Sending both at these rates tracked at 57–59 fps with no re-pair.

Both are additive, so `VERSION` did not change: an app that does not know them never
sends `preview=on`, and they are sent only after it.

**Pictures over BLE** go over the board's own hotspot, the way Quick Share moves data:
BLE finds the device, Wi-Fi carries what is too big for it.

1. `preview=on` starts the hotspot on a thread (`pyscripts/hotspot.py`, through the root
   helper `setup/noark-hotspot`), and the status says when it is up.
2. The tablet joins with Android's `WifiNetworkSpecifier` (GdAndroidBLE `wifi_join`), with
   the password typed once per board. **The password never goes over BLE.** The name
   and BSSID do: they are not secret. Android asks once per access point, then joins by
   itself, but only when asked for that exact name and BSSID.
3. The tablet sends `PICTURE_HELLO` (`0x09`, one byte, no sequence number) to the status's
   `ip`:`port` about once a second. The tracker sends pictures to whoever said it last,
   as `PREVIEW` or `CHUNK`s of one, in datagrams of up to 1400 bytes, and stops after 3 s
   of silence, so nothing is encoded for nobody.
4. `preview=off`, or the app going, takes the hotspot down.

The port (8010) is open only while the hotspot is up, and bound to its address. The
hotspot is WPA2, with a password made per board, and routing is off, so a device on it
reaches the board and nothing behind it. Measured on the board with a tablet: 5 GHz beside
the normal Wi-Fi, 5.3 ms, no loss at 40 kB five times a second. Without the hotspot
(`setup/setup_board.sh` not run, or a failure) the tab still works on the numbers.

**Measuring the device's tags** (Settings > Calibration; `calibration_tab.gd`,
`pyscripts/body_take.py`, `pyscripts/body_solve.py`), after one was moved, swapped or added:

| `BODY` | When | ACK detail |
|---|---|---|
| `status` | any time | empty; a `BODY_STATUS` follows |
| `start` | not during a take or a solve | `started`. Needs `track=position` to get frames: the 60 s run from the first one |
| `finish` | during a take; it also ends by itself | `solving`, or `failed` if the fixed tag was never seen |
| `cancel` | any time | `cancelled`: ends a take or a solve, drops a result |
| `save` | a result with `ok` | `saved`: the tracker uses it from the next frame, with no restart |
| `restore` | idle or failed | `restored`: the newest calibration replaced goes back in use |

`BODY_STATUS` always has `state` (`idle`, `capturing`, `solving`, `review`, `failed`),
`anchor` (the fixed tag: `[tip] tag` in device.toml) and
`current` (`{"tags", "created", "agreement_mm", "can_restore"}`: what is in use). Then:

- `capturing`: `capture`, `{"left": s or null before the first frame, "frames", "level", "tag_px",
  "tags": [{"id", "seen", "joined"}]}`. `joined` means it reaches the fixed tag through
  tags seen beside it, often enough for the solve to use.
- `solving`: `elapsed`, seconds.
- `review`: `result`, `{"ok", "problems", "warnings", "tags": [{"id", "state", "moved_mm", "seen",
  "spread_mm"}], "gone", "dropped", "agreement_mm": [median, p95], "reprojection_px": [median, p95],
  "turned_deg", "solve_s"}`. A tag's `state` is `same`, `moved` (over 5 mm from the
  calibration in use, relative to the fixed tag) or `new`. `gone` was in use and is not in
  this one; `dropped` was seen but left out. Only `problems` stop a save. A refused
  take may have fewer fields: `ok`, `problems`, `warnings`, `tags`, `gone`, `dropped`.
- `failed`: `reason`.

A link lost or a new `HELLO` ends a take; a solve goes on and `status` finds its result.
Additive like the others: `VERSION` did not change.

## 6. Tools

- `uv run pyscripts/tests/test_body_live.py` — the same against `BODY`: a take on real
  frames beside the link and the picture, then a solve started and cancelled, or the
  refusal without tag 1. Saves nothing. About 30 s.
- `uv run pyscripts/tests/test_camera_live.py` — a client against the running
  tracker on the board's cameras: exposure and gain reach the sensor, the image
  follows, a cap shows, the preview stops. Close the app first; about a minute.

- `uv run pyscripts/ble_test.py` — a BLE peripheral with the tracker's service
  and link, no cameras, streaming a fake hand circle.
- `pyscripts/tests/test_ble_receiver.py`, `test_btplug_connect.py` — minimal BLE
  centrals (HELLO, print what arrives, STOP).
