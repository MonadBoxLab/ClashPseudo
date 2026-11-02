import 'dart:io';

import '../../model/config_entry.dart';
import '../../model/app_preferences.dart';
import '../../model/application_contract.dart';
import '../../model/messages.dart';
import '../../model/storage_json.dart';
import 'storage_files.dart';

class PreferencesStore {
  PreferencesStore(this.directory, {this.beforeWrite, this.publish});

  final Directory directory;
  final Future<void> Function()? beforeWrite;
  final Future<void> Function(String file)? publish;
  File get _file => File('${directory.path}/preferences.json');

  Future<AppPreferences> read() async {
    try {
      return AppPreferences.fromJson(
        await readStorageJson(
          _file,
          ApplicationContract.backupPreferencesJsonBytes,
        ) as Map<String, dynamic>,
      );
    } catch (error) {
      if (isMissingStorageFile(error)) return const AppPreferences();
      throw ConfigFailure(messages.preferencesUnreadable.withDetail(error));
    }
  }

  Future<void> save(AppPreferences preferences) async {
    AppPreferences.fromJson(preferences.toJson());
    final bytes = encodeStorageJson(
      _file.path,
      preferences.toJson(),
      ApplicationContract.backupPreferencesJsonBytes,
    );
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
        await commit('preferences.json');
      }
      published = true;
    } on FileSystemException catch (error) {
      final wrapped = ConfigFailure(
        messages.preferencesSaveFailed.withDetail(error),
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
}
