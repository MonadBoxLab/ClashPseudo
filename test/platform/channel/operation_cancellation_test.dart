import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:async';
import 'dart:convert';

import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/tunnel_mode.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const original =
      'https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture';
  const core = CoreSnapshot(
    phase: 'READY',
    generation: 17,
    configId: 'fixture',
    revision: 4,
    composition: 'original-composition',
    purpose: 'PREVIEW',
  );
  tearDown(() => messenger.setMockMethodCallHandler(AppBridge.channel, null));

  test(
    'cancelled owner can confirm an actual start with a read-only snapshot',
    () async {
      final methods = <String>[];
      final startEntered = Completer<void>();
      final started = Completer<void>();
      messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
        methods.add(call.method);
        expect((call.arguments as Map)['owner'], 'owner');
        if (call.method == 'start') {
          startEntered.complete();
          await started.future;
          return null;
        }
        expect(call.method, 'snapshot');
        return {
          'phase': 'RUNNING',
          'configId': 'fixture',
          'revision': 4,
          'mode': 'rule',
        };
      });
      final bridge = AppBridge(operationId: 'owner');
      final pending = bridge.start(id: 'fixture', revision: 4, mode: null);
      await startEntered.future;
      bridge.cancel();
      started.complete();
      await pending;
      final actual = await bridge.snapshot();
      expect(actual.confirmed, isTrue);
      expect(actual.running, isTrue);
      expect(actual.configId, 'fixture');
      expect(actual.revision, 4);
      await expectLater(bridge.stop(), throwsA(isA<PlatformFailure>()));
      expect(methods, ['start', 'snapshot']);
    },
  );

  test(
    'cancelled owner snapshot retains unconfirmed state and original error',
    () async {
      messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
        expect(call.method, 'snapshot');
        return {
          'phase': 'UNKNOWN',
          'error': messages.platformOperationFailed
              .withDetail(original)
              .toMap(),
        };
      });
      final bridge = AppBridge(operationId: 'owner')..cancel();
      final actual = await bridge.snapshot();
      expect(actual.confirmed, isFalse);
      expect(actual.errorMessage?.detail, original);
    },
  );

  final operations =
      <
        String,
        ({Future<Object?> Function(AppBridge) invoke, Object? response})
      >{
        'delayCancel': (
          invoke: (bridge) => bridge.cancelDelayTest('actual-batch'),
          response: null,
        ),
        'stage': (
          invoke: (bridge) => bridge.stage(messages.settingsSaved),
          response: null,
        ),
        'start': (
          invoke: (bridge) =>
              bridge.start(id: 'fixture', revision: 4, mode: null),
          response: null,
        ),
        'stop': (invoke: (bridge) => bridge.stop(), response: null),
        'setMode': (
          invoke: (bridge) => bridge.setMode(TunnelMode.direct, core),
          response: 'direct',
        ),
        'prepareStrategies': (
          invoke: (bridge) =>
              bridge.prepareStrategies(id: 'fixture', revision: 4, mode: null),
          response: null,
        ),
        'releasePreview': (
          invoke: (bridge) => bridge.releasePreview(),
          response: null,
        ),
        'closeConnection': (
          invoke: (bridge) => bridge.closeConnection(core, 'connection'),
          response: jsonEncode({'status': 'closed'}),
        ),
        'syncSchedules': (
          invoke: (bridge) => bridge.syncSchedules([], kind: 'config'),
          response: null,
        ),
        'backupPrepareExport': (
          invoke: (bridge) => bridge.backupPrepareExport(
            requestId: 'request',
            createdAtMillis: 100,
            expectedEpoch: 7,
            defaults: {},
          ),
          response: {
            'status': 'ready',
            'future': [original, false, null],
          },
        ),
        'backupInstall': (
          invoke: (bridge) =>
              bridge.backupInstall('candidate', expectedEpoch: 7),
          response: {'committed': true, 'epoch': 8, 'future': original},
        ),
        'publishStore': (
          invoke: (bridge) => bridge.publishStore('preferences.json', 7),
          response: {
            'saved': true,
            'durable': true,
            'epoch': 7,
            'future': [original, false, null],
          },
        ),
        'scheduleCoreCleanup': (
          invoke: (bridge) => bridge.scheduleCoreCleanup({'scope': 'cache'}),
          response: {'scheduled': true, 'future': original},
        ),
        'updateResource': (
          invoke: (bridge) =>
              bridge.updateResource(core, kind: 'geo', name: 'GeoIP'),
          response: jsonEncode({
            'generation': 17,
            'composition': 'original-composition',
            'update': {'status': 'ok', 'future': original},
          }),
        ),
        'clearDnsCache': (
          invoke: (bridge) => bridge.clearDnsCache(core),
          response: jsonEncode({
            'cache': {'status': 'cleared', 'future': original},
          }),
        ),
        'runtimeConfig': (
          invoke: (bridge) => bridge.runtimeConfiguration(core),
          response: jsonEncode({
            'general': {
              'future': [original, false, null],
            },
          }),
        ),
      };

  for (final entry in operations.entries) {
    final method = entry.key;
    final operation = entry.value;
    for (final failing in [false, true]) {
      test(
        '$method waits for its actual ${failing ? 'failure' : 'completion'} after cancellation',
        () async {
          final entered = Completer<void>();
          final native = Completer<Object?>();
          final actualError = PlatformException(
            code: 'actual-code',
            message: original,
            details: {
              'future': [original, false, null],
            },
          );
          messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
            expect(call.method, method);
            expect((call.arguments as Map)['owner'], 'owner');
            entered.complete();
            return native.future;
          });
          final bridge = AppBridge(operationId: 'owner');
          final pending = operation.invoke(bridge);
          var settled = false;
          final observer = pending.then<void>(
            (_) => settled = true,
            onError: (Object _) => settled = true,
          );
          final expectation = failing
              ? expectLater(
                  pending,
                  throwsA(
                    isA<PlatformFailure>()
                        .having((error) => error.code, 'code', actualError.code)
                        .having(
                          (error) => error.message,
                          'message',
                          actualError.message,
                        )
                        .having(
                          (error) => error.details,
                          'details',
                          actualError.details,
                        ),
                  ),
                )
              : pending;
          try {
            await entered.future;
            bridge.cancel();
            await bridge.whenCancelled;
            await Future<void>.delayed(Duration.zero);
            expect(settled, isFalse);
            if (failing) {
              native.completeError(actualError);
            } else {
              native.complete(operation.response);
            }
            final actual = await expectation;
            if (!failing && operation.response is Map) {
              expect(actual, operation.response);
            } else if (!failing && method == 'setMode') {
              expect(actual, TunnelMode.direct);
            } else if (!failing && method == 'closeConnection') {
              expect(actual, 'closed');
            } else if (!failing && operation.response is String) {
              expect(actual, jsonDecode(operation.response as String));
            }
            expect(settled, isTrue);
          } finally {
            if (!native.isCompleted) native.complete(operation.response);
            await observer;
          }
        },
      );
    }

    test(
      '$method cancelled before submission never enters the channel',
      () async {
        var calls = 0;
        messenger.setMockMethodCallHandler(AppBridge.channel, (_) async {
          calls++;
          return operation.response;
        });
        final bridge = AppBridge(operationId: 'owner')..cancel();
        await expectLater(
          operation.invoke(bridge),
          throwsA(
            isA<PlatformFailure>().having(
              (error) => error.code,
              'code',
              'expired',
            ),
          ),
        );
        expect(calls, 0);
      },
    );
  }
}
