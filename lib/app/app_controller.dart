import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../features/configs/config_entry.dart';
import '../features/configs/config_store.dart';
import '../platform/app_bridge.dart';

class AppController extends ChangeNotifier {
  AppController(this.platform);

  final AppBridge platform;
  ConfigCollection collection = ConfigCollection(entries: []);
  AppSnapshot state = const AppSnapshot();
  String? error;
  bool loading = true;
  bool dispatching = false;
  Map<String, Object?>? lastCommand;
  bool _refreshing = false;
  bool _refreshAgain = false;
  bool _disposed = false;
  ConfigStore? _store;

  bool get busy => loading || dispatching || state.busy;
  bool get canEdit => !busy && state.confirmed && error == null;

  Future<void> initialize() async {
    AppBridge.channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') await refresh();
    });
    await refresh();
  }

  Future<void> refresh() async {
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    do {
      _refreshAgain = false;
      try {
        state = await platform.snapshot();
        if (_store == null) {
          final paths = await platform.paths();
          _store = ConfigStore(Directory(paths['configs'] as String));
        }
        collection = await _store!.read();
        error = null;
      } on ConfigFailure catch (failure) {
        error = failure.message;
      } catch (_) {
        state = const AppSnapshot();
        error = '无法核实应用状态，请刷新重试。';
      }
      loading = false;
      if (!_disposed) notifyListeners();
    } while (_refreshAgain && !_disposed);
    _refreshing = false;
  }

  Future<void> submit(Map<String, Object?> command) async {
    if (busy) return;
    lastCommand = Map.of(command);
    dispatching = true;
    error = null;
    notifyListeners();
    try {
      await platform.submit(command);
    } on PlatformException catch (failure) {
      error = failure.message ?? '请求未被受理，请重试。';
    } catch (_) {
      error = '请求未被受理，请重试。';
    } finally {
      dispatching = false;
      if (!_disposed) notifyListeners();
    }
    if (!_disposed && error == null) await refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    AppBridge.channel.setMethodCallHandler(null);
    super.dispose();
  }
}
