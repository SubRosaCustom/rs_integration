#!/usr/bin/env python3

import json
from pathlib import Path
import socket
import time


SERVER = ("127.0.0.1", 27070)
DEADLINE_SECONDS = 15
PING = b'{"type":"SRC_PING","payload":{"protocol":6}}\n'


deadline = time.monotonic() + DEADLINE_SECONDS
while True:
    try:
        tcp = socket.create_connection(SERVER, timeout=1)
        break
    except OSError:
        if time.monotonic() >= deadline:
            raise
        time.sleep(0.01)

with tcp:
    tcp.settimeout(DEADLINE_SECONDS)
    split = len(PING) // 2
    tcp.sendall(PING[:split])
    time.sleep(0.05)
    tcp.sendall(PING[split:])
    tcp.sendall(PING + PING)

    responses = []
    buffered = b""
    while len(responses) < 3:
        buffered += tcp.recv(4096)
        while b"\n" in buffered:
            line, buffered = buffered.split(b"\n", 1)
            if line:
                responses.append(json.loads(line))

Path("tcp_framing.json").write_text(json.dumps(responses))
