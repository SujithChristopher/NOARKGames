"""Record the synchronised frame pairs a session produced, alongside tracking.

Frames are stored raw — msgpack-numpy, exactly as `dual_recorder_rcam.py` in
NOARK_backbone writes them — rather than encoded. That is a deliberate trade:
FFV1 would compress 2.18x but costs 26 ms of CPU per pair, and the tracking loop
is already the thing competing for the big cores. Packing a pair costs 1.2 ms
and the writes release the GIL, so recording is about 4% of a 33 ms frame budget
instead of most of it.

The price is on disk: 61 MB/s, 37 GB per ten minutes. That is the number to plan
around, not the CPU.

    {patient}/Session-{date}/Video/rec_HH-MM-SS/
        cam{0,1}_frame.msgpack      raw HxW uint8 frames
        cam{0,1}_timestamp.msgpack  [sync, wall_iso, monotonic_ns, sensor_ns, seq]
        sync_events.msgpack         [timestamp_ns, value, line_seqno] per edge
        metadata.json

Pair frames across the cameras on the sensor_ns column, never on frame index:
it is CLOCK_MONOTONIC as stamped by CAMSS in its frame-done interrupt, the same
clock the GPIO edges carry, so a trigger pulse and a frame exposure sit on one
timeline without any clock fitting.
"""

import json
import queue
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Optional

import msgpack
import msgpack_numpy as mpn
import numpy as np

# How many pairs may be waiting on disk before the capture loop is affected.
# 32 pairs is about a second at 30 Hz — enough to ride out a flush, far short of
# the memory a real backlog would need (each pair is 2 MB).
QUEUE_DEPTH = 32


class SyncLine:
    """The mocap trigger on the 40-pin header: a per-frame level and edge times.

    Ported from NOARK_backbone's dual_recorder_rcam.py, narrowed to the libgpiod
    v2 API this board actually has. The header is gpiochip4 (the SoC TLMM) and
    header pin N is *not* TLMM line N — the device tree names them, so a line is
    given either by number or by its header name. PIN_11 (line 29) is the
    default because it is the same physical hole the Pi used for GPIO17, so
    existing trigger wiring does not have to move.

    Two things are recorded and only one is cheap to misread. The per-frame
    `sync` column is a level sampled once per frame, so a pulse shorter than the
    frame period is usually missed outright and one that is caught is located
    only to within a frame. So a latch thread also records every transition with
    the kernel's own CLOCK_MONOTONIC timestamp — the same clock as sensor_ns —
    which places a pulse against a frame at interrupt accuracy, and keeps edges
    that fall between recordings.

    Degrades rather than fails: no gpiod, a claimed line, or a kernel that
    refuses edge detection each fall back a step, ending at a constant 0 so a
    session without the trigger box still records.
    """

    def __init__(self, chip: str = "gpiochip4", line="PIN_11", latch_edges: bool = True):
        self.available = False
        self.edges_available = False
        self.chip = chip
        self.line: Optional[int] = None
        self._read = lambda: 0
        self._req = None
        self._events: list = []
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._level = 0

        try:
            import gpiod
            from gpiod.line import Direction, Edge, Value
        except ImportError:
            print("[SYNC] gpiod not installed — sync column stays 0")
            return

        try:
            self.line = self._resolve(gpiod, chip, line)

            def request(with_edges: bool):
                settings = gpiod.LineSettings(direction=Direction.INPUT)
                if with_edges:
                    settings.edge_detection = Edge.BOTH
                return gpiod.request_lines(
                    f"/dev/{chip}", consumer="noark_recorder",
                    config={self.line: settings},
                )

            if latch_edges:
                try:
                    self._req = request(True)
                    self.edges_available = True
                except (OSError, ValueError) as exc:
                    print(f"[SYNC] Edge detection refused ({exc}); polling the level")
            if self._req is None:
                self._req = request(False)

            self._level = 1 if self._req.get_value(self.line) == Value.ACTIVE else 0
            if self.edges_available:
                self._read = self._latched_level
                self._thread = threading.Thread(
                    target=self._latch_loop, name="sync-latch", daemon=True
                )
                self._thread.start()
            else:
                self._read = lambda: (
                    1 if self._req.get_value(self.line) == Value.ACTIVE else 0
                )
            self.available = True
            named = "" if str(line) == str(self.line) else f" ({line})"
            how = ("level + edge timestamps" if self.edges_available
                   else "level only — pulse starts known to one frame")
            print(f"[SYNC] GPIO on {chip} line {self.line}{named} ({how}), "
                  f"idle level {self._level}")
        except Exception as exc:                  # any GPIO failure degrades to 0
            print(f"[SYNC] GPIO unavailable on {chip} line {line}: {exc}")
            print("[SYNC] Sync column stays 0.")

    @staticmethod
    def _resolve(gpiod, chip: str, line) -> int:
        """Accept a TLMM line number or a device-tree name such as PIN_11."""
        text = str(line)
        if text.lstrip("-").isdigit():
            return int(text)
        with gpiod.Chip(f"/dev/{chip}") as c:
            return c.line_offset_from_id(text)

    def _latch_loop(self) -> None:
        """Block on the line's event fd, keeping every transition the kernel saw."""
        import datetime as _dt
        poll = _dt.timedelta(milliseconds=200)   # only bounds the stop check
        try:
            while not self._stop.is_set():
                if not self._req.wait_edge_events(poll):
                    continue
                for event in self._req.read_edge_events():
                    value = 1 if event.event_type == event.Type.RISING_EDGE else 0
                    with self._lock:
                        self._events.append(
                            (event.timestamp_ns, value, event.line_seqno)
                        )
                        self._level = value
        except Exception as exc:      # a dead latch must not end the recording
            print(f"[SYNC] Edge latch stopped: {exc!r}")

    def _latched_level(self) -> int:
        with self._lock:
            return self._level

    def get_value(self) -> int:
        return int(self._read())

    @property
    def event_count(self) -> int:
        with self._lock:
            return len(self._events)

    def write_events(self, out_dir: Path, filename: str = "sync_events.msgpack"):
        """Write the latched edges as [timestamp_ns, value, line_seqno] records.

        timestamp_ns shares CLOCK_MONOTONIC with the frames' sensor_ns, so a
        pulse is placed against a frame by direct comparison.
        """
        with self._lock:
            events = list(self._events)
        if not events:
            return None
        path = Path(out_dir) / filename
        with open(path, "wb") as fh:
            for record in events:
                fh.write(msgpack.packb(list(record)))
        return path

    def close(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=1.0)
        if self._req is not None:
            try:
                self._req.release()
            except Exception:
                pass


