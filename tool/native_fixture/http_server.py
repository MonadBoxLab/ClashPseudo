"""配置、更新与传输失败场景，以及原生网络探针端点。"""
import contextlib
import http.server
from urllib.parse import urlsplit

from .network_servers import event
from .scenarios import configuration, mode_configuration, provider, strategy_configuration


class HTTP(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        owner = self.server.fixture
        path = urlsplit(self.path).path
        with owner.lock:
            owner.requests[path] = owner.requests.get(path, 0) + 1
            count = owner.requests[path]
        event("http", path=path, request=count)
        if path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/config")
            self.end_headers()
            return
        if path in ("/slow-provider", "/slow-config"):
            owner.stopped.wait(8)
        if path in ("/provider", "/slow-provider"):
            body = provider(owner.host, owner.port)
        elif path in ("/config", "/slow-config", "/direct", "/update", "/update-fails"):
            if path == "/update-fails" and count > 1:
                self.send_error(503)
                return
            body = configuration(owner.host, owner.port, direct=path == "/direct", revision=count)
        elif path in ("/strategies", "/strategies-other", "/strategies-changing"):
            body = strategy_configuration(owner.host, owner.port, changing=path == "/strategies-changing")
        elif path == "/strategy-provider-update":
            body = provider(owner.host, owner.port)
            if count > 5:
                body = body.replace(b"name: fixture", b"name: replacement")
        elif path == "/modes":
            body = mode_configuration(owner.host, owner.port)
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
