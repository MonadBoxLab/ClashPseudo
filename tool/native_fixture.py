#!/usr/bin/env python3
"""受控原生接入 fixture；只代理到自身 HTTP 端点，不提供通用代理。"""
import argparse
import importlib.util
import ipaddress
from pathlib import Path
import signal
import sys
import threading

# -I 不从工作目录或脚本目录搜模块；仅加载入口旁的可信仓库包。
package = Path(__file__).resolve().with_suffix("")
spec = importlib.util.spec_from_file_location(
    "native_fixture", package / "__init__.py", submodule_search_locations=[str(package)])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
from native_fixture import Fixture
from native_fixture.self_test import self_test


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
