import 'dart:async';
import 'dart:convert';

import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/diagnostics/dns/dns_controller.dart';
import 'package:clash_pseudo/src/model/dns_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/core_diagnostic_fixture.dart';
import 'dns_fakes.dart';

const nativeDnsResult = <String, dynamic>{
  'question': {'name': 'example.com.', 'type': 'A'},
  'rcode': 0,
  'rcodeName': 'NOERROR',
  'elapsedMs': 48.4008,
  'truncated': false,
  'answer': [
    {
      'name': 'example.com.',
      'type': 'A',
      'class': 'IN',
      'ttl': 122,
      'data': '172.66.147.243',
    },
    {
      'name': 'example.com.',
      'type': 'A',
      'class': 'IN',
      'ttl': 122,
      'data': '104.20.23.154',
    },
  ],
  'authority': [],
  'additional': [],
  'message': {
    'Id': 17,
    'Response': true,
    'Question': [
      {'Name': 'example.com.', 'Qtype': 1, 'Qclass': 1},
    ],
  },
  'future': [false, null],
  'processId': 'native-body-value',
};

class RuntimeDnsUiApp extends DnsTestApp {
  RuntimeDnsUiApp(this.native) : super(native.platform) {
    syncRuntime();
  }

  final CoreDiagnosticFixture native;

  void syncRuntime() {
    state = AppSnapshot(
      phase: 'RUNNING',
      generation: native.core.generation,
      core: native.core,
      networkEpoch: native.core.networkRevision,
      dnsBusy: native.dns.busy,
      dnsOperation: native.dns.snapshot(),
    );
    notifyListeners();
  }

  @override
  Future<void> refresh() async {
    refreshes++;
    if (refreshPending case final pending?) await pending.future;
    onRefresh?.call();
    syncRuntime();
  }
}

Future<RuntimeDnsUiApp> runtimeDnsUiApp(WidgetTester tester) async {
  final native = CoreDiagnosticFixture()..core = dnsCore();
  addTearDown(() => native.dispose(tester));
  await native.warmUp(tester);
  return RuntimeDnsUiApp(native);
}

