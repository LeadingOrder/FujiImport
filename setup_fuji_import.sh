#!/usr/bin/env bash
# Fuji Import repository bootstrap — Mac-local protocol experiment (FI-01).
# Run from the root of FujiImport, where docs/ already exists.
# Intentionally does not modify networking, DNS, TLS trust, Pi, or Nextcloud.
set -euo pipefail

if [[ ! -f docs/fuji-import-spec.md || ! -f docs/fuji-import-implementation-tickets.md ]]; then
    echo "Error: run this from FujiImport/, containing docs/fuji-import-spec.md and docs/fuji-import-implementation-tickets.md" >&2
    exit 1
fi

mkdir -p poc/mac/output poc/mac/certs poc/mac/logs scripts

# Each file is created only once. Re-running this script will not overwrite edits.
write_new() {
    local path="$1"
    if [[ -e "$path" ]]; then
        echo "Preserved: $path"
        cat >/dev/null
    else
        cat > "$path"
        echo "Created:   $path"
    fi
}

write_new .gitignore <<'EOF'
.DS_Store
.idea/
.vscode/
.venv/
__pycache__/
*.py[cod]
.pytest_cache/
.env
.env.*
!.env.example
# Mac protocol experiment: photographs, captures, logs, CA & TLS private material
poc/mac/output/
poc/mac/certs/
poc/mac/logs/
poc/mac/captures/
EOF

write_new .editorconfig <<'EOF'
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
indent_style = space
indent_size = 4
trim_trailing_whitespace = true

[*.md]
trim_trailing_whitespace = false
EOF

write_new README.md <<'EOF'
# Fuji Import

Private-first, self-hosted wireless Fujifilm photo importer.

**Current milestone: Mac-only protocol proof of concept (FI-01 → FI-04).**
Do not inspect or modify the Raspberry Pi / Nextcloud installation until FI-04 passes.

- [Specification](docs/fuji-import-spec.md)
- [Implementation tickets](docs/fuji-import-implementation-tickets.md)
- [Mac experiment notes](docs/mac-poc.md)

## Start FI-01

Requires Python 3 (standard library only). Run from the repository root:

```sh
python3 poc/mac/receiver.py --bind 127.0.0.1 --port 8765
```

In another terminal:

```sh
curl -fsS http://127.0.0.1:8765/health
printf 'test payload' | curl -fsS -X POST --data-binary @- http://127.0.0.1:8765/_debug/upload
```

To permit LAN requests **during an isolated test**, bind to `0.0.0.0` and use
`http://<mac-lan-ip>:8765/health` from another device. This is a diagnostic
HTTP service, **not** the HTTPS/Frame.io implementation. It is unauthenticated;
stop it after testing and do not expose it to the Internet.

FI-02 adds test-only DNS/TLS. FI-03 and FI-04 implement the camera protocol.
EOF

write_new docs/mac-poc.md <<'EOF'
# Mac proof of concept — lab notes

## FI-01 — Minimal local receiver

- [ ] Record X-E5 firmware version: **TBD**
- [ ] Record Mac version and Python version: **TBD**
- [ ] Record active Mac LAN IP/interface: **TBD**
- [ ] Start `python3 poc/mac/receiver.py --bind 127.0.0.1 --port 8765`
- [ ] Confirm `curl -fsS http://127.0.0.1:8765/health` responds
- [ ] Confirm test binary POST saves to `poc/mac/output/`
- [ ] Temporarily bind to LAN interface and verify another LAN device can access `/health`
- [ ] Choose a **temporary, reversible** Mac↔camera Wi-Fi connection method
- [ ] Document how WAN access will be blocked for both camera and test receiver
- [ ] Document exact rollback; verify no production router/Pi/Nextcloud changes

## FI-02 — DNS and local HTTPS (not yet started)

- Required Frame.io hostnames observed: **TBD**
- Test-only DNS choice: **TBD**
- Certificate SAN / camera CA import result: **TBD**
- TLS request observed at Mac receiver: **TBD**

## FI-03 — Pairing protocol (not yet started)

- Redacted endpoint sequence and response shapes: **TBD**
- Fully offline pairing result: **TBD**

## FI-04 — Original file transfer (not yet started)

| Original | Source SHA-256 | Received SHA-256 | Match? |
|---|---|---|---|
| RAF | TBD | TBD | TBD |
| JPEG | TBD | TBD | TBD |

- Camera reports upload completion: **TBD**
- WAN access blocked during test: **TBD**
- Reconnection retest: **TBD**

## Rollback

