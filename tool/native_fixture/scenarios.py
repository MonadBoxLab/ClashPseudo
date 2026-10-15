"""受控完整配置；不依赖外部订阅、GeoIP 或公共 DNS。"""


def provider(host, port):
    return f"proxies:\n  - {{name: fixture, type: socks5, server: {host}, port: {port + 3}}}\n".encode()


def mode_configuration(host, port):
    return configuration(host, port).replace(b"mode: rule", b"mode: direct").replace(
        b"proxy-groups:\n", b"proxy-groups:\n  - {name: GLOBAL, type: select, proxies: [REJECT]}\n")


def strategy_configuration(host, port, *, changing=False):
    body = configuration(host, port).replace(
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


def configuration(host, port, *, direct=False, revision=1):
    # 故意带常见平台字段：应用必须托管它们，但不能修改保存的原文。
    route = "DIRECT" if direct else "测试🌐"
    return f"""# fixture revision {revision}
mode: rule
log-level: info
mixed-port: 17890
external-controller: 127.0.0.1:19090
tun:
  enable: true
ipv6: false
dns:
  enable: true
  ipv6: false
  enhanced-mode: redir-host
  use-hosts: false
  use-system-hosts: false
  nameserver: ["udp://{host}:{port + 2}"]
  default-nameserver: ["{host}:{port + 2}"]
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
  - DST-PORT,{port + 4},REJECT
  - DST-PORT,{port},{route}
  - MATCH,DIRECT
""".encode()
