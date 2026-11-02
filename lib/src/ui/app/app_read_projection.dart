import 'package:clash_pseudo/src/model/app_platform.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../logic/configs/config_store.dart';
import '../../logic/overrides/override_store.dart';
import '../../logic/storage/preferences_store.dart';
import '../../model/app_preferences.dart';
import '../../model/app_snapshot.dart';
import '../../model/config_entry.dart';
import '../../model/messages.dart';
import '../../model/override_entry.dart';
import '../locale/message_text.dart';
import '../locale/model_text.dart';

/// 读取配置、插件、偏好及平台快照，在存储版本一致时更新界面，不提交业务操作。
class AppReadProjection {
  AppReadProjection(
    this.platform, {
    required this.changed,
    this.store,
    this.preferencesStore,
    this.overrideStore,
  });

  final AppPlatform platform;
  final ConfigStore? store;
  final PreferencesStore? preferencesStore;
  final OverrideStore? overrideStore;
  final VoidCallback changed;

  ConfigCollection collection = ConfigCollection(entries: []);
  List<OverrideEntry> overrides = const [];
  bool overridesLoaded = false;
  AppMessage? overrideErrorMessage;
  AppSnapshot state = const AppSnapshot();
  bool loading = true;
  bool configsLoaded = false;
  AppPreferences preferences = const AppPreferences();
  bool preferencesLoaded = false;
  AppMessage? preferencesErrorMessage;
  AppMessage? platformErrorMessage;
  AppMessage? configErrorMessage;
  int _storageEpoch = 0;
  int get storageEpoch => _storageEpoch;
  String? get platformError => platformErrorMessage?.text;
  String? get configError => configErrorMessage?.text;
  String? get overrideError => overrideErrorMessage?.text;
  String? get preferencesError => preferencesErrorMessage?.text;

  bool _refreshing = false;
  Completer<void>? _refreshDone;
  bool _refreshAgain = false;
  bool _disposed = false;
  bool _foreground = true;
  bool get foreground => _foreground;
  int _readRevision = 0;
  int _runner = 0;
  int _retryStep = 0;
  Timer? _retry;
  bool _uiReadinessPending = false;
  static const _readTimeout = Duration(seconds: 5);
  static const _retrySeconds = [1, 2, 5, 10, 30];

  void _changed() {
    if (!_disposed) changed();
  }

  void prepareUiReadiness() => _uiReadinessPending = true;

  void invalidate() => _readRevision++;

  void setForeground(bool value) {
    if (_disposed || _foreground == value) return;
    _foreground = value;
    _retry?.cancel();
    if (value) {
      _retryStep = 0;
    } else {
      // 停止更新界面；已经开始的平台调用和文件读取继续执行。
      _runner++;
      _readRevision++;
      _refreshing = false;
      _refreshAgain = false;
    }
  }

