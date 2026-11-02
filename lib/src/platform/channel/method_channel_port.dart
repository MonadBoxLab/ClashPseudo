import 'package:flutter/services.dart';

import '../../model/platform_failure.dart';
import '../../model/platform_port.dart';

class MethodChannelPort implements PlatformPort {
  const MethodChannelPort(this.channel);
  final MethodChannel channel;

  @override
  Future<T?> invoke<T>(String method, [Object? arguments]) async {
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error, stack) {
      Error.throwWithStackTrace(platformFailure(error), stack);
    }
  }
}

PlatformFailure platformFailure(PlatformException error) => PlatformFailure(
  code: error.code,
  message: error.message,
  details: error.details,
  stacktrace: error.stacktrace,
);

PlatformException platformException(PlatformFailure error) => PlatformException(
  code: error.code,
  message: error.message,
  details: error.details,
  stacktrace: error.stacktrace,
);
