"""受控服务必须关闭已接收的真实 socket 并等待处理线程退出。"""
import errno
import importlib.util
from pathlib import Path
import socket
import struct
import subprocess
import sys
import threading
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("fixture_entry", ROOT / "tool/network/native_fixture.py")
assert SPEC is not None and SPEC.loader is not None
ENTRY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ENTRY)
NETWORK = sys.modules["native_fixture.network_servers"]
SCENARIOS = sys.modules["native_fixture.scenarios"]
SELF_TEST = sys.modules["native_fixture.self_test"]


class NativeFixtureTest(unittest.TestCase):
    def test_specific_ipv4_nonce_and_dynamic_ports_are_required(self):
        for host, port, nonce in [("0.0.0.0", 0, "valid-fixture"), ("::", 0, "valid-fixture"),
                                  ("255.255.255.255", 0, "valid-fixture"),
                                  ("224.0.0.1", 0, "valid-fixture"),
                                  ("example.invalid", 0, "valid-fixture"),
                                  ("127.0.0.1", 18880, "valid-fixture"),
                                  ("127.0.0.1", 0, "../bad"), ("127.0.0.1", 0, "")]:
            with self.subTest(host=host, port=port, nonce=nonce), self.assertRaises(ValueError):
                ENTRY.Fixture(host, port, nonce)

    def test_explicit_host_is_not_tied_to_a_particular_network_or_replaced_on_bind_failure(self):
        package = sys.modules["native_fixture"]
        for host in ("192.0.2.17", "198.51.100.8"):
            with self.subTest(host=host), \
                    mock.patch.object(package, "HTTPServer", side_effect=OSError("address not assigned")) as bind, \
                    self.assertRaises(OSError):
                ENTRY.Fixture(host, 0, "valid-fixture")
            bind.assert_called_once_with((host, 0), package.HTTP)

    def test_binding_never_uses_implicit_reverse_dns(self):
        with mock.patch.object(socket, "getfqdn", side_effect=AssertionError("implicit DNS is forbidden")):
            fixture = ENTRY.Fixture("127.0.0.1", 0)
            try:
                self.assertEqual(fixture.servers[0].server_name, "127.0.0.1")
            finally:
                fixture.close()

    def test_constructor_bind_failure_or_cancellation_closes_prior_listeners(self):
        package = sys.modules["native_fixture"]
        original = package.HTTPServer
        created = []

        def capture(*args):
            server = original(*args)
            created.append(server)
            return server

        for error in (OSError("injected bind failure"), KeyboardInterrupt()):
            created.clear()
            with mock.patch.object(package, "HTTPServer", capture), mock.patch.object(package, "UDPServer", side_effect=error):
                with self.assertRaises(type(error)):
                    ENTRY.Fixture("127.0.0.1", 0)
            self.assertEqual(len(created), 1)
            self.assertEqual(created[0].socket.fileno(), -1)

    def test_dynamic_dns_udp_tcp_pair_and_emitted_configuration_use_actual_ports(self):
        fixture = ENTRY.Fixture("127.0.0.1", 0)
        fixture.start()
        try:
            SELF_TEST.check_datagrams(fixture)
            self.assertTrue(all(server.server_address[1] > 0 for server in fixture.servers))
            udp = [server for server in fixture.servers if isinstance(server, NETWORK.UDPServer)]
            tcp = [server for server in fixture.servers if isinstance(server, NETWORK.TCPServer)]
            self.assertEqual(len([server for server in udp if server.server_address[1] == fixture.dns_port]), 1)
            self.assertEqual(len([server for server in tcp if server.server_address[1] == fixture.dns_port]), 1)
            configuration = SCENARIOS.configuration(fixture)
            self.assertIn(f'"udp://{fixture.host}:{fixture.dns_port}"'.encode(), configuration)
            self.assertIn(f"port: {fixture.socks_port}".encode(), SCENARIOS.provider(fixture))
            self.assertNotIn(b"external-controller", configuration)
            self.assertNotIn(b"mixed-port:", configuration)
            packet = struct.pack("!HHHHHH", 19, 0x100, 1, 0, 0, 0) + b"\x07outside\x07invalid\x00" + struct.pack("!HH", 1, 1)
            with socket.create_connection((fixture.host, fixture.dns_port), 2) as sock:
                sock.sendall(struct.pack("!H", len(packet)) + packet)
                size = struct.unpack("!H", NETWORK.read_exact(sock, 2))[0]
                response = NETWORK.read_exact(sock, size)
                self.assertEqual(response[:2], b"\x00\x13")
                self.assertEqual(struct.unpack("!H", response[2:4])[0] & 15, 3)
        finally:
            fixture.close()

    def test_dns_dynamic_udp_does_not_reuse_an_existing_tcp_listener_port(self):
        package = sys.modules["native_fixture"]
        http, udp = package.HTTPServer, package.UDPServer
        created = []

        def bind_http(*arguments):
            server = http(*arguments)
            created.append(server)
            return server

        def bind_udp(address, handler):
            if handler is package.DNS and address[1] == 0:
                address = created[0].server_address
            return udp(address, handler)

        with mock.patch.object(package, "HTTPServer", bind_http), mock.patch.object(package, "UDPServer", bind_udp):
            fixture = ENTRY.Fixture("127.0.0.1", 0)
        try:
            self.assertNotEqual(fixture.dns_port, fixture.port)
            dns = [server for server in fixture.servers
                   if server.RequestHandlerClass in (package.DNS, package.DNSTCP)]
            self.assertEqual(len(dns), 2)
            self.assertTrue(all(server.server_address[1] == fixture.dns_port for server in dns))
        finally:
            fixture.close()
        self.assertTrue(all(server.socket.fileno() == -1 for server in fixture.servers))

    def test_dns_pair_reserves_both_protocols_before_later_tcp_listeners(self):
        package = sys.modules["native_fixture"]
        tcp, udp = package.TCPServer, package.UDPServer
        dns = []

        def bind_tcp(address, handler):
            if handler is package.DNSTCP:
                self.assertEqual(address[1], 0)
            else:
                self.assertEqual(len(dns), 2)
                self.assertEqual(dns[0].server_address, dns[1].server_address)
            server = tcp(address, handler)
            if handler is package.DNSTCP:
                dns.append(server)
            return server

        def bind_udp(address, handler):
            if handler is package.DNS:
                self.assertEqual(len(dns), 1)
                self.assertEqual(address, dns[0].server_address)
            server = udp(address, handler)
            if handler is package.DNS:
                dns.append(server)
            return server

        with mock.patch.object(package, "TCPServer", bind_tcp), mock.patch.object(package, "UDPServer", bind_udp):
            fixture = ENTRY.Fixture("127.0.0.1", 0)
        try:
            self.assertEqual(len(fixture.servers), 6)
            self.assertEqual(fixture.dns_port, dns[0].server_address[1])
            self.assertEqual(len({fixture.port, fixture.dns_port, fixture.socks_port, fixture.reject_port}), 4)
            self.assertTrue(all(server.socket.fileno() >= 0 for server in fixture.servers))
        finally:
            fixture.close()
        self.assertTrue(all(server.socket.fileno() == -1 for server in fixture.servers))

    def test_udp_listeners_do_not_share_another_reusable_socket(self):
        fixture = ENTRY.Fixture("127.0.0.1", 0)
        try:
            for server in fixture.servers:
                if isinstance(server, NETWORK.UDPServer):
                    with self.subTest(address=server.server_address), socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as other:
                        self.assertEqual(server.socket.getsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR), 0)
                        other.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                        with self.assertRaises(OSError) as failure:
                            other.bind(server.server_address)
                        self.assertEqual(failure.exception.errno, errno.EADDRINUSE)
        finally:
            fixture.close()

    def test_dns_pair_conflicts_close_candidates_and_keep_the_exhausted_bind_error(self):
        package = sys.modules["native_fixture"]
        tcp, udp, http = package.TCPServer, package.UDPServer, package.HTTPServer
        for conflicts in (1, 16):
            with self.subTest(conflicts=conflicts), socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as occupied:
                occupied.bind(("127.0.0.1", 0))
                blocked = occupied.getsockname()
                created, candidates, failures = [], [], []

                def bind_http(*arguments):
                    server = http(*arguments)
                    created.append(server)
                    return server

                def bind_tcp(address, handler):
                    if handler is package.DNSTCP and len(candidates) < conflicts:
                        address = blocked
                    server = tcp(address, handler)
                    created.append(server)
                    if handler is package.DNSTCP:
                        candidates.append(server)
                    return server

                def bind_udp(address, handler):
                    try:
                        server = udp(address, handler)
                    except OSError as error:
                        failures.append(error)
                        raise
                    created.append(server)
                    return server

                fixture = None
                try:
                    with mock.patch.object(package, "HTTPServer", bind_http), \
                            mock.patch.object(package, "TCPServer", bind_tcp), mock.patch.object(package, "UDPServer", bind_udp):
                        if conflicts == 16:
                            with self.assertRaises(OSError) as failure:
                                fixture = ENTRY.Fixture("127.0.0.1", 0)
                            self.assertIs(failure.exception, failures[-1])
                            self.assertEqual(failure.exception.errno, errno.EADDRINUSE)
                            self.assertEqual(len(candidates), 16)
                            self.assertTrue(all(server.socket.fileno() == -1 for server in created))
                        else:
                            fixture = ENTRY.Fixture("127.0.0.1", 0)
                            self.assertGreaterEqual(len(candidates), 2)
                            self.assertLessEqual(len(candidates), 16)
                            self.assertTrue(all(server.socket.fileno() == -1 for server in candidates[:-1]))
                            self.assertEqual(fixture.dns_port, candidates[-1].server_address[1])
                            self.assertNotEqual(fixture.dns_port, blocked[1])
                            self.assertTrue(all(server.socket.fileno() >= 0 for server in fixture.servers))
                    self.assertEqual(len(failures), len(candidates) - (fixture is not None))
                    self.assertTrue(all(error.errno == errno.EADDRINUSE for error in failures))
                    self.assertEqual(occupied.getsockname(), blocked)
                finally:
                    if fixture is not None:
                        fixture.close()
                self.assertTrue(all(server.socket.fileno() == -1 for server in created))

    def test_dns_pair_other_bind_errors_and_cancellation_close_the_tcp_candidate(self):
        package = sys.modules["native_fixture"]
        tcp, udp, http = package.TCPServer, package.UDPServer, package.HTTPServer
        for error in (OSError(errno.EACCES, "injected DNS UDP bind failure"), KeyboardInterrupt()):
            with self.subTest(error=type(error).__name__):
                created = []

                def capture(server_type):
                    def bind(address, handler):
                        if handler is package.DNS:
                            raise error
                        server = server_type(address, handler)
                        created.append(server)
                        return server
                    return bind

                with mock.patch.object(package, "HTTPServer", capture(http)), \
                        mock.patch.object(package, "TCPServer", capture(tcp)), \
                        mock.patch.object(package, "UDPServer", capture(udp)):
                    with self.assertRaises(type(error)) as failure:
                        ENTRY.Fixture("127.0.0.1", 0)
                self.assertIs(failure.exception, error)
                self.assertEqual(len(created), 3)
                self.assertTrue(all(server.socket.fileno() == -1 for server in created))

    def test_cli_rejects_invalid_host_lifetime_and_fixed_ports(self):
        for arguments in (["--host", "0.0.0.0", "--nonce", "valid-fixture"],
                          ["--host", "127.0.0.1", "--nonce", "valid-fixture", "--seconds", "301"],
                          ["--host", "127.0.0.1", "--nonce", "valid-fixture", "--port", "18880"]):
            with self.subTest(arguments=arguments):
                value = subprocess.run([sys.executable, "-I", str(ROOT / "tool/network/native_fixture.py"), *arguments],
                                       capture_output=True, timeout=5)
                self.assertEqual(value.returncode, 2)

    def test_close_before_start_and_repeated_close_release_every_listener(self):
        fixture = ENTRY.Fixture("127.0.0.1", 0)
        fixture.close()
        fixture.close()
        self.assertTrue(all(server.socket.fileno() == -1 for server in fixture.servers))
        with self.assertRaises(RuntimeError):
            fixture.start()

    def test_partial_start_failure_joins_started_server_and_closes_all_listeners(self):
        fixture = ENTRY.Fixture("127.0.0.1", 0)
        start = threading.Thread.start
        started = []

        def fail_second(thread):
            if started:
                raise RuntimeError("injected thread start failure")
            start(thread)
            started.append(thread)

        try:
            with mock.patch.object(threading.Thread, "start", fail_second):
                with self.assertRaisesRegex(RuntimeError, "injected"):
                    fixture.start()
            self.assertTrue(all(not thread.is_alive() for thread in started))
            self.assertTrue(all(server.socket.fileno() == -1 for server in fixture.servers))
            self.assertTrue(fixture.closed)
        finally:
            fixture.close()

    def test_admission_limit_and_stop_do_not_need_an_eleventh_network_connection(self):
        fixture = ENTRY.Fixture("127.0.0.1", 0)
        tokens = [object() for _ in range(11)]
        try:
            self.assertTrue(all(fixture.accept_socket(token) for token in tokens[:10]))
            self.assertFalse(fixture.accept_socket(tokens[10]))
            fixture.release_socket(tokens[0])
            self.assertTrue(fixture.accept_socket(tokens[10]))
            fixture.stopped.set()
            self.assertFalse(fixture.accept_socket(tokens[0]))
        finally:
            for token in tokens:
                fixture.release_socket(token)
            fixture.close()

    def test_close_joins_partial_http_header_and_live_response(self):
        fixture = ENTRY.Fixture("127.0.0.1", 0)
        clients = []
        workers = []
        before = set(threading.enumerate())
        fixture.start()
        try:
            partial = socket.create_connection((fixture.host, fixture.port), 2)
            clients.append(partial)
            partial.sendall(b"GET /ok/partial HTTP/1.1\r\nHost:")
            active = socket.create_connection((fixture.host, fixture.port), 2)
            clients.append(active)
            active.settimeout(2)
            active.sendall(b"GET /hold/join HTTP/1.0\r\n\r\n")
            self.assertIn(b"200", active.recv(1024))
            deadline = time.monotonic() + 2
            while len(workers) < 2:
                workers = [thread for thread in threading.enumerate()
                           if thread not in before and thread not in fixture.threads
                           and "process_request_thread" in thread.name]
                self.assertLess(time.monotonic(), deadline)
                time.sleep(.01)
            fixture.close()
            self.assertTrue(all(not thread.is_alive() for thread in fixture.threads))
            self.assertTrue(all(not thread.is_alive() for thread in workers),
                            "close returned while an accepted HTTP request was still running")
        finally:
            for client in clients:
                client.close()
            # Also release the negative-control implementation's leaked workers.
            for worker in workers:
                worker.join(2)
            fixture.close()


if __name__ == "__main__":
    unittest.main()
