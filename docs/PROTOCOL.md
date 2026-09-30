# NOARK App ↔ Tracker Protocol

What the Godot app sends to the tracking device (`device/tracker.py`), what
comes back, and what the device does on silence. Companion to
[DATA_FORMATS.md](DATA_FORMATS.md), which covers the files the two sides write.

Everything here was read from the code, not from a spec. Where the code defines
nothing (numeric opcodes, error codes, a state machine), this document says so
rather than inventing it — see §7.

Sources: `app/scripts/device_link.gd` (app side),
`device/tracker.py` and `device/udp_link.py` (device side),
`device/ble_link.py` (BLE peripheral).

---

## 1. Transport

| | UDP (default) | BLE |
|---|---|---|
| Selected by | `config.json` `"stream_type": "udp"` | `"stream_type": "ble"` |
| Endpoint | `127.0.0.1:8000` (`udp_port` in `config.json`) | GATT service `4e4f4152-4b00-0000-0000-000000000000` |
| Uplink (app → device) | UDP datagram | Write to characteristic `…4b02…` (write or write-without-response, whichever the peripheral offers) |
| Downlink (device → app) | UDP datagram | Notify on characteristic `…4b01…` |
| Roles | Python binds and is the server; Godot `connect_to_host()`s | Python is the GATT peripheral (`NOARK_Tracker`); Godot is the central |

The tracker does not learn Godot's address from configuration. It replies to
the source address of the **last command it received**, so it cannot send
anything until the first command arrives.

BLE note: `ble_link.py` implements the peripheral, but `tracker.py` only
instantiates the UDP link class. BLE is therefore documented from the app side and
the streamer file; no code in this repo runs tracker + BLE together.

## 2. Command encoding

There are **no numeric opcodes** on the uplink. A command is a UTF-8 ASCII
string, one command per datagram (or per BLE write), with no length prefix, no
terminator, no checksum, and no sequence number.

```
"STOP"            4 bytes  53 54 4F 50
"RESET"           5 bytes  52 45 53 45 54
"CONNECTED"       9 bytes  (heartbeat)
"USER:<id>"       5 + len(id) bytes
"CHANGE:<id>"     7 + len(id) bytes
```

Matching is exact for `STOP` and `RESET` (`== b"STOP"`), and by prefix for
`USER:` / `CHANGE:` (the text after the first `:` is the patient id).

**Size limit: 30 bytes.** The tracker reads with `recvfrom(30)`. A longer
datagram is truncated on Linux (the target platform), so `USER:` + id must fit
in 30 bytes — a hospital id of at most **25 bytes**. Nothing validates this on
either side; an over-long id arrives cut short and names the wrong folder.

## 3. Commands

| Command | Sent by app? | Parameter | Valid values | Effect on device | Downlink code |
|---|---|---|---|---|---|
| `CONNECTED` | Yes — default heartbeat message | none | fixed string | Refreshes the liveness timer. Any message the tracker does not recognise is treated the same way. | `2.0` |
| `USER:<id>` | Yes — on patient login (login handler) | `<id>` hospital id | non-empty; ≤ 25 bytes; used as a folder name, so no path separators. Not validated. | Sets the patient id, opens the session log and recordings if none are open (§5), starts recording. Becomes the heartbeat: the app resends it every 0.1 s for the rest of the run. | `2.0` |
| `CHANGE:<id>` | **No** — tracker understands it, app never sends it | `<id>` as above | as above | Same as `USER:` but first clears the current session path, so a new session log is opened for the new id. | `2.0` |
| `RESET` | **No** — tracker understands it, app never sends it | none | fixed string | Replies with code `5.0`. Nothing else changes on the device. | `5.0` |
| `STOP` | Yes — once, on quit (quit handler) | none | fixed string | Latches a stop; tracker finishes the current iteration, closes recordings and cameras, exits. | `-99.0` |

Downlink codes are the first float of the position packet (§4).

`CHANGE:` and `RESET` are dead paths from the app's point of view. On the app
side `5.0` sets `reset_position`, which nothing reads.

### Heartbeat behaviour

- The app-side link script starts a timer at `delay_time = 0.1` s (an `@export`) that
  resends whatever `_outgoing_message` currently holds: `"CONNECTED"` at
  launch, `"USER:<id>"` after login, `"STOP"` after quit.
- The packet handler also sends `_outgoing_message` once per received
  position packet, so the real uplink rate is the timer plus the packet rate.
- Because `USER:<id>` replaces `CONNECTED` as the heartbeat, a login is not a
  one-shot command. It is repeated until the app exits. Handling is
  idempotent (a session is only opened when none is open), so this is safe.
- `STOP` is the exception: the timer is stopped first, so it is sent once from
  `handle_quit_request()` (plus once per position packet still in flight).

## 4. Response: the position packet

The device answers with one packet per processed frame, not per command.

```
11 × float32, little-endian, 44 bytes
[ msg_code, cx, cy, cz, rvx, rvy, rvz, tx, ty, tz, ref_id ]
   0         1   2   3   4    5    6    7   8   9   10
```

