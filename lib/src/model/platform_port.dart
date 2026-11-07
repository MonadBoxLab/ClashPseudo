/// Platform channel transport without business objects or runtime state.
abstract interface class PlatformPort {
  Future<T?> invoke<T>(String method, [Object? arguments]);
}
