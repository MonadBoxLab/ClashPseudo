import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:async';

import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(AppBridge.channel, null));

  for (final durable in [true, false]) {
    test('publication preserves actual durability $durable', () async {
      messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
        expect(call.method, 'publishStore');
        expect(call.arguments, {
          'owner': 'publication-owner',
          'file': 'overrides.json',
          'epoch': 7,
        });
        return {'saved': true, 'durable': durable, 'epoch': 7};
      });
      expect(
        await AppBridge(operationId: 'publication-owner')
            .publishStore('overrides.json', 7),
        {'saved': true, 'durable': durable, 'epoch': 7},
      );
    });
  }

  test(
    'cancel waits for admitted publication and preserves a committed result',
    () async {
      final entered = Completer<void>();
      final native = Completer<Map<String, Object?>>();
      messenger.setMockMethodCallHandler(AppBridge.channel, (_) async {
        entered.complete();
        return native.future;
      });
      final bridge = AppBridge(operationId: 'publication-owner');
      final pending = bridge.publishStore('configurations.json', 7);
      var settled = false;
      final observation = pending.then<void>(
        (_) {
          settled = true;
        },
        onError: (Object _) {
          settled = true;
        },
      );
      try {
        await entered.future;
        bridge.cancel();
        await Future<void>.delayed(Duration.zero);
        expect(settled, isFalse);
        native.complete({'saved': true, 'durable': true, 'epoch': 7});
        expect(await pending, {'saved': true, 'durable': true, 'epoch': 7});
      } finally {
        if (!native.isCompleted) {
          native.complete({'saved': true, 'durable': true, 'epoch': 7});
        }
        await observation;
      }
    },
  );

  test('cancel before publication never submits native work', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(AppBridge.channel, (_) async {
      calls++;
      return {'saved': true, 'durable': true, 'epoch': 7};
    });
    final bridge = AppBridge(operationId: 'publication-owner')..cancel();
    await expectLater(
      bridge.publishStore('configurations.json', 7),
      throwsA(
        isA<PlatformFailure>().having((error) => error.code, 'code', 'expired'),
      ),
    );
    expect(calls, 0);
  });

  test(
    'cancellation that wins native admission remains a real rejection',
    () async {
      final entered = Completer<void>();
      final native = Completer<Map<String, Object?>>();
      messenger.setMockMethodCallHandler(AppBridge.channel, (_) async {
        entered.complete();
        return native.future;
      });
      final bridge = AppBridge(operationId: 'publication-owner');
      final pending = bridge.publishStore('overrides.json', 7);
      final expectation = expectLater(
        pending,
        throwsA(
          isA<PlatformFailure>().having(
            (error) => error.code,
            'code',
            'expired',
          ),
        ),
      );
      await entered.future;
      bridge.cancel();
      native.completeError(PlatformException(code: 'expired'));
      await expectation;
    },
  );

  final invalid = <Object?>[
    null,
    {},
    {'saved': false, 'durable': true, 'epoch': 7},
    {'saved': true, 'durable': true, 'epoch': 8},
    {'saved': true, 'durable': true, 'epoch': 7.0},
    {'saved': true, 'epoch': 7},
    {'saved': true, 'durable': 'true', 'epoch': 7},
  ];
  final expectedDetails = <String>[
    '{expectedEpoch: 7, epochType: null, savedType: null, durableType: null}',
    '{expectedEpoch: 7, epochType: Null, savedType: Null, durableType: Null}',
    '{expectedEpoch: 7, epoch: 7, saved: false, durable: true}',
    '{expectedEpoch: 7, epoch: 8, saved: true, durable: true}',
    '{expectedEpoch: 7, epochType: double, saved: true, durable: true}',
    '{expectedEpoch: 7, epoch: 7, saved: true, durableType: Null}',
    '{expectedEpoch: 7, epoch: 7, saved: true, durableType: String}',
  ];
  for (final (index, response) in invalid.indexed) {
    test('publication rejects unconfirmed response $index', () async {
      messenger.setMockMethodCallHandler(
        AppBridge.channel,
        (_) async => response,
      );
      await expectLater(
        AppBridge(operationId: 'publication-owner')
            .publishStore('preferences.json', 7),
        throwsA(
          isA<PlatformFailure>()
              .having((error) => error.code, 'code', 'storage')
              .having(
                (error) => (error.details as Map)['id'],
                'message',
                'storageUnavailable',
              )
              .having(
                (error) => (error.details as Map)['detail'],
                'projected detail',
                expectedDetails[index],
              ),
        ),
      );
    });
  }
}
