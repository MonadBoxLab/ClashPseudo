import 'dart:convert';

import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:clash_pseudo/src/platform/channel/method_channel_port.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('MethodChannel 边界与 typed failure 往返保留 cause、stack、suppressed、cancelError 和未知字段', () async {
    const channel = MethodChannel('fixture/structured-failure');
    const codec = StandardMethodCodec();
    final original = AppMessage.withArgs('operationAndCleanupFailed', {
      'operation': messages.operationFailed.withDetail('原始操作'),
      'cleanup': messages.androidErrorReleaseUnconfirmed.withDetail(
        '原始 cleanup',
      ),
    }, detail: '外层原文');
    final longStack = '原始 frame\n' * 10000;
    final details = {
      ...original.toMap(),
      'cause': {
        'type': 'IOException',
        'message': 'cause 原文',
        'stack': longStack,
      },
      'suppressed': [
        {'message': '相同 suppressed'},
        {'message': '相同 suppressed'},
      ],
      'cancelError': {
        'future': [false, null, '取消原文'],
      },
      'unknown': {
        'values': [false, null, 'https://user:pass@fixture.test/?token=原文'],
      },
    };
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMessageHandler(channel.name, (_) async {
      final buffer = WriteBuffer()..putUint8(1);
      codec.messageCodec.writeValue(buffer, 'native');
      codec.messageCodec.writeValue(buffer, '平台原文');
      codec.messageCodec.writeValue(buffer, details);
      codec.messageCodec.writeValue(buffer, longStack);
      return buffer.done();
    });
    addTearDown(() => messenger.setMockMessageHandler(channel.name, null));
    PlatformFailure? failure;
    try {
      await const MethodChannelPort(channel).invoke<void>('read');
    } on PlatformFailure catch (error) {
      failure = error;
    }
    expect(failure, isNotNull);
    expect(failure!.code, 'native');
    expect(failure.message, '平台原文');
    expect(failure.details, details);
    expect(failure.stacktrace, longStack);
    final restored = platformException(failure);
    expect(restored.code, failure.code);
    expect(restored.message, failure.message);
    expect(restored.details, details);
    expect(restored.stacktrace, longStack);
    expect(platformFailure(restored).toMap(), failure.toMap());
    expect(jsonDecode(jsonEncode(failure.toMap()))['details'], details);
    final message = messageFromFailure(
      failure,
      fallback: messages.requestNotAccepted,
    );
    expect(message.args, original.args);
    expect(message.detail, contains('cause 原文'));
    expect(message.detail, contains('取消原文'));
    expect(message.detail, contains(longStack));
    expect((failure.details['suppressed'] as List), hasLength(2));
    expect(failure.details['unknown']['values'], [
      false,
      null,
      'https://user:pass@fixture.test/?token=原文',
    ]);
  });

  test('无效 AppMessage 结构保留在 fallback，原始 typed failure 不变', () {
    for (final details in <Object?>[
      null,
      '旧展示文字',
      <String, Object?>{},
      {'id': 'operationFailed', 'args': 'invalid'},
      {
        'id': 'operationAndCleanupFailed',
        'args': {
          'operation': {'id': 'operationFailed', 'args': 'invalid'},
        },
      },
    ]) {
      final failure = PlatformFailure(
        code: 'native',
        message: '原始 diagnostic',
        details: details,
      );
      final decoded = messageFromFailure(
        failure,
        fallback: messages.requestNotAccepted,
      );
      expect(decoded, messages.requestNotAccepted.withDetail(failure));
      expect(decoded.detail, failure.toString());
      expect(failure.details, details);
    }
  });
}
