"""The camera recordings on the board, for the app's Settings > Storage tab.

The app asks through the link (STORAGE, docs/PROTOCOL.md) because over BLE it
runs on a tablet and cannot see the board's disk. A recording is tens of GB, so
listing and deleting run on a worker thread: the tracking loop, and the
heartbeat the app's liveness check needs, never wait on the disk. Each finished
job leaves a STORAGE_LIST message for the loop to send (`poll`).

Only recording directories can be deleted, never the one being written and
nothing outside the data directory:

    <patient>/Session-<date>/Video/rec_HH-MM-SS                    FrameRecorder
    <patient>/Session-<date>/MovementData/recordings/rec_HH-MM-SS  --record
"""

import json
import queue
import shutil
import threading
from pathlib import Path
from typing import Callable, Iterable, Optional

import protocol

PATTERNS = ("*/*/Video/rec_*", "*/*/*/recordings/rec_*")


def _is_recording(parts: tuple) -> bool:
    if not parts or not parts[-1].startswith("rec_"):
        return False
    return (len(parts) == 4 and parts[2] == "Video") or (len(parts) == 5 and parts[3] == "recordings")


def _size(path: Path) -> int:
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file())


class Storage:
    def __init__(self, root: Path, active: Callable[[], Iterable[Path]]) -> None:
        """`active()` -> the recording directories being written now."""
        self.root = Path(root)
        self._active = active
        self._jobs: queue.Queue = queue.Queue()
        self._done: queue.Queue = queue.Queue()
        threading.Thread(target=self._work, name="storage", daemon=True).start()

    def command(self, text: str) -> tuple[bool, str]:
        """STORAGE `list` | `delete=<path>` -> (ok, detail) for the ACK. The
        answer itself comes later, as STORAGE_LIST."""
        if text == "list":
            self._jobs.put(("list", None))
            return True, "listing"
        if text.startswith("delete="):
            rel = text[len("delete="):]
            try:
                path = self._recording(rel)
            except ValueError as e:
                return False, str(e)
            self._jobs.put(("delete", path))
            return True, "deleting " + rel
        return False, "unknown storage command: " + text

    def poll(self) -> Optional[bytes]:
        """A finished job's STORAGE_LIST, or None."""
        try:
            return self._done.get_nowait()
        except queue.Empty:
            return None

    def _recording(self, rel: str) -> Path:
        root = self.root.resolve()
        path = (root / rel).resolve()
        try:
            parts = path.relative_to(root).parts
        except ValueError:
            raise ValueError("not in the data directory: " + rel) from None
        if not _is_recording(parts):
            raise ValueError("not a recording: " + rel)
        if not path.is_dir():
            raise ValueError("no such recording: " + rel)
        if path in self._active_dirs():
            raise ValueError("being recorded now: " + rel)
        return path

    def _active_dirs(self) -> set:
        return {Path(p).resolve() for p in self._active()}

    def _work(self) -> None:
        while True:
            job, path = self._jobs.get()
            event = ""
            if job == "delete":
                event = self._delete(path)
            try:
                listing = self._list()
            except OSError as e:
                listing = {"recordings": [], "total": 0, "free": 0}
                event = event or f"error: could not list the recordings ({e})"
            listing["event"] = event
            self._done.put(protocol.encode(
                protocol.STORAGE_LIST, json.dumps(listing, separators=(",", ":"))))

    def _delete(self, path: Path) -> str:
        rel = path.relative_to(self.root.resolve()).as_posix()
        if path in self._active_dirs():   # a session started since it was asked
            return "error: being recorded now: " + rel
        try:
            size = _size(path)
            shutil.rmtree(path)
        except OSError as e:
            print(f"[STORAGE] Could not delete {rel}: {e}")
            return f"error: {rel}: {e}"
        parent = path.parent              # Video/ or recordings/, if now empty
        if not any(parent.iterdir()):
            parent.rmdir()
        print(f"[STORAGE] Deleted {rel} ({size / 1e9:.1f} GB)")
        return "deleted " + rel

    def _list(self) -> dict:
        root = self.root.resolve()
        active = self._active_dirs()
        recordings = []
        for pattern in PATTERNS:
            for d in sorted(root.glob(pattern)):
                parts = d.relative_to(root).parts
                if not d.is_dir() or not _is_recording(parts):
                    continue
                recordings.append({
                    "path": d.relative_to(root).as_posix(),
                    "patient": parts[0],
                    "session": parts[1],
                    "name": parts[-1],
                    "bytes": _size(d),
                    "active": d.resolve() in active,
                })
        disk = shutil.disk_usage(root if root.exists() else Path.home())
        return {"total": disk.total, "free": disk.free, "recordings": recordings}
