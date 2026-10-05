"""NeuroDash laptop agent: one small program that runs all day on each training laptop.

It keeps the laptop in touch with the server so the server knows which patient is playing here. It does NOT poll on a
timer: it talks to the server only when something happens.

  * a patient starts       the training software calls /start: the agent claims the patient on the server (the patient lock)
  * a trial ends           the agent renews the claim and refreshes the patient list, once. It notices a trial ending because
                           sessions.csv changes (a local file check, no network), or the software can say so with /trial-ended
  * a patient stops        /stop: the agent releases the patient
  * another laptop starts  the server pushes a nudge and the agent refreshes the patient list

It does NOT upload sessions.csv or configdata.csv: sender.py keeps doing that, as before. (Those uploads also refresh the
server's record of who is playing.)

Run it (Windows: start it at logon, see README):

    python agent.py

The training software talks to it on this computer only (127.0.0.1, port 5055 or NEURODASH_AGENT_PORT):

    GET|POST /start?patient=118   -> 200 {"ok": true}   or   409 {"ok": false, "in_use_by": {...}, "message": "..."}
    GET|POST /stop                -> 200 {"ok": true}
    GET|POST /trial-ended         -> 200 {"ok": true, "lost": null}     (optional: the file check does this on its own)
    GET      /check?patient=118   -> {"in_use": false, "in_use_by": null}        (asks only, locks nothing)
    GET      /status              -> what the agent is doing (patient held, lock lost, last trial / sync)

/start is refused (409) while another laptop is training that patient: do not start the session. After each trial,
/status (or the reply of /trial-ended) says "lost": true when another laptop took the patient (only possible after this
laptop was offline longer than the server's window), so stop the session. If the server cannot be reached /start still
says ok (a network fault never stops therapy) and "server_reachable" is false.

The server frees a patient ACTIVE_WINDOW_SECONDS after the last sign of life (a trial end, an upload, /start). Keep that
longer than your longest trial.
"""

import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import importlib


def load_sender(name=None):
    """The module with this device's settings and server calls (DEVICE_ID, CLIENT_ID, PatientInUse, _ask_server,
    sync_patients, listen_for_nudge, and sessions_file_for(patient) or _load_csv_files()).

    Chosen automatically: a Windows laptop has sender.py next to the agent; a Raspberry Pi has only sender_rapberryPI.py,
    which is used when there is no sender.py. To force one, run `python agent.py --sender sender_rapberryPI` or set
    NEURODASH_SENDER."""

    name = name or os.environ.get("NEURODASH_SENDER")

    if not name and "--sender" in sys.argv[:-1]:
        name = sys.argv[sys.argv.index("--sender") + 1]

    if name:
        return importlib.import_module(name)

    try:
        return importlib.import_module("sender")
    except ModuleNotFoundError as error:
        if error.name != "sender":  # sender.py exists but one of ITS imports is missing: say so
            raise

        return importlib.import_module("sender_rapberryPI")


sender = load_sender()

HTTP_HOST = "127.0.0.1"  # this computer only: the agent is never reachable from the network
HTTP_PORT = int(os.environ.get("NEURODASH_AGENT_PORT", "5055"))

WATCH_POLL_SECONDS = 2   # how often the local sessions.csv is looked at: a file check on this computer, no network
DEBOUNCE_SECONDS = 1     # a trial end seen twice (file and software call) within this long counts once

PATIENT_ID = re.compile(r"^[A-Za-z0-9_-]{1,40}$")


_UNSET = object()


