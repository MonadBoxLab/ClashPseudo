import 'dart:convert';

import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../../model/config_text.dart';
import '../../model/lan_proxy.dart';

/// 便捷表单只改本功能监听的地址、端口和 UDP，其他字段沿原文保留。
class LanProxySettings {
  LanProxySettings({
    required Iterable<String> addresses,
    this.port = 7890,
    this.udp = true,
    Map<String, String> interfaces = const {},
  }) : interfaces = Map.unmodifiable(interfaces),
       addresses = List.unmodifiable(addresses) {
    if (port < 1 ||
        port > 65535 ||
        this.addresses.any((address) => !isConcreteLanAddress(address)) ||
        this.addresses.toSet().length != this.addresses.length) {
      throw const FormatException('局域网地址或端口无效');
    }
  }

  static const listenerPrefix = 'clash-pseudo-lan-';
  final List<String> addresses;
  final Map<String, String> interfaces;
  final int port;
  final bool udp;

  static String listenerName(String address, {String interfaceName = ''}) =>
      '$listenerPrefix${base64Url.encode(utf8.encode('$interfaceName\u0000$address')).replaceAll('=', '')}';

  static String _interfaceName(String name, String address) {
    try {
      final encoded = name.substring(listenerPrefix.length);
      final decoded = utf8.decode(
        base64Url.decode(base64Url.normalize(encoded)),
      );
      final parts = decoded.split('\u0000');
      if (parts.length == 2 && parts.last == address) return parts.first;
    } catch (_) {
      throw const FormatException('监听身份无效，请使用原文编辑');
    }
    throw const FormatException('监听身份无效，请使用原文编辑');
  }

  factory LanProxySettings.fromBody(String body) {
    final root = _root(body);
    final listeners = root['listeners'];
    if (listeners == null) return LanProxySettings(addresses: const []);
    if (listeners is! YamlList) {
      throw const FormatException('请在原文中编辑 listeners');
    }
    final addresses = <String>[];
    final interfaces = <String, String>{};
    int? port;
    bool? udp;
    final names = <String>{};
    for (final item in listeners) {
      if (item is! YamlMap || item['name'] is! String) {
        throw const FormatException('请在原文中编辑监听配置');
      }
      final name = item['name'] as String;
      if (!names.add(name)) throw const FormatException('监听名称重复');
      if (!name.startsWith(listenerPrefix)) continue;
      final address = item['listen'];
      final nextPort = item['port'];
      final nextUdp = item['udp'];
      if (item['type'] != 'mixed' ||
          address is! String ||
          !isConcreteLanAddress(address) ||
          nextPort is! int ||
          nextUdp is! bool ||
          port != null && port != nextPort ||
          udp != null && udp != nextUdp) {
        throw const FormatException('当前监听配置请使用原文编辑');
      }
      addresses.add(address);
      interfaces[address] = _interfaceName(name, address);
      port = nextPort;
      udp = nextUdp;
    }
    return LanProxySettings(
      addresses: addresses,
      port: port ?? 7890,
      udp: udp ?? true,
      interfaces: interfaces,
    );
  }

  String applyTo(String original) {
    final body = original.isEmpty ? '{}\n' : original;
    // 无法表示的正文不能由表单重建。
    LanProxySettings.fromBody(body);
    final root = _root(body);
    final current = root['listeners'] as YamlList?;
    final editor = YamlEditor(body);
    final selected = addresses.toSet();
    final existing = <String>{};
    if (current == null) {
      editor.update(['listeners'], <Object?>[]);
    } else {
      for (var index = current.length - 1; index >= 0; index--) {
        final item = current[index] as YamlMap;
        final name = item['name'] as String;
        if (!name.startsWith(listenerPrefix)) continue;
        final address = item['listen'] as String;
        if (!selected.contains(address) ||
            _interfaceName(name, address) != (interfaces[address] ?? '')) {
          editor.remove(['listeners', index]);
        }
      }
    }
    // 删除后重新读取位置，不按旧索引修改相邻监听。
    final remaining = (_root(editor.toString())['listeners'] as YamlList);
    for (var index = 0; index < remaining.length; index++) {
      final item = remaining[index] as YamlMap;
      if (!(item['name'] as String).startsWith(listenerPrefix)) continue;
      final address = item['listen'] as String;
      existing.add(address);
      if (item['port'] != port) {
        editor.update(['listeners', index, 'port'], port);
      }
      if (item['udp'] != udp) editor.update(['listeners', index, 'udp'], udp);
    }
    var index = remaining.length;
    for (final address in addresses) {
      if (existing.contains(address)) continue;
      editor.insertIntoList(
        ['listeners'],
        index++,
        {
          'name': listenerName(
            address,
            interfaceName: interfaces[address] ?? '',
          ),
          'type': 'mixed',
          'listen': address,
          'port': port,
          'udp': udp,
          'users': <Object?>[],
        },
      );
    }
    final result = editor.toString();
    checkConfigText(result);
    final check = LanProxySettings.fromBody(result);
    if (check.port != port && addresses.isNotEmpty ||
        check.udp != udp && addresses.isNotEmpty ||
        check.addresses.toSet().length != selected.length ||
        !check.addresses.toSet().containsAll(selected)) {
      throw const FormatException('监听配置未完整保存');
    }
    return result;
  }

  static YamlMap _root(String body) {
    final documents = loadYamlDocuments(body);
    if (documents.length != 1 || documents.single.contents is! YamlMap) {
      throw const FormatException('局域网插件需要一个 YAML 对象');
    }
    final root = documents.single.contents as YamlMap;
    final listeners = root.nodes['listeners'];
    // 别名或 merge key 不能经表单修改，否则会影响其他定义。
    final source = body;
    if (root.nodes.keys.any((key) => key.value == '<<') ||
        listeners != null &&
            RegExp(r'(^|\s)[&*][^\s]+').hasMatch(
              source.substring(
                listeners.span.start.offset,
                listeners.span.end.offset,
              ),
            )) {
      throw const FormatException('包含锚点或合并字段，请使用原文编辑');
    }
    return root;
  }
}
