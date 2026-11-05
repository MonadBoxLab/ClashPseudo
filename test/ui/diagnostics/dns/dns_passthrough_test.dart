import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:async';
import 'dart:convert';

import 'package:clash_pseudo/src/ui/diagnostics/dns/dns_controller.dart';
import 'package:clash_pseudo/src/model/dns_snapshot.dart';
import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dns_fakes.dart';
import 'dns_controller_test.dart' show runtimeDnsUiApp;

const original =
    'https://user:pass@fixture.test/?token=原文🙂\n'
    'Authorization: Bearer fixture';

void main() {
  group('DNS controller passthrough', () {
    testWidgets(
      'oversized failure.details rejects the query whole and keeps full causes through drain',
      (tester) async {
        final detail =
            'DNS result exceeds byte limit\n${original * 4096}\n'
            'Caused by: native cancellation failed\nSuppressed: close failed';
        expect(
          utf8.encode(detail).length,
          greaterThan(ApplicationContract.dnsResultBytes),
        );
        final bridge = DnsTestBridge();
        final app = DnsTestApp(bridge);
        final controller = DnsController(app)
          ..setVisible(true)
          ..setName('controlled.example');
        final first = controller.query();
        bridge.replies.single.complete(dnsReply());
        await first;
        final previous = controller.response;
        final pending = controller.query();
        app.publish(dnsBusy: true);
        await tester.pump(
          const Duration(milliseconds: ApplicationContract.dnsBridgeTimeoutMs),
        );
        app.publish(network: 2, dnsBusy: true);
        final failure = PlatformFailure(
          code: 'resultTooLarge',
          details: {
            'id': 'androidErrorCoreReadFailed',
            'args': <String, Object?>{},
            'detail': detail,
          },
        );
        bridge.replies.last.completeError(failure);
        await pending;
        expect(controller.errorCode, 'resultTooLarge');
        expect(controller.errorDetail, '$detail\n$failure');
        expect(controller.response, same(previous));
        expect(controller.stale, isTrue);
        expect(controller.queryBusy, isTrue);
        await controller.query();
        expect(bridge.queries, hasLength(2));
        app.publish(network: 2, dnsBusy: false);
        expect(controller.queryBusy, isFalse);
        expect(controller.errorDetail, '$detail\n$failure');
        controller.dispose();
        app.dispose();
      },
    );

    for (final fakeIp in [false, true]) {
      testWidgets(
        'cache oversized failure.details retains full diagnostics without accepting a result: $fakeIp',
        (tester) async {
          final detail =
              '$original\n${'cause🙂' * (ApplicationContract.dnsResultBytes ~/ 4)}\nSuppressed: close';
          final bridge = DnsTestBridge()
            ..clearPending = Completer<Map<String, dynamic>>();
          final app = DnsTestApp(bridge);
          final controller = DnsController(app)..setVisible(true);
          final pending = controller.clearCache(fakeIp: fakeIp);
          final failure = PlatformFailure(
            code: 'resultTooLarge',
            details: {
              'id': 'androidErrorCoreReadFailed',
              'args': <String, Object?>{},
              'detail': detail,
            },
          );
          final expectation = expectLater(
            pending,
            throwsA(
              isA<DnsFailure>()
                  .having((error) => error.code, 'code', 'resultTooLarge')
                  .having(
                    (error) => error.detail,
                    'complete detail',
                    '$detail\n$failure',
                  ),
            ),
          );
          app.publish(network: 2, dnsBusy: true);
          bridge.clearPending!.completeError(failure);
          await expectation;
          expect(controller.response, isNull);
          expect(controller.clearing, isFalse);
          expect(controller.queryBusy, isTrue);
          expect(bridge.clears, [fakeIp]);
          app.publish(network: 2, dnsBusy: false);
          expect(controller.queryBusy, isFalse);
          controller.dispose();
          app.dispose();
        },
      );
    }

    testWidgets(
      'typed cancellation failure keeps cause and suppressed after actual success',
      (tester) async {
        const detail = '$original\nCaused by: cancel\nSuppressed: close';
        final failure = PlatformFailure(
          code: 'dns',
          details: {
            'id': 'androidErrorCoreReadFailed',
            'args': <String, Object?>{},
            'detail': detail,
          },
        );
        final app = await runtimeDnsUiApp(tester);
        final native = app.native;
        final cancellation = native.gate();
        native.onCancel = (_) async {
          await cancellation.future;
          return {'cancelError': failure.toMap()};
        };
        final controller = DnsController(app)
          ..setVisible(true)
          ..setName('controlled.example');
        final pending = controller.query();
        await tester.pump();
        final request = native
            .calls(ApplicationContract.coreOperationDnsQuery)
            .single;
        await tester.pump(
          const Duration(milliseconds: ApplicationContract.dnsBridgeTimeoutMs),
        );
        app.syncRuntime();
        expect(native.cancellations.single.id, request.id);
        final value = dnsReply(core: native.core);
        request.complete(value['dns']);
        await tester.pump();
        expect(controller.queryBusy, isTrue);
        expect(request.actualExited, isFalse);
        request.signalExit();
        await tester.pump();
        await pending;
        cancellation.complete();
        await tester.pump();
        app.syncRuntime();
        expect(controller.cancellationError, failure.toMap().toString());
        expect(native.dns.snapshot()['cancelError'], failure.toMap());
        expect(controller.response!.answer.single.data, '192.0.2.1');
        expect(
          controller.response!.source.matchesIdentity(native.core),
          isTrue,
        );
        expect(controller.errorCode, isNull);
        expect(controller.queryBusy, isFalse);
        controller.dispose();
        app.dispose();
      },
    );

    for (final networkChanges in [false, true]) {
      testWidgets(
        'actual native failure wins after deadline; network change=$networkChanges',
        (tester) async {
          final app = await runtimeDnsUiApp(tester);
          final native = app.native;
          final controller = DnsController(app)
            ..setVisible(true)
            ..setName('controlled.example');
          final pending = controller.query();
          await tester.pump();
          final source = native.core;
          final request = native
              .calls(ApplicationContract.coreOperationDnsQuery)
              .single;
          await tester.pump(
            const Duration(
              milliseconds: ApplicationContract.dnsBridgeTimeoutMs,
            ),
          );
          app.syncRuntime();
          expect(controller.errorCode, 'timeout');
          expect(controller.queryBusy, isTrue);
          if (networkChanges) {
            native.replaceCore(networkRevision: 2);
            app.syncRuntime();
          }
          final value = dnsError('future-error', core: source);
          (value['dns'] as Map)
            ..['detail'] = original
            ..['future'] = [original, false, null];
          request.complete(value['dns']);
          await tester.pump();
          expect(request.actualExited, isFalse);
          expect(controller.queryBusy, isTrue);
          request.signalExit();
          await tester.pump();
          await pending;
          expect(controller.response, isNull);
          expect(controller.errorCode, 'future-error');
          expect(controller.errorDetail, contains(original));
          expect(controller.errorDetail, isNot(contains('"future"')));
          expect(controller.stale, networkChanges);
          native.replaceCore(networkRevision: 3);
          app.syncRuntime();
          expect(controller.errorCode, 'future-error');
          expect(controller.errorDetail, contains(original));
          expect(controller.errorDetail, isNot(contains('"future"')));
          controller.dispose();
          app.dispose();
        },
      );
    }

    testWidgets('actual platform failure is not replaced by a local deadline', (
      tester,
    ) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      final controller = DnsController(app)
        ..setVisible(true)
        ..setName('controlled.example');
      final pending = controller.query();
      await tester.pump(
        const Duration(milliseconds: ApplicationContract.dnsBridgeTimeoutMs),
      );
      final failure = PlatformFailure(
        code: 'nativeDNS',
        message: original,
        details: {
          'future': [original, false, null],
        },
      );
      bridge.replies.single.completeError(failure);
      await pending;
      expect(controller.errorCode, 'queryFailed');
      expect(controller.errorDetail, failure.toString());
      expect(controller.queryBusy, isFalse);
      controller.dispose();
      app.dispose();
    });

    testWidgets(
      'a cancellation error arriving after query completion cannot rewrite its success',
      (tester) async {
        final failure = PlatformFailure(code: 'cancelDNS', message: original);
        final app = await runtimeDnsUiApp(tester);
        final native = app.native;
        final cancellation = native.gate();
        native.onCancel = (_) async {
          await cancellation.future;
          return {'cancelError': failure.toMap()};
        };
        final controller = DnsController(app)
          ..setVisible(true)
          ..setName('controlled.example');
        final pending = controller.query();
        await tester.pump();
        final request = native
            .calls(ApplicationContract.coreOperationDnsQuery)
            .single;
        await tester.pump(
          const Duration(milliseconds: ApplicationContract.dnsBridgeTimeoutMs),
        );
        app.syncRuntime();
        expect(native.cancellations.length, 1);
        expect(native.cancellations.single.id, request.id);
        final value = dnsReply(core: native.core);
        request.complete(value['dns']);
        await tester.pump();
        expect(controller.queryBusy, isTrue);
        expect(request.actualExited, isFalse);
        request.signalExit();
        await tester.pump();
        await pending;
        expect(controller.response!.answer.single.data, '192.0.2.1');
        expect(
          controller.response!.source.matchesIdentity(native.core),
          isTrue,
        );
        expect(controller.errorCode, isNull);
        expect(controller.status, DnsStatus.ready);
        cancellation.complete();
        await tester.pump();
        app.syncRuntime();
        expect(controller.cancellationError, failure.toMap().toString());
        expect(native.dns.snapshot()['cancelError'], failure.toMap());
        expect(controller.response!.answer.single.data, '192.0.2.1');
        expect(
          controller.response!.source.matchesIdentity(native.core),
          isTrue,
        );
        expect(controller.errorCode, isNull);
        expect(controller.queryBusy, isFalse);
        controller.dispose();
        app.dispose();
      },
    );

    for (final fakeIp in [false, true]) {
      testWidgets(
        'completed cache action retains its full original source and feedback: fakeIp=$fakeIp',
        (tester) async {
          final bridge = DnsTestBridge()
            ..clearPending = Completer<Map<String, dynamic>>();
          final app = DnsTestApp(bridge);
          final controller = DnsController(app)..setVisible(true);
          final pending = controller.clearCache(fakeIp: fakeIp);
          app.publish(network: 2);
          final value = dnsCacheReply(
            fakeIp: fakeIp,
            status: fakeIp ? 'partialOrFailed' : 'completed',
          );
          (value['cache'] as Map)
            ..['detail'] = original
            ..['future'] = [original, false, null];
          bridge.clearPending!.complete(value);
          final result = (await pending)!;
          expect(result.detail, original);
          expect(result.cancellationError, isNull);
          expect(result.networkEpoch, 1);
          expect(result.source.matchesIdentity(dnsCore()), isTrue);
          expect(
            result.status,
            fakeIp ? DnsCacheStatus.partialOrFailed : DnsCacheStatus.completed,
          );
          expect(app.state.networkEpoch, 2);
          expect(controller.clearing, isFalse);
          expect(bridge.clears, [fakeIp]);
          expect(bridge.queries, isEmpty);
          controller.dispose();
          app.dispose();
        },
      );

      testWidgets(
        'failed cache action keeps its actual exception across a network change: fakeIp=$fakeIp',
        (tester) async {
          final bridge = DnsTestBridge()
            ..clearPending = Completer<Map<String, dynamic>>();
          final app = DnsTestApp(bridge);
          final controller = DnsController(app)..setVisible(true);
          final failure = PlatformFailure(code: 'cache', message: original);
          final pending = controller.clearCache(fakeIp: fakeIp);
          final expectation = expectLater(pending, throwsA(same(failure)));
          app.publish(network: 2);
          bridge.clearPending!.completeError(failure);
          await expectation;
          expect(controller.clearing, isFalse);
          expect(bridge.clears, [fakeIp]);
          controller.dispose();
          app.dispose();
        },
      );
    }

    testWidgets(
      'DNS name admission does not blacklist URL-like, whitespace or escaped input',
      (tester) async {
        final bridge = DnsTestBridge();
        final app = DnsTestApp(bridge);
        final controller = DnsController(app)..setVisible(true);
        for (final name in [
          original,
          ' 	controlled.example\n',
          r'one\046label.Example',
          '例子.Example',
        ]) {
          controller.setName(name);
          final pending = controller.query();
          expect(bridge.queries.last.name, name);
          bridge.replies.last.complete(dnsReply());
          await pending;
          expect(controller.name, name);
          expect(controller.errorCode, isNull);
        }
        controller.dispose();
        app.dispose();
      },
    );
  });
}
