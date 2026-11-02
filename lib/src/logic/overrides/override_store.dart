import 'dart:convert';
import 'dart:io';

import '../../model/messages.dart';
import '../../model/storage_json.dart';
import '../storage/storage_files.dart';
import '../../model/application_contract.dart';
import '../../model/config_entry.dart';
import '../../model/config_text.dart';
import '../../model/override_entry.dart';

class OverrideStore {
  OverrideStore(this.directory, {this.beforeWrite, this.publish});

  final Directory directory;
  final Future<void> Function()? beforeWrite;
  final Future<void> Function(String file)? publish;
  File get _file => File('${directory.path}/overrides.json');
  Map<String, Object?> _envelope = const {};

  Future<List<OverrideEntry>> read() async {
    try {
      final data = await readStorageJson(
        _file,
        ApplicationContract.backupOverridesJsonBytes,
      ) as Map<String, dynamic>;
      checkStorageLimit(
        _file.path,
        'entries',
        (data['entries'] as List).length,
        ApplicationContract.backupCollectionEntries,
      );
      final entries = (data['entries'] as List)
          .map((value) => OverrideEntry.fromJson(value as Map<String, dynamic>))
          .toList();
      _checkEntries(entries);
      _envelope = Map.unmodifiable({...data}..remove('entries'));
      return List.unmodifiable(entries);
    } catch (error) {
      if (isMissingStorageFile(error)) {
        _envelope = const {};
        return const [];
      }
      throw ConfigFailure(messages.overridesUnreadable.withDetail(error));
    }
  }

  Future<void> save(List<OverrideEntry> entries) async {
    _checkEntries(entries);
    final snapshot = entries
        .map((entry) => OverrideEntry.fromJson(entry.toJson()))
        .toList();
    // Keep envelope fields even when callers supply a newly built List.
    await read();
    final bytes = encodeStorageJson(_file.path, {
      ..._envelope,
      'entries': snapshot.map((entry) => entry.toJson()).toList(),
    }, ApplicationContract.backupOverridesJsonBytes);
    await _write(bytes);
  }

  /// Explicit reset deliberately discards even a previously read envelope.
  Future<void> clear() async {
    await _write(
      encodeStorageJson(_file.path, {
        'entries': const [],
      }, ApplicationContract.backupOverridesJsonBytes),
    );
    _envelope = const {};
  }

  Future<void> _write(List<int> bytes) async {
    await beforeWrite?.call();
    await directory.create(recursive: true);
    final temporary = File('${_file.path}.tmp');
    var published = false;
    Object? failure;
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await beforeWrite?.call();
      final commit = publish;
      if (commit == null) {
        await temporary.rename(_file.path);
      } else {
        await commit('overrides.json');
      }
      published = true;
    } on FileSystemException catch (error) {
      final wrapped = ConfigFailure(
        messages.overridesSaveFailed.withDetail(error),
      );
      failure = wrapped;
      throw wrapped;
    } catch (error) {
      failure = error;
      rethrow;
    } finally {
      if (!published) await cleanupStorageTemporary(temporary, cause: failure);
    }
  }

  void _checkEntries(List<OverrideEntry> entries) {
    checkStorageLimit(
      _file.path,
      'entries',
      entries.length,
      ApplicationContract.backupCollectionEntries,
    );
    final ids = <String>{};
    final roles = <OverrideRole>{};
    for (final entry in entries) {
      if (!ids.add(entry.id) ||
          (entry.role != null && !roles.add(entry.role!))) {
        throw const FormatException('Inconsistent override collection');
      }
    }
    enabledOverrides(entries);
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
