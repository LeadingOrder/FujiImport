#!/usr/bin/env bash
# Run from FujiImport repository root. Installs FI-02 Mac-only, disposable lab files.
set -euo pipefail

if [[ ! -f poc/mac/receiver.py || ! -f docs/fuji-import-implementation-tickets.md ]]; then
    echo 'Run this from the FujiImport root (existing receiver.py and docs required).' >&2
    exit 1
fi

mkdir -p poc/mac/certs poc/mac/logs
# Ensure cert/private-key files never enter git even if initial bootstrap was edited.
if [[ ! -f .gitignore ]]; then touch .gitignore; fi
for entry in 'poc/mac/certs/' 'poc/mac/logs/'; do
    if ! grep -qxF "$entry" .gitignore; then
        printf '%s\n' "$entry" >> .gitignore
    fi
done

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

write_new poc/mac/tls_frontend.py <<'PYTHON'
#!/usr/bin/env python3
"""FI-02: short-lived TLS termination proxy for api.frame.io -> FI-01 HTTP.

Binds only to the selected LAN IP, accepts TLS on 443, streams decrypted bytes
unchanged to 127.0.0.1:8765. Private lab use only, no production hardening.
"""

import argparse
import logging
import socket
import socketserver
import ssl
import threading
from pathlib import Path

BLOCK = 64 * 1024


def relay(source, target):
    try:
        while True:
            data = source.recv(BLOCK)
            if not data:
                break
            target.sendall(data)
    except (ConnectionError, OSError, ssl.SSLError):
        pass
    finally:
        try:
            target.shutdown(socket.SHUT_WR)
        except OSError:
            pass


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        peer = self.client_address[0]
        try:
            with self.server.tls_context.wrap_socket(self.request, server_side=True) as secure:
                logging.info("TLS handshake from %s; %s", peer, secure.version())
                with socket.create_connection(self.server.backend, timeout=10) as backend:
                    secure.settimeout(60)
                    backend.settimeout(60)
                    forward = threading.Thread(target=relay, args=(secure, backend), daemon=True)
                    forward.start()
                    relay(backend, secure)
                    forward.join(timeout=2)
        except (ssl.SSLError, TimeoutError, OSError) as exc:
            logging.warning("TLS/relay error from %s: %s", peer, str(exc)[:180])


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", required=True, help="Mac's LAN IPv4 (not 0.0.0.0)")
    parser.add_argument("--port", type=int, default=443)
    parser.add_argument("--backend-host", default="127.0.0.1")
    parser.add_argument("--backend-port", type=int, default=8765)
    certs = Path(__file__).parent / "certs"
    parser.add_argument("--cert", type=Path, default=certs / "server.crt")
    parser.add_argument("--key", type=Path, default=certs / "server.key")
    args = parser.parse_args()
    if args.bind in ("0.0.0.0", "127.0.0.1"):
        parser.error("Use the Mac's LAN IPv4, not 0.0.0.0 or loopback")

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(str(args.cert), str(args.key))
    ctx.set_servername_callback(
        lambda _socket, name, _context: logging.info("TLS requested SNI: %s", name or "<none>")
    )
    with Server((args.bind, args.port), Handler) as server:
        server.tls_context = ctx
        server.backend = (args.backend_host, args.backend_port)
        logging.info("TLS lab listener %s:%s -> %s:%s", args.bind, args.port, *server.backend)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
PYTHON

write_new poc/mac/dns_lab.py <<'PYTHON'
#!/usr/bin/env python3
"""FI-02: disposable fail-closed DNS server for an X-E5 on the same LAN.

Only api.frame.io gets the Mac's IPv4 address. All other hostnames return
NXDOMAIN. Never forwards DNS queries to the public internet.
"""

import argparse
import ipaddress
import logging
import socket
import socketserver
import struct
import threading


def make_answer(data, target_ip):
    if len(data) < 12:
        return None
    ident, flags, qdcount, _, _, _ = struct.unpack("!HHHHHH", data[:12])
    if flags & 0x8000 or (flags & 0x7800) or qdcount != 1:
        return None

    labels = []
    pos = 12
    # Compression pointers in incoming questions are intentionally unsupported.
    for _ in range(128):
        if pos >= len(data):
            return None
        length = data[pos]
        pos += 1
        if length == 0:
            break
        if length > 63 or pos + length > len(data):
            return None
        try:
            labels.append(data[pos:pos + length].decode("ascii"))
        except UnicodeDecodeError:
            return None
        pos += length
    else:
        return None
    if pos + 4 > len(data):
        return None
    qtype, qclass = struct.unpack("!HH", data[pos:pos + 4])
    question = data[12:pos + 4]
    domain = ".".join(labels).lower()

    match = domain == "api.frame.io"
    answer = b""
    if match and qclass == 1 and qtype == 1:  # IN A
        answer = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 30, 4) + socket.inet_aton(target_ip)

    rcode = 0 if match else 3  # NOERROR / NXDOMAIN
    # Response, authoritative, repeat RD bit; recursion not available.
    reply_flags = 0x8400 | (flags & 0x0100) | rcode
    response = struct.pack("!HHHHHH", ident, reply_flags, 1, 1 if answer else 0, 0, 0)
    types = {1: "A", 28: "AAAA"}
    logging.info("DNS %-24s %-5s => %s", domain or "<root>", types.get(qtype, str(qtype)), target_ip if answer else ("NODATA" if match else "NXDOMAIN"))
    return response + question + answer


