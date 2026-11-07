import 'app_message.dart';
import 'config_entry.dart';

/// Raw platform error structure; details preserve cause, stack, suppressed, and unknown
/// fields.
class PlatformFailure implements Exception {
  const PlatformFailure({
    required this.code,
    this.message,
    this.details,
    this.stacktrace,
  });

  final String code;
  final String? message;
  final dynamic details;
  final String? stacktrace;

  Map<String, Object?> toMap() => {
    'code': code,
    if (message != null) 'message': message,
    if (details != null) 'details': details,
    if (stacktrace != null) 'stacktrace': stacktrace,
  };

  @override
  String toString() => 'PlatformFailure(${toMap()})';
}

/// Passes the raw error structure to operation receipts rather than replacing it with
/// display text.
Map<String, Object?> failureValue(Object error, [StackTrace? stack]) =>
    switch (error) {
      PlatformFailure() => {
        ...error.toMap(),
        if (stack != null) 'dartStack': stack.toString(),
      },
      ConfigFailure() => {
        'type': 'ConfigFailure',
        'message': error.message.toMap(),
        if (error.cause != null)
          'cause': failureValue(error.cause!, error.stackTrace),
        if (stack != null) 'stack': stack.toString(),
      },
      Map() => Map<String, Object?>.from(error),
      _ => {
        'type': error.runtimeType.toString(),
        'message': error.toString(),
        if (stack != null) 'stack': stack.toString(),
      },
    };

AppMessage messageFromFailure(
  PlatformFailure error, {
  required AppMessage fallback,
}) {
  AppMessage? typed;
  final pending = <Object?>[error.details];
  while (pending.isNotEmpty && typed == null) {
    final current = pending.removeLast();
    if (current is List) {
      pending.addAll(current.reversed);
    } else if (current is Map) {
      if (current['id'] is String && current['args'] is Map) {
        try {
          typed = AppMessage.fromMap(current);
        } on FormatException {
          // Continue searching nested typed causes.
        }
      }
      for (final key in const [
        'value',
        'terminal',
        'actual',
        'nativeReceipt',
        'cause',
        'details',
        'error',
      ]) {
        if (current[key] != null) pending.add(current[key]);
      }
    }
  }
  return (typed ?? fallback).withDetail(error);
}
