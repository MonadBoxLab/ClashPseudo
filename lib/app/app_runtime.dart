import 'dart:io';

import 'package:flutter/services.dart';

import '../features/connections/connection_actions.dart';
import '../features/connections/connection_observer.dart';
import '../features/strategies/strategy_snapshot.dart';
import '../features/configs/config_actions.dart';
import '../features/configs/config_downloader.dart';
import '../features/configs/config_entry.dart';
import '../features/configs/config_store.dart';
import '../features/strategies/strategy_actions.dart';
import '../platform/app_bridge.dart';

class AppRuntime {
  AppBridge? _operation;
  final _observer = ConnectionObserver(AppBridge());

  Future<void> start() async {
    AppBridge.channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'cancel':
          if (_operation?.operationId == call.arguments) _operation?.cancel();
          return null;
        case 'runtimeState':
          _observer.updateState(
            Map<String, dynamic>.from(call.arguments as Map),
          );
          return {'retain': _observer.retained};
        case 'connections':
          final args = Map<String, dynamic>.from(call.arguments as Map);
          return _observer.snapshot(
            Map<String, dynamic>.from(args['state'] as Map),
            args['detail'] as Map?,
          );
        case 'releaseDetail':
          _observer.window.pinDetail(null);
          return null;
        case 'execute':
          return _execute(Map<String, dynamic>.from(call.arguments as Map));
        default:
          throw MissingPluginException();
      }
    });
    await AppBridge.channel.invokeMethod<void>('ready');
  }

  Future<Map<String, Object?>> _execute(Map<String, dynamic> command) async {
    if (_operation != null) {
      return {'success': false, 'message': '已有操作正在处理。'};
    }
    final platform = AppBridge(operationId: command['owner'] as String);
    _operation = platform;
    try {
      if (command['action'] == 'closeConnection') {
        final outcome = await ConnectionActions(platform).execute(command);
        if (outcome['connectionStatus'] == 'closed' ||
            outcome['connectionStatus'] == 'absent') {
          _observer.closed(
            CoreSnapshot(
              generation: command['generation'] as int,
              phase: 'READY',
              purpose: 'VPN',
              configId: command['configId'] as String,
              revision: command['revision'] as int,
            ),
            command['connectionId'] as String,
          );
        }
        return outcome;
      }
      final paths = await platform.paths();
      final store = ConfigStore(
        Directory(paths['configs'] as String),
        beforeWrite: platform.checkOperation,
      );
      final actions = ConfigActions(
        store,
        ConfigDownloader(),
        platform,
        File(paths['runInput'] as String),
      );
      return {
        'success': true,
        'message': command['action'] == 'setStrategy'
            ? await StrategyActions(store, platform).execute(command)
            : await actions.execute(command),
      };
    } on ConfigFailure catch (error) {
      return {
        'success': false,
        'message': error.message,
        'needsHttpConfirmation': error.needsHttpConfirmation,
      };
    } on PlatformException catch (error) {
      return {'success': false, 'message': error.message ?? '平台操作未完成，请核实接管状态。'};
    } catch (_) {
      return {'success': false, 'message': '操作未完成，请核实状态后重试。'};
    } finally {
      _operation = null;
    }
  }
}
