import 'package:clash_pseudo/src/ui/locale/message_text.dart';

import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';

import 'package:clash_pseudo/src/model/app_platform.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';

import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/config_text.dart';
import 'package:clash_pseudo/src/model/messages.dart';

Future<XFile?> selectConfigFile() => ConfigFileSelection(AppBridge()).select();

class ConfigFileSelection {
  ConfigFileSelection(this.platform);

  final AppPlatform platform;
  static int _sequence = 0;
  late final String _id =
      'config-file-${DateTime.now().microsecondsSinceEpoch}-${++_sequence}';
  Future<XFile?>? _pending;
  Future<void>? _cancelling;
  bool _cancelled = false;

  Future<XFile?> select() => _pending ??= _select();

  Future<XFile?> _select() async {
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
    return XFile.fromData(bytes, name: name, path: name);
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

Future<String> readConfigFile(XFile file) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in file.openRead()) {
    if (bytes.length + chunk.length > maxConfigBytes) {
      throw ConfigFailure(messages.textTooLargeImport);
    }
    bytes.add(chunk);
  }
  return decodeConfigText(bytes.takeBytes());
}

String configFileName(String name) {
  final dot = name.lastIndexOf('.');
  final stem = (dot > 0 ? name.substring(0, dot) : name).trim();
  return stem.isEmpty ? localizedMessages.localConfig : configNamePrefix(stem);
}
