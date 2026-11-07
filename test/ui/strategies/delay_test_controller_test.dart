import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import 'package:clash_pseudo/src/ui/strategies/delay_test_controller.dart';
import 'package:clash_pseudo/src/model/delay_result.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

const source = CoreSnapshot(
  processId: 'delay-process',
  inputId: 'delay-input',
  networkRevision: 3,
  generation: 7,
  phase: 'READY',
  purpose: 'PREVIEW',
  configId: 'config',
  revision: 1,
  composition: 'composition',
);

class DelayBridge extends AppBridge {
  Completer<Map<String, dynamic>>? pendingStart;
  Completer<Map<String, dynamic>>? pendingRead;
  int starts = 0;
  int reads = 0;
  late String batchId;
  final cancelled = <String>[];
  String state = 'running';
  List<Map<String, Object?>> members = [
    {'name': 'A', 'status': 'running'},
    {'name': 'B', 'status': 'pending'},
  ];

  Map<String, dynamic> envelope(String key) => {
    'processId': source.processId,
    'inputId': source.inputId,
    'networkRevision': source.networkRevision,
    'generation': source.generation,
    'configId': source.configId,
    'revision': source.revision,
    'purpose': source.purpose,
    'composition': source.composition,
    key: {
      'id': batchId,
      'group': 'group',
      'state': state,
      'target': 'https://probe.example.test/generate_204',
      'members': members,
    },
  };

  @override
  Future<Map<String, dynamic>> startDelayTest(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) async {
    expectSync(core.identity, source.identity);
    expectSync(core.networkRevision, source.networkRevision);
    expectSync(query['id'], matches(RegExp(r'^[0-9a-f]{32}$')));
    batchId = query['id'] as String;
    starts++;
    return pendingStart == null ? envelope('start') : pendingStart!.future;
  }

  @override
  Future<Map<String, dynamic>> delayTest(
    CoreSnapshot core,
    String batch,
  ) async {
    expectSync(core.identity, source.identity);
    expectSync(core.networkRevision, source.networkRevision);
    expectSync(batch, batchId);
    reads++;
    return pendingRead == null ? envelope('batch') : pendingRead!.future;
  }

  @override
  Future<void> cancelDelayTest(String batch) async => cancelled.add(batch);
}

class _CleanupBridge extends DelayBridge {
  Completer<void>? pendingCancel;
  Object? cancelFailure;

  @override
  Future<void> cancelDelayTest(String batch) async {
    cancelled.add(batch);
    if (pendingCancel != null) await pendingCancel!.future;
    if (cancelFailure case final error?) throw error;
  }
}

