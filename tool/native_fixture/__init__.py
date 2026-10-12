"""受控 fixture 服务的创建与关闭。"""
import http.server
import threading

from .http_server import HTTP
from .network_servers import DNS, SOCKS, Echo, RejectTarget, TCPServer, UDPServer, event


class Fixture:
    def __init__(self, host, port):
        self.host = host
        self.stopped = threading.Event()
        self.lock = threading.Lock()
        self.requests = {}
        self.servers = []
        self.threads = []
        try:
            server = http.server.ThreadingHTTPServer((host, port), HTTP)
            self.servers.append(server)
            self.port = server.server_port
            for server_type, handler, delta in [(UDPServer, Echo, 1), (UDPServer, DNS, 2),
                                                (TCPServer, SOCKS, 3), (TCPServer, RejectTarget, 4)]:
                self.servers.append(server_type((host, self.port + delta), handler))
            for server in self.servers:
                server.fixture = self
        except Exception:
            for server in self.servers:
                server.server_close()
            raise

    def start(self):
        for server in self.servers:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            self.threads.append(thread)
        event("ready", host=self.host, http=self.port, udp=self.port + 1,
              dns=self.port + 2, socks=self.port + 3, reject=self.port + 4)

    def close(self):
        self.stopped.set()
        for server in self.servers:
            server.shutdown()
            server.server_close()
        for thread in self.threads:
            thread.join()
        event("closed")
