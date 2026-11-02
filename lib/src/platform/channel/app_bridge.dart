import 'package:flutter/services.dart';

import '../../model/app_platform.dart';
import '../core/core_client.dart';
import 'method_channel_port.dart';

/// UI 使用的 Android channel adapter；后台业务使用构造注入的 AppPlatform。
class AppBridge extends AppPlatform {
  AppBridge({super.operationId, super.admittedAt, super.deadline})
    : super(
        port: const MethodChannelPort(channel),
        coreClient: CoreClient(const MethodChannelPort(channel)),
      );

  static const channel = MethodChannel('io.github.monadboxlab.clashpseudo/app');
}
