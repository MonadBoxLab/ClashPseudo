import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'package:clash_pseudo/src/logic/overrides/lan_proxy_settings.dart';
import 'package:clash_pseudo/src/model/lan_proxy.dart';

void main() {
  test('default mixed listener serves TCP and UDP on the same port without authentication', () {
    final body = LanProxySettings(addresses: ['192.168.1.2']).applyTo('');
    final root = loadYaml(body) as YamlMap;
    final listener = (root['listeners'] as YamlList).single as YamlMap;
    expect(listener['type'], 'mixed');
    expect(listener['listen'], '192.168.1.2');
    expect(listener['port'], 7890);
    expect(listener['udp'], isTrue);
    expect(listener['users'], isEmpty);
  });

  test('changing port and UDP preserves unknown fields, authentication, and other listeners', () {
    final name = LanProxySettings.listenerName('192.168.1.2');
    final original =
        '''# 保留说明
extension: unchanged
listeners:
  - name: $name
    type: mixed
    listen: 192.168.1.2
    port: 7890
    udp: true
    users: [{username: user, password: pass}]
    extra: '007' # 保留字段
  - name: other
    type: http
    listen: 127.0.0.1
    port: 8080
''';
    final body = LanProxySettings(
      addresses: ['192.168.1.2'],
      port: 9000,
      udp: false,
    ).applyTo(original);
    expect(body, contains("extra: '007' # 保留字段"));
    expect(body, contains('users: [{username: user, password: pass}]'));
    expect(body, contains('extension: unchanged'));
    final rows = (loadYaml(body) as YamlMap)['listeners'] as YamlList;
    expect(rows.last['name'], 'other');
    expect(rows.first['port'], 9000);
    expect(rows.first['udp'], false);
  });

  test('IPv6 scope is preserved in source text and copied addresses', () {
    const address = 'fe80::1234%wlan0';
    final settings = LanProxySettings(addresses: [address]);
    final body = settings.applyTo('');
    expect(LanProxySettings.fromBody(body).addresses, [address]);
    expect(lanEndpoint(address, 7890), '[fe80::1234%wlan0]:7890');
  });

  test('the form cannot save wildcard, loopback, or duplicate addresses', () {
    for (final address in ['0.0.0.0', '::', '127.0.0.1', '::1', '*']) {
      expect(
        () => LanProxySettings(addresses: [address]),
        throwsFormatException,
      );
    }
    expect(
      () => LanProxySettings(addresses: ['192.168.1.2', '192.168.1.2']),
      throwsFormatException,
    );
  });

  test('listeners unsupported by the form retain source text without rebuilding default configuration', () {
    final name = LanProxySettings.listenerName('192.168.1.2');
    final body =
        '''listeners:
  - name: $name
    type: socks
    listen: 192.168.1.2
    port: 7890
    udp: true
''';
    expect(() => LanProxySettings.fromBody(body), throwsFormatException);
    expect(
      () => LanProxySettings(addresses: ['192.168.1.2']).applyTo(body),
      throwsFormatException,
    );
  });

  test('unknown interfaces require confirmation and recognized cellular or VPN interfaces cannot be selected', () {
    const unknown = LanInterfaceAddress(
      address: '192.168.10.1',
      interfaceName: 'other0',
      interfaceIndex: 4,
      kind: 'unknown',
    );
    expect(unknown.selectable, true);
    expect(unknown.needsConfirmation, true);
    for (final kind in ['cellular', 'vpn', 'loopback']) {
      final item = LanInterfaceAddress(
        address: '192.168.10.1',
        interfaceName: 'other0',
        interfaceIndex: 4,
        kind: kind,
      );
      expect(item.selectable, false);
    }
  });
}
