import 'dart:convert';
import 'dart:io';

import '../../l10n/messages.dart';
import '../configs/config_entry.dart';
import '../configs/config_text.dart';
import 'override_entry.dart';

class OverrideStore {
  OverrideStore(this.directory, {this.beforeWrite, this.publish});

  final Directory directory;
  final Future<void> Function()? beforeWrite;
  final Future<void> Function(String file)? publish;
  File get _file => File('${directory.path}/overrides.json');

  Future<List<OverrideEntry>> read() async {
    try {
      if (!await _file.exists()) return const [];
      final data =
          jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      final entries = (data['entries'] as List)
          .map((value) => OverrideEntry.fromJson(value as Map<String, dynamic>))
          .toList();
      _checkEntries(entries);
      return List.unmodifiable(entries);
    } catch (_) {
      throw ConfigFailure(messages.overridesUnreadable);
    }
  }

  Future<void> save(List<OverrideEntry> entries) async {
    final snapshot = entries
        .map((entry) => OverrideEntry.fromJson(entry.toJson()))
        .toList();
    _checkEntries(snapshot);
    await beforeWrite?.call();
    await directory.create(recursive: true);
    final temporary = File('${_file.path}.tmp');
    var published = false;
    try {
      await temporary.writeAsString(
        jsonEncode({
          'entries': snapshot.map((entry) => entry.toJson()).toList(),
        }),
        flush: true,
      );
      await beforeWrite?.call();
      final commit = publish;
      if (commit == null) {
        await temporary.rename(_file.path);
      } else {
        await commit('overrides.json');
      }
      published = true;
    } on FileSystemException {
      throw ConfigFailure(messages.overridesSaveFailed);
    } finally {
      if (!published && await temporary.exists()) await temporary.delete();
    }
  }

  void _checkEntries(List<OverrideEntry> entries) {
    final ids = <String>{};
    final sources = <String>{};
    final roles = <OverrideRole>{};
    for (final entry in entries) {
      if (!ids.add(entry.id) ||
          (entry.remote && !sources.add(entry.source!)) ||
          (entry.role != null && !roles.add(entry.role!))) {
        throw const FormatException('Inconsistent override collection');
      }
    }
  }
}

List<Map<String, Object?>> enabledOverrides(List<OverrideEntry> entries) {
  var bytes = 0;
  final result = <Map<String, Object?>>[];
  for (final entry in entries.where((entry) => entry.enabled)) {
    bytes += utf8.encode(entry.body).length;
    if (bytes > maxConfigBytes) {
      throw ConfigFailure(messages.overridesTooLarge);
    }
    result.add({
      'id': entry.id,
      'revision': entry.revision,
      'mode': entry.mode.name,
      'body': entry.body,
    });
  }
  return result;
}
