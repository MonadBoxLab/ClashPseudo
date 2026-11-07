import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:convert';

import 'package:clash_pseudo/src/model/app_message.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:flutter/services.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:clash_pseudo/src/platform/channel/method_channel_port.dart';
import 'package:clash_pseudo/src/platform/core/core_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const core = CoreSnapshot(
    processId: 'core-process',
    inputId: 'core-input',
    networkRevision: 12,
    phase: 'READY',
    generation: 17,
    composition: 'actual-loaded-composition',
    configId: 'configuration-id',
    revision: 4,
    purpose: 'PREVIEW',
  );
  const identity = {
    'processId': 'core-process',
    'inputId': 'core-input',
    'networkRevision': 12,
    'generation': 17,
    'composition': 'actual-loaded-composition',
    'configId': 'configuration-id',
    'revision': 4,
    'purpose': 'PREVIEW',
  };
  tearDown(() => messenger.setMockMethodCallHandler(AppBridge.channel, null));

  test(
    'query and cancellation carry the same per-query owner and full identity',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
        calls.add(call.method);
        expect(call.arguments, {
          ...identity,
          'queryOwner': 'page-query-1',
          if (call.method == 'dnsQuery')
            'query': {'name': '_service.example.test', 'type': 'SRV'},
        });
        return call.method == 'dnsQuery'
            ? jsonEncode({
                ...identity,
                'networkEpoch': 12,
                'dns': {'error': 'cancelled'},
              })
            : null;
      });
      final bridge = AppBridge();
      final result = await bridge.dnsQuery(
        core,
        name: '_service.example.test',
        type: 'SRV',
        queryOwner: 'page-query-1',
      );
      await bridge.cancelDnsQuery(core, queryOwner: 'page-query-1');
      expect(result['dns'], {'error': 'cancelled'});
      expect(calls, ['dnsQuery', 'cancelDnsQuery']);
    },
  );

  for (final method in ['dnsQuery', 'clearDnsCache', 'flushFakeIp']) {
    test(
      '$method rejects an oversized result with its machine code and complete diagnostics',
      () async {
        final original =
            '${'native detail 原文🙂\n'.padRight(300000, 'x')}'
            '\nCaused by: cancel original\nSuppressed: close original';
        final failure = AppMessage(
          'androidErrorCoreReadFailed',
          detail: original,
        );
        messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
          expect(call.method, method);
          throw PlatformException(
            code: 'resultTooLarge',
            details: failure.toMap(),
          );
        });
        final bridge = AppBridge();
        final Future<Object?> pending = switch (method) {
          'dnsQuery' => bridge.dnsQuery(
            core,
            name: 'fixture.test',
            type: 'A',
            queryOwner: 'query',
          ),
          'clearDnsCache' => bridge.clearDnsCache(core),
          _ => bridge.flushFakeIp(core),
        };
        await expectLater(
          pending,
          throwsA(
            isA<PlatformFailure>()
                .having((error) => error.code, 'code', 'resultTooLarge')
                .having((error) => error.details, 'details', failure.toMap()),
          ),
        );
      },
    );
  }

  test('cache operations remain independent and carry full identity', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
      calls.add(call.method);
      expect(call.arguments, identity);
      return jsonEncode({
        ...identity,
        'networkEpoch': 12,
        'cache': {'status': 'empty'},
      });
    });
    final bridge = AppBridge();
    expect((await bridge.clearDnsCache(core))['cache'], {'status': 'empty'});
    expect(calls, ['clearDnsCache']);
    expect((await bridge.flushFakeIp(core))['cache'], {'status': 'empty'});
    expect(calls, ['clearDnsCache', 'flushFakeIp']);
  });

  test(
    'memory read requires neither a core identity nor a work owner',
    () async {
      messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
        expect(call.method, 'appMemory');
        expect(call.arguments, isEmpty);
        return jsonEncode({
          'valid': false,
          'processRssBytes': null,
          'sampledAt': 123,
          'error': 'unavailable',
        });
      });
      final result = await AppBridge().appMemory();
      expect(result['valid'], isFalse);
      expect(result['processRssBytes'], isNull);
      expect(result['error'], 'unavailable');
    },
  );

  test('response parsing errors retain cause and position without the full response', () async {
    const wire = '{"responseOnly":"not-for-display",!';
    late final FormatException original;
    try {
      jsonDecode(wire);
      fail('Invalid JSON must not parse successfully');
    } on FormatException catch (error) {
      original = error;
    }
    final bridge = AppBridge().forOperation(operationId: 'operation');
    final calls = <String, Future<Map<String, dynamic>> Function()>{
      'appMemory': bridge.appMemory,
      'coreMemory': () => bridge.coreMemory(core),
      'dnsQuery': () => bridge.dnsQuery(
        core,
        name: 'example.test',
        type: 'A',
        queryOwner: 'query',
      ),
      'clearDnsCache': () => bridge.clearDnsCache(core),
      'flushFakeIp': () => bridge.flushFakeIp(core),
      'sampleConnections': () => bridge.sampleConnections(core, {}),
      'updateResource': () =>
          bridge.updateResource(core, kind: 'proxy', name: 'provider'),
    };
    for (final entry in calls.entries) {
      messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
        expect(call.method, entry.key);
        return wire;
      });
      await expectLater(
        entry.value(),
        throwsA(
          isA<FormatException>()
              .having((error) => error.message, 'message', original.message)
              .having((error) => error.offset, 'offset', original.offset)
              .having((error) => error.source, 'source', isNull)
              .having(
                (error) => error.toString(),
                'detail',
                isNot(contains(wire)),
              ),
        ),
      );
    }
  });

  test(
    'storage commit identity failures retain only actual state and errors',
    () async {
      messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
        expect(call.method, 'publishStore');
        return {
          'saved': true,
          'durable': false,
          'epoch': 4,
          'errorCode': 'publishedDirectorySyncFailed',
          'errorDetail': {'id': 'storageUnavailable', 'detail': 'fsync failed'},
          'responseOnly': 'not-for-display',
        };
      });
      final bridge = AppBridge().forOperation(operationId: 'operation');
      await expectLater(
        bridge.publishStore('preferences.json', 3),
        throwsA(
          isA<PlatformFailure>()
              .having((error) => error.code, 'code', 'storage')
              .having(
                (error) => error.details.toString(),
                'detail',
                allOf(
                  contains('expectedEpoch: 3'),
                  contains('epoch: 4'),
                  contains('saved: true'),
                  contains('durable: false'),
                  contains('publishedDirectorySyncFailed'),
                  contains('fsync failed'),
                  isNot(contains('not-for-display')),
                ),
              ),
        ),
      );
    },
  );

  test('runtime input publication failures retain identity and errors without the full response', () async {
    messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
      expect(call.method, 'publishRunInput');
      expect(call.arguments, {'path': '/tmp/input', 'inputId': 'expected'});
      return {
        'saved': true,
        'durable': false,
        'path': '/private/published',
        'inputId': 'other',
        'error': {'message': '实际 fsync 错误'},
        'cancelError': {'message': '实际取消错误'},
        'responseOnly': '不显示的完整响应字段',
      };
    });
    final client = CoreClient(const MethodChannelPort(AppBridge.channel));
    await expectLater(
      client.publishRunInput('/tmp/input', 'expected'),
      throwsA(
        isA<PlatformFailure>()
            .having((error) => error.code, 'code', 'storage')
            .having((error) => error.details, 'details', {
              'expectedInputId': 'expected',
              'inputId': 'other',
              'saved': true,
              'durable': false,
              'path': '/private/published',
              'error': {'message': '实际 fsync 错误'},
              'cancelError': {'message': '实际取消错误'},
            }),
      ),
    );
  });

  test('native DNS slot is not a global application writer', () {
    final state = AppSnapshot.fromMap({
      'phase': 'STOPPED',
      'generation': 0,
      'storageReady': true,
      'storageEpoch': 3,
      'dnsBusy': true,
      'networkEpoch': 12,
    });
    expect(state.dnsBusy, isTrue);
    expect(state.networkEpoch, 12);
    expect(state.busy, isFalse);
  });

  for (final value in [null, -1, 1.5, '12']) {
    test(
      'invalid network epoch $value stays unavailable rather than becoming zero',
      () {
        expect(
          AppSnapshot.fromMap({'networkEpoch': value}).networkEpoch,
          isNull,
        );
      },
    );
  }
}
