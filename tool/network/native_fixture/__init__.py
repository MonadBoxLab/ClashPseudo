"""Creation and shutdown of controlled fixture servers."""
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
    # Allocate dynamic TCP and UDP ports; accept a port pair only after both sockets bind successfully.
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
            # server_close waits for all request threads, including partial HTTP headers or SOCKS handshakes.
            for server in self.servers:
                server.server_close()
            for thread in self.threads:
                thread.join()
            with self.lock:
                if self.accepted:
                    raise RuntimeError("accepted request did not finish")
            self.closed = True
            event("closed", tasksJoined=True, remainingAccepted=0)


def register_parser(subparsers):
    parser = subparsers.add_parser(
        "native-fixture", help="Provide HTTP, UDP, DNS, and target-restricted SOCKS test servers",
        description="Bind an explicit IPv4 address and dynamic ports, emit JSON events, and leave project inputs unchanged.",
        epilog="Example: network native-fixture --self-test; network native-fixture --host 127.0.0.1 --nonce test-run-123")
    parser.add_argument("--host", type=ipv4_host, help="Explicit local IPv4 address to bind servers to")
    parser.add_argument("--nonce", help="Synthetic request ID of 8..48 lowercase letters, digits, or hyphens")
    parser.add_argument("--seconds", type=int, default=60, help="Total server lifetime of 1..300 seconds, including close/join")
    parser.add_argument("--self-test", action="store_true", help="Run a short loopback-only self-test without external network access")
    parser.set_defaults(handler=run, validate_args=validate_args)


def validate_args(args, parser):
    if args.self_test:
        if args.host or args.nonce:
            parser.error("--self-test uses only the internal loopback environment")
    elif not args.host or not args.nonce or not re.fullmatch(r"[a-z0-9-]{8,48}", args.nonce):
        parser.error("Requires --host and a --nonce of 8..48 lowercase letters, digits, or hyphens")
    if not 1 <= args.seconds <= 300:
        parser.error("--seconds must be 1..300 seconds")


def run(args):
    if args.self_test:
        from .self_test import self_test
        self_test()
        return 0
    import signal
    import time
    started = time.monotonic()
    stop = threading.Event()
    previous = {number: signal.signal(number, lambda *_: stop.set())
                for number in (signal.SIGTERM, signal.SIGINT)}
    try:
        fixture = Fixture(args.host, 0, args.nonce)
        try:
            if not stop.is_set():
                fixture.start()
                # Reserve time to close listeners and join request threads.
                reserve = min(5, args.seconds / 2)
                stop.wait(max(0, args.seconds - reserve - (time.monotonic() - started)))
        finally:
            fixture.close()
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)
    if time.monotonic() - started > args.seconds:
        raise RuntimeError("All resources exited, but the total lifetime exceeded the specified limit")
    return 0
