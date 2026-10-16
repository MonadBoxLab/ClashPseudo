import 'dart:convert';
import 'dart:io';

import '../mode/tunnel_mode.dart';
import 'config_entry.dart';

class ConfigStore {
  ConfigStore(this.directory, {this.beforeWrite});

  final Directory directory;
  final Future<void> Function()? beforeWrite;
  File get _file => File('${directory.path}/configurations.json');

  Future<ConfigCollection> read() async {
    if (!await _file.exists()) return ConfigCollection(entries: []);
    try {
      final data =
          jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      if (data['version'] != 1) throw const FormatException('Unknown version');
      final entries = (data['entries'] as List)
          .map((value) => ConfigEntry.fromJson(value as Map<String, dynamic>))
          .toList();
      final selected = data['selectedId'] as String?;
      if (entries.map((e) => e.id).toSet().length != entries.length ||
          entries.map((e) => e.source).toSet().length != entries.length ||
          (selected != null && !entries.any((e) => e.id == selected))) {
        throw const FormatException('Inconsistent configuration collection');
      }
      return ConfigCollection(
        entries: entries,
        selectedId: selected,
        mode: data.containsKey('mode')
            ? TunnelMode.parse(data['mode'])
            : TunnelMode.rule,
      );
    } catch (_) {
      // Never turn a damaged store into an empty list and overwrite user data.
      throw const ConfigFailure('无法读取已保存配置，原文件未被修改。');
    }
  }

  Future<void> save(ConfigCollection collection) async {
    await beforeWrite?.call();
    await directory.create(recursive: true);
    final temporary = File('${_file.path}.tmp');
    try {
      await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'selectedId': collection.selectedId,
          'mode': collection.mode.name,
          'entries': collection.entries.map((entry) => entry.toJson()).toList(),
        }),
        flush: true,
      );
      // Recheck after I/O: an expired operation must not publish its late body.
      await beforeWrite?.call();
      // One business writer; readers see either complete version after rename.
      await temporary.rename(_file.path);
    } on FileSystemException {
      throw const ConfigFailure('保存配置失败，请检查可用存储空间后重试。');
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
