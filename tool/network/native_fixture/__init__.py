"""受控 fixture 服务的创建与关闭。"""
import contextlib
import errno
import ipaddress
import re
import socket
import threading

from .http_server import HTTP
from .network_servers import DNS, DNSTCP, SOCKS, Echo, HTTPServer, RejectTarget, TCPServer, UDPServer, event


def ipv4_host(value):
    address = ipaddress.IPv4Address(value)
    if address.is_unspecified or address.is_multicast or int(address) == 0xffffffff:
        raise ValueError("fixture requires a specific IPv4 interface address")
    return str(address)


def _dns_servers(host):
    # TCP 与 UDP 分别分配动态端口；两种 socket 都绑定成功后才取得该端口对。
    for attempt in range(16):
        tcp = TCPServer((host, 0), DNSTCP)
        try:
            return tcp, UDPServer(tcp.server_address, DNS)
        except BaseException as error:
            tcp.server_close()
            if not isinstance(error, OSError) or error.errno != errno.EADDRINUSE or attempt == 15:
                raise


class Fixture:
    def __init__(self, host, port=0, nonce="fixture-self-test"):
        host = ipv4_host(host)
        if port != 0:
            raise ValueError("fixture requires dynamic ports")
        if not isinstance(nonce, str) or not re.fullmatch(r"[a-z0-9-]{8,48}", nonce):
            raise ValueError("fixture requires an explicit synthetic nonce")
        self.host = host
        self.nonce = nonce
        self.udp_port = self.dns_port = self.socks_port = self.reject_port = 0
        self.stopped = threading.Event()
        self.lock = threading.Lock()
        self.requests = {}
        self.accepted = set()
        self.servers = []
        self.started = []
        self.threads = []
        self.close_lock = threading.Lock()
        self.closed = False
        try:
            server = HTTPServer((host, port), HTTP)
            self.servers.append(server)
            self.port = server.server_port
            server = UDPServer((host, 0), Echo)
            self.servers.append(server)
            self.udp_port = server.server_address[1]
            dns_tcp, dns_udp = _dns_servers(host)
            self.servers.extend((dns_tcp, dns_udp))
            self.dns_port = dns_tcp.server_address[1]
            for attribute, handler in [("socks_port", SOCKS), ("reject_port", RejectTarget)]:
                server = TCPServer((host, 0), handler)
                self.servers.append(server)
                setattr(self, attribute, server.server_address[1])
            for server in self.servers:
                server.fixture = self
        except BaseException:
            for server in self.servers:
                server.server_close()
            raise

    def accept_socket(self, request):
        with self.lock:
            if self.stopped.is_set() or len(self.accepted) >= 10:
                return False
            self.accepted.add(request)
            return True

    def release_socket(self, request):
        with self.lock:
            self.accepted.discard(request)

    def start(self):
        if self.stopped.is_set() or self.threads:
            raise RuntimeError("fixture cannot be started twice or after close")
        try:
            for server in self.servers:
                thread = threading.Thread(target=server.serve_forever)
                thread.start()
                self.started.append(server)
                self.threads.append(thread)
        except BaseException:
            self.close()
            raise
        event("ready", nonce=self.nonce, host=self.host, http=self.port, udp=self.udp_port,
              dns=self.dns_port, socks=self.socks_port, reject=self.reject_port)

    def close(self):
        with self.close_lock:
            if self.closed:
                return
            self.stopped.set()
            for server in self.started:
                server.shutdown()
            with self.lock:
                accepted = tuple(self.accepted)
            for request in accepted:
                with contextlib.suppress(OSError):
                    request.shutdown(socket.SHUT_RDWR)
                request.close()
            # server_close等待全部请求线程，包括只收到部分HTTP头或SOCKS握手的请求。
            for server in self.servers:
                server.server_close()
            for thread in self.threads:
                thread.join()
            with self.lock:
                if self.accepted:
                    raise RuntimeError("accepted request did not finish")
            self.closed = True
            event("closed", tasksJoined=True, remainingAccepted=0)
