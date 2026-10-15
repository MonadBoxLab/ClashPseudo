import 'dart:async';

import 'package:clash_pseudo/features/configs/config_entry.dart';
import 'package:clash_pseudo/features/mode/tunnel_mode.dart';
import 'package:clash_pseudo/features/strategies/strategy_choice.dart';
import 'package:clash_pseudo/features/strategies/strategy_controller.dart';
import 'package:clash_pseudo/features/strategies/strategy_snapshot.dart';
import 'package:clash_pseudo/platform/app_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import 'strategy_fakes.dart';

void main() {
  late StrategyBridgeFake bridge;
  late StrategyAppFake app;
  late StrategyController controller;
  setUp(() {
    bridge = StrategyBridgeFake();
    app = StrategyAppFake(bridge);
    controller = StrategyController(app);
  });
  tearDown(() {
    controller.dispose();
    app.dispose();
  });

  testWidgets('only visible strategy page reads and notifications coalesce', (
    tester,
  ) async {
    app.changed();
    await tester.pump(const Duration(seconds: 10));
    expect(bridge.reads, 0);
    controller.setVisible(true);
    await tester.pump();
    expect(bridge.reads, 1);
    expect(controller.canChoose, isTrue);
    app.changed();
    app.changed();
    app.changed();
    await tester.pump();
    expect(bridge.reads, 1);
    await tester.pump(const Duration(seconds: 5));
    expect(bridge.reads, 2);
    controller.setVisible(false);
    await tester.pump(const Duration(seconds: 30));
    expect(bridge.reads, 2);
    controller.setVisible(true);
    await tester.pump();
    expect(bridge.reads, 3);
    app.setForeground(false);
    await tester.pump(const Duration(seconds: 30));
    expect(bridge.reads, 3);
  });

  testWidgets(
    'saved choices arriving after platform result notify without querying',
    (tester) async {
      controller.setVisible(true);
      await tester.pump();
      var notifications = 0;
      controller.addListener(() => notifications++);
      app.collection = app.collection.replace(
        strategyEntry.withChoice(
          '出口',
          const StrategyChoice(type: StrategyType.select, member: 'B'),
        ),
      );
      app.changed();
      await tester.pump();
      expect(notifications, 1);
      expect(controller.app.collection.selected!.choices['出口']!.member, 'B');
      expect(bridge.reads, 1);
      controller.setVisible(false);
    },
  );

  testWidgets('late hidden-page result cannot overwrite a fresh read', (
    tester,
  ) async {
    final late = Completer<StrategySnapshot>();
    bridge.pendingRead = late;
    controller.setVisible(true);
    await tester.pump();
    controller.setVisible(false);
    bridge.pendingRead = null;
    controller.setVisible(true);
    await tester.pump();
    expect(controller.data!.find('出口')!.now, 'A');
    late.complete(strategyData(now: 'B'));
    await tester.pump();
    expect(controller.data!.find('出口')!.now, 'A');
    controller.setVisible(false);
  });

  testWidgets(
    'timed out strategy read disables choices but keeps running VPN stoppable',
    (tester) async {
      app.state = const AppSnapshot(
        phase: 'RUNNING',
        configId: 'one',
        revision: 1,
        mode: TunnelMode.rule,
        core: vpnCore,
      );
      bridge.pendingRead = Completer<StrategySnapshot>();
      controller.setVisible(true);
      await tester.pump(const Duration(seconds: 5));
      expect(controller.readError, isNotNull);
      expect(controller.canChoose, isFalse);
      expect(app.canToggle, isTrue);
      app.state = const AppSnapshot(
        phase: 'RUNNING',
        configId: 'one',
        revision: 1,
        mode: TunnelMode.rule,
        core: CoreSnapshot(phase: 'UNKNOWN', error: 'unconfirmed'),
      );
      app.changed();
      expect(app.canToggle, isTrue);
      expect(controller.canChoose, isFalse);
      controller.setVisible(false);
    },
  );

  testWidgets('failed query disables old choices without preventing VPN stop', (
    tester,
  ) async {
    app.state = const AppSnapshot(
      phase: 'RUNNING',
      configId: 'one',
      revision: 1,
      mode: TunnelMode.rule,
      core: vpnCore,
    );
    bridge.data = strategyData(core: vpnCore);
    controller.setVisible(true);
    await tester.pump();
    bridge.failRead = true;
    await tester.pump(const Duration(seconds: 5));
    expect(controller.readError, isNotNull);
    expect(controller.data, isNotNull);
    expect(controller.canChoose, isFalse);
    expect(app.canToggle, isTrue);
    final reads = bridge.reads;
    await tester.pump(const Duration(seconds: 1));
    expect(bridge.reads, reads + 1);
    bridge.failRead = false;
    await tester.pump(const Duration(seconds: 2));
    expect(controller.canChoose, isTrue);
    expect(app.commands, isEmpty);
    controller.setVisible(false);
  });

  testWidgets(
    'mode and definition references govern GLOBAL, never the whole page',
    (tester) async {
      controller.setVisible(true);
      await tester.pump();
      expect(controller.groups.any((group) => group.name == 'GLOBAL'), isFalse);
      expect(controller.groups.any((group) => group.hidden), isFalse);
      app.collection = ConfigCollection(
        entries: [strategyEntry],
        selectedId: 'one',
        mode: TunnelMode.global,
      );
      app.changed();
      await tester.pump();
      expect(controller.groups.any((group) => group.name == 'GLOBAL'), isTrue);
      app.collection = ConfigCollection(
        entries: [strategyEntry],
        selectedId: 'one',
        mode: TunnelMode.direct,
      );
      app.changed();
      await tester.pump();
      expect(controller.groups.any((group) => group.name == 'GLOBAL'), isFalse);
      expect(controller.groups.any((group) => group.name == '出口'), isTrue);
      app.collection = ConfigCollection(
        entries: [strategyEntry],
        selectedId: 'one',
      );
      bridge.data = strategyData(globalReferenced: true);
      app.changed();
      await tester.pump();
      expect(controller.groups.any((group) => group.name == 'GLOBAL'), isTrue);
      controller.setVisible(false);
    },
  );

  testWidgets(
    'preparation failure requires retry, not an automatic loading loop',
    (tester) async {
      app.state = const AppSnapshot(phase: 'STOPPED');
      controller.setVisible(true);
      await tester.pump();
      expect(app.commands.single['action'], 'prepareStrategies');
      app.state = const AppSnapshot(
        phase: 'STOPPED',
        resultId: 'failed',
        resultMessage: '加载失败',
        core: CoreSnapshot(
          generation: 8,
          purpose: 'PREVIEW',
          configId: 'one',
          revision: 1,
          error: '加载失败',
        ),
      );
      app.changed();
      await tester.pump(const Duration(seconds: 30));
      controller.setVisible(false);
      controller.setVisible(true);
      await tester.pump();
      expect(app.commands.length, 1);
      await controller.retry();
      await tester.pump();
      expect(app.commands.length, 2);
      expect(bridge.events, isEmpty);
    },
  );

  testWidgets(
    'choice carries clicked context and waits without optimistic selection',
    (tester) async {
      controller.setVisible(true);
      await tester.pump();
      await controller.choose('出口', 'B');
      expect(controller.data!.find('出口')!.now, 'A');
      expect(controller.changingGroup, '出口');
      expect(app.commands.single, {
        'action': 'setStrategy',
        'id': 'one',
        'revision': 1,
        'generation': 7,
        'name': '出口',
        'choice': {'type': 'select', 'member': 'B'},
      });
      await controller.choose('出口', 'A');
      expect(app.commands.length, 1);
      bridge.data = strategyData(now: 'B');
      app.state = const AppSnapshot(
        phase: 'STOPPED',
        core: previewCore,
        resultId: 'done',
        resultSuccess: true,
      );
      app.changed();
      await tester.pump();
      expect(controller.data!.find('出口')!.now, 'B');
      expect(controller.changingGroup, isNull);
      app.state = const AppSnapshot(
        phase: 'STOPPED',
        core: CoreSnapshot(generation: 8, phase: 'LOADING'),
      );
      app.changed();
      await tester.pump();
      expect(controller.data, isNull);
      expect(controller.canChoose, isFalse);
    },
  );

  testWidgets(
    'load balance never submits a selection or restore-auto command',
    (tester) async {
      controller.setVisible(true);
      await tester.pump();
      await controller.choose('均衡', 'A');
      await controller.choose('出口', null);
      expect(app.commands, isEmpty);
      controller.setVisible(false);
    },
  );
}