class _CameraWriter(threading.Thread):
    """Packs and writes one camera's frames, off the capture thread.

    A flush that stalls must not stall capture, because capture is also what
    feeds tracking — a stutter in the game is worse than a gap in the recording.
    So the queue is bounded and overflow drops the pair, counted and reported,
    rather than blocking.

    Output is rotated every `chunk_frames` frames. An hour at 30 Hz is 110 GB
    per camera in one file, which is awkward to copy, painful to resume and
    unopenable in anything that wants to seek. Both the frames and their
    timestamps rotate together on the same boundary, so each chunk stands alone
    and can be moved or processed on its own.
    """

    def __init__(self, index: int, out_dir: Path, chunk_frames: int = 0):
        super().__init__(name=f"rec-cam{index}", daemon=True)
        self.index = index
        self.written = 0
        self.dropped = 0
        self.chunks: list = []
        self._chunk_frames = max(0, int(chunk_frames))
        self._out_dir = Path(out_dir)
        self._queue: queue.Queue = queue.Queue(maxsize=QUEUE_DEPTH)

    def offer(self, frame: np.ndarray, record: list) -> bool:
        try:
            self._queue.put_nowait((frame, record))
            return True
        except queue.Full:
            self.dropped += 1
            return False

    def _paths(self, chunk: int):
        """Chunk 0 keeps the unsuffixed names, so a short take looks unchanged."""
        suffix = "" if self._chunk_frames == 0 else f"_{chunk:04d}"
        return (self._out_dir / f"cam{self.index}_frame{suffix}.msgpack",
                self._out_dir / f"cam{self.index}_timestamp{suffix}.msgpack")

    def run(self) -> None:
        chunk = 0
        in_chunk = 0
        first_ns = last_ns = None
        frame_path, stamp_path = self._paths(chunk)
        fh_frame = open(frame_path, "wb")
        fh_stamp = open(stamp_path, "wb")
        try:
            while True:
                item = self._queue.get()
                if item is None:                  # sentinel: recording finished
                    break
                frame, record = item
                fh_frame.write(msgpack.packb(frame, default=mpn.encode))
                fh_stamp.write(msgpack.packb(record))
                self.written += 1
                in_chunk += 1
                sensor_ns = record[3]
                first_ns = sensor_ns if first_ns is None else first_ns
                last_ns = sensor_ns

                if self._chunk_frames and in_chunk >= self._chunk_frames:
                    fh_frame.close(); fh_stamp.close()
                    self.chunks.append({
                        "chunk": chunk, "frames": in_chunk,
                        "first_sensor_ns": first_ns, "last_sensor_ns": last_ns,
                        "frame_file": frame_path.name,
                        "timestamp_file": stamp_path.name,
                    })
                    chunk += 1
                    in_chunk = 0
                    first_ns = last_ns = None
                    frame_path, stamp_path = self._paths(chunk)
                    fh_frame = open(frame_path, "wb")
                    fh_stamp = open(stamp_path, "wb")
        finally:
            fh_frame.close(); fh_stamp.close()
            if in_chunk:
                self.chunks.append({
                    "chunk": chunk, "frames": in_chunk,
                    "first_sensor_ns": first_ns, "last_sensor_ns": last_ns,
                    "frame_file": frame_path.name,
                    "timestamp_file": stamp_path.name,
                })
            elif self._chunk_frames:
                # Rotated exactly on the last frame: remove the empty files
                # rather than leave a reader to trip over them.
                for path in (frame_path, stamp_path):
                    if path.exists() and path.stat().st_size == 0:
                        path.unlink()

    def finish(self) -> None:
        self._queue.put(None)
        self.join(timeout=15.0)

    @property
    def backlog(self) -> int:
        return self._queue.qsize()


