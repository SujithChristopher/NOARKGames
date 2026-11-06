"""The Camera tab's tracker side: live exposure/gain, status and preview.

No cameras needed; test_camera_live.py runs the same path on the board.

    python pyscripts/tests/test_camera_view.py
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cv2
import numpy as np

import protocol
from camera_view import CameraView, frame_stats, parse_exposure, parse_gain
from stereo_capture import StereoCapture

GREY = np.full((800, 1280), 100, dtype=np.uint8)
SENSORS = [(10001.0, 2.0), (10001.0, 2.0)]
ASKED = (10000, 2.0)


def refused(fn, text):
    try:
        fn(text)
    except ValueError:
        return True
    return False


def view_on():
    view = CameraView(udp=True)
    view.set_enabled(True)
    return view


def frame(view, now, sensors=lambda: SENSORS):
    return view.frame(now, GREY, GREY, [], [], sensors, ASKED)


def kinds(messages):
    return sorted(m[0] for m in messages)


def status_of(messages):
    return json.loads(next(m for m in messages if m[0] == protocol.CAMERA_STATUS)[1:])


def picture_of(messages):
    jpeg = next(m for m in messages if m[0] == protocol.PREVIEW)[1:]
    return cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)


def test_exposure_values():
    assert parse_exposure("5000") == 5000
    assert parse_exposure("16353.0") == 16353
    # rcam treats 0 as "hand it back to auto exposure", which is off here, so a
    # zero would be acknowledged and then silently do nothing. inf would raise
    # OverflowError past the ValueError the tracker catches, and stop it.
    for bad in ("0", "-1", "abc", "", "inf", "nan"):
        assert refused(parse_exposure, bad), f"exposure {bad!r} was accepted"


def test_gain_values():
    assert parse_gain("1") == 1.0
    assert parse_gain("2.5") == 2.5
    assert parse_gain("16") == 16.0
    # Above 16 rcam quietly goes on in digital gain, below 1 it reads as 1.
    for bad in ("0.5", "16.5", "abc", "", "nan"):
        assert refused(parse_gain, bad), f"gain {bad!r} was accepted"


def test_frame_stats_level_and_blown_out():
    half = np.zeros((800, 1280), dtype=np.uint8)
    half[:400] = 255
    level, blown = frame_stats(half)
    assert abs(level - 127.5) < 1, level
    assert abs(blown - 50.0) < 1, blown

    level, blown = frame_stats(GREY)
    assert level == 100.0 and blown == 0.0, (level, blown)


def test_over_ble_the_status_goes_but_no_picture_until_someone_is_on_the_hotspot():
    # A picture is several kB and BLE moves 244 bytes a message: encoding one
    # with nobody on Wi-Fi to take it would be wasted work on the tracking loop.
    view = CameraView(udp=False)
    view.set_enabled(True)
    assert kinds(frame(view, 100.0)) == [protocol.CAMERA_STATUS]
    view.send_pictures = True
    assert kinds(frame(view, 100.3)) == [protocol.PREVIEW]


def test_status_says_where_the_pictures_are_over_wifi():
    view = CameraView(udp=False)
    view.set_enabled(True)
    view.wifi = {"state": "on", "ssid": "NOARK-c920", "ip": "10.42.0.1", "port": 8010}
    assert status_of(frame(view, 100.0))["wifi"] == view.wifi


def test_status_has_no_wifi_field_over_udp():
    assert "wifi" not in status_of(frame(view_on(), 100.0))


def test_the_largest_status_fits_one_ble_message():
    # Past 244 bytes the link would chunk it, and every status would then cost
    # several notifications next to the hand position.
    view = CameraView(udp=False)
    view.set_enabled(True)
    view.wifi = {"state": "on", "ssid": "NOARK-c920", "ip": "10.42.0.1", "port": 8010,
                 "bssid": "36:22:7f:b9:c9:20"}
    messages = view.frame(100.0, GREY, GREY, [tuple(range(4))] * 12, [tuple(range(4))] * 12,
                          lambda: [(16443.7, 15.94), (16443.7, 15.94)], (16000, 15.75))
    assert len(messages[0]) <= 244, len(messages[0])


def test_nothing_sent_while_off():
    def no_read():
        raise AssertionError("sensor read while the preview is off")

    view = CameraView(udp=True)
    assert frame(view, 0.0, no_read) == []


def test_rates():
    view = view_on()
    assert kinds(frame(view, 100.0)) == [protocol.CAMERA_STATUS, protocol.PREVIEW]
    assert frame(view, 100.1) == []
    assert kinds(frame(view, 100.21)) == [protocol.PREVIEW]
    assert kinds(frame(view, 100.42)) == [protocol.PREVIEW]
    assert kinds(frame(view, 100.63)) == [protocol.CAMERA_STATUS, protocol.PREVIEW]


def test_sensor_read_only_when_a_status_is_due():
    # Each read starts a v4l2-ctl: on every frame it would slow tracking.
    reads = []

    def counted():
        reads.append(1)
        return SENSORS

    view = view_on()
    for i in range(10):
        frame(view, 100.0 + i * 0.03, counted)
    assert len(reads) == 1, len(reads)


def test_status_fields():
    corners = [np.zeros((4, 2)), np.zeros((4, 2)), np.zeros((4, 2))]
    view = view_on()
    messages = view.frame(100.0, GREY, np.zeros((800, 1280), np.uint8), corners, [],
                          lambda: [(16353.0, 15.94), (16300.0, 15.0)], (25000, 16.0))
    assert status_of(messages) == {
        "ask": [25000, 16.0],
        "exposure": [16353.0, 16300.0],
        "gain": [15.94, 15.0],
        "level": [100.0, 0.0],
        "blown": [0.0, 0.0],
        "tags": [3, 0],
        "fps": 0.0,
    }


def test_status_with_a_sensor_unreadable():
    view = view_on()
    status = status_of(frame(view, 100.0, lambda: [None, (5000.0, 1.0)]))
    assert status["exposure"] == [None, 5000.0]
    assert status["gain"] == [None, 1.0]


def test_fps_counts_frames_between_statuses():
    view = view_on()
    frame(view, 100.0)
    messages = []
    for i in range(1, 11):   # 10 more frames over 0.5 s
        messages = frame(view, 100.0 + i * 0.05)
    assert abs(status_of(messages)["fps"] - 20.0) < 0.01, status_of(messages)


def test_turning_on_again_sends_at_once_and_restarts_fps():
    view = view_on()
    frame(view, 100.0)
    frame(view, 100.1)
    view.set_enabled(False)
    view.set_enabled(True)
    messages = frame(view, 100.15)
    assert kinds(messages) == [protocol.CAMERA_STATUS, protocol.PREVIEW]
    assert status_of(messages)["fps"] == 0.0


def test_preview_shows_each_camera_on_its_own_side():
    dark = np.zeros((800, 1280), np.uint8)
    bright = np.full((800, 1280), 255, np.uint8)
    view = view_on()
    picture = picture_of(view.frame(100.0, dark, bright, [], [], lambda: SENSORS, ASKED))
    assert picture.shape == (200, 640, 3), picture.shape
    assert picture[:, :300].mean() < 10
    assert picture[:, 340:].mean() > 245


def test_preview_outlines_a_tag_where_it_was_found():
    # A tag at (640, 400)-(800, 560) in the frame is (160, 100)-(200, 140) in
    # the left half of a preview a quarter the size; a tag seen by cam1 is
    # drawn in the right half.
    tag = np.array([[640, 400], [800, 400], [800, 560], [640, 560]], dtype=np.float32)
    view = view_on()
    left = picture_of(view.frame(100.0, GREY, GREY, [tag], [], lambda: SENSORS, ASKED))
    view = view_on()
    right = picture_of(view.frame(100.0, GREY, GREY, [], [tag], lambda: SENSORS, ASKED))

    def greenness(picture, x0, y0, x1, y1):
        patch = picture[y0:y1, x0:x1].astype(int)
        return (patch[..., 1] - patch[..., 0]).max()

    assert greenness(left, 170, 98, 190, 103) > 40, "no outline on the left"
    assert greenness(left, 330, 98, 350, 103) < 20, "outline on the wrong side"
    assert greenness(right, 490, 98, 510, 103) > 40, "no outline on the right"


class FakeCamera:
    """rcam.Camera's control surface, as StereoCapture uses it."""

    def __init__(self, lines=1000, code=40, unreadable=False):
        self.lines, self.code, self.unreadable = lines, code, unreadable
        self.calls = []

    def set_controls(self, controls, *, settle=True):
        self.calls.append((controls, settle))

    def get_control(self, name):
        if self.unreadable:
            raise RuntimeError("v4l2-ctl failed")
        return {"exposure": self.lines, "analogue_gain": self.code}[name]

    def line_time_us(self):
        return 9.1


