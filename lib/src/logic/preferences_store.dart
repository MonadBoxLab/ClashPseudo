import 'dart:convert';
import 'dart:io';

import '../features/configs/config_entry.dart';
import '../model/app_preferences.dart';
import '../l10n/messages.dart';

class PreferencesStore {
  PreferencesStore(this.directory, {this.beforeWrite, this.publish});

  final Directory directory;
  final Future<void> Function()? beforeWrite;
  final Future<void> Function(String file)? publish;
  File get _file => File('${directory.path}/preferences.json');

  Future<AppPreferences> read() async {
    if (!await _file.exists()) return const AppPreferences();
    try {
      return AppPreferences.fromJson(
        jsonDecode(await _file.readAsString()) as Map<String, dynamic>,
      );
    } catch (_) {
      throw ConfigFailure(messages.preferencesUnreadable);
    }
  }

  Future<void> save(AppPreferences preferences) async {
    AppPreferences.fromJson(preferences.toJson());
    await beforeWrite?.call();
    await directory.create(recursive: true);
    final temporary = File('${_file.path}.tmp');
    try {
      await temporary.writeAsString(
        jsonEncode(preferences.toJson()),
        flush: true,
      );
      await beforeWrite?.call();
      final commit = publish;
      if (commit == null) {
        await temporary.rename(_file.path);
      } else {
        await commit('preferences.json');
      }
    } on FileSystemException {
      throw ConfigFailure(messages.preferencesSaveFailed);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
