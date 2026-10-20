#!/usr/bin/env python3
"""Minimal, idempotent FI-03 WebSocket compatibility/diagnostics patch.

Apply from the FujiImport repository root:
    python3 fi03_fix_websocket.py

Changes only poc/mac/fi03_device.py. Does not touch TLS/DNS/receiver endpoints.
Does not log request tokens, WebSocket payloads, or file contents.
"""

from __future__ import annotations

from datetime import datetime
from pathlib import Path

module_path = Path("poc/mac/fi03_device.py")
if not module_path.is_file():
    raise SystemExit("Missing poc/mac/fi03_device.py; run from FujiImport root.")

source = module_path.read_text(encoding="utf-8")
MARKER = "# FI-03 diagnostic: Phoenix v1/v2 frames"
if MARKER in source:
    print("WebSocket compatibility patch already present; unchanged.")
    raise SystemExit(0)

old = """                message = json.loads(data.decode("utf-8"))
                if not isinstance(message, dict):
                    raise ValueError("expected JSON object")
                event = message.get("event")
                topic = message.get("topic")
                if not isinstance(event, str) or not isinstance(topic, str):
                    raise ValueError("invalid Phoenix message")
                logging.info("FI-03 WebSocket event=%s topic=%s", event[:64], topic[:80])
                if event == "phx_join" and topic != "devices:" + DEVICE_ID:
                    result = {"status": "error", "response": {"reason": "unknown topic"}}
                else:
                    result = {"status": "ok", "response": {}}
                if event in ("phx_join", "heartbeat", "phx_leave"):
                    reply = {
                        "topic": topic,
                        "event": "phx_reply",
                        "payload": result,
                        "ref": message.get("ref"),
                    }
                    send_frame(handler.wfile, 0x1, json.dumps(reply, separators=(",", ":")).encode("utf-8"))
"""

new = """                # FI-03 diagnostic: Phoenix v1/v2 frames
                message = json.loads(data.decode("utf-8"))
                if isinstance(message, dict):
                    # Frame.io C2C documented object representation.
                    style = "object"
                    topic = message.get("topic")
                    event = message.get("event")
                    reference = message.get("ref")
                    join_ref = None
                elif isinstance(message, list) and len(message) == 5:
                    # Phoenix V2 JSONSerializer: [join_ref, ref, topic, event, payload].
                    style = "array"
                    join_ref, reference, topic, event, _payload = message
                else:
                    raise ValueError("unexpected Phoenix JSON shape")
                if not isinstance(event, str) or not isinstance(topic, str):
                    raise ValueError("invalid Phoenix event/topic")
                logging.info("FI-03 WebSocket %s event=%s topic=%s", style, event[:64], topic[:80])
                if event == "phx_join" and topic != "devices:" + DEVICE_ID:
                    result = {"status": "error", "response": {"reason": "unknown topic"}}
                else:
                    result = {"status": "ok", "response": {}}
                if event in ("phx_join", "heartbeat", "phx_leave"):
                    if style == "array":
                        reply = [join_ref, reference, topic, "phx_reply", result]
                    else:
                        reply = {"topic": topic, "event": "phx_reply", "payload": result, "ref": reference}
                    send_frame(handler.wfile, 0x1, json.dumps(reply, separators=(",", ":")).encode("utf-8"))
"""

old_log = """        except (socket.timeout, ConnectionError, OSError, ValueError, UnicodeError, json.JSONDecodeError) as exc:
            logging.info("FI-03 WebSocket closed (%s)", type(exc).__name__)
"""
new_log = """        except (socket.timeout, ConnectionError, OSError, ValueError, UnicodeError, json.JSONDecodeError) as exc:
            # No raw messages, bearer tokens, or HTTP query parameters in logs.
            logging.info("FI-03 WebSocket closed (%s: %s)", type(exc).__name__, str(exc)[:120])
"""
if source.count(old) != 1 or source.count(old_log) != 1:
    raise SystemExit(
        "Unexpected fi03_device.py structure; refusing to modify. No files changed."
    )

updated = source.replace(old, new, 1).replace(old_log, new_log, 1)
compile(updated, str(module_path), "exec")
backup_dir = Path("poc/mac/logs")
backup_dir.mkdir(parents=True, exist_ok=True)
backup_path = (
    backup_dir / f"fi03_device.py.before-ws-{datetime.now():%Y%m%d-%H%M%S-%f}.bak"
)
backup_path.write_text(source, encoding="utf-8")
module_path.write_text(updated, encoding="utf-8")
print("Updated poc/mac/fi03_device.py")
print("  - Supports both object and Phoenix V2 array JSON frames")
print("  - Logs sanitized WebSocket close reason")
print("  - No changes to DNS, TLS, pairing tokens, or upload routes")
print(f"Backup: {backup_path}")