| Field | Meaning |
|---|---|
| `msg_code` | `2.0` START/OK, `5.0` RESET, `-99.0` STOP |
| `cx..cz` | Smoothed tracked point, metres, camera frame |
| `rvx..rvz` | Rodrigues rotation of the reference tag / rigid body |
| `tx..tz` | Translation of the reference tag / rigid body |
| `ref_id` | Reference tag id (float) |

`msg_code` is chosen from the latest command: `STOP` → `-99.0`, `RESET` →
`5.0`, everything else (including `USER:`, `CHANGE:`, `CONNECTED` and
unrecognised text) → `2.0`.

App handling of `msg_code` (frame update in `device_link.gd`):

| Received | App does |
|---|---|
| `2.0` | `connected = true` |
| `5.0` | `reset_position = true` (unused) |
| `-99.0` | Marks disconnected/ended, joins the network and tracker threads, quits the app |

BLE payloads must be at least 44 bytes and a multiple of 4, otherwise the app
logs `Unexpected position payload size` and drops the packet.

**There is no command-level acknowledgement.** A reply confirms only that the
tracker is alive and saw a pose. Two consequences:

- **No marker in view → no packet at all.** The device only sends when a pose
  was solved. The app cannot tell "tracker alive, no marker" from "tracker
  dead" by packets alone.
- `STOP` is acknowledged with `-99.0` only if a pose is available at that
  moment. If not, the tracker exits without acknowledging, and the app relies
  on its own quit path.

## 5. Device states and which commands apply

The tracker has no explicit state variable. The states below are inferred from
the control flow in `tracker.py`.

| State | Entered when | Exited when |
|---|---|---|
| **Starting** | Process spawn. Socket bound first, then cameras brought up (phase alignment, tens of seconds). | Cameras ready, the main loop begins |
| **Running, no session** | Loop started, no `USER:` yet (no session path set) | First `USER:` / `CHANGE:` |
| **Running, session open** | `USER:` / `CHANGE:` handled | STOP, heartbeat timeout, or exception |
| **Stopping** | STOP latched | Process exit |

| Command | Starting | Running, no session | Running, session open | Stopping |
|---|---|---|---|---|
| `CONNECTED` | Read and kept; only refreshes liveness. No reply (loop not running). | Accepted, reply `2.0` (if pose) | Accepted, reply `2.0` | Ignored |
| `USER:<id>` | Read and kept, **not acted on** until the loop starts; the heartbeat repeat then delivers it. | Accepted: opens log and recordings | Accepted, no-op (session already open) | Ignored |
| `CHANGE:<id>` | As `USER:` | Accepted, same as `USER:` | Accepted: reopens a session for the new id | Ignored |
| `RESET` | Kept, not acted on | Accepted, reply `5.0` | Accepted, reply `5.0` | Ignored |
| `STOP` | **Honoured immediately** by the startup watcher, which aborts the camera bring-up | Accepted, exits | Accepted, closes recordings, exits | — |

Notes:

- Nothing is ever *rejected*. Commands not valid in a state are held or
  ignored silently; the device sends no refusal.
- The session log and recordings open on the command, not on tracking success,
  so a session with no marker in view still records frames.
- `CHANGE:` clears the session path and opens a new CSV but does not close the
  previous session CSV writer; see the source before relying on it.
- The last command received is latched and reused every
  frame. It is cleared only after a `STOP` acknowledgement.

## 6. Timeouts and retry

| Timer | Value | Where | What happens on expiry |
|---|---|---|---|
| Heartbeat interval (app) | 0.1 s (`delay_time`) | `device_link.gd` | — (this *is* the retry mechanism) |
| Liveness timeout (device) | **3.0 s** since the last received command | `tracker.py` main loop | Prints `Lost connection to Godot, exiting…` and exits |
| Startup | none | — | Loop's liveness clock starts only when the main loop begins, so a slow camera bring-up does not trip the 3 s timeout |
| BLE peripheral start | 10 s | `ble_link.py` start | Raises `BLE server did not start within 10 seconds` |
| Godot-side wait for packets | none | — | The app never times out waiting for the tracker |
| Tracker respawn (app) | checked every frame | frame update | If the tracker thread is dead, not `debug`, not `endgame`: restart it |

**What to use for retry.** The protocol does not retry individual commands. It
resends the current message every 0.1 s and the device tolerates 3.0 s of
silence, which is 30 missed heartbeats. An app-side timeout for "device
unresponsive" should be **≥ 3 s** of no position packets *and* a check that a
marker is expected in view. Anything shorter will fire while the device is
alive but cannot see a marker.

Because the uplink is UDP (or unacknowledged BLE writes), a lost `STOP` is
recovered only by the device's own 3 s timeout, once the app stops sending.

## 7. What the protocol does not define

- **No numeric opcodes and no byte-level frame** on the uplink. Commands are
  bare ASCII strings (§2).
- **No error codes.** Failures show up as log lines (`Error: … — Godot likely
  closed`, `Lost connection to Godot, exiting…`) and process exit, not as
  values sent to the app. The `msg_code` slot carries only `2.0`, `5.0`,
  `-99.0`; other values are not produced.
- **No per-command acknowledgement or retry counter.**