- Stop the Mac receiver (`Ctrl-C`).
- Remove any temporary DNS overrides and restore previous camera network settings.
- Remove the *test* root certificate from camera trust, once no longer needed.
- Delete test-only certificates under `poc/mac/certs/` if appropriate.

Never log or commit camera authentication tokens, private keys, personal photos or packet captures.
EOF

write_new poc/mac/receiver.py <<'PYTHON'
#!/usr/bin/env python3
"""Disposable FI-01 HTTP receiver; NOT the Frame.io protocol or production server.

Only two endpoints exist: GET /health and POST /_debug/upload (raw bytes).
No access tokens, headers, query strings or image bodies are logged.
"""

import argparse
import json
import logging
import os
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

MAX_TEST_BYTES = 512 * 1024 * 1024
BLOCK_SIZE = 1024 * 1024


class Handler(BaseHTTPRequestHandler):
    server_version = "FujiImportMacPoC/0.1"

    def log_message(self, fmt, *args):
        # Don't log raw request lines (which may contain auth query strings).
        pass

    def _respond(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def _path(self):
        return urlsplit(self.path).path

    def do_GET(self):
        path = self._path()
        logging.info("GET %s from %s", path, self.client_address[0])
        if path == "/health":
            self._respond(200, {"status": "ok", "stage": "FI-01"})
        else:
            self._respond(404, {"error": "unimplemented"})

    def do_POST(self):
        path = self._path()
        logging.info("POST %s from %s", path, self.client_address[0])
        if path != "/_debug/upload":
            self._respond(404, {"error": "unimplemented"})
            return

        length = self.headers.get("Content-Length", "")
        if not length.isdecimal():
            self._respond(411, {"error": "Content-Length required"})
            return
        remaining = int(length)
        if not 0 < remaining <= MAX_TEST_BYTES:
            self._respond(413, {"error": "invalid test payload size"})
            return

        output = self.server.output_dir
        output.mkdir(parents=True, exist_ok=True)
        file_id = uuid.uuid4().hex
        part_path = output / (file_id + ".part")
        final_path = output / (file_id + ".bin")
        try:
            with part_path.open("xb") as fh:
                while remaining:
                    chunk = self.rfile.read(min(remaining, BLOCK_SIZE))
                    if not chunk:
                        raise ConnectionError("upload ended early")
                    fh.write(chunk)
                    remaining -= len(chunk)
                fh.flush()
                os.fsync(fh.fileno())
            part_path.replace(final_path)
        except (OSError, ConnectionError) as exc:
            part_path.unlink(missing_ok=True)
            logging.warning("Debug upload failed: %s", type(exc).__name__)
            self._respond(500, {"error": "test upload failed"})
            return
        logging.info("Saved debug upload %s (%d bytes)", file_id, int(length))
        self._respond(201, {"saved_as": final_path.name, "bytes": int(length)})

    def do_PUT(self):
        logging.info("PUT %s from %s", self._path(), self.client_address[0])
        self._respond(404, {"error": "unimplemented"})


class Receiver(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, handler_class, output_dir):
        super().__init__(address, handler_class)
        self.output_dir = output_dir


def main():
    parser = argparse.ArgumentParser(description="FI-01 Mac-only diagnostic receiver")
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "output")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    with Receiver((args.bind, args.port), Handler, args.output.resolve()) as server:
        logging.info("FI-01 receiver at http://%s:%d", args.bind, server.server_port)
        logging.info("Output: %s", server.output_dir)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
PYTHON

write_new scripts/mac-info.sh <<'EOF'
#!/usr/bin/env bash
# Diagnostic only. Does not change Mac networking.
set -euo pipefail

echo "macOS: $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
echo "Python: $(python3 --version 2>&1 || echo 'not installed')"
if command -v route >/dev/null 2>&1 && command -v ipconfig >/dev/null 2>&1; then
    iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
    if [[ -n "$iface" ]]; then
        echo "Default interface: $iface"
        echo "IPv4: $(ipconfig getifaddr "$iface" 2>/dev/null || echo 'not assigned')"
    else
        echo "Default interface not detected"
    fi
fi
echo "No networking settings were changed."
EOF

chmod +x scripts/mac-info.sh

echo
echo "Ready. No existing docs were changed. No network settings were modified."
echo "Next: ./scripts/mac-info.sh"
echo "      python3 poc/mac/receiver.py --bind 127.0.0.1 --port 8765"
echo "      curl -fsS http://127.0.0.1:8765/health"
echo "Then fill out docs/mac-poc.md to complete FI-01."
