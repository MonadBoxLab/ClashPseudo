"""配置、更新与传输失败场景，以及原生网络探针端点。"""
import contextlib
import struct
import zlib
import http.server
from urllib.parse import urlsplit
from pathlib import Path

from .network_servers import event
from .scenarios import configuration, icon_configuration, mode_configuration, provider, strategy_configuration


def icon_image(path):
    if path in ("/icons/color.jpg", "/icons/color.webp"):
        name = path.rsplit("/", 1)[1]
        return ("image/jpeg" if name.endswith(".jpg") else "image/webp",
                (Path(__file__).parent / "images" / name).read_bytes())
    if path == "/icons/color.svg":
        return "image/svg+xml", b'<svg xmlns="http://www.w3.org/2000/svg" width="32" height="24"><rect width="32" height="24" rx="4" fill="#2468cc"/><circle cx="16" cy="12" r="8" fill="#1a7a64"/><path d="M13 7L22 12L13 17Z" fill="#ffffff"/></svg>'
    if path == "/icons/invalid.svg":
        return "image/svg+xml", b"<svg"
    if path == "/icons/color.png":
        def chunk(kind, data):
            return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data))
        pixels = b"".join(b"\x00" + bytes((36, 104, 204) if y < 12 else (26, 122, 100)) * 32 for y in range(24))
        return "image/png", (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!2I5B", 32, 24, 8, 2, 0, 0, 0))
                             + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))
    return None



class HTTP(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        owner = self.server.fixture
        if owner.stopped.is_set():
            return
        path = urlsplit(self.path).path
        with owner.lock:
            owner.requests[path] = owner.requests.get(path, 0) + 1
            count = owner.requests[path]
        event("http", path=path, request=count)
        image = icon_image(path)
        if image is not None:
            content_type, body = image
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                self.wfile.write(body)
            return
        if path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/config")
            self.end_headers()
            return
        if path in ("/slow-provider", "/slow-config"):
            owner.stopped.wait(8)
        if path in ("/provider", "/slow-provider"):
            body = provider(owner)
        elif path in ("/config", "/slow-config", "/direct", "/update", "/update-fails"):
            if path == "/update-fails" and count > 1:
                self.send_error(503)
                return
            body = configuration(owner, direct=path == "/direct", revision=count)
        elif path == "/icons-config":
            body = icon_configuration(owner)
        elif path in ("/strategies", "/strategies-other", "/strategies-changing"):
            body = strategy_configuration(owner, changing=path == "/strategies-changing")
        elif path == "/strategy-provider-update":
            body = provider(owner)
            if count > 5:
                body = body.replace(b"name: fixture", b"name: replacement")
        elif path == "/modes":
            body = mode_configuration(owner)
        elif path == "/invalid":
            body = b"[invalid yaml"
        elif path == "/empty":
            body = b""
        elif path.startswith("/ok/"):
            body = path.removeprefix("/ok/").encode()
        elif path.startswith("/hold/"):
            self.hold(path)
            return
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            self.wfile.write(body)

    def hold(self, path):
        self.send_response(200)
        self.end_headers()
        try:
            while not self.server.fixture.stopped.wait(0.2):
                self.wfile.write(b"tick\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            event("hold_closed", path=path)
