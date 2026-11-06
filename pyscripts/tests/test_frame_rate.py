"""The fastest frame a given exposure allows, on the numbers this rig's sensor reports."""
import sys
import tempfile
import threading
from collections import deque
from pathlib import Path
from types import SimpleNamespace

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from frame_recorder import FrameRecorder
from stereo_capture import StereoCapture, fastest_blanking

LINE_US = 1456 / 160  # (1280 + 176) / 160 MHz
HEIGHT = 800


def fps(blanking: int) -> float:
    return 1e6 / ((HEIGHT + blanking) * LINE_US)


class FakeCamera:
    height = HEIGHT

    def __init__(self, log):
        self.log, self.blanking = log, 324

    def get_control(self, name):
        return self.blanking

    def set_controls(self, controls, *, settle=True):
        assert not settle, "settling would break the pairing"
        self.log.append(next(iter(controls)))
        self.blanking = controls.get("vertical_blanking", self.blanking)

    def frame_period_us(self):
        return (HEIGHT + self.blanking) * LINE_US


def running_capture():
    log = []
    capture = StereoCapture.__new__(StereoCapture)
    capture.cam0, capture.cam1 = FakeCamera(log), FakeCamera(log)
    capture.exposure_us, capture.gain, capture.fps_value = 10000, 1.0, None
    capture._frame_sync = SimpleNamespace(line_time_us=LINE_US, period_us=0.0)
    capture._frame_period_us = 0.0
    capture._resync_busy = threading.Event()
    capture._recent_ns = (deque([1, 2]), deque([1, 2]))
    return capture, log


def test_the_frame_makes_room_before_a_longer_exposure():
    capture, log = running_capture()
    capture.set_exposure(16000, 1.0)
    assert log == ["vertical_blanking"] * 2 + ["ExposureTime"] * 2, log
    assert 60 < 1e6 / capture._frame_period_us < 62, capture._frame_period_us
    assert capture._frame_sync.period_us == capture._frame_period_us
    assert not capture._recent_ns[0], "stamps from the old period would read as a phase error"


def test_a_shorter_exposure_gives_the_time_back_after():
    capture, log = running_capture()
    capture.exposure_us = 16000
    capture.cam0.blanking = capture.cam1.blanking = 1000
    capture.set_exposure(10000, 1.0)
    assert log == ["ExposureTime"] * 2 + ["vertical_blanking"] * 2, log


def test_a_capped_rate_keeps_its_frame():
    capture, log = running_capture()
    capture.fps_value = 60
    capture.set_exposure(16000, 1.0)
    assert log == ["ExposureTime"] * 2, log


def saved(target_hz: float) -> int:
    """Pairs a recording keeps from one second of a 100 fps sensor."""
    frame = np.zeros((8, 8), np.uint8)
    with tempfile.TemporaryDirectory() as folder:
        recorder = FrameRecorder(Path(folder) / "rec", target_hz=target_hz)
        for i in range(100):
            stamp = 10 ** 9 + i * 10 ** 7
            recorder.add(frame, frame, stamp, stamp, (i, i))
        recorder.close()
        return recorder.frames


def test_a_recording_keeps_the_rate_it_was_given():
    assert saved(0) == 100, "0 means every frame"
    assert saved(30) in (30, 31), saved(30)
    assert 59 <= saved(60) <= 61, "the average holds even where the spacing cannot be even"


if __name__ == "__main__":
    test_the_frame_makes_room_before_a_longer_exposure()
    test_a_shorter_exposure_gives_the_time_back_after()
    test_a_capped_rate_keeps_its_frame()
    test_a_recording_keeps_the_rate_it_was_given()
    ten_ms = fastest_blanking(10000, LINE_US, HEIGHT)
    assert ten_ms == 1099 + 25 - 800, ten_ms
    assert 97 < fps(ten_ms) < 99, fps(ten_ms)
    assert fastest_blanking(1000, LINE_US, HEIGHT) == 110, "the driver's minimum"
    assert 120 < fps(110) < 121.5, fps(110)
    assert 59 < fps(fastest_blanking(16000, LINE_US, HEIGHT)) < 62
    assert fastest_blanking(10_000_000, LINE_US, HEIGHT) == 51_540, "the driver's maximum"
    print(f"OK — 10 ms gives {fps(ten_ms):.1f} fps, nothing shorter beats {fps(110):.1f}.")
