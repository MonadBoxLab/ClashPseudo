import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import 'package:clash_pseudo/src/features/strategies/delay_test_controller.dart';
import 'package:clash_pseudo/src/features/strategies/delay_result.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

const source = CoreSnapshot(
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
  final cancelled = <String>[];
  String state = 'running';
  List<Map<String, Object?>> members = [
    {'name': 'A', 'status': 'running'},
    {'name': 'B', 'status': 'pending'},
  ];

  Map<String, dynamic> envelope(String key) => {
    'generation': source.generation,
    'composition': source.composition,
    key: {
      'id': 'batch',
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
    starts++;
    return pendingStart == null ? envelope('start') : pendingStart!.future;
  }

  @override
  Future<Map<String, dynamic>> delayTest(
    CoreSnapshot core,
    String batch,
  ) async {
    reads++;
    return pendingRead == null ? envelope('batch') : pendingRead!.future;
  }

  @override
  Future<void> cancelDelayTest(String batch) async => cancelled.add(batch);
}

void main() {
  testWidgets('late accepted start is cancelled after popup disposal', (
    tester,
  ) async {
    final bridge = DelayBridge()..pendingStart = Completer();
    final controller = DelayTestController(bridge, source, 'group');
    final start = controller.start();
    controller.dispose();
    bridge.pendingStart!.complete(bridge.envelope('start'));
    await start;
    expect(bridge.cancelled, ['batch']);
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
    await start;
    expect(controller.error, 'start');
    bridge.pendingStart!.complete(bridge.envelope('start'));
    await tester.pump();
    expect(bridge.cancelled, ['batch']);
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
    await start;
    final retry = controller.start();
    expect(bridge.starts, 1);
    bridge.pendingRead!.complete(bridge.envelope('batch'));
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
    'finished results are invalidated on same-name provider replacement',
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
      bridge.state = 'expired';
      bridge.members = [
        {'name': 'A', 'status': 'expired'},
      ];
      await tester.pump(DelayTestController.pollInterval);
      await tester.pump();
      expect(controller.results['A']?.status, DelayMemberStatus.expired);
      expect(controller.running, isFalse);
      expect(controller.finished, isTrue);
      final reads = bridge.reads;
      await tester.pump(const Duration(seconds: 2));
      expect(bridge.reads, reads);
    },
  );

  testWidgets('zero success and terminal states retain the real HTTP target', (
    tester,
  ) async {
    final bridge = DelayBridge()
      ..state = 'done'
      ..members = [
        {'name': 'A', 'status': 'success', 'delay': 0},
        {'name': 'B', 'status': 'timeout'},
        {'name': 'C', 'status': 'failed'},
      ];
    final controller = DelayTestController(bridge, source, 'group');
    addTearDown(controller.dispose);
    await controller.start();
    expect(controller.target, 'https://probe.example.test/generate_204');
    expect(controller.results['A']?.status, DelayMemberStatus.success);
    expect(controller.results['A']?.delay, 0);
    expect(controller.results['B']?.status, DelayMemberStatus.timeout);
    expect(controller.results['C']?.status, DelayMemberStatus.failed);
    bridge.pendingRead = Completer();
    await tester.pump(DelayTestController.pollInterval);
    bridge.pendingRead!.completeError(StateError('read failed'));
    await tester.pump();
    expect(controller.error, 'read');
    expect(
      controller.results.values.every(
        (row) => row.status == DelayMemberStatus.expired,
      ),
      isTrue,
    );
    expect(bridge.cancelled, ['batch']);
    final reads = bridge.reads;
    await tester.pump(const Duration(seconds: 2));
    expect(bridge.reads, reads);
  });

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
    expect(controller.error, 'start');
    expect(bridge.cancelled, ['batch']);
    expect(bridge.reads, 0);
  });
}
