import 'package:flutter/services.dart';

import '../../model/app_platform.dart';
import '../core/core_client.dart';
import 'method_channel_port.dart';

/// Android channel adapter for the UI; background logic uses a constructor-injected
/// AppPlatform.
class AppBridge extends AppPlatform {
  AppBridge({super.operationId, super.admittedAt, super.deadline})
    : super(
        port: const MethodChannelPort(channel),
        coreClient: CoreClient(const MethodChannelPort(channel)),
      );

  static const channel = MethodChannel('io.github.monadboxlab.clashpseudo/app');
}
