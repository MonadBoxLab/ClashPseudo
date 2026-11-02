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
  tearDown(() => messenger.setMockMethodCallHandler(AppBridge.channel, null));

  const detail = <String, Object?>{'id': 'connection', 'generation': 7};
  const snapshot = <String, Object?>{
    'generation': 7,
    'configId': 'fixture',
    'revision': 1,
    'connections': <Object?>[],
  };

  for (final clear in [false, true]) {
    test(
      '${clear ? 'clear' : 'read'} forwards the exact detail lease',
      () async {
        final bridge = AppBridge();
        messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
          expect(
            call.method,
            clear ? 'clearInactiveConnections' : 'connections',
          );
          final arguments = call.arguments as Map;
          expect(arguments['detail'], detail);
          expect(arguments['detailOwner'], 'new-pin');
          return snapshot;
        });
        if (clear) {
          await bridge.clearInactiveConnections(
            detail: detail,
            detailOwner: 'new-pin',
          );
        } else {
          await bridge.recentConnections(
            detail: detail,
            detailOwner: 'new-pin',
          );
        }
      },
    );

    test(
      '${clear ? 'clear' : 'read'} cannot acquire a detail without an owner',
      () async {
        var entered = false;
        messenger.setMockMethodCallHandler(AppBridge.channel, (_) async {
          entered = true;
          return snapshot;
        });
        final bridge = AppBridge();
        for (final owner in [null, '']) {
          await expectLater(
            clear
                ? bridge.clearInactiveConnections(
                    detail: detail,
                    detailOwner: owner,
                  )
                : bridge.recentConnections(detail: detail, detailOwner: owner),
            throwsArgumentError,
          );
        }
        expect(entered, isFalse);
      },
    );
  }

  test('list-only reads carry no detail release instruction', () async {
    messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
      expect((call.arguments as Map)['detail'], isNull);
      expect((call.arguments as Map)['detailOwner'], isNull);
      return snapshot;
    });
    await AppBridge().recentConnections();
    await AppBridge().clearInactiveConnections();
  });

  test('retention names the observer and preserves release failure', () async {
    const original = AppMessage(
      'operationNotCompletedRetry',
      detail: 'cause\nSuppressed: close',
    );
    final values = <bool>[];
    messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
      expect(call.method, 'retain');
      final arguments = call.arguments as Map;
      expect(arguments['observationOwner'], 'observer');
      values.add(arguments['value'] as bool);
      if (arguments['value'] == false) {
        throw PlatformException(code: 'retain', details: original.toMap());
      }
      return null;
    });
    final bridge = AppBridge();
    await bridge.retainObservation(true, owner: 'observer');
    await expectLater(
      bridge.retainObservation(false, owner: 'observer'),
      throwsA(
        isA<PlatformFailure>().having(
          (error) => error.details,
          'details',
          original.toMap(),
        ),
      ),
    );
    expect(values, [true, false]);
  });

  test(
    'detail release keeps the owner and waits for the actual acknowledgment',
    () async {
      final entered = Completer<void>();
      final released = Completer<void>();
      messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
        expect(call.method, 'releaseDetail');
        expect((call.arguments as Map)['detailOwner'], 'old-pin');
        entered.complete();
        await released.future;
        return null;
      });
      var settled = false;
      final pending = AppBridge()
          .releaseConnectionDetail(owner: 'old-pin')
          .then((_) => settled = true);
      try {
        await entered.future;
        await Future<void>.delayed(Duration.zero);
        expect(settled, isFalse);
      } finally {
        released.complete();
        await pending;
      }
      expect(settled, isTrue);
    },
  );
}
