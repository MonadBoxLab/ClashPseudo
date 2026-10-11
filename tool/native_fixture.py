#!/usr/bin/env python3
"""受控原生接入 fixture；只代理到自身 HTTP 端点，不提供通用代理。"""
import argparse
import contextlib
import http.server
import ipaddress
import json
import select
import signal
import socket
import socketserver
import struct
import threading
import time
import urllib.request


def event(kind, **fields):
    print(json.dumps({"time": time.time(), "kind": kind, **fields}), flush=True)


def read_exact(sock, count):
    result = bytearray()
    while len(result) < count:
        chunk = sock.recv(count - len(result))
        if not chunk:
            raise EOFError("short socket read")
        result.extend(chunk)
    return bytes(result)


class TCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class UDPServer(socketserver.ThreadingUDPServer):
    allow_reuse_address = True
    daemon_threads = True


class Fixture:
    def __init__(self, host, port):
        self.host = host
        self.stopped = threading.Event()
        self.servers = []
        owner = self

        class HTTP(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                event("http", path=self.path)
                if self.path == "/slow-provider":
                    owner.stopped.wait(8)
                if self.path in ("/provider", "/slow-provider"):
                    body = f"proxies:\n  - {{name: fixture, type: socks5, server: {host}, port: {owner.port + 3}}}\n".encode()
                elif self.path.startswith("/ok/"):
                    body = self.path.removeprefix("/ok/").encode()
                elif self.path.startswith("/hold/"):
                    self.send_response(200)
                    self.end_headers()
                    try:
                        while not owner.stopped.wait(0.2):
                            self.wfile.write(b"tick\n")
                            self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError):
                        event("hold_closed", path=self.path)
                    return
                else:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                    self.wfile.write(body)

        class Echo(socketserver.BaseRequestHandler):
            def handle(self):
                data, sock = self.request
                if len(data) > 512:
                    return
                event("udp", payload=data.decode(errors="replace"))
                sock.sendto(data, self.client_address)

        class DNS(socketserver.BaseRequestHandler):
            def handle(self):
                data, sock = self.request
                if len(data) < 12 or len(data) > 512 or struct.unpack("!H", data[4:6])[0] != 1:
                    return
                offset, labels = 12, []
                try:
                    while data[offset]:
                        size = data[offset]
                        if size > 63 or offset + size + 1 >= len(data):
                            return
                        labels.append(data[offset + 1:offset + size + 1].decode("ascii"))
                        offset += size + 1
                    offset += 1
                    qtype, qclass = struct.unpack("!HH", data[offset:offset + 4])
                except (IndexError, UnicodeError, struct.error):
                    return
                name = ".".join(labels).lower()
                event("dns", name=name, qtype=qtype)
                allowed = name.endswith(".fixture.test")
                answer = allowed and qtype == 1 and qclass == 1
                flags = 0x8180 if allowed else 0x8183
                response = data[:2] + struct.pack("!HHHHH", flags, 1, int(answer), 0, 0)
                response += data[12:offset + 4]
                if answer:
                    response += b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 1, 4) + socket.inet_aton(host)
                sock.sendto(response, self.client_address)

        class SOCKS(socketserver.BaseRequestHandler):
            def handle(self):
                client = self.request
                client.settimeout(5)
                try:
                    version, count = read_exact(client, 2)
                    methods = read_exact(client, count)
                    if version != 5 or 0 not in methods:
                        client.sendall(b"\x05\xff")
                        return
                    client.sendall(b"\x05\x00")
                    version, command, reserved, kind = read_exact(client, 4)
                    if (version, command, reserved) != (5, 1, 0):
                        return
                    if kind == 1:
                        address = socket.inet_ntoa(read_exact(client, 4))
                    elif kind == 3:
                        address = read_exact(client, read_exact(client, 1)[0]).decode("ascii")
                    else:
                        client.sendall(b"\x05\x08\x00\x01" + b"\x00" * 6)
                        return
                    target_port = struct.unpack("!H", read_exact(client, 2))[0]
                    if (address != host and not address.lower().endswith(".fixture.test")) or target_port != owner.port:
                        event("proxy_denied", address=address, port=target_port)
                        client.sendall(b"\x05\x02\x00\x01" + b"\x00" * 6)
                        return
                    event("proxy", address=address, port=target_port)
                    with socket.create_connection((host, owner.port), 5) as upstream:
                        client.sendall(b"\x05\x00\x00\x01" + b"\x00" * 6)
                        while not owner.stopped.is_set():
                            ready, _, _ = select.select([client, upstream], [], [], 1)
                            for source in ready:
                                chunk = source.recv(8192)
                                if not chunk:
                                    return
                                (upstream if source is client else client).sendall(chunk)
                except (OSError, EOFError, UnicodeError):
                    return

        class RejectTarget(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.settimeout(2)
                with contextlib.suppress(OSError):
                    payload = self.request.recv(512)
                    event("reject_target_reached", payload=payload.decode(errors="replace"))
                    self.request.sendall(b"unexpected")

        try:
            http_server = http.server.ThreadingHTTPServer((host, port), HTTP)
            self.servers.append(http_server)
            self.port = http_server.server_port
            for server_type, handler, delta in [(UDPServer, Echo, 1), (UDPServer, DNS, 2),
                                                (TCPServer, SOCKS, 3), (TCPServer, RejectTarget, 4)]:
                self.servers.append(server_type((host, self.port + delta), handler))
        except Exception:
            for server in self.servers:
                server.server_close()
            raise

    def start(self):
        for server in self.servers:
            threading.Thread(target=server.serve_forever, daemon=True).start()
        event("ready", host=self.host, http=self.port, udp=self.port + 1,
              dns=self.port + 2, socks=self.port + 3, reject=self.port + 4)

    def close(self):
        self.stopped.set()
        for server in self.servers:
            server.shutdown()
            server.server_close()
        event("closed")


def self_test():
    fixture = Fixture("127.0.0.1", 0)
    fixture.start()
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        assert opener.open(f"http://127.0.0.1:{fixture.port}/ok/self-test", timeout=3).read() == b"self-test"
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(3)
            sock.sendto(b"udp-test", (fixture.host, fixture.port + 1))
            assert sock.recv(64) == b"udp-test"
            question = b"\x04self\x07fixture\x04test\x00" + struct.pack("!HH", 1, 1)
            sock.sendto(struct.pack("!HHHHHH", 7, 0x100, 1, 0, 0, 0) + question, (fixture.host, fixture.port + 2))
            response = sock.recv(512)
            assert response[:2] == b"\x00\x07" and response[-4:] == socket.inet_aton(fixture.host)
        for address, target_port, expected in [(fixture.host, fixture.port, 0),
                                               ("self.fixture.test", fixture.port, 0),
                                               ("example.com", fixture.port, 2),
                                               (fixture.host, 9, 2)]:
            with socket.create_connection((fixture.host, fixture.port + 3), 3) as sock:
                sock.sendall(b"\x05\x01\x00")
                assert read_exact(sock, 2) == b"\x05\x00"
                encoded = address.encode("ascii")
                sock.sendall(b"\x05\x01\x00\x03" + bytes([len(encoded)]) + encoded + struct.pack("!H", target_port))
                assert read_exact(sock, 10)[1] == expected
                if expected == 0:
                    sock.sendall(b"GET /ok/proxy-test HTTP/1.0\r\n\r\n")
                    data = bytearray()
                    while chunk := sock.recv(4096):
                        data.extend(chunk)
                    assert data.endswith(b"proxy-test")
        event("self_test_passed")
    finally:
        fixture.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host")
    parser.add_argument("--port", type=int, default=18880)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.host:
        parser.error("--host 必须明确指定 loopback 或局域网 IPv4")
    address = ipaddress.ip_address(args.host)
    if address.version != 4 or not address.is_private or address.is_unspecified or address.is_multicast:
        parser.error("只允许绑定明确的本机私有 IPv4")
    if not 1024 <= args.port <= 65529:
        parser.error("端口必须在 1024..65529")
    fixture = Fixture(args.host, args.port)
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    fixture.start()
    try:
        stop.wait()
    finally:
        fixture.close()


if __name__ == "__main__":
    main()