class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        query, sock = self.request
        reply = make_answer(query, self.server.target_ip)
        if reply is not None:
            sock.sendto(reply, self.client_address)


class TCPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        header = self._read_exact(2)
        if not header:
            return
        length = struct.unpack("!H", header)[0]
        query = self._read_exact(length)
        if not query:
            return
        response = make_answer(query, self.server.target_ip)
        if response is not None:
            self.request.sendall(struct.pack("!H", len(response)) + response)

    def _read_exact(self, count):
        chunks = bytearray()
        while len(chunks) < count:
            chunk = self.request.recv(count - len(chunks))
            if not chunk:
                return None
            chunks.extend(chunk)
        return bytes(chunks)


class UDPServer(socketserver.ThreadingUDPServer):
    allow_reuse_address = True
    daemon_threads = True


class TCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", required=True, help="Mac's LAN IPv4")
    parser.add_argument("--port", type=int, default=53)
    args = parser.parse_args()
    parsed = ipaddress.ip_address(args.bind)
    if parsed.version != 4 or parsed.is_loopback or parsed.is_unspecified:
        parser.error("Use Mac's concrete LAN IPv4")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    with UDPServer((args.bind, args.port), UDPHandler) as udp, TCPServer((args.bind, args.port), TCPHandler) as tcp:
        udp.target_ip = tcp.target_ip = args.bind
        thread = threading.Thread(target=tcp.serve_forever, daemon=True)
        thread.start()
        logging.info("Fail-closed DNS running UDP+TCP %s:%d", args.bind, args.port)
        try:
            udp.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            tcp.shutdown()


if __name__ == "__main__":
    main()
PYTHON

write_new scripts/fi02-certs.sh <<'CERTS'
#!/usr/bin/env bash
# Generate disposable private CA + api.frame.io leaf certificate; run from FujiImport root.
set -euo pipefail
cd "$(dirname "$0")/.."
certdir='poc/mac/certs'
mkdir -p "$certdir"
if [[ -e "$certdir/ca.key" || -e "$certdir/server.key" ]]; then
    echo 'Certificates already exist; refusing to rotate keys. Move/remove them deliberately to regenerate.' >&2
    exit 1
