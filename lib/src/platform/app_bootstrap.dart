import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../logic/app_runtime.dart';
import '../model/app_message.dart';
import '../model/app_platform.dart';
import '../model/application_contract.dart';
import '../model/platform_failure.dart';
import 'channel/app_bridge.dart';
import 'channel/method_channel_port.dart';

class _BackgroundBinding extends BindingBase
    with SchedulerBinding, ServicesBinding {}

void runBackground() {
  _BackgroundBinding();
  unawaited(AppBootstrap().start());
}

/// Flutter integration and state notifications for the sole background runtime in the
/// default process.
class AppBootstrap {
  AppBootstrap({
    AppPlatform? platform,
    this.channel = AppBridge.channel,
    void Function()? changed,
  }) {
    runtime = AppRuntime(
      platform ?? AppBridge(),
      changed: () {
        changed?.call();
        _changed();
      },
    );
  }

  final MethodChannel channel;
  late final AppRuntime runtime;
  Timer? _notification;
  bool _flight = false;
  bool _dirty = false;
  bool _disposed = false;
  Object? _notificationError;

  Future<void> start() async {
    channel.setMethodCallHandler((call) async {
      try {
        return encodeAppMessages(
          await runtime.handle(call.method, call.arguments),
        );
      } on PlatformFailure catch (error) {
        throw platformException(error);
      } on UnsupportedError catch (error) {
        throw MissingPluginException(error.message);
      }
    });
    await MethodChannelPort(channel).invoke<void>('ready');
    await runtime.start();
  }

  void _changed() {
    if (_disposed) return;
    _dirty = true;
    _notification ??= Timer(const Duration(milliseconds: 60), () async {
      _notification = null;
      if (_disposed || _flight) return;
      _flight = true;
      _dirty = false;
      try {
        await MethodChannelPort(channel)
            .invoke<void>(ApplicationContract.coreChannelRuntimeChanged, {
              ...runtime.projection,
              if (_notificationError != null)
                'error': _notificationError.toString(),
            });
        _notificationError = null;
      } catch (error) {
        _notificationError = error;
      } finally {
        _flight = false;
        if (_dirty) _changed();
      }
    });
  }

  void dispose() {
    _disposed = true;
    _notification?.cancel();
    channel.setMethodCallHandler(null);
    runtime.dispose();
  }
}
