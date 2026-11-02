import 'dart:io';

import '../../model/messages.dart';
import '../../model/storage_json.dart';
import '../storage/storage_files.dart';
import '../../model/application_contract.dart';
import '../../model/tunnel_mode.dart';
import '../../model/config_entry.dart';

class ConfigStore {
  ConfigStore(this.directory, {this.beforeWrite, this.publish});

  final Directory directory;
  final Future<void> Function()? beforeWrite;
  final Future<void> Function(String file)? publish;
  File get _file => File('${directory.path}/configurations.json');

  Future<ConfigCollection> read() async {
    try {
      final data = await readStorageJson(
        _file,
        ApplicationContract.backupConfigurationsJsonBytes,
      ) as Map<String, dynamic>;
      checkStorageLimit(
        _file.path,
        'entries',
        (data['entries'] as List).length,
        ApplicationContract.backupCollectionEntries,
      );
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
        originalJson: Map.unmodifiable({...data}..remove('entries')),
        selectedId: selected,
        mode: data['mode'] == null ? null : TunnelMode.parse(data['mode']),
      );
    } catch (error) {
      if (isMissingStorageFile(error)) return ConfigCollection(entries: []);
      throw ConfigFailure(messages.configStoreUnreadable.withDetail(error));
    }
  }

  Future<void> save(ConfigCollection collection) async {
    _checkEntries(collection.entries, collection.selectedId);
    final entries = collection.entries
        .map((entry) => ConfigEntry.fromJson(entry.toJson()))
        .toList();
    // Actions may rebuild the collection; retain the current disk envelope.
    final previous = await read();
    final envelope = {...collection.originalJson, ...previous.originalJson};
    final bytes = encodeStorageJson(_file.path, {
      ...envelope,
      if (envelope.containsKey('selectedId') ||
          collection.selectedId != null ||
          envelope.isEmpty)
        'selectedId': collection.selectedId,
      'mode': collection.mode?.name,
      'entries': entries.map((entry) => entry.toJson()).toList(),
    }, ApplicationContract.backupConfigurationsJsonBytes);
    await _write(bytes);
  }

  /// Explicit whole-collection reset also works for unreadable/oversized data.
  Future<void> clear() => _write(
    encodeStorageJson(_file.path, {
      'selectedId': null,
      'mode': null,
      'entries': const [],
    }, ApplicationContract.backupConfigurationsJsonBytes),
  );

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
        await commit('configurations.json');
      }
      published = true;
    } on FileSystemException catch (error) {
      final wrapped = ConfigFailure(
        messages.configSaveFailed.withDetail(error),
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

  void _checkEntries(List<ConfigEntry> entries, String? selected) {
    checkStorageLimit(
      _file.path,
      'entries',
      entries.length,
      ApplicationContract.backupCollectionEntries,
    );
    if (entries.map((entry) => entry.id).toSet().length != entries.length ||
        (selected != null && !entries.any((entry) => entry.id == selected))) {
      throw const FormatException('Inconsistent configuration collection');
    }
  }
}
