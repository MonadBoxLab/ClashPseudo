"""只面向 fixture 自身端点的 TCP、UDP、DNS 与 SOCKS 服务。"""
import contextlib
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


class TCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class UDPServer(socketserver.ThreadingUDPServer):
    allow_reuse_address = True
    daemon_threads = True


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        if len(data) <= 512:
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
            response += b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 1, 4)
            response += socket.inet_aton(self.server.fixture.host)
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