  Future<void> refresh() async {
    if (_disposed || !_foreground) return;
    _retry?.cancel();
    if (_refreshing) {
      _refreshAgain = true;
      _readRevision++;
      await _refreshDone!.future;
      return;
    }
    _refreshing = true;
    final done = Completer<void>();
    _refreshDone = done;
    final runner = ++_runner;
    try {
      do {
        _refreshAgain = false;
        final revision = _readRevision;
        bool current() =>
            !_disposed &&
            _foreground &&
            runner == _runner &&
            revision == _readRevision;
        AppMessage? readinessFailure;
        if (_uiReadinessPending) {
          try {
            await platform.uiReady().timeout(_readTimeout);
            if (!current()) continue;
            _uiReadinessPending = false;
          } catch (failure) {
            readinessFailure = messages.temporaryStatusUnavailable.withDetail(
              failure,
            );
          }
        }
        if (!current()) continue;
        final (snapshot, snapshotFailure) = await _readState();
        if (!current()) continue;
        state = snapshot;
        platformErrorMessage = snapshotFailure == null
            ? readinessFailure
            : readinessFailure == null
            ? snapshotFailure
            : snapshotFailure.withDetail(readinessFailure.detail);
        // Native readiness and local files are independent. A running service
        // remains stoppable while the business files are still being read.
        if (snapshot.stale ||
            snapshot.running ||
            snapshot.pendingStart ||
            snapshot.pendingSystemStart ||
            snapshot.pendingRestore ||
            snapshot.scheduleBusy ||
            snapshot.resourceBusy ||
            snapshot.phase == 'STARTING') {
          loading = false;
        }
        _changed();
        if (state.storageReady && !state.storageRestoring) {
          final epoch = state.storageEpoch;
          ConfigCollection? configs;
          List<OverrideEntry>? parts;
          AppPreferences? settings;
          AppMessage? configFailure;
          AppMessage? overrideFailure;
          AppMessage? preferencesFailure;
          try {
            configs = await _readConfigs().timeout(_readTimeout);
          } catch (failure) {
            configFailure = failure is ConfigFailure
                ? failure.message
                : messages.temporaryConfigsUnreadable.withDetail(failure);
          }
          if (!current()) continue;
          try {
            parts = await _readOverrides().timeout(_readTimeout);
          } catch (failure) {
            overrideFailure = failure is ConfigFailure
                ? failure.message
                : messages.temporaryOverridesUnreadable.withDetail(failure);
          }
          if (!current()) continue;
          try {
            settings = await _readPreferences().timeout(_readTimeout);
          } catch (failure) {
            preferencesFailure = failure is ConfigFailure
                ? failure.message
                : messages.temporarySettingsUnreadable.withDetail(failure);
          }
          if (!current()) continue;
          final (after, afterFailure) = await _readState(
            coreFailure: snapshotFailure,
          );
          if (!current()) continue;
          state = after;
          platformErrorMessage = afterFailure == null
              ? readinessFailure
              : readinessFailure == null
              ? afterFailure
              : afterFailure.withDetail(readinessFailure.detail);
          if (!after.storageReady ||
              after.storageRestoring ||
              after.storageEpoch != epoch) {
            // A restore crossing this read invalidates the projection, not the
            // draft. Read the new epoch before publishing any of its files.
            _refreshAgain = after.storageReady && !after.storageRestoring;
            loading = false;
            _changed();
            continue;
          }
          _storageEpoch = epoch;
          if (configs != null) {
            collection = configs;
            configsLoaded = true;
          }
          if (parts != null) {
            overrides = parts;
            overridesLoaded = true;
          }
          if (settings != null) {
            preferences = settings;
            preferencesLoaded = true;
            setMessageLanguage(settings.language);
          }
          configErrorMessage = configFailure;
          overrideErrorMessage = overrideFailure;
          preferencesErrorMessage = preferencesFailure;
        }
        loading = false;
        _changed();
      } while (_refreshAgain && !_disposed && runner == _runner && _foreground);
      if (_disposed || runner != _runner) return;
      _refreshing = false;
      if (!state.storageReady ||
          state.storageRestoring ||
          platformError != null ||
          configError != null ||
          preferencesError != null ||
          overrideError != null ||
          state.modeError != null) {
        final seconds = _retrySeconds[_retryStep];
        if (_retryStep < _retrySeconds.length - 1) _retryStep++;
        if (_foreground) {
          _retry = Timer(
            Duration(seconds: seconds),
            () => unawaited(refresh()),
          );
        }
      } else {
        _retryStep = 0;
      }
    } finally {
      if (runner == _runner) {
        _refreshing = false;
        _refreshDone = null;
      }
      done.complete();
    }
  }

  Future<(AppSnapshot, AppMessage?)> _readState({
    AppMessage? coreFailure,
  }) async {
    AppMessage? error = coreFailure;
    if (error == null) {
      try {
        final snapshot = await platform.snapshot().timeout(_readTimeout);
        return (snapshot, snapshot.storageReady ? null : snapshot.storageError);
      } catch (failure) {
        error = messages.temporaryStatusUnavailable.withDetail(failure);
      }
    }
    try {
      // paths observes only the file transaction, without querying the core.
      final paths = await platform.paths().timeout(_readTimeout);
      return (
        state.asStale(
          storageReady: true,
          storageRestoring: false,
          storageEpoch: paths['storageEpoch'] as int,
        ),
        error,
      );
    } catch (storageFailure) {
      return (
        state.asStale(storageReady: false),
        error.withDetail(storageFailure),
      );
    }
  }

  Future<AppPreferences> _readPreferences() async {
    final source = preferencesStore;
    if (source != null) return source.read();
    final directory =
        store?.directory ??
        Directory((await platform.paths())['configs'] as String);
    return PreferencesStore(directory).read();
  }

  Future<List<OverrideEntry>> _readOverrides() async {
    final source = overrideStore;
    if (source != null) return source.read();
    final directory =
        store?.directory ??
        Directory((await platform.paths())['configs'] as String);
    return OverrideStore(directory).read();
  }

  Future<ConfigCollection> _readConfigs() async {
    final source = store;
    if (source != null) return source.read();
    final paths = await platform.paths();
    // Keep the result local and publish only while the invocation remains current.
    return ConfigStore(Directory(paths['configs'] as String)).read();
  }

  void dispose() {
    _disposed = true;
    _runner++;
    _retry?.cancel();
  }
}
