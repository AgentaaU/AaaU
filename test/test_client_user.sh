#!/bin/sh
# Exercise the client `--user` option without a running server.
set -eu
client="$1"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

"$client" --help=plain >"$work/help"
grep -F -- '--user=USER' "$work/help"
# The default account is selected by the server.
grep -F -- 'defaults to the server account' "$work/help"

# A named account is accepted and the connection failure is reported cleanly
# (no argument-parsing error).
if "$client" -s "$work/missing.sock" --user researcher >"$work/out" 2>&1; then
  echo "Unexpected success connecting to a missing socket" >&2
  exit 1
fi
grep -F -- 'Cannot connect to AaaU server' "$work/out"
echo 'PASS: client --user option'

# Plain aaau must use the legacy default-session request: older servers reject
# NEW_JSON payloads that omit program/args (issue #31).
python3 - "$client" "$work" <<'PYTEST'
import json
import os
import socket
import subprocess
import sys
import threading

client, work = sys.argv[1:]
for options, expected in [([], "legacy"), (["--user", "researcher"], "user"),
                          (["--user", "agent"], "agent"),
                          (["-p", "/bin/echo hello"], "program")]:
    path = os.path.join(work, "server.sock")
    with socket.socket(socket.AF_UNIX) as server:
        server.bind(path)
        server.listen(1)
        server.settimeout(5)
        requests = []
        errors = []

        def serve():
            try:
                with server.accept()[0] as peer:
                    peer.settimeout(5)
                    data = b""
                    while not data.endswith(b"\n"):
                        chunk = peer.recv(4096)
                        if not chunk:
                            raise AssertionError("client closed before handshake")
                        data += chunk
                    requests.append(data.decode().rstrip("\n"))
                    peer.sendall(b"test complete\n")
            except Exception as error:
                errors.append(error)

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        subprocess.run([client, "-s", path] + options, capture_output=True,
                       timeout=5, check=True)
        thread.join(timeout=5)
        assert not thread.is_alive(), "server did not receive handshake"
        assert not errors, errors
        request, = requests
        if expected == "legacy":
            prefix, rows, cols = request.split(":")
            assert prefix == "NEW", request
            assert int(rows) > 0 and int(cols) > 0, request
        else:
            assert request.startswith("NEW_JSON:"), request
            payload = json.loads(request[len("NEW_JSON:"):])
            if expected in ("user", "agent"):
                assert payload["user"] == ("researcher" if expected == "user" else "agent"), payload
                assert "program" not in payload, payload
            else:
                assert payload["program"] == "/bin/echo", payload
                assert payload["args"] == ["hello"], payload
    os.unlink(path)
print("PASS: default and explicit client session handshakes")
PYTEST
