"""FI-03 Mac PoC authentication state. Not a production authorization service.

Only the locally issued device code can be exchanged for a token; the device is
*automatically approved* for this experiment. State is in memory and disappears
when receiver.py restarts. No Adobe credentials, no remote HTTP requests.
"""

from __future__ import annotations

import json
import secrets
import threading
import time
from email.parser import BytesParser
from email.policy import default
from urllib.parse import parse_qs

MAX_FORM_SIZE = 64 * 1024
DEVICE_CODE_LIFETIME = 120
ACCESS_TOKEN_LIFETIME = 28800
REFRESH_TOKEN_LIFETIME = 14 * 24 * 3600
GRANT_DEVICE = "urn:ietf:params:oauth:grant-type:device_code"


def read_form(request):
    """Read a small urlencoded/multipart/JSON POST body, or raise ValueError."""
    length = request.headers.get("Content-Length")
    if length is None or not length.isdecimal():
        raise ValueError("Content-Length required")
    n = int(length)
    if n > MAX_FORM_SIZE:
        raise ValueError("form body too large")
    body = request.rfile.read(n)
    if len(body) != n:
        raise ValueError("truncated form body")
    content_type = request.headers.get("Content-Type", "").strip()
    media_type = content_type.split(";", 1)[0].lower()

    if media_type in ("", "application/x-www-form-urlencoded"):
        parsed = parse_qs(body.decode("utf-8"), keep_blank_values=True)
        return {key: values[0] for key, values in parsed.items()}

    if media_type == "multipart/form-data":
        wrapped = (
            "MIME-Version: 1.0\r\nContent-Type: "
            + content_type
            + "\r\n\r\n"
        ).encode("ascii") + body
        message = BytesParser(policy=default).parsebytes(wrapped)
        if not message.is_multipart():
            raise ValueError("invalid multipart form")
        fields = {}
        for part in message.iter_parts():
            if part.get_content_disposition() != "form-data":
                continue
            key = part.get_param("name", header="content-disposition")
            if key:
                fields[key] = part.get_payload(decode=True).decode("utf-8")
        return fields

    if media_type == "application/json":
        value = json.loads(body)
        if not isinstance(value, dict):
            raise ValueError("JSON body must be an object")
        return {str(key): str(value) for key, value in value.items()}

    raise ValueError("unsupported content type")


class PairingStore:
    """In-memory, thread-safe state for camera testing; no persistence."""

    def __init__(self):
        self._lock = threading.Lock()
        self._devices = {}
        self._refresh = {}
        self._access = {}

    def issue_code(self, client_id):
        if not client_id:
            return 400, {"error": "invalid_request"}
        device_code = secrets.token_urlsafe(32)
        with self._lock:
            self._devices[device_code] = {
                "client_id": client_id,
                "expires": time.monotonic() + DEVICE_CODE_LIFETIME,
                "tokens": None,
            }
        return 200, {
            "device_code": device_code,
            "user_code": "123456",  # Known value for the X-E5 display test.
            "expires_in": DEVICE_CODE_LIFETIME,
            "interval": 5,
            "name": "FujiImport",
        }

    def exchange(self, form):
        grant = form.get("grant_type", "")
        if grant == GRANT_DEVICE or (not grant and "device_code" in form):
            return self._exchange_device(form)
        if grant == "refresh_token":
            return self._exchange_refresh(form)
        return 400, {"error": "unsupported_grant_type"}

    def _exchange_device(self, form):
        code = form.get("device_code")
        client_id = form.get("client_id")
        if not code or not client_id:
            return 400, {"error": "invalid_request"}
        with self._lock:
            device = self._devices.get(code)
            if device is None or device["client_id"] != client_id:
                return 400, {"error": "invalid_grant"}
            if time.monotonic() > device["expires"] and device["tokens"] is None:
                self._devices.pop(code, None)
                return 400, {"error": "expired_token"}
            if device["tokens"] is None:
                device["tokens"] = self._issue_tokens_locked(client_id)
            return 200, device["tokens"].copy()

    def _exchange_refresh(self, form):
        refresh = form.get("refresh_token")
        client_id = form.get("client_id")
        if not refresh or not client_id:
            return 400, {"error": "invalid_request"}
        with self._lock:
            record = self._refresh.get(refresh)
            if record is None or record[0] != client_id or time.monotonic() > record[1]:
                return 400, {"error": "invalid_grant"}
            del self._refresh[refresh]
            return 200, self._issue_tokens_locked(client_id)

    def valid_access(self, token):
        if not token:
            return False
        with self._lock:
            deadline = self._access.get(token)
            if deadline is None:
                return False
            if time.monotonic() > deadline:
                self._access.pop(token, None)
                return False
            return True

    def _issue_tokens_locked(self, client_id):
        access = secrets.token_urlsafe(48)
        self._access[access] = time.monotonic() + ACCESS_TOKEN_LIFETIME
        refresh = secrets.token_urlsafe(48)
        self._refresh[refresh] = (
            client_id,
            time.monotonic() + REFRESH_TOKEN_LIFETIME,
        )
        return {
            "access_token": access,
            "expires_in": ACCESS_TOKEN_LIFETIME,
            "refresh_token": refresh,
            "token_type": "bearer",
        }
