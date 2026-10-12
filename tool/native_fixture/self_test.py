"""fixture 自测：配置传输和仅限自身的网络服务。"""
import socket
import struct
import urllib.error
import urllib.request

from . import Fixture
from .network_servers import event, read_exact


def check_http(fixture):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    base = f"http://{fixture.host}:{fixture.port}"

    def get(path):
        with opener.open(base + path, timeout=3) as response:
            return response.read()

    assert get("/ok/self-test") == b"self-test"
    assert b"proxy-providers:" in get("/config")
    assert "测试🌐".encode() in get("/redirect")
    assert get("/invalid") == b"[invalid yaml"
    assert get("/empty") == b""
    assert get("/update") != get("/update")
    assert get("/update-fails")
    try:
        get("/update-fails")
        raise AssertionError("second update must fail")
    except urllib.error.HTTPError as error:
        assert error.code == 503
        error.close()


def check_datagrams(fixture):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(3)
        sock.sendto(b"udp-test", (fixture.host, fixture.port + 1))
        assert sock.recv(64) == b"udp-test"
        question = b"\x04self\x07fixture\x04test\x00" + struct.pack("!HH", 1, 1)
        sock.sendto(struct.pack("!HHHHHH", 7, 0x100, 1, 0, 0, 0) + question,
                    (fixture.host, fixture.port + 2))
        response = sock.recv(512)
        assert response[:2] == b"\x00\x07" and response[-4:] == socket.inet_aton(fixture.host)


def check_proxy(fixture):
    for address, port, expected in [(fixture.host, fixture.port, 0),
                                     ("self.fixture.test", fixture.port, 0),
                                     ("example.com", fixture.port, 2), (fixture.host, 9, 2)]:
        with socket.create_connection((fixture.host, fixture.port + 3), 3) as sock:
            sock.sendall(b"\x05\x01\x00")
            assert read_exact(sock, 2) == b"\x05\x00"
            encoded = address.encode("ascii")
            sock.sendall(b"\x05\x01\x00\x03" + bytes([len(encoded)]) + encoded + struct.pack("!H", port))
            assert read_exact(sock, 10)[1] == expected
            if expected == 0:
                sock.sendall(b"GET /ok/proxy-test HTTP/1.0\r\n\r\n")
                data = bytearray()
                while chunk := sock.recv(4096):
                    data.extend(chunk)
                assert data.endswith(b"proxy-test")


def self_test():
    fixture = Fixture("127.0.0.1", 0)
    fixture.start()
    try:
        check_http(fixture)
        check_datagrams(fixture)
        check_proxy(fixture)
        event("self_test_passed")
    finally:
        fixture.close()