class Agent:
    """All the agent's state and behaviour. The pieces that talk to the outside (server requests, the patient-list sync,
    which file to watch) are passed in, so everything can be tested without a network."""

    def __init__(self, ask=None, sync=None, sessions_file=None, keepalive=None, run=None, debounce=DEBOUNCE_SECONDS):
        # looked up at call time, so tests (and sender.py edits) are picked up
        self.ask = ask or (lambda action, user_id: sender._ask_server(action, user_id))
        self.sync = sync or (lambda: sender.sync_patients())
        self.sessions_file = sessions_file or self._default_sessions_file
        self.keepalive = keepalive   # optional safety net: also check in every N seconds. None = only when something happens
        self.debounce = debounce
        # how slow work (a patient-list sync can take seconds) is run: in the background, so /start never waits for it
        self._run = run or (lambda fn: threading.Thread(target=fn, daemon=True).start())

        self._lock = threading.RLock()
        self.patient = None        # the patient this laptop currently holds
        self.lost = None           # who took the patient, if the hold was lost
        self.server_reachable = True
        self.last_sync = None
        self.last_trial = None
        self._last_trial_at = 0.0
        self._file_path = None     # which file that is
        self._file_seen = _UNSET   # (mtime, size) of sessions.csv at the last look (None = the file did not exist)
        self.stopping = threading.Event()

    def _default_sessions_file(self):
        """The sessions.csv to watch for a trial ending. A Raspberry Pi keeps one folder per patient, so it is the held
        patient's file; a Windows laptop has just one."""

        per_patient = getattr(sender, "sessions_file_for", None)

        if per_patient:
            return per_patient(self.patient)  # None while no patient is held

        return next(iter(sender._load_csv_files()), None)

    # ------------------------------------------------------------ the patient lock

    def start_session(self, patient):
        """Claim `patient` for this laptop. Returns (True, None), or (False, holder) when another laptop has them."""

        with self._lock:
            if self.patient and self.patient != patient:
                self._release_locked()  # moving on to another patient: let go of the previous one

            reply = self.ask("claim_user", patient)
            self.server_reachable = bool(reply and reply.get("success"))

            if self.server_reachable and not reply.get("claimed"):
                return False, reply.get("in_use_by") or {}

            self.patient = patient
            self.lost = None

        self._run(self.sync_once)  # the list now has to hide this patient from the other laptops: refreshed by the nudge
        return True, None

    def stop_session(self):
        """Release the held patient. Returns the patient that was released, or None if none was held."""

        with self._lock:
            patient = self._release_locked()

        if patient:
            self._run(self.sync_once)

        return patient

    def check(self, patient):
        reply = self.ask("check_user", patient)

        if not reply or not reply.get("success"):
            return False, None

        return bool(reply.get("in_use")), reply.get("in_use_by")

    def _release_locked(self):
        patient = self.patient

        if patient:
            self.ask("release", patient)

        self.patient = None
        self.lost = None
        return patient

    # ------------------------------------------------------------ a trial ended

    def trial_ended(self, now=None, force=False):
        """A trial just ended: renew the claim (and find out if another laptop took the patient), and refresh the patient
        list. Once per trial, never on a timer. Returns the status."""

        now = time.time() if now is None else now

        with self._lock:
            if not force and now - self._last_trial_at < self.debounce:
                return self.status()  # the file and the software both reported the same trial

            self._last_trial_at = now
            self.last_trial = time.strftime("%Y-%m-%dT%H:%M:%S")
            patient = self.patient

            if patient:
                reply = self.ask("claim_user", patient)
                self.server_reachable = bool(reply and reply.get("success"))

                if self.server_reachable and not reply.get("claimed"):
                    self.lost = reply.get("in_use_by") or {}

        self._run(self.sync_once)
        return self.status()

    def sync_once(self):
        try:
            self.sync()
            self.last_sync = time.strftime("%Y-%m-%dT%H:%M:%S")
        except Exception as error:  # never let one bad round take the agent down
            print(f"Sync failed: {error}")

    def check_sessions_file(self):
        """Cheap local check: has sessions.csv changed since the last look? A change means a trial ended. The very first look
        only records the file's state (even a missing file), so a file that appears later counts as a change. Returns True when a trial end was reported."""

        path = self.sessions_file()

        if path != self._file_path:  # another patient's file: just record where we are now
            self._file_path, self._file_seen = path, _UNSET

        try:
            stat = path.stat() if path else None
        except OSError:
            stat = None

        signature = (stat.st_mtime, stat.st_size) if stat else None
        previous, self._file_seen = self._file_seen, signature

        if previous is _UNSET or signature is None or signature == previous:
            return False

        self.trial_ended()
        return True

    # ------------------------------------------------------------ status

    def status(self):
        with self._lock:
            return {
                "client": sender.CLIENT_ID,
                "device": sender.DEVICE_ID,
                "patient": self.patient,
                "lost": self.lost,
                "server_reachable": self.server_reachable,
                "last_trial": self.last_trial,
                "last_sync": self.last_sync,
            }

    # ------------------------------------------------------------ background work

    def run_watch_loop(self):
        """One patient-list sync at start, then only react: look at the local file every WATCH_POLL_SECONDS (no network)."""

        self.sync_once()
        self.check_sessions_file()  # records the file's state

        while not self.stopping.wait(WATCH_POLL_SECONDS):
            try:
                self.check_sessions_file()
            except Exception as error:
                print(f"File check failed: {error}")

    def run_keepalive_loop(self):
        """Optional (NEURODASH_KEEPALIVE_SECONDS): also check in on a timer, e.g. so the dashboard shows an idle laptop online."""

        while not self.stopping.wait(self.keepalive):
            self.trial_ended(force=True)

    def shutdown(self):
        self.stopping.set()
        self.stop_session()


