"""The board's hotspot and the picture channel over it. No radio needed; the
hotspot trial and the tablet cover the real thing.

    python pyscripts/tests/test_hotspot.py
"""
import json
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import protocol
from camera_view import save_settings
from hotspot import Hotspot
from picture_link import PictureLink


# `iw dev` on the board with the hotspot up, as measured.
IW_DEV = """phy#0
\tUnnamed/non-netdev interface
\t\twdev 0x4
\t\taddr 3e:22:7f:b9:b5:89
\t\ttype P2P-device
\tInterface wlx36227fb9c920
\t\tifindex 5
\t\twdev 0x2
\t\taddr 36:22:7f:b9:c9:20
\t\tssid NOARK-c920
\t\ttype AP
\t\tchannel 149 (5745 MHz), width: 80 MHz, center1: 5775 MHz
\tInterface wlan0
\t\tifindex 3
\t\twdev 0x1
\t\taddr 3c:22:7f:b9:c9:20
\t\tssid mocap
\t\ttype managed
"""


class FakeHelper:
    """Stands in for `sudo -n noark-hotspot` and `iw dev`: records the helper's
    calls, and can be held open."""

    def __init__(self, up_output="ssid=NOARK-c920\nip=10.42.0.1\n", up_code=0):
        self.calls = []
        self.up_output, self.up_code = up_output, up_code
        self.hold = threading.Event()
        self.hold.set()

    iw_output = IW_DEV

    def __call__(self, cmd, **kwargs):
        if cmd[0] == "iw":
            return subprocess.CompletedProcess(cmd, 0, self.iw_output, "")
        action = cmd[-1]
        self.calls.append(action)
        if action == "up":
            self.hold.wait(5)
            return subprocess.CompletedProcess(cmd, self.up_code, self.up_output, "no such device")
        return subprocess.CompletedProcess(cmd, 0, "", "")


def settle(hotspot, state, seconds=3.0):
    end = time.time() + seconds
    while hotspot.state != state and time.time() < end:
        time.sleep(0.01)
    assert hotspot.state == state, f"state {hotspot.state}, wanted {state}: {hotspot.reason}"


def test_starting_reaches_on_and_says_the_network():
    helper = FakeHelper()
    helper.hold.clear()
    hotspot = Hotspot(run=helper)
    hotspot.want(True)
    settle(hotspot, Hotspot.STARTING)   # the tracking loop must not wait for this
    helper.hold.set()
    settle(hotspot, Hotspot.ON)
    assert hotspot.ssid == "NOARK-c920" and hotspot.ip == "10.42.0.1"
    assert helper.calls == ["up"]


def test_failure_says_why_and_is_not_retried_in_a_loop():
    helper = FakeHelper(up_code=1)
    hotspot = Hotspot(run=helper)
    hotspot.want(True)
    settle(hotspot, Hotspot.FAILED)
    assert "no such device" in hotspot.reason
    time.sleep(0.05)
    assert helper.calls == ["up"], helper.calls


def test_a_missing_helper_is_a_failure_not_a_crash():
    def missing(cmd, **kwargs):
        raise FileNotFoundError("sudo")

    hotspot = Hotspot(run=missing)
    hotspot.want(True)
    settle(hotspot, Hotspot.FAILED)
    assert "sudo" in hotspot.reason


def test_a_helper_that_never_returns_is_a_failure():
    def stuck(cmd, **kwargs):
        raise subprocess.TimeoutExpired(cmd, kwargs.get("timeout"))

    hotspot = Hotspot(run=stuck)
    hotspot.want(True)
    settle(hotspot, Hotspot.FAILED)


def test_stopping_while_it_starts_ends_up_off():
    helper = FakeHelper()
    helper.hold.clear()
    hotspot = Hotspot(run=helper)
    hotspot.want(True)
    settle(hotspot, Hotspot.STARTING)
    hotspot.want(False)
    helper.hold.set()
    settle(hotspot, Hotspot.OFF)
    assert helper.calls == ["up", "down"], helper.calls


def test_asking_twice_starts_once():
    helper = FakeHelper()
    hotspot = Hotspot(run=helper)
    hotspot.want(True)
    settle(hotspot, Hotspot.ON)
    hotspot.want(True)
    time.sleep(0.05)
    assert helper.calls == ["up"], helper.calls


def test_trying_again_after_a_failure_needs_a_new_ask():
    helper = FakeHelper(up_code=1)
    hotspot = Hotspot(run=helper)
    hotspot.want(True)
    settle(hotspot, Hotspot.FAILED)
    hotspot.want(False)
    settle(hotspot, Hotspot.OFF)
    helper.up_code = 0
    hotspot.want(True)
    settle(hotspot, Hotspot.ON)


def test_cleaning_up_after_a_crash_takes_the_hotspot_down():
    # A tracker that died with the tab open left it running.
    helper = FakeHelper()
    hotspot = Hotspot(run=helper)
    hotspot.clean_up()
    settle(hotspot, Hotspot.OFF)
    end = time.time() + 2.0
    while helper.calls != ["down"] and time.time() < end:
        time.sleep(0.01)
    assert helper.calls == ["down"], helper.calls


def test_status_says_why_it_failed_in_few_bytes():
    helper = FakeHelper(up_code=1)
    helper.up_output = ""
    hotspot = Hotspot(run=helper)
    hotspot.want(True)
    settle(hotspot, Hotspot.FAILED)
    status = hotspot.status(8010)
    assert status["state"] == "failed" and "no such device" in status["reason"]
    assert len(status["reason"]) <= 60


