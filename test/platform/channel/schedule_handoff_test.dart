import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:clash_pseudo/src/model/tunnel_mode.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  const expected = AppSnapshot(
    phase: 'RUNNING',
    generation: 4,
    configId: 'one',
    revision: 1,
    mode: TunnelMode.rule,
    core: CoreSnapshot(
      generation: 8,
      phase: 'READY',
      purpose: 'RUNNING',
      configId: 'one',
      revision: 1,
      composition: '["one",1]',
    ),
  );

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppBridge.channel, (call) async {
          calls.add(call);
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppBridge.channel, null);
  });

  test(
    'scheduled handoff carries its owner and exact running identity',
    () async {
      final bridge = AppBridge(operationId: 'scheduled-owner');
      await bridge.finishScheduledDownload(
        expected,
        kind: 'override',
        id: 'part',
      );
      expect(calls, hasLength(1));
      expect(calls.single.method, 'finishScheduledDownload');
      expect(calls.single.arguments, {
        'owner': 'scheduled-owner',
        'kind': 'override',
        'id': 'part',
        'sessionGeneration': 4,
        'generation': 8,
        'composition': '["one",1]',
        'configId': 'one',
        'revision': 1,
      });
    },
  );

  test('a cancelled executor cannot request a local handoff', () async {
    final bridge = AppBridge(operationId: 'retired-owner')..cancel();
    await expectLater(
      bridge.finishScheduledDownload(expected, kind: 'config', id: 'one'),
      throwsA(isA<PlatformFailure>()),
    );
    expect(calls, isEmpty);
  });
}
