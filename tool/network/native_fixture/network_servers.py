"""TCP, UDP, DNS, and SOCKS servers restricted to fixture endpoints."""
import contextlib
import http.server
import json
import select
import socket
import socketserver
import struct
import time


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


class AcceptedTCP:
    daemon_threads = False

    def get_request(self):
        request, address = super().get_request()
        request.settimeout(5)
        if not self.fixture.accept_socket(request):
            request.close()
            raise OSError("fixture stopped or active connection limit reached")
        return request, address

    def shutdown_request(self, request):
        try:
            super().shutdown_request(request)
        finally:
            self.fixture.release_socket(request)


class HTTPServer(AcceptedTCP, http.server.ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer's default getfqdn would perform implicit host DNS I/O.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


class TCPServer(AcceptedTCP, socketserver.ThreadingTCPServer):
    allow_reuse_address = True


class UDPServer(socketserver.ThreadingUDPServer):
    allow_reuse_address = False
    daemon_threads = False


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        if len(data) <= 512:
            event("udp", payload=data.decode(errors="replace"))
            sock.sendto(data, self.client_address)


def dns_response(data, owner):
    if len(data) < 12 or len(data) > 4096 or struct.unpack("!H", data[4:6])[0] != 1:
        return None
    offset, labels = 12, []
    try:
        while data[offset]:
            size = data[offset]
            if size > 63 or offset + size + 1 >= len(data):
                return None
            labels.append(data[offset + 1:offset + size + 1].decode("ascii"))
            offset += size + 1
        offset += 1
        qtype, qclass = struct.unpack("!HH", data[offset:offset + 4])
    except (IndexError, UnicodeError, struct.error):
        return None
    if owner.stopped.is_set():
        return None
    name = ".".join(labels).lower()
    event("dns", nonce=owner.nonce, name=name, qtype=qtype)
    allowed = name.endswith(".fixture.test")
    answer = allowed and qtype == 1 and qclass == 1
    response = data[:2] + struct.pack("!HHHHH", 0x8180 if allowed else 0x8183, 1, int(answer), 0, 0)
    response += data[12:offset + 4]
    if answer:
        response += b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 1, 4) + socket.inet_aton(owner.host)
    return response


class DNS(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        response = dns_response(data, self.server.fixture)
        if response is not None:
            sock.sendto(response, self.client_address)


class DNSTCP(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            size = struct.unpack("!H", read_exact(self.request, 2))[0]
            if not 12 <= size <= 4096:
                return
            response = dns_response(read_exact(self.request, size), self.server.fixture)
            if response is not None:
                self.request.sendall(struct.pack("!H", len(response)) + response)
        except (OSError, EOFError, struct.error):
            return


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
            self.connect(address, struct.unpack("!H", read_exact(client, 2))[0])
        except (OSError, EOFError, UnicodeError):
            return

    def connect(self, address, port):
        owner = self.server.fixture
        if (address != owner.host and not address.lower().endswith(".fixture.test")) or port != owner.port:
            event("proxy_denied", address=address, port=port)
            self.request.sendall(b"\x05\x02\x00\x01" + b"\x00" * 6)
            return
        event("proxy", address=address, port=port)
        with socket.create_connection((owner.host, owner.port), 5) as upstream:
            self.request.sendall(b"\x05\x00\x00\x01" + b"\x00" * 6)
            while not owner.stopped.is_set():
                ready, _, _ = select.select([self.request, upstream], [], [], 1)
                for source in ready:
                    chunk = source.recv(8192)
                    if not chunk:
                        return
                    (upstream if source is self.request else self.request).sendall(chunk)


class RejectTarget(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(2)
        with contextlib.suppress(OSError):
            payload = self.request.recv(512)
            event("reject_target_reached", payload=payload.decode(errors="replace"))
            self.request.sendall(b"unexpected")
