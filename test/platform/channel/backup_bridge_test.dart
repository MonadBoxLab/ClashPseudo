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

  for (final committed in [true, false, null]) {
    test(
      'restore preserves native outcome $committed after Dart cancellation',
      () async {
        final entered = Completer<void>();
        final native = Completer<Map<String, Object?>>();
        final outcome = <String, Object?>{
          'committed': committed,
          'rolledBack': committed == false,
          'ready': committed != null,
          'epoch': 8,
          'errorCode': committed == null ? 'storageRecoveryFailed' : null,
        };
        messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
          expect(call.method, 'backupInstall');
          expect(call.arguments, {
            'owner': 'restore-owner',
            'token': 'candidate-token',
            'expectedEpoch': 7,
          });
          entered.complete();
          return native.future;
        });
        final bridge = AppBridge(operationId: 'restore-owner');
        final pending = bridge.backupInstall(
          'candidate-token',
          expectedEpoch: 7,
        );
        var settled = false;
        final observer = pending.then<void>(
          (_) => settled = true,
          onError: (Object _) => settled = true,
        );
        try {
          await entered.future;
          bridge.cancel();
          await Future<void>.delayed(Duration.zero);
          expect(settled, isFalse);
          native.complete(outcome);
          expect(await pending, outcome);
        } finally {
          if (!native.isCompleted) native.complete(outcome);
          await observer;
        }
      },
    );
  }

  test('an ownerless or already cancelled restore never enters native installation', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(AppBridge.channel, (_) async {
      calls++;
      return {};
    });
    for (final bridge in [
      AppBridge(),
      AppBridge(operationId: 'old')..cancel(),
    ]) {
      await expectLater(
        bridge.backupInstall('candidate-token', expectedEpoch: 7),
        throwsA(
          isA<PlatformFailure>().having(
            (error) => error.code,
            'code',
            'expired',
          ),
        ),
      );
    }
    expect(calls, 0);
  });

  test('SAF methods carry tokens and request identities, not archive bytes or caller paths', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
      calls.add(call);
      return call.method == 'backupCancel' || call.method == 'backupDiscard'
          ? null
          : {'status': 'cancelled'};
    });
    final bridge = AppBridge();
    await bridge.backupPickImport('pick-1');
    await bridge.backupSaveExport(
      requestId: 'save-1',
      token: 'token',
      title: 'backup.zip',
    );
    await bridge.backupCancel('save-1');
    await bridge.backupDiscard('token');
    expect(calls.map((call) => call.method), [
      'backupPickImport',
      'backupSaveExport',
      'backupCancel',
      'backupDiscard',
    ]);
    expect(calls.map((call) => call.arguments), [
      {'requestId': 'pick-1'},
      {'requestId': 'save-1', 'token': 'token', 'title': 'backup.zip'},
      {'requestId': 'save-1'},
      {'token': 'token'},
    ]);
  });
}