fi
umask 077
cat > "$certdir/ca.cnf" <<'EOF'
[req]
prompt = no
distinguished_name = dn
x509_extensions = v3_ca
[dn]
CN = Fuji Import Disposable Test CA
[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
cat > "$certdir/server.ext" <<'EOF'
basicConstraints = critical, CA:FALSE
subjectAltName = DNS:api.frame.io
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF
openssl genrsa -out "$certdir/ca.key" 2048
openssl req -new -x509 -sha256 -days 30 -key "$certdir/ca.key" -out "$certdir/ca.crt" -config "$certdir/ca.cnf" -extensions v3_ca
openssl genrsa -out "$certdir/server.key" 2048
openssl req -new -sha256 -key "$certdir/server.key" -out "$certdir/server.csr" -subj '/CN=api.frame.io'
openssl x509 -req -sha256 -days 30 -in "$certdir/server.csr" -CA "$certdir/ca.crt" -CAkey "$certdir/ca.key" -set_serial 1 -extfile "$certdir/server.ext" -out "$certdir/server.crt"
cp "$certdir/ca.crt" "$certdir/ca.pem"
chmod 600 "$certdir"/*.key
printf '\nGenerated: %s/ca.crt (PUBLIC certificate to import into camera)\n' "$certdir"
printf 'Do NOT copy ca.key or server.key to the camera, share them, or commit them.\n'
openssl x509 -in "$certdir/server.crt" -noout -subject -issuer -ext subjectAltName
CERTS

write_new docs/mac-fi02.md <<'GUIDE'
# FI-02 — X-E5 → Mac HTTPS connection (temporary test only)

This is a standalone local lab. It does not change the Raspberry Pi, router or
Mac system-wide DNS. FI-03 pairing and uploads are **not** implemented yet.

## Prerequisites

- Existing FI-01 receiver running on port 8765.
- Mac and camera on the same LAN; camera-to-LAN connectivity confirmed.
- Use one camera test profile; note old settings before changing them.
- Camera firmware version recorded in `docs/mac-poc.md`.

## 1. Generate a private test CA and server certificate

```bash
./scripts/fi02-certs.sh
```

This generates `poc/mac/certs/ca.pem` (PUBLIC CA) and private keys
`ca.key` and `server.key`. The entire `certs/` directory is gitignored.
Copy **only `ca.pem`** to the SD card. Never copy private keys.

## 2. Record Mac LAN IP

```bash
MAC_IF=$(route -n get default | awk '/interface:/{print $2;exit}')
MAC_IP=$(ipconfig getifaddr "$MAC_IF")
echo "$MAC_IF $MAC_IP"
sysctl -n net.inet.ip.forwarding
```

IP forwarding should be `0` for the offline-gateway test. If `1`, stop and
investigate rather than relying on the Mac to block WAN access.

## 3. Run three processes in separate terminals

Receiver (already running; keep it running):

```bash
python3 poc/mac/receiver.py --bind 127.0.0.1 --port 8765
```

Check no other program is listening on ports 443 and 53:

```bash
sudo lsof -nP -iTCP:443 -sTCP:LISTEN
sudo lsof -nP -iTCP:53 -sTCP:LISTEN
sudo lsof -nP -iUDP:53
```

TLS front end (TCP 443):

```bash
sudo "$(command -v python3)" poc/mac/tls_frontend.py --bind "$MAC_IP"
```

Fail-closed DNS (UDP+TCP 53):

```bash
sudo "$(command -v python3)" poc/mac/dns_lab.py --bind "$MAC_IP"
```

Both services listen **only on the specified Mac LAN IP**.

## 4. Test without the camera

```bash
curl --cacert poc/mac/certs/ca.crt \
    --resolve "api.frame.io:443:$MAC_IP" \
    https://api.frame.io/health

dig @"$MAC_IP" api.frame.io A +short
dig @"$MAC_IP" example.org A +noall +comments
```

Expected: JSON `status: ok` from HTTPS; DNS returns the Mac IP for
`api.frame.io`; other domains return NXDOMAIN. The curl test uses no external
Frame.io servers.

## 5. Camera configuration

- Copy `poc/mac/certs/ca.pem` to the card (ideally card root, without modifying photos).
- X-E5: NETWORK/USB SETTING → Frame.io Camera to Cloud → UPLOAD SETTING →
  ROOT CERTIFICATE → LOAD FROM STORAGE MEDIA; select the test CA.
- X-E5: NETWORK/USB SETTING → NETWORK SETTING → registered home Wi-Fi → EDIT →
  IP ADDRESS SETTING → MANUAL. Use a genuinely free static IPv4 on your LAN,
  the correct subnet mask, `GATEWAY ADDRESS = MAC_IP`, and
  `DNS SERVER ADDRESS = MAC_IP`.
- A Mac gateway with IP forwarding disabled prevents ordinary IPv4 WAN access
  from the camera while permitting direct access to the Mac. It is **not** a
  substitute for checking other routes, IPv6, or external IP traffic.
- Use Frame.io Camera to Cloud → CONNECT to trigger an attempt.

At FI-02, a 404 or failed Frame.io pairing **after an observed HTTPS request** is
expected: the pairing API is FI-03. Record SNI, DNS lookups and request paths
without copying tokens or personal photo contents into documentation.

If the camera cannot find/import the certificate, do not guess success: record
the camera message and research its certificate file-format expectations.

## Rollback

1. Stop both services with Ctrl+C; stop the receiver when finished.
2. Restore camera IP ADDRESS SETTING to AUTO (or its original configuration).
3. On camera ROOT CERTIFICATE → DELETE to remove the test CA.
4. Optionally remove the temporary public cert from the SD card.
5. No router, global Mac resolver, Pi or Nextcloud setting should have changed.

Do **not** expose the test certificate private key, make router-wide DNS changes,
or interpret failed pairing as an FI-02 failure if HTTPS requests arrived.
GUIDE

chmod +x scripts/fi02-certs.sh
cat <<'EOF'

FI-02 scaffold installed (existing files preserved).

From repo root:
    ./scripts/fi02-certs.sh

Then follow the accompanying FI-02 setup instructions for DNS, HTTPS,
and manual X-E5 network settings. Nothing modified system DNS or the router.
EOF
