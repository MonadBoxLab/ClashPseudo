import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:async';

import 'package:clash_pseudo/src/model/app_message.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const original =
      'original marker failure\nCaused by: read\nSuppressed: close';

  tearDown(() => messenger.setMockMethodCallHandler(AppBridge.channel, null));

  for (final shown in [false, true]) {
    test('privacy marker read keeps explicit $shown', () async {
      messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
        expect(call.method, 'privacyNoticeShown');
        return shown;
      });
      expect(await AppBridge().privacyNoticeShown(), shown);
    });
  }

  test('an empty marker reply is unknown, not an absent marker', () async {
    messenger.setMockMethodCallHandler(AppBridge.channel, (call) async => null);
    await expectLater(
      AppBridge().privacyNoticeShown(),
      throwsA(isA<FormatException>()),
    );
  });

  for (final marking in [false, true]) {
    test(
      '${marking ? 'write' : 'read'} keeps the original platform error',
      () async {
        final descriptor = const AppMessage(
          'privacyNoticeNotSaved',
          detail: original,
        ).toMap();
        messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
          expect(
            call.method,
            marking ? 'markPrivacyNoticeShown' : 'privacyNoticeShown',
          );
          throw PlatformException(code: 'privacyNotice', details: descriptor);
        });
        final bridge = AppBridge();
        await expectLater(
          marking
              ? bridge.markPrivacyNoticeShown()
              : bridge.privacyNoticeShown(),
          throwsA(
            isA<PlatformFailure>()
                .having((error) => error.code, 'code', 'privacyNotice')
                .having((error) => error.details, 'details', descriptor),
          ),
        );
      },
    );
  }

  test('mark waits for the actual file-worker acknowledgment', () async {
    final entered = Completer<void>();
    final written = Completer<void>();
    messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
      expect(call.method, 'markPrivacyNoticeShown');
      entered.complete();
      await written.future;
      return null;
    });
    var settled = false;
    final mark = AppBridge().markPrivacyNoticeShown().then(
      (_) => settled = true,
    );
    try {
      await entered.future;
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);
    } finally {
      written.complete();
      await mark;
    }
    expect(settled, isTrue);
  });
}
