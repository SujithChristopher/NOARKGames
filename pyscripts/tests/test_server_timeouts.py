"""server_request gives up on a dead server quickly, and not on a slow one.

No real server: a local socket stands in for a slow one, and a reserved address
that nobody owns (TEST-NET-1) for a dead one.

    python pyscripts/tests/test_server_timeouts.py
"""
import json
import socket
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import sender_raspberryPI as sender  # noqa: E402

CONNECT_S = 0.3
REPLY_DELAY_S = 1.0   # longer than the connect limit: it must not apply to the reply


def answer_slowly(listener):
    client, _ = listener.accept()
    with client:
        length = int.from_bytes(sender.receive_exact(client, 4), "big")
        sender.receive_exact(client, length)
        time.sleep(REPLY_DELAY_S)
        reply = json.dumps({"success": True}).encode("utf-8")
        client.sendall(len(reply).to_bytes(4, "big") + reply)


def main():
    sender.CONNECT_TIMEOUT_SECONDS = CONNECT_S

    with socket.create_server(("127.0.0.1", 0)) as listener:
        threading.Thread(target=answer_slowly, args=(listener,), daemon=True).start()
        sender.SERVER_IP, sender.SERVER_PORT = listener.getsockname()
        reply = sender.server_request({"action": "test"})
        assert reply == {"success": True}, reply
    print(f"ok: a reply after {REPLY_DELAY_S} s is still accepted")

    sender.SERVER_IP = "192.0.2.1"
    started = time.monotonic()
    try:
        sender.server_request({"action": "test"})
    except OSError:
        pass
    else:
        raise AssertionError("nothing should answer at a reserved address")
    took = time.monotonic() - started
    assert took < CONNECT_S * 3, f"took {took:.1f} s to give up"
    print(f"ok: a dead server is given up on in {took:.1f} s")


if __name__ == "__main__":
    main()
