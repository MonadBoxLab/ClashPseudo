import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:convert';

import 'package:clash_pseudo/src/model/app_message.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:flutter/services.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
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