void main() {
  group('request identity and lifecycle', () {
    testWidgets('late accepted start is cancelled after popup disposal', (
      tester,
    ) async {
      final bridge = DelayBridge()..pendingStart = Completer();
      final controller = DelayTestController(bridge, source, 'group');
      final start = controller.start();
      controller.dispose();
      bridge.pendingStart!.complete(bridge.envelope('start'));
      await start;
      expect(bridge.cancelled, [bridge.batchId]);
      expect(bridge.reads, 0);
    });

    testWidgets('timed out start cancels its eventual accepted batch', (
      tester,
    ) async {
      final bridge = DelayBridge()..pendingStart = Completer();
      final controller = DelayTestController(bridge, source, 'group');
      addTearDown(controller.dispose);
      final start = controller.start();
      await tester.pump(const Duration(seconds: 6));
      expect(controller.error, contains('TimeoutException'));
      expect(controller.busy, isTrue);
      controller.abandon();
      bridge.pendingStart!.complete(bridge.envelope('start'));
      await start;
      await tester.pump();
      expect(bridge.cancelled, [bridge.batchId]);
    });

    testWidgets('only one native read remains in flight even after timeout', (
      tester,
    ) async {
      final bridge = DelayBridge()..pendingRead = Completer();
      final controller = DelayTestController(bridge, source, 'group');
      addTearDown(controller.dispose);
      final start = controller.start();
      await tester.pump();
      expect(bridge.reads, 1);
      await tester.pump(const Duration(seconds: 4));
      expect(bridge.reads, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(controller.error, contains('TimeoutException'));
      expect(controller.busy, isTrue);
      final retry = controller.start();
      expect(bridge.starts, 1);
      controller.abandon();
      bridge.pendingRead!.complete(bridge.envelope('batch'));
      await start;
      await retry;
      await tester.pump();
      expect(controller.results['A']?.status, isNot(DelayMemberStatus.running));
    });

    testWidgets(
      'cancelled batch keeps settled member results and maps cancellation',
      (tester) async {
        final bridge = DelayBridge()
          ..state = 'cancelled'
          ..members = [
            {'name': 'A', 'status': 'success', 'delay': 12},
            {'name': 'B', 'status': 'cancelled'},
          ];
        final controller = DelayTestController(bridge, source, 'group');
        addTearDown(controller.dispose);
        await controller.start();
        expect(controller.results['A']?.status, DelayMemberStatus.success);
        expect(controller.results['A']?.delay, 12);
        expect(controller.results['B']?.status, DelayMemberStatus.cancelled);
        expect(controller.running, isFalse);
        expect(controller.finished, isTrue);
      },
    );

    testWidgets(
      'source expiry preserves finished results after same-name replacement',
      (tester) async {
        final bridge = DelayBridge()
          ..state = 'done'
          ..members = [
            {'name': 'A', 'status': 'success', 'delay': 12},
          ];
        final controller = DelayTestController(bridge, source, 'group');
        addTearDown(controller.dispose);
        await controller.start();
        expect(controller.finished, isTrue);
        expect(controller.terminalState, 'done');
        expect(controller.results['A']?.status, DelayMemberStatus.success);
        expect(controller.results['A']?.delay, 12);
        expect(controller.target, 'https://probe.example.test/generate_204');
        final doneResults = controller.results;
        final doneReads = bridge.reads;
        await tester.pump(const Duration(milliseconds: 2100));
        expect(bridge.reads, doneReads);
        expect(bridge.cancelled, isEmpty);
        expect(controller.results, same(doneResults));

        final activeBridge = DelayBridge()..members = List.of(bridge.members);
        final active = DelayTestController(activeBridge, source, 'group');
        addTearDown(active.dispose);
        await active.start();
        expect(active.finished, isFalse);
        expect(activeBridge.reads, 1);
        activeBridge.state = 'expired';
        activeBridge.members = [
          {'name': 'A', 'status': 'success', 'delay': 12},
        ];
        await tester.pump(DelayTestController.pollInterval);
        expect(activeBridge.reads, 2);
        await tester.pump();
        expect(active.results['A']?.status, DelayMemberStatus.success);
        expect(active.results['A']?.delay, 12);
        expect(active.terminalState, 'expired');
        expect(active.running, isFalse);
        expect(active.finished, isTrue);
        expect(activeBridge.cancelled, [activeBridge.batchId]);
        final reads = activeBridge.reads;
        await tester.pump(const Duration(seconds: 2));
        expect(activeBridge.reads, reads);
        expect(bridge.reads, doneReads);
        expect(controller.terminalState, 'done');
        expect(controller.results, same(doneResults));
      },
    );

    testWidgets(
      'zero success and terminal states retain the real HTTP target',
      (tester) async {
        final bridge = DelayBridge()
          ..state = 'done'
          ..members = [
            {'name': 'A', 'status': 'success', 'delay': 0},
            {
              'name': 'B',
              'status': 'timeout',
              'error': 'context deadline exceeded',
              'cancelError': 'original cancel error',
              'time': '2026-11-05T10:20:30.000Z',
            },
            {
              'name': 'C',
              'status': 'failed',
              'error':
                  'connect https://user:pass@example.test/path?token=fixture',
            },
          ];
        final controller = DelayTestController(bridge, source, 'group');
        addTearDown(controller.dispose);
        await controller.start();
        expect(controller.target, 'https://probe.example.test/generate_204');
        expect(controller.results['A']?.status, DelayMemberStatus.success);
        expect(controller.results['A']?.delay, 0);
        expect(controller.results['B']?.status, DelayMemberStatus.timeout);
        expect(controller.results['C']?.status, DelayMemberStatus.failed);
        expect(controller.results['B']?.error, 'context deadline exceeded');
        expect(
          controller.results['B']?.cancellationError,
          'original cancel error',
        );
        expect(
          controller.results['B']?.time,
          DateTime.utc(2026, 11, 5, 10, 20, 30),
        );
        expect(
          controller.results['C']?.error,
          'connect https://user:pass@example.test/path?token=fixture',
        );
        expect(controller.terminalState, 'done');
        expect(controller.finished, isTrue);
        final doneResults = controller.results;
        final doneReads = bridge.reads;
        await tester.pump(const Duration(milliseconds: 2100));
        expect(bridge.reads, doneReads);
        expect(bridge.cancelled, isEmpty);
        expect(controller.results, same(doneResults));

        final activeBridge = DelayBridge()..members = List.of(bridge.members);
        final active = DelayTestController(activeBridge, source, 'group');
        addTearDown(active.dispose);
        await active.start();
        expect(active.running, isTrue);
        expect(activeBridge.reads, 1);
        activeBridge.pendingRead = Completer();
        await tester.pump(DelayTestController.pollInterval);
        expect(activeBridge.reads, 2);
        activeBridge.pendingRead!.completeError(StateError('read failed'));
        await tester.pump();
        expect(active.error, StateError('read failed').toString());
        expect(active.terminalState, 'expired');
        expect(active.results['A']?.status, DelayMemberStatus.success);
        expect(active.results['A']?.delay, 0);
        expect(active.results['B']?.status, DelayMemberStatus.timeout);
        expect(active.results['B']?.error, 'context deadline exceeded');
        expect(active.results['C']?.status, DelayMemberStatus.failed);
        expect(
          active.results['C']?.error,
          'connect https://user:pass@example.test/path?token=fixture',
        );
        expect(active.target, 'https://probe.example.test/generate_204');
        expect(activeBridge.cancelled, [activeBridge.batchId]);
        final reads = activeBridge.reads;
        await tester.pump(const Duration(seconds: 2));
        expect(activeBridge.reads, reads);
        expect(bridge.reads, doneReads);
        expect(controller.terminalState, 'done');
        expect(controller.results, same(doneResults));
      },
    );

    testWidgets('wrong start identity is released instead of being polled', (
      tester,
    ) async {
      final bridge = DelayBridge()..pendingStart = Completer();
      final controller = DelayTestController(bridge, source, 'group');
      addTearDown(controller.dispose);
      final start = controller.start();
      bridge.pendingStart!.complete({
        ...bridge.envelope('start'),
        'composition': 'other',
      });
      await start;
      expect(controller.error, contains('FormatException'));
      expect(bridge.cancelled, [bridge.batchId]);
      expect(bridge.reads, 0);
    });

    testWidgets('read failure retires only unfinished member observations', (
      tester,
    ) async {
      final bridge = DelayBridge()
        ..members = [
          {'name': 'A', 'identity': 'first', 'status': 'success', 'delay': 12},
          {'name': 'B', 'identity': 'second', 'status': 'running'},
        ];
      final controller = DelayTestController(bridge, source, 'group');
      addTearDown(controller.dispose);
      await controller.start();
      final settled = controller.results['A'];
      bridge.pendingRead = Completer();
      await tester.pump(DelayTestController.pollInterval);
      bridge.pendingRead!.completeError(StateError('read 原文'));
      await tester.pump();
      expect(identical(controller.results['A'], settled), isTrue);
      expect(controller.results['B']?.identity, 'second');
      expect(controller.results['B']?.status, DelayMemberStatus.expired);
      expect(controller.error, StateError('read 原文').toString());
      expect(controller.terminalState, 'expired');
      expect(bridge.cancelled, [bridge.batchId]);
    });
  });

  group('completion and actual drain', () {
    testWidgets(
      'deadline reports waiting but actual start and zero result settle',
      (tester) async {
        final bridge = DelayBridge()
          ..pendingStart = Completer()
          ..state = 'done'
          ..members = [
            {'name': 'A', 'status': 'success', 'delay': 0},
          ];
        final controller = DelayTestController(bridge, source, 'group');
        addTearDown(controller.dispose);
        var settled = false;
        final start = controller.start().then((_) => settled = true);
        await tester.pump(const Duration(seconds: 6));
        expect(settled, isFalse);
        expect(controller.busy, isTrue);
        expect(controller.failure, isA<TimeoutException>());
        await controller.start();
        expect(bridge.starts, 1);
        bridge.pendingStart!.complete(bridge.envelope('start'));
        await start;
        expect(settled, isTrue);
        expect(controller.error, isNull);
        expect(controller.results['A']?.status, DelayMemberStatus.success);
        expect(controller.results['A']?.delay, 0);
        expect(controller.terminalState, 'done');
        expect(bridge.cancelled, isEmpty);
      },
    );

    testWidgets('done stops polling only after the actual read settles', (
      tester,
    ) async {
      final bridge = DelayBridge();
      final controller = DelayTestController(bridge, source, 'group');
      addTearDown(controller.dispose);
      await controller.start();
      expect(bridge.reads, 1);
      bridge.pendingRead = Completer();
      await tester.pump(DelayTestController.pollInterval);
      expect(bridge.reads, 2);
      bridge.state = 'done';
      bridge.members = [
        {
          'name': 'A',
          'identity': 'actual-member',
          'status': 'success',
          'delay': 0,
          'future': {'empty': [], 'enabled': false},
        },
      ];
      await tester.pump(const Duration(seconds: 6));
      expect(controller.failure, isA<TimeoutException>());
      expect(controller.finished, isFalse);
      expect(controller.busy, isTrue);
      expect(controller.batch, bridge.batchId);
      expect(bridge.cancelled, isEmpty);
      await controller.start();
      expect(bridge.starts, 1);
      expect(bridge.reads, 2);
      bridge.pendingRead!.complete(bridge.envelope('batch'));
      await tester.idle();
      expect(controller.busy, isFalse);
      expect(controller.finished, isTrue);
      expect(controller.terminalState, 'done');
      expect(controller.failure, isNull);
      expect(controller.results['A']?.delay, 0);
      expect(controller.results['A']?.identity, 'actual-member');
      final result = controller.results;
      await tester.pump(const Duration(milliseconds: 2100));
      expect(bridge.reads, 2);
      expect(bridge.starts, 1);
      expect(bridge.cancelled, isEmpty);
      expect(controller.batch, bridge.batchId);
      expect(controller.results, same(result));
    });

    testWidgets('done batch restart retains the slot until actual release', (
      tester,
    ) async {
      final bridge = _CleanupBridge()
        ..state = 'done'
        ..members = [
          {'name': 'A', 'status': 'success', 'delay': 0},
        ];
      final controller = DelayTestController(bridge, source, 'group');
      addTearDown(controller.dispose);
      await controller.start();
      expect(controller.terminalState, 'done');
      expect(bridge.cancelled, isEmpty);
      bridge.pendingCancel = Completer();
      var settled = false;
      final restart = controller.start().then((_) => settled = true);
      await tester.pump(const Duration(seconds: 6));
      expect(controller.busy, isTrue);
      expect(settled, isFalse);
      expect(controller.cleanupFailure, isA<TimeoutException>());
      expect(bridge.cancelled, [bridge.batchId]);
      expect(bridge.starts, 1);
      expect(bridge.reads, 1);
      await controller.start();
      expect(bridge.starts, 1);
      bridge.pendingCancel!.complete();
      await restart;
      expect(settled, isTrue);
      expect(controller.busy, isFalse);
      expect(controller.cleanupFailure, isNull);
      expect(controller.terminalState, 'done');
      expect(bridge.starts, 2);
      expect(bridge.reads, 2);
      await tester.pump(const Duration(milliseconds: 2100));
      expect(bridge.reads, 2);
    });

    testWidgets(
      'abandon retains late actual observation without restoring actions',
      (tester) async {
        final bridge = _CleanupBridge()..pendingRead = Completer();
        final controller = DelayTestController(bridge, source, 'group');
        addTearDown(controller.dispose);
        final start = controller.start();
        await tester.pump();
        controller.abandon();
        bridge.members = [
          {
            'name': 'A',
            'identity': 'captured-member',
            'status': 'success',
            'delay': 0,
            'future': {
              'zero': 0,
              'enabled': false,
              'nullable': null,
              'empty': [],
            },
          },
        ];
        final reply = bridge.envelope('batch');
        bridge.pendingRead!.complete(reply);
        await start;
        expect(controller.results['A']?.status, DelayMemberStatus.success);
        expect(controller.results['A']?.delay, 0);
        expect(controller.results['A']?.identity, 'captured-member');
        expect(controller.terminalState, 'expired');
        expect(controller.running, isFalse);
        expect(bridge.cancelled, [bridge.batchId]);
        await controller.start();
        await tester.pump(const Duration(seconds: 2));
        expect(bridge.starts, 1);
        expect(bridge.reads, 1);
      },
    );

    testWidgets(
      'late original failure and cleanup failure both survive deadline',
      (tester) async {
        final actual = StateError('actual probe 原文');
        final cleanup = StateError('actual release 原文');
        final bridge = _CleanupBridge()
          ..pendingRead = Completer()
          ..cancelFailure = cleanup;
        final controller = DelayTestController(bridge, source, 'group');
        addTearDown(controller.dispose);
        final start = controller.start();
        await tester.pump(const Duration(seconds: 6));
        expect(controller.failure, isA<TimeoutException>());
        expect(controller.busy, isTrue);
        bridge.pendingRead!.completeError(actual, StackTrace.current);
        await start;
        expect(controller.failure, same(actual));
        expect(controller.cleanupFailure, same(cleanup));
        expect(controller.failureStack, isNotNull);
        expect(controller.cleanupStack, isNotNull);
        expect(controller.error, contains(actual.toString()));
        expect(controller.error, contains(cleanup.toString()));
        expect(controller.batch, bridge.batchId);
        expect(bridge.starts, 1);
      },
    );

    testWidgets('release owns busy slot until its actual receipt', (
      tester,
    ) async {
      final bridge = _CleanupBridge()
        ..state = 'cancelled'
        ..pendingCancel = Completer();
      final controller = DelayTestController(bridge, source, 'group');
      addTearDown(controller.dispose);
      var settled = false;
      final start = controller.start().then((_) => settled = true);
      await tester.pump(const Duration(seconds: 6));
      expect(controller.busy, isTrue);
      expect(settled, isFalse);
      await controller.start();
      expect(bridge.starts, 1);
      bridge.pendingCancel!.complete();
      await start;
      expect(controller.busy, isFalse);
      expect(controller.cleanupFailure, isNull);
    });

    testWidgets('actual delay results remain when the source expires', (
      tester,
    ) async {
      final bridge = DelayBridge()
        ..state = 'expired'
        ..members = [
          {
            'name': 'A',
            'status': 'expired',
            'delay': 0,
            'result': {'status': 'success', 'delay': 0},
            'future': false,
          },
        ];
      final controller = DelayTestController(bridge, source, 'group');
      addTearDown(controller.dispose);
      await controller.start();
      expect(controller.results['A']?.status, DelayMemberStatus.success);
      expect(controller.results['A']?.delay, 0);
      expect(controller.results['A']?.name, 'A');
      expect(controller.terminalState, 'expired');
    });
  });
}
