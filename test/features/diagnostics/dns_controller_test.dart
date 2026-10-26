import 'dart:async';

import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/diagnostics/dns_controller.dart';
import 'package:clash_pseudo/src/features/diagnostics/dns_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dns_fakes.dart';

void main() {
  testWidgets(
    'background cancellation cannot use a cached false as the native drain barrier',
    (tester) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      final controller = DnsController(app)
        ..setVisible(true)
        ..setName('controlled.example');
      final pending = controller.query();
      app.setForeground(false);
      bridge.replies.single.complete(dnsError('cancelled'));
      await pending;
      expect(
        app.state.dnsBusy,
        isFalse,
      ); // Last UI snapshot predates admission.
      expect(controller.queryBusy, isTrue);
      app.refreshPending = Completer<void>();
      app.onRefresh = () => app.publish(dnsBusy: true);
      app.setForeground(true);
      await tester.pump();
      expect(controller.queryBusy, isTrue);
      await controller.query();
      expect(bridge.queries.length, 1);
      app.refreshPending!.complete();
      await tester.pump();
      expect(controller.queryBusy, isTrue);
      app.publish(dnsBusy: false);
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
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      final controller = DnsController(app)
        ..setVisible(true)
        ..setName('controlled.example');
      final pending = controller.query();
      await tester.pump(const Duration(seconds: 6));
      expect(controller.errorCode, 'timeout');
      expect(controller.queryBusy, isTrue);
      expect(bridge.cancellations.length, 1);
      await controller.query();
      await tester.pump(const Duration(seconds: 30));
      expect(bridge.queries.length, 1);
      bridge.replies.single.complete(dnsReply());
      await pending;
      expect(controller.response, isNull);
      expect(controller.errorCode, 'timeout');
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
    testWidgets('old response is isolated across $change and draft survives', (
      tester,
    ) async {
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
        case 'configId':
          app.publish(
            core: const CoreSnapshot(
              generation: 1,
              phase: 'READY',
              purpose: 'VPN',
              configId: 'replacement',
              revision: 1,
              composition: 'composition-1',
            ),
          );
        case 'revision':
          app.publish(
            core: const CoreSnapshot(
              generation: 1,
              phase: 'READY',
              purpose: 'VPN',
              configId: 'controlled',
              revision: 2,
              composition: 'composition-1',
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
      expect(controller.response!.answer.single.data, '192.0.2.1');
      expect(controller.name, '_sip._tcp.controlled.example');
      expect(controller.type, 'SRV');
      controller.setVisible(true);
      app.setForeground(true);
      await tester.pump();
      expect(bridge.queries.length, 2);
      controller.dispose();
      app.dispose();
    });
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
        expect(controller.errorCode, 'obsolete', reason: field);
      }
      controller.dispose();
      app.dispose();
    },
  );

  testWidgets(
    'invalid admission never starts I/O; edits can recover without clearing input',
    (tester) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      final controller = DnsController(app)
        ..setVisible(true)
        ..setName('https://controlled.example');
      await controller.query();
      expect(controller.errorCode, 'invalidRequest');
      expect(bridge.queries, isEmpty);
      controller.setName('例子.example');
      expect(controller.errorCode, isNull);
      final pending = controller.query();
      expect(bridge.queries.single.name, '例子.example');
      bridge.replies.single.complete(dnsReply());
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
    'cache action cannot overlap queries or another cache call; late clear is obsolete',
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
      final expectation = expectLater(
        clear,
        throwsA(isA<DnsFailure>().having((e) => e.code, 'code', 'obsolete')),
      );
      bridge.clearPending!.complete(dnsCacheReply());
      await expectation;
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
