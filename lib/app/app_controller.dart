import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../features/configs/config_entry.dart';
import '../features/configs/config_store.dart';
import '../platform/app_bridge.dart';

class AppController extends ChangeNotifier {
  AppController(this.platform, {this.store});

  final AppBridge platform;
  ConfigCollection collection = ConfigCollection(entries: []);
  AppSnapshot state = const AppSnapshot();
  bool loading = true;
  bool configsLoaded = false;
  String? platformError;
  String? configError;
  String? commandError;
  bool dispatching = false;
  Map<String, Object?>? lastCommand;
  bool lastCommandAutomatic = false;
  bool _refreshing = false;
  bool _refreshAgain = false;
  bool _disposed = false;
  bool _foreground = true;
  int _readRevision = 0;
  int _runner = 0;
  int _retryStep = 0;
  Timer? _retry;
  final ConfigStore? store;

  static const _readTimeout = Duration(seconds: 5);
  static const _retrySeconds = [1, 2, 5, 10, 30];

  bool get foreground => _foreground;
  String? get error =>
      platformError ??
      configError ??
      commandError ??
      (state.core.blocked ? state.core.error : null);
  bool get configsCurrent => configsLoaded && configError == null;
  bool get busy => loading || dispatching || state.busy;
  bool get canEdit =>
      !busy && state.confirmed && platformError == null && configsCurrent;
  bool get canChangeMode => canEdit && (!state.running || state.mode != null);
  bool get canToggle =>
      !busy &&
      state.confirmed &&
      platformError == null &&
      (state.running ||
          (!state.core.blocked &&
              configsCurrent &&
              collection.selected?.body != null));

  Future<void> initialize() async {
    AppBridge.channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') await refresh();
    });
    await refresh();
  }

  void setForeground(bool foreground) {
    if (_disposed || _foreground == foreground) return;
    _foreground = foreground;
    _retry?.cancel();
    if (foreground) {
      _retryStep = 0;
      unawaited(refresh());
    } else {
      // A pending platform/file future cannot be cancelled, only invalidated.
      _runner++;
      _readRevision++;
      _refreshing = false;
      _refreshAgain = false;
    }
    notifyListeners();
  }

  Future<void> refresh() async {
    if (_disposed || !_foreground) return;
    _retry?.cancel();
    if (_refreshing) {
      _refreshAgain = true;
      _readRevision++;
      return;
    }
    _refreshing = true;
    final runner = ++_runner;
    do {
      _refreshAgain = false;
      final revision = _readRevision;
      bool current() =>
          !_disposed &&
          _foreground &&
          runner == _runner &&
          revision == _readRevision;
      try {
        final snapshot = await platform.snapshot().timeout(_readTimeout);
        if (current()) {
          state = snapshot;
          platformError = null;
          loading = false;
          notifyListeners();
        }
      } catch (_) {
        if (current()) {
          state = const AppSnapshot();
          platformError = '暂时无法获取接管状态，前台将自动重试，不会自动启动。';
          loading = false;
          notifyListeners();
        }
      }
      if (runner != _runner || _disposed) return;
      if (current()) {
        try {
          final configs = await _readConfigs().timeout(_readTimeout);
          if (current()) {
            collection = configs;
            configsLoaded = true;
            configError = null;
          }
        } catch (failure) {
          if (current()) {
            configError = failure is ConfigFailure
                ? failure.message
                : '暂时无法读取已保存配置，原文件未被修改。';
          }
        }
        if (current()) notifyListeners();
      }
    } while (_refreshAgain && !_disposed && runner == _runner && _foreground);
    if (_disposed || runner != _runner) return;
    _refreshing = false;
    if (platformError != null ||
        configError != null ||
        state.modeError != null) {
      final seconds = _retrySeconds[_retryStep];
      if (_retryStep < _retrySeconds.length - 1) _retryStep++;
      if (_foreground) {
        _retry = Timer(Duration(seconds: seconds), () => unawaited(refresh()));
      }
    } else {
      _retryStep = 0;
    }
  }

  Future<ConfigCollection> _readConfigs() async {
    final source = store;
    if (source != null) return source.read();
    final paths = await platform.paths();
    // Keep this read local: a timed-out invocation must not publish late data.
    return ConfigStore(Directory(paths['configs'] as String)).read();
  }

  Future<String?> submit(
    Map<String, Object?> command, {
    bool automatic = false,
  }) async {
    if (_disposed || busy) return null;
    lastCommandAutomatic = automatic;
    String? operationId;
    lastCommand = Map.of(command);
    dispatching = true;
    commandError = null;
    _readRevision++;
    notifyListeners();
    try {
      operationId = await platform.submit(command);
    } on PlatformException catch (failure) {
      if (!_disposed) commandError = failure.message ?? '请求未被受理，请重试。';
    } catch (_) {
      if (!_disposed) commandError = '请求未被受理，请重试。';
    } finally {
      if (!_disposed) {
        dispatching = false;
        notifyListeners();
      }
    }
    // Even an ambiguous submission failure must re-read, never re-submit.
    if (!_disposed) await refresh();
    return operationId;
  }

  @override
  void dispose() {
    _disposed = true;
    _runner++;
    _retry?.cancel();
    AppBridge.channel.setMethodCallHandler(null);
    super.dispose();
  }
}
