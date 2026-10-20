#!/usr/bin/env python3
"""FI-03 (step 1): add a disposable local Frame.io device-code endpoint.

Run from the FujiImport repository root:
    python3 fi03_add_device_code.py

This modifies only poc/mac/receiver.py. It preserves existing GET /health,
HTTP upload diagnostics, certificates, DNS settings, and HTTPS proxy config.
"""

from pathlib import Path

TARGET = Path("poc/mac/receiver.py")
MARKER = '        if path != "/_debug/upload":\n'
BEGIN = '        # FI-03 proof of concept: device-code pairing (local only).\n'
BLOCK = '''        # FI-03 proof of concept: device-code pairing (local only).
        if path == "/v2/auth/device/code":
            # The camera sends form-encoded client credentials. We do not need
            # to inspect or log them for this response-shape experiment.
            device_code = str(uuid.uuid4())
            user_code = "123456"  # Fixed deliberately for first camera test.
            logging.info("FI-03 issued local pairing code %s", user_code)
            self._respond(200, {
                "device_code": device_code,
                "expires_in": 120,
                "interval": 5,
                "name": "FujiImport",
                "user_code": user_code,
            })
            return

'''


def main():
    if not TARGET.is_file():
        raise SystemExit("Run from FujiImport root; missing poc/mac/receiver.py")

    source = TARGET.read_text(encoding="utf-8")
    if BEGIN in source:
        print("FI-03 endpoint already installed; no changes made.")
        return
    if source.count(MARKER) != 1:
        raise SystemExit("Receiver structure differs from the scaffold; no changes made.")
    if "import uuid" not in source or "def do_POST(self):" not in source:
        raise SystemExit("Receiver lacks expected imports/handler; no changes made.")

    output = source.replace(MARKER, BLOCK + MARKER, 1)
    compile(output, str(TARGET), "exec")

    backup = Path("poc/mac/logs/receiver.before-fi03.py")
    backup.parent.mkdir(parents=True, exist_ok=True)
    if backup.exists():
        raise SystemExit(f"Backup already exists: {backup}; no changes made.")
    backup.write_text(source, encoding="utf-8")
    TARGET.write_text(output, encoding="utf-8")
    print(f"Updated {TARGET}")
    print(f"Backup: {backup}")
    print("Restart receiver.py and press GET PAIRING CODE on the camera.")


if __name__ == "__main__":
    main()
