import 'package:clash_pseudo/src/ui/locale/message_text.dart';

import 'dart:typed_data';

import 'package:clash_pseudo/src/model/app_platform.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';

import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/config_text.dart';
import 'package:clash_pseudo/src/model/messages.dart';

class ConfigFile {
  const ConfigFile(this.bytes, {this.name = ''});

  final Uint8List bytes;
  final String name;
}

Future<ConfigFile?> selectConfigFile() =>
    ConfigFileSelection(AppBridge()).select();

class ConfigFileSelection {
  ConfigFileSelection(this.platform);

  final AppPlatform platform;
  static int _sequence = 0;
  late final String _id =
      'config-file-${DateTime.now().microsecondsSinceEpoch}-${++_sequence}';
  Future<ConfigFile?>? _pending;
  Future<void>? _cancelling;
  bool _cancelled = false;

  Future<ConfigFile?> select() => _pending ??= _select();

  Future<ConfigFile?> _select() async {
    if (_cancelled) return null;
    final result = await platform.pickConfigFile(_id);
    if (_cancelled ||
        result['retired'] == true ||
        const ['cancelled', 'expired'].contains(result['status'])) {
      return null;
    }
    if (result['requestId'] != _id || result['status'] != 'ready') {
      throw ConfigFailure(
        result['errorCode'] == 'textTooLargeImport'
            ? messages.textTooLargeImport
            : messages.fileUnreadable,
      );
    }
    final bytes = result['bytes'];
    final name = result['name'];
    if (bytes is! Uint8List || name is! String) {
      throw ConfigFailure(messages.fileUnreadable);
    }
    if (bytes.length > maxConfigBytes) {
      throw ConfigFailure(messages.textTooLargeImport);
    }
    return ConfigFile(bytes, name: name);
  }

  Future<void> cancel() => _cancelling ??= _cancel();

  Future<void> _cancel() async {
    _cancelled = true;
    if (_pending == null) return;
    try {
      await platform.cancelConfigFile(_id);
    } finally {
      // Cancellation only revokes the read; its original reply confirms FD drain.
      await _pending;
    }
  }
}

Future<String> readConfigFile(ConfigFile file) async {
  if (file.bytes.length > maxConfigBytes) {
    throw ConfigFailure(messages.textTooLargeImport);
  }
  return decodeConfigText(file.bytes);
}

String configFileName(String name) {
  final dot = name.lastIndexOf('.');
  final stem = (dot > 0 ? name.substring(0, dot) : name).trim();
  return stem.isEmpty ? localizedMessages.localConfig : configNamePrefix(stem);
}
