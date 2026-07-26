#!/usr/bin/env python3

from pathlib import Path
import socket
import time


SERVER = ("127.0.0.1", 27070)
PROBE = ("127.0.0.1", 27071)
DEADLINE_SECONDS = 15


with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
    udp.bind(PROBE)
    udp.settimeout(DEADLINE_SECONDS)
    Path("udp_probe.ready").write_text("ready")

    deadline = time.monotonic() + DEADLINE_SECONDS
    while not Path("udp_request.bin").exists():
        if time.monotonic() >= deadline:
            raise TimeoutError("timed out waiting for UDP request")
        time.sleep(0.01)

    payload = Path("udp_request.bin").read_bytes()
    udp.sendto(payload, SERVER)
    udp.sendto(payload, SERVER)

    response, _ = udp.recvfrom(1200)
    Path("udp_outbound.bin").write_bytes(response)
