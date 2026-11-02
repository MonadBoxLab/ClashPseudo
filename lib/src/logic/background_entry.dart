import 'app_runtime.dart';

/// 后台业务入口接收 platform 已创建的唯一 runtime。
Future<void> runBackground(AppRuntime runtime) => runtime.start();
