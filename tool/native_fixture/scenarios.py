"""受控完整配置；不依赖外部订阅、GeoIP 或公共 DNS。"""


def provider(host, port):
    return f"proxies:\n  - {{name: fixture, type: socks5, server: {host}, port: {port + 3}}}\n".encode()


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