def test_status_block():
    helper = FakeHelper()
    hotspot = Hotspot(run=helper)
    assert hotspot.status(8010) == {"state": "off"}
    hotspot.want(True)
    settle(hotspot, Hotspot.ON)
    assert hotspot.status(8010) == {"state": "on", "ssid": "NOARK-c920", "ip": "10.42.0.1", "port": 8010,
                                    "bssid": "36:22:7f:b9:c9:20"}


def test_the_bssid_is_the_access_points_not_the_normal_wifis():
    # Android joins without asking again only for a specific access point, so a
    # wrong address here means a prompt, or no connection, every time.
    hotspot = Hotspot(run=FakeHelper())
    hotspot.want(True)
    settle(hotspot, Hotspot.ON)
    assert hotspot.status(8010)["bssid"] == "36:22:7f:b9:c9:20"


def test_without_a_readable_bssid_it_still_says_the_network():
    helper = FakeHelper()
    helper.iw_output = "phy#0\n\tInterface wlan0\n\t\taddr 3c:22:7f:b9:c9:20\n\t\ttype managed\n"
    hotspot = Hotspot(run=helper)
    hotspot.want(True)
    settle(hotspot, Hotspot.ON)
    assert hotspot.status(8010) == {"state": "on", "ssid": "NOARK-c920", "ip": "10.42.0.1", "port": 8010}


def client_for(link):
    client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    client.settimeout(1.0)
    client.connect(("127.0.0.1", link.port))
    return client


def open_link():
    link = PictureLink("127.0.0.1", 0)
    link.open()
    return link


def wait_for_client(link, now=100.0):
    end = time.time() + 2.0
    while time.time() < end:
        link.poll(now)
        if link.has_client(now):
            return
        time.sleep(0.01)
    raise AssertionError("the hello never arrived")


def test_no_client_means_nothing_is_sent_and_nothing_breaks():
    link = open_link()
    assert not link.has_client(100.0)
    link.send(protocol.encode(protocol.PREVIEW, b"x" * 5000))
    link.close()


def test_a_hello_makes_a_client_and_a_small_message_arrives_whole():
    link = open_link()
    client = client_for(link)
    client.send(bytes([protocol.PICTURE_HELLO]))
    wait_for_client(link)
    message = protocol.encode(protocol.PREVIEW, b"jpeg")
    link.send(message)
    assert client.recv(2048) == message
    link.close()


def test_a_big_message_arrives_as_chunks_that_add_up():
    link = open_link()
    client = client_for(link)
    client.send(bytes([protocol.PICTURE_HELLO]))
    wait_for_client(link)
    picture = bytes(range(256)) * 40   # 10240 bytes: several datagrams
    message = protocol.encode(protocol.PREVIEW, picture)
    link.send(message)
    parts = {}
    total = None
    while total is None or len(parts) < total:
        data = client.recv(2048)
        assert data[0] == protocol.CHUNK, data[0]
        total = data[3]
        parts[data[2]] = data[4:]
    assert b"".join(parts[i] for i in range(total)) == message
    link.close()


def test_anything_else_on_the_port_is_not_a_client():
    link = open_link()
    client = client_for(link)
    client.send(b"hello")
    client.send(bytes([protocol.POSITION]))
    time.sleep(0.05)
    link.poll(100.0)
    assert not link.has_client(100.0)
    link.close()


def test_a_client_that_goes_quiet_stops_counting():
    link = open_link()
    client = client_for(link)
    client.send(bytes([protocol.PICTURE_HELLO]))
    wait_for_client(link, 100.0)
    assert link.has_client(100.0 + PictureLink.SILENCE_S - 0.1)
    assert not link.has_client(100.0 + PictureLink.SILENCE_S + 0.1)
    link.close()


def test_a_closed_link_does_not_raise():
    link = open_link()
    link.close()
    link.close()
    link.poll(100.0)
    link.send(b"x")
    assert not link.has_client(100.0)


def test_open_failing_is_a_reason_not_a_crash():
    link = PictureLink("203.0.113.1", 0)   # not an address of this machine
    assert not link.open()
    assert link.reason


def in_temp(text):
    folder = tempfile.mkdtemp()
    path = Path(folder) / "settings.json"
    if text is not None:
        path.write_text(text, encoding="utf-8")
    return path


def test_save_settings_keeps_everything_else():
    path = in_temp(json.dumps({"stream_type": "ble", "camera_gain": 1, "udp_port": 8000}))
    assert save_settings(path, {"camera_exposure_us": 5000, "camera_gain": 2.5})
    assert json.loads(path.read_text()) == {
        "stream_type": "ble", "camera_gain": 2.5, "udp_port": 8000, "camera_exposure_us": 5000}


def test_save_settings_will_not_replace_a_file_it_cannot_read():
    # The app's whole configuration is in there: a bad edit must not lose it.
    path = in_temp("{not json")
    assert not save_settings(path, {"camera_gain": 2.0})
    assert path.read_text() == "{not json"


def test_save_settings_leaves_no_temporary_file_behind():
    path = in_temp("{}")
    save_settings(path, {"camera_gain": 2.0})
    assert [p.name for p in path.parent.iterdir()] == ["settings.json"]


def test_save_settings_without_a_file_does_nothing():
    path = in_temp(None)
    assert not save_settings(path, {"camera_gain": 2.0})
    assert not path.exists()


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
            print(f"  ok  {name}")
    print("\nOK")
