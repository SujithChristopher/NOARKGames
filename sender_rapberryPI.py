import socket
import json
import os
import signal
import sys
import time
from pathlib import Path


# =========================================================
# CONFIGURATION
# =========================================================

SERVER_IP = "172.17.227.246"
SERVER_PORT = 5000

DEVICE_ID = "MARS"

# Parent folder that holds one sub-folder per patient:
#   ROOT_DIR/<patient_id>/sessions.csv
#   ROOT_DIR/<patient_id>/configdata.csv
ROOT_DIR = Path("/home/pi/NeuroDash/patients")

# Kept OUTSIDE the root folder so it is never mistaken for a patient
PATIENTS_FILE = ROOT_DIR.parent / "patients.json"

# Identifies THIS Raspberry Pi for the training lock. DEVICE_ID is the kind of device (several Pis can all be "MARS"),
# so the lock needs this to tell two of them apart. Defaults to the Pi's hostname: give every Pi a different one,
# or set NEURODASH_CLIENT_ID.
CLIENT_ID = os.environ.get("NEURODASH_CLIENT_ID") or socket.gethostname()
LAPTOP_ID = CLIENT_ID  # older name

# Renew the training lock this often while "--login" is holding a patient. The server frees a patient after
# ACTIVE_WINDOW_SECONDS (default 900) without a sign of life, so this only has to be well below that.
LOCK_RENEW_SECONDS = 30

# How long one lock request (claim / check / release) waits for the server before giving up
LOCK_TIMEOUT_SECONDS = 3

NUDGE_PORT = 5001   # must match patients_store.NUDGE_PORT

CSV_NAMES = ["sessions.csv", "configdata.csv"]

BUFFER_SIZE = 64 * 1024


# =========================================================
# PATIENT FOLDERS
# =========================================================

def find_file(patient_folder, name):
    """patient_folder/name, or the first match anywhere inside it."""

    direct = patient_folder / name

    if direct.exists():
        return direct

    return next(patient_folder.rglob(name), direct)


def patient_csv_files(patient_id):
    folder = ROOT_DIR / patient_id
    return [find_file(folder, name) for name in CSV_NAMES]


def current_patient_id():
    """The patient folder whose CSVs changed most recently, i.e. the
    patient playing right now. Used only if no id was given."""

    best_id, best_time = None, 0

    for folder in ROOT_DIR.iterdir():

        if not folder.is_dir():
            continue

        for path in patient_csv_files(folder.name):
            if path.exists() and path.stat().st_mtime > best_time:
                best_id, best_time = folder.name, path.stat().st_mtime

    return best_id


# =========================================================
# SEND FILE
# =========================================================

def send_file(CSV_FILE):

    print()
    print("=" * 50)
    print("       NeuroDash CSV Sender")
    print("=" * 50)

    # -----------------------------------------------------
    # Check file
    # -----------------------------------------------------

    if not CSV_FILE.exists():

        print()
        print("ERROR:")
        print(f"File not found:")
        print(CSV_FILE)

        return

    file_size = CSV_FILE.stat().st_size

    print()
    print(f"Device      : {DEVICE_ID}")
    print(f"Server      : {SERVER_IP}:{SERVER_PORT}")
    print(f"File        : {CSV_FILE}")
    print(f"Size        : {file_size:,} bytes")

    # -----------------------------------------------------
    # Prepare header
    # -----------------------------------------------------

    header = {
        "device_id": DEVICE_ID,
        "client_id": CLIENT_ID,
        "filename": CSV_FILE.name,
        "file_size": file_size
    }

    header_data = json.dumps(
        header
    ).encode("utf-8")

    header_length = len(
        header_data
    ).to_bytes(
        4,
        byteorder="big"
    )

    # -----------------------------------------------------
    # Connect
    # -----------------------------------------------------

    client = socket.socket(
        socket.AF_INET,
        socket.SOCK_STREAM
    )

    client.settimeout(30)

    try:

        print()
        print("Connecting to server...")

        client.connect(
            (SERVER_IP, SERVER_PORT)
        )

        print("Connected!")
        print("Sending file...")

        # Send header size
        client.sendall(
            header_length
        )

        # Send header
        client.sendall(
            header_data
        )

        # -------------------------------------------------
        # Send CSV
        # -------------------------------------------------

        sent = 0

        with open(CSV_FILE, "rb") as file:

            while True:

                data = file.read(
                    BUFFER_SIZE
                )

                if not data:
                    break

                client.sendall(data)

                sent += len(data)

                percentage = (
                    sent / file_size
                ) * 100 if file_size else 100

                print(
                    f"\rProgress: {percentage:.1f}%",
                    end=""
                )

        print()
        print("Upload complete.")

        # -------------------------------------------------
        # Wait for server confirmation
        # -------------------------------------------------

        response_data = client.recv(4096)

        response = json.loads(
            response_data.decode("utf-8")
        )

        print()

        if response.get("success"):

            print("SUCCESS!")
            print(
                "Server received the CSV successfully."
            )

        else:

            print("SERVER ERROR:")
            print(
                response.get(
                    "message",
                    "Unknown error"
                )
            )

    except ConnectionRefusedError:

        print()
        print("ERROR:")
        print("Server refused the connection.")
        print(
            "Check that s2.py is running."
        )

    except socket.timeout:

        print()
        print("ERROR:")
        print("Connection timed out.")

    except Exception as error:

        print()
        print("ERROR:")
        print(error)

    finally:

        client.close()


