#!/usr/bin/env python3
"""Fuji Import: local Frame.io-compatible Mac experiment (standard library only).

This is an integrated PROOF OF CONCEPT, not an internet-facing service.
Keep behind the existing TLS front end and camera-specific DNS override.
No Adobe calls, no post-import execution, no automatic deletion of originals.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import hmac
import json
import logging
import os
import re
import secrets
import socket
import sqlite3
import struct
import threading
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlsplit

LOG = logging.getLogger("fuji")
BLOCK = 1024 * 1024
MAX_JSON = 1024 * 1024
MAX_PART = 2 * 1024**3
MAX_ASSET = 32 * 1024**3
MAX_PARTS = 8192
MAX_WS = 1024 * 1024
DEVICE_ID = str(uuid.uuid5(uuid.NAMESPACE_URL, "fuji-import:poc:xe5:device"))
PROJECT_ID = str(uuid.uuid5(uuid.NAMESPACE_URL, "fuji-import:poc:project"))
USER_ID = str(uuid.uuid5(uuid.NAMESPACE_URL, "fuji-import:poc:user"))
AUTH_ID = str(uuid.uuid5(uuid.NAMESPACE_URL, "fuji-import:poc:authorization"))
CHANNEL_ID = str(uuid.uuid5(uuid.NAMESPACE_URL, "fuji-import:poc:channel"))
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def stamp():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def safe_filename(value):
    # Browser/Windows reserved names are not relevant to the PoC, but avoid traversal.
    name = str(value or "").replace("\\", "/").rsplit("/", 1)[-1]
    name = re.sub(r"[\x00-\x1f\x7f]", "_", name).strip(" .")
    if not name or name in (".", ".."):
        raise ValueError("invalid filename")
    return name[:200]


def fsync_dir(path):
    # Directory fsync is not supported on some platforms, so best-effort only.
    try:
        fd = os.open(str(path), os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        pass


class Store:
    """Thread-safe small SQLite manifest for the Mac experiment."""

    def __init__(self, output):
        self.root = Path(output).expanduser().resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.parts = self.root / ".parts"
        self.parts.mkdir(exist_ok=True)
        self.lock = threading.RLock()
        self.db = self.root / ".fuji-import.sqlite3"
        self._init()

    def _conn(self):
        conn = sqlite3.connect(self.db, timeout=30)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout=30000")
        conn.execute("PRAGMA foreign_keys=ON")
        return conn

    def _init(self):
        with self._conn() as db:
            db.executescript(
                """
                CREATE TABLE IF NOT EXISTS sessions (
                    client_id TEXT NOT NULL,
                    device_code TEXT PRIMARY KEY,
                    expires REAL NOT NULL,
                    access_token TEXT,
                    refresh_token TEXT,
                    token_expiry REAL
                );
                CREATE TABLE IF NOT EXISTS assets (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    filetype TEXT,
                    filesize INTEGER NOT NULL,
                    part_count INTEGER NOT NULL,
                    created TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'receiving',
                    output_path TEXT,
                    sha256 TEXT
                );
                CREATE TABLE IF NOT EXISTS parts (
                    asset_id TEXT NOT NULL REFERENCES assets(id),
                    number INTEGER NOT NULL,
                    bytes INTEGER NOT NULL,
                    sha256 TEXT NOT NULL,
                    PRIMARY KEY(asset_id, number)
                );
            """
            )

    def code(self, client_id):
        if not client_id:
            return 400, {"error": "invalid_request"}
        device = secrets.token_urlsafe(32)
        with self.lock, self._conn() as db:
            db.execute(
                "INSERT INTO sessions(client_id,device_code,expires) VALUES(?,?,?)",
                (client_id, device, time.time() + 120),
            )
        return 200, {
            "device_code": device,
            "user_code": "123456",
            "expires_in": 120,
            "interval": 5,
            "name": "FujiImport",
        }

    def token(self, form):
        grant = form.get("grant_type", "")
        client_id = form.get("client_id", "")
        with self.lock, self._conn() as db:
            if grant == "refresh_token":
                row = db.execute(
                    "SELECT * FROM sessions WHERE refresh_token=? AND client_id=?",
                    (form.get("refresh_token", ""), client_id),
                ).fetchone()
                if not row:
                    return 400, {"error": "invalid_grant"}
            elif grant in ("", "urn:ietf:params:oauth:grant-type:device_code"):
                row = db.execute(
                    "SELECT * FROM sessions WHERE device_code=? AND client_id=?",
                    (form.get("device_code", ""), client_id),
                ).fetchone()
                if not row:
                    return 400, {"error": "invalid_grant"}
                if not row["access_token"] and row["expires"] < time.time():
                    return 400, {"error": "expired_token"}
                if row["access_token"] and row["token_expiry"] > time.time():
                    return 200, {
                        "access_token": row["access_token"],
                        "refresh_token": row["refresh_token"],
                        "expires_in": max(1, int(row["token_expiry"] - time.time())),
                        "token_type": "bearer",
                    }
            else:
                return 400, {"error": "unsupported_grant_type"}
            access = secrets.token_urlsafe(48)
            refresh = secrets.token_urlsafe(48)
            expiration = time.time() + 28800
            db.execute(
                "UPDATE sessions SET access_token=?,refresh_token=?,token_expiry=? WHERE device_code=?",
                (access, refresh, expiration, row["device_code"]),
            )
            return 200, {
                "access_token": access,
                "refresh_token": refresh,
                "expires_in": 28800,
                "token_type": "bearer",
            }

    def valid(self, token):
        if not token:
            return False
        with self.lock, self._conn() as db:
            return (
                db.execute(
                    "SELECT 1 FROM sessions WHERE access_token=? AND token_expiry>?",
                    (token, time.time()),
                ).fetchone()
                is not None
            )

    def create_asset(self, payload):
        name = safe_filename(payload.get("name"))
        filesize = int(payload.get("filesize"))
        parts = int(
            payload.get("parts") or max(1, (filesize + 23_109_631) // 23_109_632)
        )
        if not 0 < filesize <= MAX_ASSET or not 0 < parts <= MAX_PARTS:
            raise ValueError("invalid filesize/parts")
        asset_id = str(uuid.uuid4())
        with self.lock, self._conn() as db:
            db.execute(
                "INSERT INTO assets(id,name,filetype,filesize,part_count,created) VALUES(?,?,?,?,?,?)",
                (
                    asset_id,
                    name,
                    str(payload.get("filetype") or "application/octet-stream"),
                    filesize,
                    parts,
                    stamp(),
                ),
            )
        params = {
            "x-amz-meta-asset_id": asset_id,
            "x-amz-meta-is_realtime_upload": "false",
            "x-amz-meta-part_count": str(parts),
            "x-amz-meta-project_id": PROJECT_ID,
            "x-amz-meta-resource_id": asset_id,
            "x-amz-meta-resource_type": "asset",
            "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
            "X-Amz-SignedHeaders": "content-type;host;x-amz-acl",
        }
        urls = []
        for part in range(1, parts + 1):
            q = {
                **params,
                "x-amz-meta-part_number": str(part),
                "x-amz-meta-total_parts": str(parts),
            }
            urls.append("https://api.frame.io/upload?" + urlencode(q))
        LOG.info(
            "Asset declared id=%s name=%s bytes=%s parts=%s",
            asset_id,
            name,
            filesize,
            parts,
        )
        return {
            "_type": "file",
            "id": asset_id,
            "name": name,
            "filetype": payload.get("filetype"),
            "filesize": filesize,
            "type": "file",
            "status": "created",
            "project_id": PROJECT_ID,
            "upload_urls": urls,
            "original_upload": urls[0],
        }

    def receive_part(self, asset_id, number, inp, size):
        if size < 0 or size > MAX_PART:
            raise ValueError("invalid part length")
        with self.lock, self._conn() as db:
            asset = db.execute(
                "SELECT * FROM assets WHERE id=?", (asset_id,)
            ).fetchone()
            if not asset or number < 1 or number > asset["part_count"]:
                raise LookupError("unknown asset/part")
        partdir = self.parts / asset_id
        partdir.mkdir(exist_ok=True)
        temporary = partdir / f"{number}.{uuid.uuid4().hex}.tmp"
        completed = partdir / f"{number}.part"
        digest = hashlib.sha256()
        remaining = size
        try:
            with temporary.open("xb") as out:
                while remaining:
                    buf = inp.read(min(BLOCK, remaining))
                    if not buf:
                        raise ConnectionError("part was truncated")
                    out.write(buf)
                    digest.update(buf)
                    remaining -= len(buf)
                out.flush()
                os.fsync(out.fileno())
            hexdigest = digest.hexdigest()
            with self.lock, self._conn() as db:
                existing = db.execute(
                    "SELECT bytes,sha256 FROM parts WHERE asset_id=? AND number=?",
                    (asset_id, number),
                ).fetchone()
                if existing:
                    if existing["bytes"] != size or existing["sha256"] != hexdigest:
                        raise ValueError("retransmission content differs")
                    LOG.info(
                        "Duplicate part acknowledged asset=%s part=%d", asset_id, number
                    )
                else:
                    os.replace(temporary, completed)
                    fsync_dir(partdir)
                    db.execute(
                        "INSERT INTO parts(asset_id,number,bytes,sha256) VALUES(?,?,?,?)",
                        (asset_id, number, size, hexdigest),
                    )
                    LOG.info(
                        "Part stored asset=%s part=%d size=%d", asset_id, number, size
                    )
            self._assemble_if_complete(asset_id)
            return hexdigest
        finally:
            temporary.unlink(missing_ok=True)

    def _assemble_if_complete(self, asset_id):
        with self.lock, self._conn() as db:
            asset = db.execute(
                "SELECT * FROM assets WHERE id=?", (asset_id,)
            ).fetchone()
            if asset["status"] == "stored":
                return
            rows = db.execute(
                "SELECT number,bytes FROM parts WHERE asset_id=? ORDER BY number",
                (asset_id,),
            ).fetchall()
            if len(rows) != asset["part_count"]:
                return
            if sum(r["bytes"] for r in rows) != asset["filesize"]:
                LOG.error(
                    "Asset size mismatch asset=%s expected=%d got=%d",
                    asset_id,
                    asset["filesize"],
                    sum(r["bytes"] for r in rows),
                )
                return
            # Date of ingestion, not EXIF date; sufficient for Mac protocol PoC.
            now = datetime.now()
            folder = self.root / f"{now.year:04d}" / f"{now.month:02d}"
            folder.mkdir(parents=True, exist_ok=True)
            original = asset["name"]
            destination = folder / original
            if destination.exists():
                stem, suffix = os.path.splitext(original)
                destination = folder / f"{stem}-{asset_id[:8]}{suffix}"
            temporary = folder / f".{asset_id}.assembling"
            digest = hashlib.sha256()
            try:
                with temporary.open("xb") as out:
                    for row in rows:
                        with (self.parts / asset_id / f"{row['number']}.part").open(
                            "rb"
                        ) as inp:
                            while buf := inp.read(BLOCK):
                                out.write(buf)
                                digest.update(buf)
                    out.flush()
                    os.fsync(out.fileno())
                if temporary.stat().st_size != asset["filesize"]:
                    raise ValueError("assembled file size mismatch")
                # An atomic, no-clobber hard link avoids exposing a partial final
                # file or copying tens of MB twice. Both paths share a filesystem.
                # The .assembling file was fully fsync'ed immediately above.
                os.link(temporary, destination)
                fsync_dir(folder)
                db.execute(
                    "UPDATE assets SET status='stored',output_path=?,sha256=? WHERE id=?",
                    (str(destination), digest.hexdigest(), asset_id),
                )
                LOG.info(
                    "ASSET STORED %s bytes=%d sha256=%s",
                    destination,
                    asset["filesize"],
                    digest.hexdigest(),
                )
                # Part cleanup is safe after completed file and DB commit
                for row in rows:
                    (self.parts / asset_id / f"{row['number']}.part").unlink(
                        missing_ok=True
                    )
                try:
                    (self.parts / asset_id).rmdir()
                except OSError:
                    pass
            finally:
                temporary.unlink(missing_ok=True)

    def snapshot(self):
        with self.lock, self._conn() as db:
            recent = db.execute(
                "SELECT id,name,filesize,status,output_path,sha256 FROM assets ORDER BY created DESC LIMIT 30"
            ).fetchall()
            return {
                "assets": [dict(row) for row in recent],
                "count": db.execute("SELECT count(*) FROM assets").fetchone()[0],
            }


def identity():
    return {
        "_type": "project_device",
        "id": DEVICE_ID,
        "device_id": DEVICE_ID,
        "name": "FUJIFILM X-E5 (FujiImport)",
        "asset_type": "image",
        "project_id": PROJECT_ID,
        "project": {"_type": "project", "id": PROJECT_ID, "name": "FujiImport"},
        "authorization": {
            "_type": "project_device_authorization",
            "id": AUTH_ID,
            "project_device_id": DEVICE_ID,
            "creator_id": USER_ID,
            "expires_at": None,
            "creator": {"_type": "user", "id": USER_ID, "name": "Local User"},
            "scopes": {"offline": True, "asset_create": True, "asset_read": True},
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


def read_exact(stream, count):
    chunks = bytearray()
    while len(chunks) < count:
        more = stream.read(count - len(chunks))
        if not more:
            raise EOFError("socket closed")
        chunks.extend(more)
    return bytes(chunks)


def frame_read(stream):
    head = read_exact(stream, 2)
    first, second = head
    opcode = first & 0x0F
    if first & 0x70:
        raise ValueError("unsupported websocket extension bits")
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", read_exact(stream, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", read_exact(stream, 8))[0]
    if length > MAX_WS:
        raise ValueError("websocket frame too large")
    masked = bool(second & 0x80)
    if masked:
        key = read_exact(stream, 4)
    else:
        LOG.warning(
            "Noncompliant unmasked WebSocket client frame received; accepted for local experiment"
        )
        key = None
    data = read_exact(stream, length)
    if key:
        data = bytes(c ^ key[i % 4] for i, c in enumerate(data))
    return bool(first & 0x80), opcode, data


def frame_write(stream, opcode, data):
    length = len(data)
    if length < 126:
        header = bytes((0x80 | opcode, length))
    elif length < 65536:
        header = bytes((0x80 | opcode, 126)) + struct.pack("!H", length)
    else:
        header = bytes((0x80 | opcode, 127)) + struct.pack("!Q", length)
    stream.write(header + data)
    stream.flush()


def parse_phoenix(data, opcode):
    """Decode Phoenix V1 object JSON, V2 array JSON, and V2 binary PUSH.

    A websocket BINARY frame (opcode 2) can itself contain UTF-8 JSON;
    websocket framing and Phoenix serialization are separate layers.
    """
    if opcode not in (1, 2):
        raise ValueError(f"unsupported websocket data opcode={opcode}")

    # Several embedded clients send their JSON messages using binary WS frames.
    # Do this *before* interpreting the first byte as a Phoenix binary tag.
    decoded = None
    try:
        decoded = json.loads(data.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        pass
    if isinstance(decoded, dict):
        return (
            "object-binary" if opcode == 2 else "object",
            None,
            decoded.get("ref"),
            decoded.get("topic"),
            decoded.get("event"),
            decoded.get("payload"),
        )
    if isinstance(decoded, list) and len(decoded) >= 5:
        return (
            "array-binary" if opcode == 2 else "array",
            decoded[0],
            decoded[1],
            decoded[2],
            decoded[3],
            decoded[4],
        )

    # Phoenix.Socket.V2.JSONSerializer binary PUSH:
    # [0, join_ref_size, ref_size, topic_size, event_size, ...UTF-8 fields, bytes]
    if opcode == 2 and len(data) >= 5 and data[0] == 0:
        lengths = data[1:5]
        total = 5 + sum(lengths)
        if total > len(data):
            raise ValueError("truncated Phoenix binary push header")
        fields = []
        offset = 5
        for n in lengths:
            fields.append(data[offset : offset + n].decode("utf-8"))
            offset += n
        return (
            "phoenix-binary",
            fields[0],
            fields[1],
            fields[2],
            fields[3],
            data[offset:],
        )

    # Do not log whole frames: the body can contain camera-specific identifiers.
    # The prefix is enough to distinguish JSON, Phoenix binary and other codecs.
    raise ValueError(
        f"unrecognized Phoenix message: ws_opcode={opcode}, "
        f"length={len(data)}, prefix_hex={data[:12].hex()}"
    )


def response_phoenix(style, join_ref, ref, topic, payload):
    reply = {"status": "ok", "response": {}}
    if style in ("array", "array-binary", "phoenix-binary"):
        return json.dumps(
            [join_ref, ref, topic, "phx_reply", reply], separators=(",", ":")
        ).encode("utf-8")
    response = {"topic": topic, "event": "phx_reply", "payload": reply, "ref": ref}
    return json.dumps(response, separators=(",", ":")).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    server_version = "FujiImportMacPoC/0.5"
    protocol_version = "HTTP/1.1"

    def log_message(self, format_string, *args):
        # Avoid logging token-bearing query strings and Authorization headers.
        pass

    def path_only(self):
        return urlsplit(self.path).path

    def reply(self, status, payload, extra_headers=None):
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        if extra_headers:
            for name, val in extra_headers.items():
                self.send_header(name, val)
        self.end_headers()
        self.wfile.write(data)

    def token(self):
        raw = self.headers.get("Authorization", "")
        if raw.lower().startswith("bearer "):
            return raw.split(" ", 1)[1].strip()
        return ""

    def auth(self):
        if self.server.store.valid(self.token()):
            return True
        self.reply(401, {"error": "unauthorized"})
        return False

    def body_dict(self):
        length = self.headers.get("Content-Length", "")
        if not length.isdecimal() or int(length) > MAX_JSON:
            raise ValueError("invalid JSON/form Content-Length")
        data = read_exact(self.rfile, int(length))
        content_type = self.headers.get("Content-Type", "").lower()
        if "application/json" in content_type:
            result = json.loads(data)
            if not isinstance(result, dict):
                raise ValueError("body should be object")
            return result
        if "application/x-www-form-urlencoded" in content_type or not content_type:
            return {
                k: v[0]
                for k, v in parse_qs(
                    data.decode("utf-8"), keep_blank_values=True
                ).items()
            }
        if "multipart/form-data" in content_type:
            from email.parser import BytesParser
            from email.policy import default

            message = BytesParser(policy=default).parsebytes(
                (
                    "MIME-Version: 1.0\r\nContent-Type: "
                    + self.headers.get("Content-Type")
                    + "\r\n\r\n"
                ).encode("ascii")
                + data
            )
            if not message.is_multipart():
                raise ValueError("invalid multipart")
            return {
                part.get_param("name", header="content-disposition"): part.get_payload(
                    decode=True
                ).decode("utf-8")
                for part in message.iter_parts()
                if part.get_content_disposition() == "form-data"
            }
        raise ValueError("unsupported body type")

    def do_GET(self):
        path = self.path_only()
        LOG.info("GET %s", path)
        if path == "/health":
            self.reply(200, {"ok": True})
        elif path == "/v2/devices/me":
            if self.auth():
                self.reply(200, identity())
        elif path == "/devices/websocket":
            self.websocket()
        elif path == "/api/status":
            self.reply(200, self.server.store.snapshot())
        else:
            self.reply(404, {"error": "unimplemented"})

    def do_POST(self):
        path = self.path_only()
        LOG.info("POST %s", path)
        if path in ("/v2/auth/device/code", "/v2/auth/token"):
            try:
                payload = self.body_dict()
                code, response = (
                    self.server.store.code(payload.get("client_id"))
                    if path.endswith("/code")
                    else self.server.store.token(payload)
                )
                self.reply(code, response)
            except (ValueError, EOFError, UnicodeError) as exc:
                LOG.warning("Invalid auth request (%s)", type(exc).__name__)
                self.reply(400, {"error": "invalid_request"})
            return
        if path in ("/v2/assets", "/v2/devices/assets"):
            if not self.auth():
                return
            try:
                result = self.server.store.create_asset(self.body_dict())
                self.reply(200, result)
            except (ValueError, TypeError, KeyError, EOFError) as exc:
                LOG.warning("Asset registration failed: %s", type(exc).__name__)
                self.reply(400, {"error": "invalid asset"})
            return
        self.reply(404, {"error": "unimplemented"})

    def do_PUT(self):
        path = self.path_only()
        LOG.info("PUT %s", path)
        if path != "/upload":
            self.reply(404, {"error": "unimplemented"})
            return
        query = parse_qs(urlsplit(self.path).query)
        asset_id = query.get("x-amz-meta-asset_id", [""])[0]
        try:
            part = int(query.get("x-amz-meta-part_number", [""])[0])
            n = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self.reply(411, {"error": "content length or part number missing"})
            return
        try:
            hexdigest = self.server.store.receive_part(asset_id, part, self.rfile, n)
        except (LookupError, ValueError, ConnectionError, OSError) as exc:
            LOG.warning(
                "Upload rejected id=%s part=%s type=%s",
                asset_id,
                part,
                type(exc).__name__,
            )
            self.reply(
                409 if isinstance(exc, ValueError) else 500,
                {"error": type(exc).__name__},
            )
            self.close_connection = True
            return
        # S3 PUT-style response; Roach returns text 'ok', documented S3 returns 200.
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.send_header("ETag", '"' + hexdigest + '"')
        self.end_headers()

    def websocket(self):
        query = parse_qs(urlsplit(self.path).query)
        auth_query = query.get("Authorization", [""])[0]
        value = auth_query or self.headers.get("Authorization", "")
        token = (
            value.partition(" ")[2].strip()
            if value.lower().startswith("bearer ")
            else ""
        )
        if not self.server.store.valid(token):
            self.reply(403, {"error": "unauthorized"})
            return
        if (
            self.headers.get("Upgrade", "").lower() != "websocket"
            or "upgrade" not in self.headers.get("Connection", "").lower()
        ):
            self.reply(426, {"error": "websocket upgrade required"})
            return
        key = self.headers.get("Sec-WebSocket-Key", "")
        try:
            if len(base64.b64decode(key, validate=True)) != 16:
                raise ValueError
        except (ValueError, binascii.Error):
            self.reply(400, {"error": "invalid ws key"})
            return
        accept = base64.b64encode(
            hashlib.sha1((key + GUID).encode("ascii")).digest()
        ).decode("ascii")
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.wfile.flush()
        LOG.info("WebSocket accepted peer=%s", self.client_address[0])
        self.connection.settimeout(65)
        fragment_opcode = None
        fragments = bytearray()
        try:
            while True:
                fin, opcode, payload = frame_read(self.rfile)
                LOG.info(
                    "WebSocket frame opcode=%d bytes=%d fin=%s",
                    opcode,
                    len(payload),
                    fin,
                )
                if opcode == 8:
                    frame_write(self.wfile, 8, payload[:125])
                    break
                if opcode == 9:
                    frame_write(self.wfile, 10, payload[:125])
                    continue
                if opcode == 10:
                    continue
                if opcode == 0:
                    if fragment_opcode is None:
                        raise ValueError("unexpected continuation frame")
                    fragments.extend(payload)
                    if len(fragments) > MAX_WS:
                        raise ValueError("fragmented message too large")
                    if not fin:
                        continue
                    opcode, payload = fragment_opcode, bytes(fragments)
                    fragment_opcode = None
                    fragments.clear()
                elif not fin:
                    if opcode not in (1, 2):
                        raise ValueError("unsupported fragmented message")
                    fragment_opcode = opcode
                    fragments = bytearray(payload)
                    continue
                style, join_ref, reference, topic, event, msg_payload = parse_phoenix(
                    payload, opcode
                )
                if not isinstance(topic, str) or not isinstance(event, str):
                    raise ValueError("invalid Phoenix topic/event")
                LOG.info("Phoenix %s topic=%s event=%s", style, topic[:72], event[:48])
                if event in ("phx_join", "heartbeat", "phx_leave"):
                    # Reply in the same WebSocket frame type for JSON-in-binary
                    # cameras; Phoenix's native binary PUSH accepts a JSON reply.
                    response_opcode = (
                        2 if style in ("object-binary", "array-binary") else 1
                    )
                    frame_write(
                        self.wfile,
                        response_opcode,
                        response_phoenix(
                            style, join_ref, reference, topic, msg_payload
                        ),
                    )
                # Ignore unknown events rather than dropping connection.
        except (
            EOFError,
            ConnectionError,
            OSError,
            ValueError,
            UnicodeError,
            json.JSONDecodeError,
        ) as exc:
            # This is the reason previous versions masked as a bare ValueError.
            LOG.info("WebSocket closed: %s: %s", type(exc).__name__, str(exc)[:160])
        finally:
            self.close_connection = True


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, store):
        super().__init__(addr, Handler)
        self.store = store


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "output")
    args = parser.parse_args()
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
    )
    store = Store(args.output)
    with Server((args.bind, args.port), store) as server:
        LOG.info("Fuji receiver %s:%s output=%s", args.bind, args.port, store.root)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