def capture_with(cam0, cam1):
    capture = StereoCapture.__new__(StereoCapture)
    capture.cam0, capture.cam1 = cam0, cam1
    capture.exposure_us, capture.fps_value = 10000, 60  # a capped rate: the frame stays put
    return capture


def test_set_exposure_changes_both_cameras_without_draining_frames():
    # Draining one camera's queue and then the other's would break the pairing
    # that _align_pairing set up.
    cam0, cam1 = FakeCamera(), FakeCamera()
    capture_with(cam0, cam1).set_exposure(5000, 2.5)
    want = [({"ExposureTime": 5000, "AnalogueGain": 2.5}, False)]
    assert cam0.calls == want, cam0.calls
    assert cam1.calls == want, cam1.calls


def test_sensor_settings_reads_what_the_sensor_holds():
    capture = capture_with(FakeCamera(lines=1000, code=40), FakeCamera(lines=500, code=16))
    assert capture.sensor_settings() == [(9100.0, 2.5), (4550.0, 1.0)]


def test_sensor_settings_survives_a_failed_read():
    capture = capture_with(FakeCamera(unreadable=True), FakeCamera(lines=500, code=16))
    assert capture.sensor_settings() == [None, (4550.0, 1.0)]


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
            print(f"  ok  {name}")
    print("\nOK")