# =========================================================
# SERVER REQUESTS
# =========================================================

def receive_exact(connection, size):

    data = bytearray()

    while len(data) < size:

        packet = connection.recv(size - len(data))

        if not packet:
            raise ConnectionError("Server closed the connection.")

        data.extend(packet)

    return bytes(data)


def server_request(header, timeout=30):
    """Send one length-prefixed JSON request, return the JSON reply."""

    header_data = json.dumps(header).encode("utf-8")

    with socket.create_connection(
        (SERVER_IP, SERVER_PORT), timeout=timeout
    ) as client:

        client.sendall(len(header_data).to_bytes(4, "big"))
        client.sendall(header_data)

        length = int.from_bytes(receive_exact(client, 4), "big")

        return json.loads(receive_exact(client, length).decode("utf-8"))


# =========================================================
# PATIENT LIST SYNC
# =========================================================

def local_patients_version():

    try:
        with open(PATIENTS_FILE, "r", encoding="utf-8") as f:
            return int(json.load(f).get("version", 0))
    except (FileNotFoundError, ValueError):
        return 0


def local_view():
    """The 'view' token the server gave with the list this Pi holds (which patients it was shown)."""

    try:
        with open(PATIENTS_FILE, "r", encoding="utf-8") as f:
            return str(json.load(f).get("view", ""))
    except (FileNotFoundError, ValueError):
        return ""


def sync_patients():
    """Fetch patients.json changes. Also tells the server this Pi is
    online (heartbeat). The server leaves out patients another device is
    training right now."""

    version = local_patients_version()

    try:
        response = server_request({
            "action": "sync",
            "device_id": DEVICE_ID,
            "client_id": CLIENT_ID,
            "patients_version": version,
            "view": local_view()
        })

    except Exception as error:
        print(f"Sync failed: {error}")
        return

    if not response.get("success"):
        print(f"Sync error: {response.get('message')}")
        return

    if response["up_to_date"]:
        print(f"Patients up to date (v{response['version']})")
        return

    PATIENTS_FILE.parent.mkdir(parents=True, exist_ok=True)

    temp = PATIENTS_FILE.with_suffix(".tmp")

    with open(temp, "w", encoding="utf-8") as f:
        json.dump({
            "version": response["version"],
            "updated_at": response["updated_at"],
            "view": response.get("view"),
            "patients": response["patients"]
        }, f, indent=2)

    os.replace(temp, PATIENTS_FILE)

    print(
        f"Patients updated: v{version} -> v{response['version']} "
        f"({len(response['patients'])} for {DEVICE_ID})"
    )


# =========================================================
# NUDGES (the server pushes "something changed")
# =========================================================

def listen_for_nudge():
    """Refresh the patient list the moment the server says a patient started or stopped training elsewhere."""

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", NUDGE_PORT))

    print(f"Listening for server nudges on UDP {NUDGE_PORT}")

    while True:

        try:
            data, address = sock.recvfrom(1024)
            message = json.loads(data.decode("utf-8"))
        except (OSError, ValueError):
            continue

        if (
            message.get("type") == "patients_changed"
            and int(message.get("version", 0)) > local_patients_version()
        ) or message.get("type") == "presence_changed":
            print(f"Nudge from {address[0]}")
            sync_patients()


# =========================================================
# FOR agent.py (so the same agent runs on a Raspberry Pi)
# =========================================================

def sessions_file_for(patient_id):
    """The sessions.csv of this patient (None when no patient is held): agent.py watches it to notice a trial ending."""

    return find_file(ROOT_DIR / patient_id, "sessions.csv") if patient_id else None


def _load_csv_files():
    """Files of the patient playing right now (most recently changed folder)."""

    try:
        patient = current_patient_id()
    except OSError:
        return []

    return patient_csv_files(patient) if patient else []


