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
            with self.server.tls_context.wrap_socket(
                self.request, server_side=True
            ) as secure:
                logging.info("TLS handshake from %s; %s", peer, secure.version())
                with socket.create_connection(
                    self.server.backend, timeout=10
                ) as backend:
                    secure.settimeout(60)
                    backend.settimeout(60)
                    forward = threading.Thread(
                        target=relay, args=(secure, backend), daemon=True
                    )
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

    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
    )
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.maximum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(str(args.cert), str(args.key))
    ctx.set_servername_callback(
        lambda _socket, name, _context: logging.info(
            "TLS requested SNI: %s", name or "<none>"
        )
    )
    with Server((args.bind, args.port), Handler) as server:
        server.tls_context = ctx
        server.backend = (args.backend_host, args.backend_port)
        logging.info(
            "TLS lab listener %s:%s -> %s:%s", args.bind, args.port, *server.backend
        )
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
