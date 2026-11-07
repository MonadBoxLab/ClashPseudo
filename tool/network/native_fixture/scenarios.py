"""Controlled complete configurations without external subscriptions, GeoIP, or public DNS."""


def provider(fixture):
    return f"proxies:\n  - {{name: fixture, type: socks5, server: {fixture.host}, port: {fixture.socks_port}}}\n".encode()


def mode_configuration(fixture):
    return configuration(fixture).replace(b"mode: rule", b"mode: direct").replace(
        b"proxy-groups:\n", b"proxy-groups:\n  - {name: GLOBAL, type: select, proxies: [REJECT]}\n")


def strategy_configuration(fixture, *, changing=False):
    host, port = fixture.host, fixture.port
    body = configuration(fixture).replace(
        b"proxy-groups:\n",
        "proxy-groups:\n  - {name: 父策略, type: select, proxies: [测试🌐, 自动🌐]}\n".encode())
    body = body.replace(b"    use: [local]\n", f"""    proxies: [DIRECT, REJECT]
    use: [local]
  - name: 自动🌐
    type: url-test
    proxies: [DIRECT, REJECT]
    url: http://{host}:{port}/ok/health
    interval: 3600
    lazy: true
  - name: 故障转移
    type: fallback
    proxies: [DIRECT, REJECT]
    url: http://{host}:{port}/ok/health
    interval: 3600
    lazy: true
  - name: 均衡
    type: load-balance
    proxies: [DIRECT, REJECT]
    url: http://{host}:{port}/ok/health
    interval: 3600
    lazy: true
  - {{name: 隐藏, type: select, hidden: true, proxies: [DIRECT]}}
""".encode())
    if changing:
        body = body.replace(b"/provider\n", b"/strategy-provider-update\n")
        body = body.replace(b"interval: 3600", b"interval: 2", 1)
    return body


def icon_configuration(fixture):
    host, port = fixture.host, fixture.port
    body = strategy_configuration(fixture).replace(
        b"proxy-groups:\n", f"""proxy-groups:
  - {{name: JPEG, type: select, icon: 'http://{host}:{port}/icons/color.jpg', proxies: [DIRECT]}}
  - {{name: WebP, type: select, icon: 'http://{host}:{port}/icons/color.webp', proxies: [DIRECT]}}
""".encode())
    for name, image in (("测试🌐", "color.svg"), ("自动🌐", "color.png"),
                        ("故障转移", "invalid.svg"), ("均衡", "missing.png")):
        body = body.replace(
            f"  - name: {name}\n".encode(),
            f"  - name: {name}\n    icon: http://{host}:{port}/icons/{image}\n".encode())
    return body


def configuration(fixture, *, direct=False, revision=1):
    host, port = fixture.host, fixture.port
    route = "DIRECT" if direct else "测试🌐"
    return f"""# fixture revision {revision}
mode: rule
log-level: info
tun:
  enable: true
ipv6: false
dns:
  enable: true
  ipv6: false
  enhanced-mode: redir-host
  use-hosts: false
  use-system-hosts: false
  nameserver: ["udp://{host}:{fixture.dns_port}"]
  default-nameserver: ["{host}:{fixture.dns_port}"]
  fallback-filter:
    geoip: false
proxy-providers:
  local:
    type: http
    url: http://{host}:{port}/provider
    path: ./provider.yaml
    interval: 3600
proxy-groups:
  - name: 测试🌐
    type: select
    use: [local]
rules:
  - DST-PORT,{fixture.reject_port},REJECT
  - DST-PORT,{port},{route}
  - MATCH,DIRECT
""".encode()