# =========================================================
# TRAINING LOCK (one device per patient at a time)
# =========================================================

class PatientInUse(Exception):
    """Another device already holds this patient. `.holder` is {"device", "client", "seconds_ago"}."""

    def __init__(self, user_id, holder):
        self.user_id = user_id
        self.holder = holder or {}
        super().__init__(
            f"{user_id} is being trained on {self.holder.get('device', 'another device')}"
            f"{' (laptop ' + self.holder['client'] + ')' if self.holder.get('client') else ''} "
            f"({self.holder.get('seconds_ago', '?')} s since its last activity)."
        )


def _ask_server(action, user_id):
    """One lock request. Returns the reply dict, or None if the server cannot be reached."""

    try:
        return server_request({
            "action": action,
            "device_id": DEVICE_ID,
            "client_id": CLIENT_ID,
            "user_id": user_id
        }, timeout=LOCK_TIMEOUT_SECONDS)

    except Exception as error:
        print(f"Could not reach the server: {error}")
        return None


def claim_patient(patient_id):
    """Returns (ok, message). Also renews a lock this Pi holds."""

    reply = _ask_server("claim_user", patient_id)

    if reply is None:
        return False, "Cannot reach server"

    if not reply.get("success"):
        return False, reply.get("message", "The server refused the request")

    if reply.get("claimed"):
        return True, ""

    return False, str(PatientInUse(patient_id, reply.get("in_use_by")))


def release_patient(patient_id):

    if _ask_server("release", patient_id) is None:
        print("Release failed (the lock will expire by itself)")


def hold_session(patient_id):
    """Keep the lock alive until this process is stopped (Ctrl+C or
    SIGTERM), then release it."""

    def stop(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)

    print(f"Holding {patient_id} on {DEVICE_ID} (stop this process "
          f"when the session ends)")

    try:

        while True:

            time.sleep(LOCK_RENEW_SECONDS)

            ok, message = claim_patient(patient_id)

            if ok:
                continue

            if message.startswith("Cannot reach server"):
                # Brief network drop: keep trying, the lock simply
                # expires if it lasts too long.
                print(message)
                continue

            print(f"Lost the lock: {message}")
            return

    except KeyboardInterrupt:
        pass

    finally:
        release_patient(patient_id)
        print("Released.")


# =========================================================
# MAIN
#
#   sender_raspberryPI.py --login  [patient_id]   claim the patient and keep the lock alive until stopped
#   sender_raspberryPI.py --upload [patient_id]   upload the patient's CSVs, then sync the patient list
#   sender_raspberryPI.py --check  patient_id     only asks: is this patient being trained on another device?
#
# Exit codes for --login:  0 granted, 2 patient already training
# elsewhere, 3 server unreachable, 4 no patient found.
# Exit codes for --check:  0 free, 2 in use on another device.
#
# Better: run agent.py all day (it uses this file when there is no sender.py next to it). It holds the lock for you
# through a local web call and checks in only when a patient starts or stops and when a trial ends.
# =========================================================

if __name__ == "__main__":

    mode = sys.argv[1] if len(sys.argv) > 1 else "--upload"

    patient_id = sys.argv[2] if len(sys.argv) > 2 else current_patient_id()

    if mode not in ("--login", "--upload", "--check"):
        print(f"Unknown mode: {mode}")
        print("Usage: sender_raspberryPI.py [--login | --upload | --check] [patient_id]")
        sys.exit(1)

    if not patient_id:
        print(f"No patient folder found in {ROOT_DIR}")
        sys.exit(4)

    if mode == "--check":

        reply = _ask_server("check_user", patient_id)

        if reply and reply.get("success") and reply.get("in_use"):
            print(f"{patient_id} is IN USE: {PatientInUse(patient_id, reply.get('in_use_by'))}")
            sys.exit(2)

        print(f"{patient_id} is free.")

    elif mode == "--login":

        # Called when a patient logs in: pull patient list, then take
        # the training lock. Stays running to keep the lock alive, so
        # start it in the background and stop it when the session ends.
        print(f"[Login] Patient {patient_id} on device: {DEVICE_ID}")

        sync_patients()

        ok, message = claim_patient(patient_id)

        if not ok:
            print(message)
            sys.exit(3 if message.startswith("Cannot reach") else 2)

        print("Lock granted.")

        hold_session(patient_id)

    else:

        # Called after a session ends: upload this patient's CSVs,
        # then sync the patient list.
        print(f"[Upload] Patient {patient_id} on device: {DEVICE_ID}")

        for csv_file in patient_csv_files(patient_id):
            send_file(csv_file)

        sync_patients()
