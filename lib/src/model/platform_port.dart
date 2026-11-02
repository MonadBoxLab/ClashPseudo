/// 平台 channel 的传输能力，不保存业务对象或 runtime 状态。
abstract interface class PlatformPort {
  Future<T?> invoke<T>(String method, [Object? arguments]);
}
