#!/usr/bin/env python3
"""提供合成 HTTP、UDP、DNS 及限定目标的 SOCKS 测试服务。"""
import argparse
import importlib.util
from pathlib import Path
import signal
import sys
import threading
import time

# 在 -I 环境中通过入口文件位置加载项目包。
package = Path(__file__).resolve().with_suffix("")
spec = importlib.util.spec_from_file_location(
    "native_fixture", package / "__init__.py", submodule_search_locations=[str(package)])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
from native_fixture import Fixture, ipv4_host
from native_fixture.self_test import self_test


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", type=ipv4_host, help="显式提供服务绑定的本机 IPv4 地址")
    parser.add_argument("--nonce", help="合成请求标识，8..48 个小写字母、数字或连字符")
    parser.add_argument("--seconds", type=int, default=60, help="服务模式总生命周期 1..300 秒，含真实 close/join")
    parser.add_argument("--self-test", action="store_true", help="仅短时 loopback 自测，不访问外网")
    args = parser.parse_args()
    if args.self_test:
        if args.host or args.nonce:
            parser.error("--self-test 仅使用其内部 loopback 环境")
        self_test()
        return
    if not args.host or not args.nonce or not 1 <= args.seconds <= 300:
        parser.error("需要 --host、--nonce 和 1..300 秒的生命周期")
    started = time.monotonic()
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    fixture = Fixture(args.host, 0, args.nonce)
    try:
        if not stop.is_set():
            fixture.start()
            # 为关闭监听和等待请求线程退出预留时间。
            reserve = min(5, args.seconds / 2)
            stop.wait(max(0, args.seconds - reserve - (time.monotonic() - started)))
    finally:
        fixture.close()
    if time.monotonic() - started > args.seconds:
        raise RuntimeError("所有资源已退出，但总生命周期超出指定边界")


if __name__ == "__main__":
    main()
