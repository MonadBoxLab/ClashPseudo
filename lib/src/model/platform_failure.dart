import 'app_message.dart';
import 'config_entry.dart';

/// 平台错误的原始结构；details 保留 cause、stack、suppressed 及未知字段。
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

/// 将原始错误结构传给业务回执；展示文字不替代该结构。
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
          // 继续读取嵌套的 typed cause。
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