# ---------------------------------------------------------------- the local HTTP interface

def make_handler(agent):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):  # keep the console quiet
            pass

        def _reply(self, code, body):
            payload = json.dumps(body).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(payload)

        def _patient(self, query):
            patient = (query.get("patient") or [""])[0].strip()

            if not PATIENT_ID.match(patient):
                self._reply(400, {"ok": False, "message": "patient must be 1-40 letters, digits, - or _"})
                return None

            return patient

        def _route(self):
            url = urlparse(self.path)
            query = parse_qs(url.query)

            if self.command == "POST":  # a form or JSON body works as well as the query string
                length = int(self.headers.get("Content-Length") or 0)
                raw = self.rfile.read(length).decode("utf-8") if length else ""

                try:
                    body = json.loads(raw) if raw.strip().startswith("{") else {k: v for k, v in parse_qs(raw).items()}
                    for k, v in body.items():
                        query.setdefault(k, v if isinstance(v, list) else [str(v)])
                except ValueError:
                    pass

            if url.path == "/status":
                return self._reply(200, agent.status())

            if url.path in ("/trial-ended", "/ping"):
                return self._reply(200, {"ok": True, **agent.trial_ended()})

            if url.path == "/stop":
                released = agent.stop_session()
                return self._reply(200, {"ok": True, "released": released})

            if url.path == "/start":
                patient = self._patient(query)

                if patient is None:
                    return

                ok, holder = agent.start_session(patient)

                if ok:
                    return self._reply(200, {"ok": True, "patient": patient, "server_reachable": agent.server_reachable})

                return self._reply(409, {
                    "ok": False,
                    "in_use_by": holder,
                    "message": str(sender.PatientInUse(patient, holder)),
                })

            if url.path == "/check":
                patient = self._patient(query)

                if patient is None:
                    return

                busy, holder = agent.check(patient)
                return self._reply(200, {"in_use": busy, "in_use_by": holder})

            self._reply(404, {"ok": False, "message": "unknown path"})

        do_GET = _route
        do_POST = _route

    return Handler


def make_http_server(agent, port=HTTP_PORT):
    return ThreadingHTTPServer((HTTP_HOST, port), make_handler(agent))


# ---------------------------------------------------------------- main

def main():
    keepalive = int(os.environ.get("NEURODASH_KEEPALIVE_SECONDS", "0")) or None
    agent = Agent(keepalive=keepalive)
    server = make_http_server(agent)

    targets = [agent.run_watch_loop, sender.listen_for_nudge]
    if keepalive:
        targets.append(agent.run_keepalive_loop)

    for target in targets:
        threading.Thread(target=target, daemon=True).start()

    print("=" * 50)
    print("       NeuroDash laptop agent")
    print("=" * 50)
    print(f"Laptop      : {sender.CLIENT_ID} ({sender.DEVICE_ID})")
    print(f"Server      : {sender.SERVER_IP}:{sender.SERVER_PORT}")
    print(f"Local API   : http://{HTTP_HOST}:{HTTP_PORT}  (/start /stop /trial-ended /check /status)")
    print("Checks in with the server only when a patient starts or stops and when a trial ends.")
    print("Press Ctrl+C to stop.")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        agent.shutdown()
        server.server_close()
        print("Agent stopped.")


if __name__ == "__main__":
    main()
