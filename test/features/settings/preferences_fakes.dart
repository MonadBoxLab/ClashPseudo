import 'dart:io';

import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/logic/preferences_store.dart';

class MemoryPreferencesStore extends PreferencesStore {
  MemoryPreferencesStore() : super(Directory.systemTemp);

  AppPreferences value = const AppPreferences();
  Future<AppPreferences> Function()? readResult;

  @override
  Future<AppPreferences> read() async =>
      readResult == null ? value : await readResult!();

  @override
  Future<void> save(AppPreferences preferences) async => value = preferences;
}
