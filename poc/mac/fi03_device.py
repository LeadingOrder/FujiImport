"""Frame.io-compatible identity and minimal Phoenix WebSocket (Mac PoC).

Scoped intentionally to local X-E5 testing. This is not an authenticated,
production-grade device service and should not be exposed to the internet.
No credentials, WebSocket query strings or uploaded images are logged.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import logging
import socket
import struct
import uuid
from urllib.parse import parse_qs, urlsplit

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
DEVICE_ID = str(uuid.uuid5(uuid.NAMESPACE_URL, "fuji-import:poc:xe5:device"))
PROJECT_ID = str(uuid.uuid5(uuid.NAMESPACE_URL, "fuji-import:poc:project"))
USER_ID = str(uuid.uuid5(uuid.NAMESPACE_URL, "fuji-import:poc:user"))
AUTH_ID = str(uuid.uuid5(uuid.NAMESPACE_URL, "fuji-import:poc:authorization"))
CHANNEL_ID = str(uuid.uuid5(uuid.NAMESPACE_URL, "fuji-import:poc:channel"))
MAX_WS_PAYLOAD = 64 * 1024


def identity_payload():
    """Small response shaped like documented Frame.io project_device."""
    return {
        "_type": "project_device",
        "id": DEVICE_ID,
        "device_id": DEVICE_ID,
        "name": "FUJIFILM X-E5 (FujiImport)",
        "asset_type": "image",
        "project_id": PROJECT_ID,
        "project": {
            "_type": "project",
            "id": PROJECT_ID,
            "name": "FujiImport",
        },
        "authorization": {
            "_type": "project_device_authorization",
            "id": AUTH_ID,
            "project_device_id": DEVICE_ID,
            "expires_at": None,
            "creator": {
                "_type": "user",
                "id": USER_ID,
                "name": "Local User",
            },
            "creator_id": USER_ID,
            "scopes": {
                "offline": True,
                "asset_create": True,
                "asset_read": True,
            },
        },
        "channels": [
            {
                "_type": "project_device_channel",
                "id": CHANNEL_ID,
                "project_device_id": DEVICE_ID,
                "project_id": PROJECT_ID,
                "device_id": DEVICE_ID,
                "name": "FUJIFILM X-E5",
                "asset_type": "image",
                "external_index": 0,
                "status": "online",
            }
        ],
        "status": "online",
        "timezone": "Europe/Berlin",
    }


def access_from_header(value):
    scheme, separator, credential = (value or "").partition(" ")
    if separator and scheme.lower() == "bearer":
        return credential.strip()
    return ""


def receive_exact(stream, size):
    result = stream.read(size)
    if len(result) != size:
        raise ConnectionError("WebSocket frame ended early")
    return result


def receive_frame(stream):
    head = receive_exact(stream, 2)
    first, second = head
    opcode = first & 0x0F
    if not first & 0x80:
        raise ValueError("fragmented WebSocket messages not supported in PoC")
    if first & 0x70:
        raise ValueError("WebSocket extensions not supported")
    if not second & 0x80:
        raise ValueError("client WebSocket frame must be masked")
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", receive_exact(stream, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", receive_exact(stream, 8))[0]
    if length > MAX_WS_PAYLOAD:
        raise ValueError("WebSocket message too large")
    mask = receive_exact(stream, 4)
    data = receive_exact(stream, length)
    return opcode, bytes(char ^ mask[i % 4] for i, char in enumerate(data))


def send_frame(stream, opcode, content):
    n = len(content)
    if n < 126:
        header = bytes([0x80 | opcode, n])
    elif n <= 65535:
        header = bytes([0x80 | opcode, 126]) + struct.pack("!H", n)
    else:
        header = bytes([0x80 | opcode, 127]) + struct.pack("!Q", n)
    stream.write(header + content)
    stream.flush()


class DeviceAPI:
    def __init__(self, pairing_store):
        self.pairing = pairing_store

    def identify(self, handler):
        token = access_from_header(handler.headers.get("Authorization"))
        if not self.pairing.valid_access(token):
            handler._respond(401, {"error": "unauthorized"})
            return
        logging.info("FI-03 device identity (HTTP 200)")
        handler._respond(200, identity_payload())

    def websocket(self, handler):
        query = parse_qs(urlsplit(handler.path).query)
        tokens = query.get("Authorization", [])
        token = access_from_header(tokens[0]) if tokens else ""
        if not token:
            token = access_from_header(handler.headers.get("Authorization"))
        if not self.pairing.valid_access(token):
            handler._respond(403, {"error": "unauthorized"})
            return

        if handler.headers.get("Upgrade", "").lower() != "websocket" or (
            "upgrade" not in handler.headers.get("Connection", "").lower()
        ):
            handler._respond(426, {"error": "websocket upgrade required"})
            return
        if handler.headers.get("Sec-WebSocket-Version") != "13":
            handler._respond(400, {"error": "unsupported websocket version"})
            return
        key = handler.headers.get("Sec-WebSocket-Key", "")
        try:
            raw_key = base64.b64decode(key, validate=True)
        except (ValueError, binascii.Error):
            raw_key = b""
        if len(raw_key) != 16:
            handler._respond(400, {"error": "invalid websocket key"})
            return

        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode("ascii")).digest()).decode("ascii")
        handler.send_response(101, "Switching Protocols")
        handler.send_header("Upgrade", "websocket")
        handler.send_header("Connection", "Upgrade")
        handler.send_header("Sec-WebSocket-Accept", accept)
        handler.end_headers()
        logging.info("FI-03 WebSocket upgraded (HTTP 101)")
        handler.connection.settimeout(90)

        # After HTTP 101, the HTTP request handler owns this socket until close.
        # Only reply to Phoenix joins/heartbeats; no server-side jobs or uploads.
        try:
            while True:
                opcode, data = receive_frame(handler.rfile)
                if opcode == 0x8:  # close
                    send_frame(handler.wfile, 0x8, data[:125])
                    break
                if opcode == 0x9:  # WebSocket ping
                    send_frame(handler.wfile, 0xA, data[:125])
                    continue
                if opcode == 0xA:  # WebSocket pong
                    continue
                if opcode != 0x1:  # only text JSON frames
                    raise ValueError("unsupported frame type")
                message = json.loads(data.decode("utf-8"))
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
        except (socket.timeout, ConnectionError, OSError, ValueError, UnicodeError, json.JSONDecodeError) as exc:
            logging.info("FI-03 WebSocket closed (%s)", type(exc).__name__)
        finally:
            handler.close_connection = True
