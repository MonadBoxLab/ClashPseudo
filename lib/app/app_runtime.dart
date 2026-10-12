import 'dart:io';

import 'package:flutter/services.dart';

import '../features/configs/config_actions.dart';
import '../features/configs/config_downloader.dart';
import '../features/configs/config_entry.dart';
import '../features/configs/config_store.dart';
import '../platform/app_bridge.dart';

class AppRuntime {
  final _platform = AppBridge();
  bool _executing = false;

  Future<void> start() async {
    final paths = await _platform.paths();
    final actions = ConfigActions(
      ConfigStore(Directory(paths['configs'] as String)),
      ConfigDownloader(),
      _platform,
      File(paths['runInput'] as String),
    );
    AppBridge.channel.setMethodCallHandler((call) async {
      if (call.method != 'execute') throw MissingPluginException();
      if (_executing) return {'success': false, 'message': '已有操作正在处理。'};
      _executing = true;
      try {
        final command = Map<String, dynamic>.from(call.arguments as Map);
        return {'success': true, 'message': await actions.execute(command)};
      } on ConfigFailure catch (error) {
        return {
          'success': false,
          'message': error.message,
          'needsHttpConfirmation': error.needsHttpConfirmation,
        };
      } on PlatformException catch (error) {
        return {
          'success': false,
          'message': error.message ?? '平台操作未完成，请核实接管状态。',
        };
      } catch (_) {
        return {'success': false, 'message': '操作未完成，请核实状态后重试。'};
      } finally {
        _executing = false;
      }
    });
    await AppBridge.channel.invokeMethod<void>('ready');
  }
}
