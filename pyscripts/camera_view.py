"""What the app's Settings > Camera tab sees, and the live exposure/gain it sets.

While the tab is open (CONFIG preview=on) the tracker sends a CAMERA_STATUS and a
small PREVIEW picture at a low rate (docs/PROTOCOL.md). They answer three
different questions about an exposure change: did the sensor take it (read back,
since it caps what it cannot do), did the image change (level, blown out), and
can the tags still be found (how many, and outlined on the picture).

A status fits one BLE message and goes over whichever link the app is on. A
picture is several kB and BLE moves 244 bytes a message, so over BLE pictures go
through the board's hotspot instead (hotspot.py, picture_link.py), and only while
a tablet is there to take them.
"""

import json
import math
import os
from pathlib import Path

import cv2
import numpy as np

import protocol

STATUS_EVERY_S = 0.5
PREVIEW_EVERY_S = 0.2
PREVIEW_PANE = (320, 200)     # per camera, side by side: 3 datagrams a picture
PREVIEW_QUALITY = 50          # JPEG; the picture is for judging light, not detail
BLOWN_OUT = 250               # image value counted as blown out
TAG_OUTLINE = (0, 255, 0)     # BGR
MIN_GAIN, MAX_GAIN = 1.0, 16.0  # past 16 rcam goes on in digital gain


def parse_exposure(text: str) -> int:
    """A CONFIG exposure, in microseconds. ValueError if it cannot be one.

    Too long is not refused: the sensor caps it at the frame period, and the
    status shows what it took. Zero is, because rcam reads 0 as "hand it back to
    auto exposure", which is off here: acknowledged, then nothing would happen.
    """
    value = float(text)
    exposure_us = round(value) if math.isfinite(value) else 0
    if exposure_us < 1:
        raise ValueError(f"bad exposure: {text}")
    return exposure_us


def parse_gain(text: str) -> float:
    """A CONFIG gain, as a multiple. ValueError if outside what the sensor has."""
    value = float(text)
    if not MIN_GAIN <= value <= MAX_GAIN:
        raise ValueError(f"bad gain: {text} (from {MIN_GAIN:g} to {MAX_GAIN:g})")
    return value


def frame_stats(frame: np.ndarray) -> tuple[float, float]:
    """(mean image level 0-255, % of pixels blown out), from every 4th pixel."""
    sample = frame[::4, ::4]
    return (round(float(sample.mean()), 1),
            round(100.0 * float((sample >= BLOWN_OUT).mean()), 1))


def save_settings(path, updates: dict) -> bool:
    """Merge `updates` into settings.json, the rest of it untouched. False, and the
    file as it was, if it is missing or unreadable: the app's whole configuration is
    in there. Written to a temporary file first, so a power cut cannot truncate it."""
    path = Path(path)
    try:
        settings = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(settings, dict):
            raise ValueError("not a JSON object")
        settings.update(updates)
        temporary = path.with_name(path.name + ".tmp")
        temporary.write_text(json.dumps(settings, indent=4) + "\n", encoding="utf-8")
        os.replace(temporary, path)
    except (OSError, ValueError) as exc:
        print(f"[CFG] Could not save {sorted(updates)} to {path}: {exc}", flush=True)
        return False
    return True


def _pane(frame: np.ndarray, corners) -> np.ndarray:
    """One camera for the preview, with the tags it found outlined."""
    height, width = frame.shape[:2]
    pane = cv2.cvtColor(cv2.resize(frame, PREVIEW_PANE, interpolation=cv2.INTER_AREA),
                        cv2.COLOR_GRAY2BGR)
    scale = np.array(PREVIEW_PANE) / (width, height)
    for tag in corners:
        points = (np.asarray(tag, dtype=float).reshape(-1, 2) * scale).astype(np.int32)
        cv2.polylines(pane, [points.reshape(-1, 1, 2)], True, TAG_OUTLINE, 2, cv2.LINE_AA)
    return pane


class CameraView:
    """Decides, frame by frame, what goes to the Camera tab. Off until it opens."""

    def __init__(self, udp: bool) -> None:
        self.enabled = False
        self.send_pictures = udp   # over BLE, set while a tablet is on the hotspot
        self.wifi = None           # over BLE, the status's `wifi` field (Hotspot.status)
        self._reset()

    def _reset(self) -> None:
        self._next_status = 0.0
        self._next_preview = 0.0
        self._frames = 0
        self._since = None

    def set_enabled(self, on: bool) -> None:
        """CONFIG preview=on|off."""
        self.enabled = on
        self._reset()

    def frame(self, now, raw0, raw1, corners0, corners1, sensors, asked) -> list[bytes]:
        """One tracked frame -> the messages now due. `sensors()` gives each
        camera's (exposure_us, gain) or None; it starts subprocesses, so it is
        only called when a status is due. `asked` is the (exposure_us, gain) in
        force, which the sensor may have capped."""
        if not self.enabled:
            return []
        self._frames += 1
        messages = []
        if now >= self._next_status:
            self._next_status = now + STATUS_EVERY_S
            messages.append(self._status(now, raw0, raw1, corners0, corners1, sensors(), asked))
        if self.send_pictures and now >= self._next_preview:
            self._next_preview = now + PREVIEW_EVERY_S
            messages.append(self._preview(raw0, raw1, corners0, corners1))
        return messages

    def _status(self, now, raw0, raw1, corners0, corners1, sensors, asked) -> bytes:
        fps = 0.0
        if self._since is not None:
            fps = round((self._frames - 1) / (now - self._since), 1)
        self._frames = 1
        self._since = now
        stats = [frame_stats(raw0), frame_stats(raw1)]
        status = {
            "ask": list(asked),
            "exposure": [round(s[0], 1) if s else None for s in sensors],
            "gain": [round(s[1], 2) if s else None for s in sensors],
            "level": [s[0] for s in stats],
            "blown": [s[1] for s in stats],
            "tags": [len(corners0), len(corners1)],
            "fps": fps,
        }
        if self.wifi is not None:
            status["wifi"] = self.wifi
        return protocol.encode(protocol.CAMERA_STATUS, json.dumps(status, separators=(",", ":")))

    def _preview(self, raw0, raw1, corners0, corners1) -> bytes:
        picture = np.hstack([_pane(raw0, corners0), _pane(raw1, corners1)])
        ok, jpeg = cv2.imencode(".jpg", picture, [cv2.IMWRITE_JPEG_QUALITY, PREVIEW_QUALITY])
        if not ok:
            raise RuntimeError("could not encode the camera preview")
        return protocol.encode(protocol.PREVIEW, jpeg.tobytes())
