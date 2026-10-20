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