class FrameRecorder:
    """Both cameras' frames and the sync line, written for one session."""

    def __init__(self, out_dir: Path, metadata: Optional[dict] = None,
                 sync_chip: str = "gpiochip4", sync_pin="PIN_11",
                 target_hz: float = 30.0, chunk_frames: int = 900):
        self.out_dir = Path(out_dir)
        self.out_dir.mkdir(parents=True, exist_ok=True)
        self.sync = SyncLine(sync_chip, sync_pin)
        self._writers = [_CameraWriter(i, self.out_dir, chunk_frames) for i in (0, 1)]
        for writer in self._writers:
            writer.start()
        self.frames = 0
        self.skipped = 0
        self._started_at = time.monotonic()
        # Recording rate is decided here, not by the sensor: tracking wants
        # every frame the camera can give, while the analysis wants ~30 Hz and
        # far less disk. Pairs are dropped on elapsed sensor time rather than
        # by counting, so the rate does not depend on the capture rate dividing
        # evenly — at 57 Hz in, keeping every other pair lands at 28.5 Hz, and
        # the interval stays honest as the capture rate wanders.
        self._interval_ns = int(1e9 / target_hz) if target_hz > 0 else 0
        self._next_due: Optional[int] = None

        payload = {
            "start_time": datetime.now().isoformat(timespec="seconds"),
            "format": "msgpack-numpy raw frames",
            "timestamp_columns": ["sync", "wall_clock_iso", "monotonic_ns",
                                  "sensor_ns", "sequence"],
            "target_hz": target_hz,
            "chunk_frames": chunk_frames,
            "sync_line": {
                "chip": sync_chip,
                "line": self.sync.line,
                "available": self.sync.available,
                "edge_timestamps": self.sync.edges_available,
            },
        }
        payload.update(metadata or {})
        with open(self.out_dir / "metadata.json", "w") as fh:
            json.dump(payload, fh, indent=2)
        print(f"[REC] Recording to {self.out_dir}")

    def add(self, frame0, frame1, sensor_ns0, sensor_ns1, sequences) -> None:
        """Offer one pair, subject to the target rate.

        Cheap on the caller either way: a skipped pair costs one comparison,
        and a kept one hands the packing to the writer threads.
        """
        if self._interval_ns:
            now_ns = sensor_ns0 if sensor_ns0 is not None else time.monotonic_ns()
            if self._next_due is None:
                self._next_due = now_ns
            if now_ns < self._next_due:
                self.skipped += 1
                return
            self._next_due += self._interval_ns
            if self._next_due <= now_ns:
                # A gap longer than the interval: resync rather than trying to
                # catch up, which would burst frames to no purpose.
                self._next_due = now_ns + self._interval_ns

        sync = self.sync.get_value()
        wall = datetime.now().isoformat(sep=" ")
        mono = time.monotonic_ns()
        for writer, frame, sensor_ns, seq in zip(
            self._writers, (frame0, frame1), (sensor_ns0, sensor_ns1), sequences
        ):
            writer.offer(frame, [sync, wall, mono, sensor_ns, seq])
        self.frames += 1

    @property
    def status(self) -> str:
        written = [w.written for w in self._writers]
        dropped = [w.dropped for w in self._writers]
        backlog = [w.backlog for w in self._writers]
        elapsed = max(time.monotonic() - self._started_at, 1e-6)
        return (f"{self.frames} pairs at {self.frames / elapsed:.1f} Hz "
                f"(skipped {self.skipped}), "
                f"written {written}, dropped {dropped}, backlog {backlog}, "
                f"sync edges {self.sync.event_count}")

    def close(self) -> None:
        for writer in self._writers:
            writer.finish()

        # Written at teardown because the chunks only exist by then. It gives a
        # reader the frame counts and the sensor_ns span of each file, so the
        # chunk holding a given moment is found without opening any of them.
        index_path = self.out_dir / "chunks.json"
        with open(index_path, "w") as fh:
            json.dump({f"cam{w.index}": w.chunks for w in self._writers}, fh, indent=2)
        path = self.sync.write_events(self.out_dir)
        self.sync.close()
        gigabytes = sum(
            f.stat().st_size for f in self.out_dir.glob("*.msgpack")
        ) / 1e9
        print(f"[REC] {self.status}")
        if path is not None:
            print(f"[REC] Sync edges -> {path.name}")
        elif self.sync.available:
            print("[REC] No sync edges seen — is the trigger wired and running?")
        chunks = len(self._writers[0].chunks)
        print(f"[REC] Wrote {gigabytes:.2f} GB to {self.out_dir} "
              f"in {chunks} chunk(s) per camera")
