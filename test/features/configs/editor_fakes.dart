import 'package:clash_pseudo/src/model/app_snapshot.dart';

import 'dart:async';

import 'package:clash_pseudo/src/app/app_controller.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/foundation.dart' show ValueListenable;

class EditorApp extends AppController {
  EditorApp({List<ConfigEntry> entries = const []}) : super(AppBridge()) {
    collection = ConfigCollection(entries: entries);
    loading = false;
    configsLoaded = true;
    state = const AppSnapshot(phase: 'STOPPED');
  }
  final commands = <Map<String, Object?>>[];
  Completer<AppSnapshot?>? pending;
  AppSnapshot? outcome;

  void updateState(AppSnapshot value) {
    state = value;
    notifyListeners();
  }

  @override
  Future<AppSnapshot?> saveLocal(
    Map<String, Object?> command, {
    ValueListenable<bool>? feedbackOwner,
  }) async {
    commands.add(command);
    return pending == null ? outcome : pending!.future;
  }
}
