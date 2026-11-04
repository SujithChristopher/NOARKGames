"""The board's own Wi-Fi hotspot, for the Camera tab's pictures when the app is on BLE.

BLE stays the link to the app: it is what finds the board and carries the hand
position, and it cannot carry pictures. While the tab is open the board brings
up a WPA2 hotspot, the tablet joins it, and pictures go over that (picture_link.py).
It is the way Quick Share works: a slow link to find each other, Wi-Fi to move data.

Starting one takes seconds and needs root, so it runs on a thread through
setup/noark-hotspot, which setup/setup_board.sh installs with its sudoers line.
A board without it carries on without pictures: tracking never depends on this.
"""

import subprocess
import threading

HELPER = ["sudo", "-n", "/usr/local/sbin/noark-hotspot"]
UP_TIMEOUT_S = 60    # the helper waits on NetworkManager, which allows 40 s
DOWN_TIMEOUT_S = 30
REASON_MAX = 60      # goes in CAMERA_STATUS, next to the hand position over BLE


class Hotspot:
    OFF = "off"
    STARTING = "starting"
    ON = "on"
    STOPPING = "stopping"
    FAILED = "failed"

    def __init__(self, run=subprocess.run, command=None) -> None:
        self._run = run
        self._command = command or HELPER
        self._lock = threading.Lock()
        self._wanted = False
        self._applied = False    # the helper last ran for this; a failed start counts
        self._worker = None
        self.state = self.OFF
        self.reason = ""
        self.ssid = ""
        self.ip = ""
        self.bssid = ""

    def want(self, on: bool) -> None:
        """Ask for the hotspot on or off. Returns at once; `state` follows.
        A failed start is not retried until it is asked for again after an off."""
        with self._lock:
            self._wanted = on
            self._start_worker()

    def clean_up(self) -> None:
        """At start: a tracker that died with the tab open left one running."""
        with self._lock:
            self._applied = True
            self._wanted = False
            self._start_worker()

    def wait(self, timeout: float) -> None:
        worker = self._worker
        if worker is not None:
            worker.join(timeout)

    def status(self, port: int) -> dict:
        """The `wifi` field of CAMERA_STATUS."""
        if self.state == self.ON:
            status = {"state": self.ON, "ssid": self.ssid, "ip": self.ip, "port": port}
            if self.bssid:
                status["bssid"] = self.bssid
            return status
        if self.state == self.FAILED:
            return {"state": self.FAILED, "reason": self.reason[:REASON_MAX]}
        return {"state": self.state}

    def _start_worker(self) -> None:
        if self._worker is None or not self._worker.is_alive():
            self._worker = threading.Thread(target=self._converge, name="hotspot", daemon=True)
            self._worker.start()

    def _converge(self) -> None:
        while True:
            with self._lock:
                wanted = self._wanted
                if wanted == self._applied:
                    return
                self._applied = wanted
                self.state = self.STARTING if wanted else self.STOPPING
            if wanted:
                self._up()
            else:
                self._down()

    def _call(self, action: str, timeout: float):
        """-> (ok, output or why not)."""
        try:
            done = self._run([*self._command, action], capture_output=True, text=True, timeout=timeout)
        except (OSError, subprocess.SubprocessError) as exc:
            return False, str(exc)
        if done.returncode != 0:
            lines = (done.stderr or done.stdout or "").strip().splitlines()
            return False, lines[-1] if lines else f"exit {done.returncode}"
        return True, done.stdout or ""

    def _up(self) -> None:
        ok, output = self._call("up", UP_TIMEOUT_S)
        if ok:
            fields = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
            self.ssid = fields.get("ssid", "")
            self.ip = fields.get("ip", "")
            ok = bool(self.ssid and self.ip)
            output = output if ok else "the helper did not say which network"
        if ok:
            self.bssid = self._access_point_address()
            self.reason = ""
            self.state = self.ON
            print(f"[WIFI] Hotspot up: {self.ssid} at {self.ip}", flush=True)
        else:
            self.reason = output
            self.state = self.FAILED
            print(f"[WIFI] Hotspot did not start: {output}", flush=True)

    def _access_point_address(self) -> str:
        """The hotspot's hardware address, which needs no root. Android joins without
        asking again only when asked for one exact access point, name and address."""
        try:
            listing = self._run(["iw", "dev"], capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            return ""
        for block in listing.split("Interface ")[1:]:
            fields = [line.split() for line in block.splitlines()]
            if ["type", "AP"] in fields:
                return next((f[1] for f in fields if len(f) == 2 and f[0] == "addr"), "")
        return ""

    def _down(self) -> None:
        ok, output = self._call("down", DOWN_TIMEOUT_S)
        if not ok:
            print(f"[WIFI] Hotspot did not stop cleanly: {output}", flush=True)
        self.state = self.OFF
