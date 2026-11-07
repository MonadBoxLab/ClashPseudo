import 'dart:convert';

import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../../model/config_text.dart';
import '../../model/lan_proxy.dart';

/// The form only changes addresses, ports, and UDP for its own listeners; other fields
/// retain their source text.
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
      throw const FormatException('Invalid LAN address or port');
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
      throw const FormatException(
        'Invalid listener identity; use the text editor',
      );
    }
    throw const FormatException(
      'Invalid listener identity; use the text editor',
    );
  }

  factory LanProxySettings.fromBody(String body) {
    final root = _root(body);
    final listeners = root['listeners'];
    if (listeners == null) return LanProxySettings(addresses: const []);
    if (listeners is! YamlList) {
      throw const FormatException('Edit listeners in the text editor');
    }
    final addresses = <String>[];
    final interfaces = <String, String>{};
    int? port;
    bool? udp;
    final names = <String>{};
    for (final item in listeners) {
      if (item is! YamlMap || item['name'] is! String) {
        throw const FormatException(
          'Edit listener configuration in the text editor',
        );
      }
      final name = item['name'] as String;
      if (!names.add(name)) {
        throw const FormatException('Duplicate listener name');
      }
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
        throw const FormatException(
          'Use the text editor for this listener configuration',
        );
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
    // Do not rebuild source text the form cannot represent.
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
    // Read positions again after deletion so stale indices cannot alter adjacent
    // listeners.
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
      throw const FormatException('Listener configuration was not fully saved');
    }
    return result;
  }

  static YamlMap _root(String body) {
    final documents = loadYamlDocuments(body);
    if (documents.length != 1 || documents.single.contents is! YamlMap) {
      throw const FormatException('LAN plugin requires a YAML mapping');
    }
    final root = documents.single.contents as YamlMap;
    final listeners = root.nodes['listeners'];
    // Editing aliases or merge keys through the form could change other definitions.
    final source = body;
    if (root.nodes.keys.any((key) => key.value == '<<') ||
        listeners != null &&
            RegExp(r'(^|\s)[&*][^\s]+').hasMatch(
              source.substring(
                listeners.span.start.offset,
                listeners.span.end.offset,
              ),
            )) {
      throw const FormatException(
        'Contains anchors or merge keys; use the text editor',
      );
    }
    return root;
  }
}
