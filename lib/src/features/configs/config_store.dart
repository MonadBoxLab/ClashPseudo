import 'dart:convert';
import 'dart:io';

import '../mode/tunnel_mode.dart';
import 'config_entry.dart';
import '../../l10n/messages.dart';

class ConfigStore {
  ConfigStore(this.directory, {this.beforeWrite, this.publish});

  final Directory directory;
  final Future<void> Function()? beforeWrite;
  final Future<void> Function(String file)? publish;
  File get _file => File('${directory.path}/configurations.json');

  Future<ConfigCollection> read() async {
    if (!await _file.exists()) return ConfigCollection(entries: []);
    try {
      final data =
          jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      final entries = (data['entries'] as List)
          .map((value) => ConfigEntry.fromJson(value as Map<String, dynamic>))
          .toList();
      final selected = data['selectedId'] as String?;
      _checkEntries(entries, selected);
      if (!data.containsKey('mode')) {
        throw const FormatException('Missing mode fallback');
      }
      return ConfigCollection(
        entries: entries,
        selectedId: selected,
        mode: data['mode'] == null ? null : TunnelMode.parse(data['mode']),
      );
    } catch (_) {
      // Preserve a damaged Store and report its read failure.
      throw ConfigFailure(messages.configStoreUnreadable);
    }
  }

  Future<void> save(ConfigCollection collection) async {
    final entries = collection.entries
        .map((entry) => ConfigEntry.fromJson(entry.toJson()))
        .toList();
    _checkEntries(entries, collection.selectedId);
    await beforeWrite?.call();
    await directory.create(recursive: true);
    final temporary = File('${_file.path}.tmp');
    var published = false;
    try {
      await temporary.writeAsString(
        jsonEncode({
          'selectedId': collection.selectedId,
          'mode': collection.mode?.name,
          'entries': entries.map((entry) => entry.toJson()).toList(),
        }),
        flush: true,
      );
      // Recheck operation identity after I/O and before publication.
      await beforeWrite?.call();
      final commit = publish;
      if (commit == null) {
        await temporary.rename(_file.path);
      } else {
        await commit('configurations.json');
      }
      published = true;
    } on FileSystemException {
      throw ConfigFailure(messages.configSaveFailed);
    } finally {
      if (!published && await temporary.exists()) await temporary.delete();
    }
  }

  void _checkEntries(List<ConfigEntry> entries, String? selected) {
    final remote = entries.where((entry) => entry.remote).toList();
    if (entries.map((entry) => entry.id).toSet().length != entries.length ||
        remote.map((entry) => entry.source).toSet().length != remote.length ||
        (selected != null && !entries.any((entry) => entry.id == selected))) {
      throw const FormatException('Inconsistent configuration collection');
    }
  }
}
