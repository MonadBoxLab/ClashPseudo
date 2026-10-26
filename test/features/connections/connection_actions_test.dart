import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import 'package:clash_pseudo/src/features/connections/connection_actions.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

const core = CoreSnapshot(
  generation: 7,
  phase: 'READY',
  purpose: 'VPN',
  configId: 'one',
  revision: 1,
);
const command = <String, dynamic>{
  'action': 'closeConnection',
  'generation': 7,
  'configId': 'one',
  'revision': 1,
  'connectionId': '00000001-0000-4000-8000-000000000000',
};

class CloseBridge extends AppBridge {
  AppSnapshot state = const AppSnapshot(phase: 'RUNNING', core: core);
  String result = 'closed';
  int calls = 0;
  Completer<String>? pending;
  @override
  Future<AppSnapshot> snapshot() async => state;
  @override
  Future<String> closeConnection(CoreSnapshot target, String id) async {
    calls++;
    expect(target.generation, core.generation);
    expect(target.configId, core.configId);
    expect(target.revision, core.revision);
    expect(id, command['connectionId']);
    return pending?.future ?? result;
  }

  @override
  Future<void> stop() async => fail('Single close must not stop the VPN');
  @override
  Future<Map<String, dynamic>> paths() async =>
      fail('Single close must not touch configurations');
}

void main() {
  for (final status in ['closed', 'absent', 'failed']) {
    test('returns structured $status without interpreting messages', () async {
      final bridge = CloseBridge()..result = status;
      final result = await ConnectionActions(bridge).execute(command);
      expect(result['connectionStatus'], status);
      expect(result['success'], status != 'failed');
      expect(bridge.calls, 1);
    });
  }

  test('stopped, replaced, and preview contexts never close', () async {
    for (final state in [
      const AppSnapshot(phase: 'STOPPED', core: core),
      const AppSnapshot(
        phase: 'RUNNING',
        core: CoreSnapshot(
          generation: 8,
          phase: 'READY',
          purpose: 'VPN',
          configId: 'one',
          revision: 1,
        ),
      ),
      const AppSnapshot(
        phase: 'RUNNING',
        core: CoreSnapshot(
          generation: 7,
          phase: 'READY',
          purpose: 'PREVIEW',
          configId: 'one',
          revision: 1,
        ),
      ),
    ]) {
      final bridge = CloseBridge()..state = state;
      final result = await ConnectionActions(bridge).execute(command);
      expect(result['connectionStatus'], 'unconfirmed');
      expect(bridge.calls, 0);
    }
  });

  test('unrecognized native status is unconfirmed, not success', () async {
    final bridge = CloseBridge()..result = 'maybe';
    final result = await ConnectionActions(bridge).execute(command);
    expect(result['connectionStatus'], 'unconfirmed');
    expect(result['success'], isFalse);
  });

  testWidgets('timeout is unconfirmed and late success never retries', (
    tester,
  ) async {
    final bridge = CloseBridge()..pending = Completer<String>();
    final operation = ConnectionActions(bridge).execute(command);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    final result = await operation;
    expect(result['connectionStatus'], 'unconfirmed');
    bridge.pending!.complete('closed');
    await tester.pump();
    expect(result['connectionStatus'], 'unconfirmed');
    expect(bridge.calls, 1);
  });
}