void main() {
  for (final purpose in ['RUNNING', 'PREVIEW']) {
    testWidgets('裸 DNS FD 正文经 CoreRuntime 到 Controller 显示两个 A 答案 $purpose', (
      tester,
    ) async {
      final app = await runtimeDnsUiApp(tester);
      final native = app.native;
      native.core = dnsCore(purpose: purpose);
      app.syncRuntime();
      final controller = DnsController(app)
        ..setVisible(true)
        ..setName('example.com');
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      final source = native.core;
      final pending = controller.query();
      await tester.pump();
      final request = native
          .calls(ApplicationContract.coreOperationDnsQuery)
          .single;
      final owner = native.dns.snapshot()['queryOwner'];
      expect(request.arguments, {'name': 'example.com', 'type': 'A'});
      expect(request.identity['processId'], source.processId);
      request.complete(nativeDnsResult);
      await tester.pump();
      expect(controller.response, isNull);
      expect(controller.queryBusy, isTrue);
      expect(native.dns.busy, isTrue);
      expect(native.dns.snapshot()['queryOwner'], owner);
      expect(request.actualExited, isFalse);
      await controller.query();
      expect(native.calls(ApplicationContract.coreOperationDnsQuery), [
        request,
      ]);
      request.signalExit();
      await tester.pump();
      await pending;
      final response = controller.response!;
      expect(response.raw['dns'], nativeDnsResult);
      expect(response.raw['processId'], source.processId);
      expect(response.raw['purpose'], purpose);
      expect(response.source.purpose, purpose);
      expect(response.source.matchesIdentity(source), isTrue);
      expect(response.source.networkRevision, source.networkRevision);
      expect(response.networkEpoch, source.networkRevision);
      expect(response.name, 'example.com.');
      expect(response.rcode, 0);
      expect(response.rcodeName, 'NOERROR');
      expect(response.elapsedMs, 48.4008);
      expect(response.answer.map((record) => record.data), [
        '172.66.147.243',
        '104.20.23.154',
      ]);
      expect(controller.status, DnsStatus.ready);
      expect(controller.errorCode, isNull);
      expect(controller.errorDetail, isNull);
      expect(controller.stale, isFalse);
      expect(controller.canQuery, isTrue);
      expect(app.commands, isEmpty);
    });
  }

  for (final errorOnly in [false, true]) {
    testWidgets('裸 DNS FD 保留${errorOnly ? '原生错误正文' : '答案与 terminal 错误'}及取消原文', (
      tester,
    ) async {
      final app = await runtimeDnsUiApp(tester);
      final native = app.native;
      const original = {
        'code': 'queryFailed',
        'message': '原始 DNS 错误',
        'cause': {'type': 'IOException', 'message': '原始 cause'},
        'stack': '原始 stack',
        'suppressed': [
          {'message': '原始 suppressed'},
        ],
        'future': [false, null],
      };
      const cancellation = {
        'code': 'cancelFailed',
        'cause': {'message': '取消 cause'},
        'suppressed': [
          {'message': '取消 suppressed'},
        ],
        'future': [false, null],
      };
      native.onCancel = (_) => {'cancelError': cancellation};
      final controller = DnsController(app)
        ..setVisible(true)
        ..setName('example.com');
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      final pending = controller.query();
      await tester.pump();
      final request = native
          .calls(ApplicationContract.coreOperationDnsQuery)
          .single;
      final owner = native.dns.snapshot()['queryOwner'] as String;
      await native.dns.cancel(native.core, 'old-owner');
      expect(native.cancellations, isEmpty);
      await native.dns.cancel(native.core, owner);
      final raw = errorOnly
          ? {'error': 'queryFailed', 'detail': '原生 detail', 'future': original}
          : nativeDnsResult;
      request.complete(
        raw,
        terminal: {
          if (!errorOnly) 'error': original,
          'cancelError': cancellation,
        },
      );
      await tester.pump();
      expect(controller.queryBusy, isTrue);
      expect(native.dns.busy, isTrue);
      expect(native.dns.snapshot()['queryOwner'], owner);
      expect(native.cancellations, [request]);
      expect(controller.response, isNull);
      request.signalExit();
      await tester.pump();
      await pending;
      expect(controller.status, DnsStatus.failed);
      expect(controller.errorCode, 'queryFailed');
      final retained = jsonDecode(controller.errorDetail!) as Map;
      expect(retained['dns'], raw);
      expect(retained['cancelError'], cancellation);
      expect(retained['operationError'], 'queryFailed');
      if (errorOnly) {
        expect(controller.response, isNull);
      } else {
        expect(retained['error'], original);
        expect(controller.response!.answer, hasLength(2));
        expect(controller.response!.cancellationError, cancellation);
      }
      expect(native.dns.snapshot()['cancelError'], cancellation);
      expect(controller.queryBusy, isFalse);
    });
  }

  for (final fakeIp in [false, true]) {
    for (final status in ['completed', 'empty', 'partialOrFailed']) {
      testWidgets(
        '裸 ${fakeIp ? 'fake-IP' : 'DNS cache'} FD 保留 $status、身份与实际 drain',
        (tester) async {
          final app = await runtimeDnsUiApp(tester);
          final native = app.native;
          final source = native.core;
          final controller = DnsController(app)..setVisible(true);
          addTearDown(() {
            controller.dispose();
            app.dispose();
          });
          final raw = <String, dynamic>{
            'status': status,
            if (fakeIp) ...{
              'persistent': true,
              'ipv4': {
                'active': status != 'empty',
                'outcome': status == 'empty'
                    ? 'inactive'
                    : status == 'completed'
                    ? 'cleared'
                    : 'unconfirmed',
              },
              'ipv6': {'active': false, 'outcome': 'inactive'},
            } else ...{
              'resolverActive': status != 'empty',
              'systemResolverActive': false,
            },
            'future': [false, null],
            'detail': '原生清理结果',
            'stale': status == 'partialOrFailed',
          };
          const cancellation = {
            'cause': '取消原文',
            'future': [false, null],
          };
          final pending = controller.clearCache(fakeIp: fakeIp);
          await tester.pump();
          final opcode = fakeIp
              ? ApplicationContract.coreOperationFakeIpFlush
              : ApplicationContract.coreOperationDnsCacheClear;
          final request = native.calls(opcode).single;
          expect(request.arguments, isEmpty);
          request.complete(raw, terminal: {'cancelError': cancellation});
          await tester.pump();
          expect(controller.clearing, isTrue);
          expect(native.dns.busy, isTrue);
          expect(await controller.clearCache(fakeIp: !fakeIp), isNull);
          expect(native.calls(opcode), [request]);
          request.signalExit();
          await tester.pump();
          final result = (await pending)!;
          expect(result.status.name, status);
          expect(result.raw['cache'], raw);
          expect(result.raw['cancelError'], cancellation);
          expect(result.source.matchesIdentity(source), isTrue);
          expect(result.networkEpoch, source.networkRevision);
          expect(result.stale, status == 'partialOrFailed');
          if (fakeIp) {
            expect(result.persistent, isTrue);
            expect(result.ipv4!.active, status != 'empty');
            expect(result.ipv6, (
              active: false,
              outcome: DnsCacheOutcome.inactive,
            ));
          }
          expect(controller.clearing, isFalse);
          expect(native.dns.busy, isFalse);
          expect(app.commands, isEmpty);
        },
      );
    }
  }

  for (final fakeIp in [false, true]) {
    testWidgets('裸 ${fakeIp ? 'fake-IP' : 'DNS cache'} FD 的原错误由严格 model 保留', (
      tester,
    ) async {
      final app = await runtimeDnsUiApp(tester);
      final native = app.native;
      final controller = DnsController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      const raw = {
        'error': 'future-cache-error',
        'detail': '原始 cache 错误',
        'future': [false, null],
      };
      final pending = controller.clearCache(fakeIp: fakeIp);
      final rejected = expectLater(
        pending,
        throwsA(
          isA<DnsFailure>()
              .having((error) => error.code, 'code', 'future-cache-error')
              .having(
                (error) => (jsonDecode(error.detail!) as Map)['cache'],
                '原始 cache 正文',
                raw,
              ),
        ),
      );
      await tester.pump();
      final opcode = fakeIp
          ? ApplicationContract.coreOperationFakeIpFlush
          : ApplicationContract.coreOperationDnsCacheClear;
      final request = native.calls(opcode).single;
      request.complete(raw);
      await tester.pump();
      expect(controller.clearing, isTrue);
      expect(native.dns.busy, isTrue);
      request.signalExit();
      await tester.pump();
      await rejected;
      expect(controller.clearing, isFalse);
      expect(native.dns.busy, isFalse);
    });
  }

  testWidgets(
    'background cancellation cannot use a cached false as the native drain barrier',
    (tester) async {
      final app = await runtimeDnsUiApp(tester);
      final native = app.native;
      final controller = DnsController(app)
        ..setVisible(true)
        ..setName('controlled.example');
      final pending = controller.query();
      await tester.pump();
      final request = native
          .calls(ApplicationContract.coreOperationDnsQuery)
          .single;
      final owner = native.dns.snapshot()['queryOwner'];
      app.setForeground(false);
      await tester.pump();
      request.complete(dnsError('cancelled', core: native.core)['dns']);
      await tester.pump();
      expect(app.state.dnsBusy, isFalse);
      expect(request.hasTerminal, isTrue);
      expect(request.actualExited, isFalse);
      expect(native.dns.busy, isTrue);
      expect(native.cancellations.single.id, request.id);
      expect(native.dns.snapshot()['queryOwner'], owner);
      expect(controller.queryBusy, isTrue);
      app.refreshPending = Completer<void>();
      app.setForeground(true);
      await tester.pump();
      expect(controller.queryBusy, isTrue);
      await controller.query();
      expect(native.calls(ApplicationContract.coreOperationDnsQuery).length, 1);
      app.refreshPending!.complete();
      await tester.pump();
      expect(controller.queryBusy, isTrue);
      request.signalExit();
      await tester.pump();
      await pending;
      expect(controller.canQuery, isTrue);
      controller.dispose();
      app.dispose();
    },
  );

  testWidgets(
    'each query owns its cancellation token across same-core reopen and another controller',
    (tester) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      final first = DnsController(app)
        ..setVisible(true)
        ..setName('controlled.example');
      final one = first.query();
      final ownerOne = bridge.queries.last.queryOwner;
      expect(ownerOne, isNotEmpty);
      first.setVisible(false);
      expect(bridge.cancellations.single.queryOwner, ownerOne);
      bridge.replies.last.complete(dnsError('cancelled'));
      await one;
      first.setVisible(true);
      final two = first.query();
      final ownerTwo = bridge.queries.last.queryOwner;
      expect(ownerTwo, isNot(ownerOne));
      first.setVisible(false);
      expect(bridge.cancellations.last.queryOwner, ownerTwo);
      bridge.replies.last.complete(dnsError('cancelled'));
      await two;
      final second = DnsController(app)
        ..setVisible(true)
        ..setName('controlled.example');
      final three = second.query();
      final ownerThree = bridge.queries.last.queryOwner;
      expect({ownerOne, ownerTwo, ownerThree}.length, 3);
      // Dispose the old completed page while retaining the new request's ownership.
      final cancelled = bridge.cancellations.length;
      first.dispose();
      expect(bridge.cancellations.length, cancelled);
      bridge.replies.last.complete(dnsReply());
      await three;
      second.dispose();
      app.dispose();
    },
  );

  testWidgets(
    'editing an in-flight draft cannot relabel its reply as the current input',
    (tester) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      final controller = DnsController(app)
        ..setVisible(true)
        ..setName('controlled.example');
      final pending = controller.query();
      controller.setName('other.example');
      controller.setType('TXT');
      expect(bridge.queries.single.name, 'controlled.example');
      expect(bridge.queries.single.type, 'A');
      bridge.replies.single.complete(dnsReply());
      await pending;
      expect(controller.response!.name, 'controlled.example.');
      expect(controller.name, 'other.example');
      expect(controller.type, 'TXT');
      expect(controller.stale, isTrue);
      expect(controller.status, DnsStatus.stale);
      controller.dispose();
      app.dispose();
    },
  );

  testWidgets(
    'construction is inert; page visibility prepares only the existing preview',
    (tester) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge)
        ..publish(phase: 'STOPPED', core: const CoreSnapshot());
      app.collection = ConfigCollection(
        entries: const [
          ConfigEntry(
            id: 'controlled',
            name: 'Controlled',
            kind: ConfigKind.local,
            revision: 1,
            body: '{}',
          ),
        ],
        selectedId: 'controlled',
      );
      final controller = DnsController(app);
      await tester.pump();
      expect(app.commands, isEmpty);
      expect(bridge.queries, isEmpty);
      controller.setVisible(true);
      await tester.pump();
      expect(app.commands.single, {
        'action': 'prepareStrategies',
        'id': 'controlled',
        'revision': 1,
      });
      app.publish(
        phase: 'STOPPED',
        core: dnsCore(purpose: 'PREVIEW'),
      );
      expect(controller.canQuery, isTrue);
      expect(bridge.queries, isEmpty);
      controller.setName('controlled.example');
      final query = controller.query();
      bridge.replies.single.complete(dnsReply(core: app.state.core));
      await query;
      expect(controller.response!.source.purpose, 'PREVIEW');
      controller.dispose();
      app.dispose();
    },
  );

  testWidgets(
    'explicit query only; one real flight and NXDOMAIN is a valid result',
    (tester) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      final controller = DnsController(app)
        ..setVisible(true)
        ..setName('controlled.example');
      expect(bridge.queries, isEmpty);
      final pending = controller.query();
      await controller.query();
      expect(bridge.queries.length, 1);
      expect(controller.queryBusy, isTrue);
      expect(controller.status, DnsStatus.querying);
      app.publish(dnsBusy: true);
      expect(bridge.cancellations, isEmpty);
      bridge.replies.single.complete(dnsReply(rcode: 3, answer: []));
      await pending;
      expect(controller.response!.rcodeName, 'NXDOMAIN');
      expect(controller.errorCode, isNull);
      expect(
        controller.queryBusy,
        isTrue,
      ); // Native completion notification wins.
      app.publish();
      expect(controller.canQuery, isTrue);
      controller.dispose();
      app.dispose();
    },
  );

  testWidgets(
    'six-second deadline never frees the real flight or automatically retries',
    (tester) async {
      final app = await runtimeDnsUiApp(tester);
      final native = app.native;
      final controller = DnsController(app)
        ..setVisible(true)
        ..setName('controlled.example');
      final pending = controller.query();
      await tester.pump();
      final request = native
          .calls(ApplicationContract.coreOperationDnsQuery)
          .single;
      final owner = native.dns.snapshot()['queryOwner'];
      await tester.pump(const Duration(seconds: 6));
      app.syncRuntime();
      expect(controller.errorCode, 'timeout');
      expect(controller.queryBusy, isTrue);
      expect(native.cancellations.length, 1);
      expect(native.cancellations.single.id, request.id);
      expect(native.dns.snapshot()['queryOwner'], owner);
      await controller.query();
      await tester.pump(const Duration(seconds: 30));
      expect(native.calls(ApplicationContract.coreOperationDnsQuery).length, 1);
      request.complete(dnsReply(core: native.core)['dns']);
      await tester.pump();
      expect(request.actualExited, isFalse);
      expect(controller.queryBusy, isTrue);
      request.signalExit();
      await tester.pump();
      await pending;
      expect(controller.response!.answer.single.data, '192.0.2.1');
      expect(controller.errorCode, isNull);
      expect(controller.queryBusy, isFalse);
      controller.dispose();
      app.dispose();
    },
  );

  testWidgets('bridge timeout retains gate until native busy actually drains', (
    tester,
  ) async {
    final bridge = DnsTestBridge();
    final app = DnsTestApp(bridge);
    final controller = DnsController(app)
      ..setVisible(true)
      ..setName('controlled.example');
    final pending = controller.query();
    app.publish(dnsBusy: true);
    bridge.replies.single.complete(dnsError('timeout'));
    await pending;
    expect(controller.errorCode, 'timeout');
    expect(controller.queryBusy, isTrue);
    expect(app.refreshes, 1);
    controller.setVisible(false);
    controller.setVisible(true);
    await controller.query();
    expect(bridge.queries.length, 1);
    app.publish(dnsBusy: false);
    expect(controller.queryBusy, isFalse);
    final retry = controller.query();
    bridge.replies.last.complete(dnsReply());
    await retry;
    expect(bridge.queries.length, 2);
    controller.dispose();
    app.dispose();
  });

  for (final change in [
    'processId',
    'inputId',
    'networkRevision',
    'generation',
    'composition',
    'configId',
    'revision',
    'purpose',
    'network',
    'stop',
    'background',
    'leave',
  ]) {
    testWidgets(
      'actual old-source response remains stale across $change and draft survives',
      (tester) async {
        final bridge = DnsTestBridge();
        final app = DnsTestApp(bridge);
        final controller = DnsController(app)
          ..setVisible(true)
          ..setName('_sip._tcp.controlled.example')
          ..setType('SRV');
        final first = controller.query();
        bridge.replies.single.complete(dnsReply(type: 'SRV'));
        await first;
        expect(controller.stale, isFalse);
        final second = controller.query();
        switch (change) {
          case 'generation':
            app.publish(core: dnsCore(generation: 2));
          case 'composition':
            app.publish(core: dnsCore(composition: 'replacement'));
          case 'processId':
          case 'inputId':
          case 'networkRevision':
          case 'configId':
          case 'revision':
            final source = app.state.core;
            app.publish(
              core: CoreSnapshot(
                processId: change == 'processId'
                    ? 'replacement-process'
                    : source.processId,
                inputId: change == 'inputId'
                    ? 'replacement-input'
                    : source.inputId,
                networkRevision: change == 'networkRevision'
                    ? 2
                    : source.networkRevision,
                generation: source.generation,
                phase: source.phase,
                purpose: source.purpose,
                configId: change == 'configId'
                    ? 'replacement'
                    : source.configId,
                revision: change == 'revision' ? 2 : source.revision,
                composition: source.composition,
              ),
            );
          case 'purpose':
            app.publish(
              core: dnsCore(purpose: 'PREVIEW'),
              phase: 'STOPPED',
            );
          case 'network':
            app.publish(network: 2);
          case 'stop':
            app.publish(phase: 'STOPPED', core: const CoreSnapshot());
          case 'background':
            app.setForeground(false);
          case 'leave':
            controller.setVisible(false);
        }
        expect(controller.stale, isTrue);
        expect(bridge.cancellations, isNotEmpty);
        bridge.replies.last.complete(
          dnsReply(answer: [dnsRecord(data: '192.0.2.99')]),
        );
        await second;
        expect(controller.response!.answer.single.data, '192.0.2.99');
        expect(controller.response!.source.matchesIdentity(dnsCore()), isTrue);
        expect(controller.response!.networkEpoch, 1);
        expect(controller.name, '_sip._tcp.controlled.example');
        expect(controller.type, 'SRV');
        controller.setVisible(true);
        app.setForeground(true);
        await tester.pump();
        expect(bridge.queries.length, 2);
        controller.dispose();
        app.dispose();
      },
    );
  }

  testWidgets(
    'response envelope identity is checked before reading data or errors',
    (tester) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      final controller = DnsController(app)
        ..setVisible(true)
        ..setName('controlled.example');
      for (final field in [
        'processId',
        'inputId',
        'networkRevision',
        'generation',
        'composition',
        'configId',
        'revision',
        'purpose',
        'networkEpoch',
      ]) {
        final pending = controller.query();
        final reply = dnsReply()..remove(field);
        bridge.replies.last.complete(reply);
        await pending;
        expect(controller.response, isNull);
        expect(controller.errorCode, 'invalidResponse', reason: field);
        expect(controller.errorDetail, reply.toString());
        final different = dnsReply();
        final original = different[field];
        different[field] = original is int
            ? original + 1
            : '$original-replaced';
        final mismatched = controller.query();
        bridge.replies.last.complete(different);
        await mismatched;
        expect(controller.response, isNull, reason: field);
        expect(controller.errorCode, 'invalidResponse', reason: field);
        expect(controller.errorDetail, different.toString());
      }
      controller.dispose();
      app.dispose();
    },
  );

  testWidgets(
    'invalid admission never starts I/O; edits can recover without clearing input',
    (tester) async {
      final app = await runtimeDnsUiApp(tester);
      final native = app.native;
      final controller = DnsController(app)
        ..setVisible(true)
        ..setName('');
      await controller.query();
      expect(controller.errorCode, 'invalidRequest');
      expect(native.calls(ApplicationContract.coreOperationDnsQuery), isEmpty);
      controller.setName('例子.example');
      expect(controller.errorCode, isNull);
      final pending = controller.query();
      await tester.pump();
      final request = native
          .calls(ApplicationContract.coreOperationDnsQuery)
          .single;
      expect(request.arguments['name'], '例子.example');
      request.complete(dnsReply(core: native.core)['dns']);
      await tester.pump();
      expect(controller.queryBusy, isTrue);
      expect(request.actualExited, isFalse);
      request.signalExit();
      await tester.pump();
      await pending;
      expect(controller.response, isNotNull);
      controller.dispose();
      app.dispose();
    },
  );

  testWidgets(
    'two clear actions remain independent and preserve partial/native empty outcomes',
    (tester) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      final controller = DnsController(app)..setVisible(true);
      expect(
        (await controller.clearCache(fakeIp: false))!.status,
        DnsCacheStatus.completed,
      );
      bridge.clearValue = dnsCacheReply(
        fakeIp: true,
        status: 'partialOrFailed',
        persistent: true,
      );
      expect(
        (await controller.clearCache(fakeIp: true))!.status,
        DnsCacheStatus.partialOrFailed,
      );
      bridge.clearValue = dnsCacheReply(fakeIp: true, status: 'empty');
      expect(
        (await controller.clearCache(fakeIp: true))!.status,
        DnsCacheStatus.empty,
      );
      expect(bridge.clears, [false, true, true]);
      expect(app.commands, isEmpty);
      expect(bridge.queries, isEmpty);
      controller.dispose();
      app.dispose();
    },
  );

  testWidgets(
    'cache actions cannot overlap; an actual clear keeps its original source after a network change',
    (tester) async {
      final bridge = DnsTestBridge()
        ..clearPending = Completer<Map<String, dynamic>>();
      final app = DnsTestApp(bridge);
      final controller = DnsController(app)
        ..setVisible(true)
        ..setName('controlled.example');
      final clear = controller.clearCache(fakeIp: false);
      expect(controller.clearing, isTrue);
      expect(await controller.clearCache(fakeIp: true), isNull);
      await controller.query();
      expect(bridge.queries, isEmpty);
      app.publish(network: 2);
      bridge.clearPending!.complete(dnsCacheReply());
      final result = (await clear)!;
      expect(result.status, DnsCacheStatus.completed);
      expect(result.networkEpoch, 1);
      expect(app.state.networkEpoch, 2);
      expect(controller.clearing, isFalse);
      controller.dispose();
      app.dispose();
    },
  );

  testWidgets(
    'dispose cancels but does not interpret a late result or notify',
    (tester) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      final controller = DnsController(app)
        ..setVisible(true)
        ..setName('controlled.example');
      final pending = controller.query();
      controller.dispose();
      expect(bridge.cancellations.length, 1);
      bridge.replies.single.complete(dnsReply());
      await pending;
      expect(controller.response, isNull);
      app.dispose();
    },
  );
}
