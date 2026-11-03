import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/tunnel_mode.dart';
import 'package:clash_pseudo/src/model/strategy_choice.dart';
import 'package:clash_pseudo/src/ui/strategies/strategy_controller.dart';
import 'package:clash_pseudo/src/model/strategy_snapshot.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/strategy_fakes.dart';

class _EpochStrategyApp extends StrategyAppFake {
  _EpochStrategyApp(super.bridge) {
    state = const AppSnapshot(
      phase: 'STOPPED',
      core: previewCore,
      storageEpoch: 1,
    );
  }
  int epoch = 1;
  @override
  int get storageEpoch => epoch;
  @override
  Future<String?> submit(
    Map<String, Object?> command, {
    bool automatic = false,
  }) async {
    commands.add(Map.of(command));
    lastCommand = Map.of(command);
    lastCommandAutomatic = automatic;
    if (command['storageEpoch'] != epoch) {
      commandErrorMessage = messages.storageUnavailable;
      notifyListeners();
      return null;
    }
    return 'operation-${commands.length}';
  }
}

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

  for (final mode in TunnelMode.values) {
    testWidgets('all-groups view scope does not change the main filter $mode', (
      tester,
    ) async {
      bridge.data = strategyData(mode: mode);
      final all = StrategyController(app, allGroups: true);
      try {
        controller.setVisible(true);
        all.setVisible(true);
        await tester.pump();
        expect(all.groups.map((group) => group.name), [
          '出口',
          '自动',
          '故障转移',
          '均衡',
          '隐藏',
          'GLOBAL',
        ]);
        expect(controller.groups.any((group) => group.hidden), isFalse);
        expect(
          controller.groups.any((group) => group.name == 'GLOBAL'),
          mode == TunnelMode.global,
        );
        controller.setShowHidden(true);
        all.setShowHidden(false);
        expect(all.groups, hasLength(6));
        expect(controller.groups.any((group) => group.hidden), isTrue);
        expect(
          controller.groups.any((group) => group.name == 'GLOBAL'),
          mode == TunnelMode.global,
        );
        expect(all.canChoose, isTrue);
        controller.setVisible(false);
        all.setVisible(false);
      } finally {
        all.dispose();
      }
    });
  }

  testWidgets(
    'running pending revision allows choices but preview or deletion does not',
    (tester) async {
      app.state = const AppSnapshot(
        phase: 'RUNNING',
        configId: 'one',
        revision: 1,
        mode: TunnelMode.rule,
        core: vpnCore,
      );
      bridge.data = strategyData(core: vpnCore);
      app.collection = ConfigCollection(
        entries: [strategyEntry.withContent('pending')],
        selectedId: 'one',
      );
      controller.setVisible(true);
      await tester.pump();
      expect(controller.canChoose, isTrue);
      app.collection = ConfigCollection(entries: []);
      app.changed();
      await tester.pump();
      expect(controller.canChoose, isFalse);
      app.collection = ConfigCollection(
        entries: [strategyEntry.withContent('pending')],
        selectedId: 'one',
      );
      app.state = const AppSnapshot(phase: 'STOPPED', core: previewCore);
      bridge.data = strategyData();
      app.changed();
      await tester.pump();
      expect(controller.canChoose, isFalse);
      controller.setVisible(false);
    },
  );

  testWidgets(
    'a delayed strategy choice carries its captured epoch without replacing core identity checks',
    (tester) async {
      controller.dispose();
      app.dispose();
      final epochApp = _EpochStrategyApp(bridge);
      app = epochApp;
      controller = StrategyController(app);
      controller.setVisible(true);
      await tester.pump();
      final actual = controller.data!;
      epochApp.epoch = 2;
      app.state = const AppSnapshot(
        phase: 'STOPPED',
        core: previewCore,
        storageEpoch: 2,
      );
      app.changed();
      await controller.choose('出口', 'B', storageEpoch: 1);
      expect(app.commands.single, {
        'action': 'setStrategy',
        'storageEpoch': 1,
        'id': actual.configId,
        'revision': actual.revision,
        'processId': actual.processId,
        'inputId': actual.inputId,
        'generation': actual.generation,
        'composition': actual.composition,
        'name': '出口',
        'choice': {'type': 'select', 'member': 'B'},
      });
      expect(controller.data!.find('出口')!.now, 'A');
      expect(controller.changingGroup, isNull);
      expect(controller.operationErrorMessage, messages.storageUnavailable);
      app.state = const AppSnapshot(
        phase: 'STOPPED',
        storageEpoch: 2,
        core: CoreSnapshot(
          phase: 'READY',
          generation: 8,
          purpose: 'PREVIEW',
          configId: 'one',
          revision: 1,
          composition: '["one",1]',
        ),
      );
      app.changed();
      await controller.choose('出口', 'B', storageEpoch: 2);
      expect(app.commands, hasLength(1));
      controller.setVisible(false);
    },
  );

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

  testWidgets('returning waits for the actual hidden read before refreshing', (
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
    expect(bridge.reads, 1);
    expect(controller.loading, isTrue);
    expect(controller.canChoose, isFalse);
    final observations = <String?>[];
    controller.addListener(
      () => observations.add(controller.data?.find('出口')?.now),
    );
    late.complete(strategyData(now: 'B'));
    await tester.pump();
    expect(observations, contains('B'));
    expect(bridge.reads, 2);
    expect(controller.data!.find('出口')!.now, 'A');
    expect(controller.canChoose, isTrue);
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
        core: CoreSnapshot(
          phase: 'UNKNOWN',
          error: AppMessage('coreContextUnconfirmed'),
        ),
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
      final reads = bridge.reads;
      final snapshot = controller.data;
      controller.setShowHidden(true);
      expect(controller.showHidden, isTrue);
      expect(controller.groups.any((group) => group.hidden), isTrue);
      expect(controller.groups.any((group) => group.name == 'GLOBAL'), isFalse);
      expect(controller.data, same(snapshot));
      expect(bridge.reads, reads);
      expect(app.commands, isEmpty);
      controller.setShowHidden(false);
      expect(controller.groups.any((group) => group.hidden), isFalse);
      app.collection = ConfigCollection(
        entries: [strategyEntry],
        selectedId: 'one',
        mode: TunnelMode.global,
      );
      app.changed();
      await tester.pump();
      expect(controller.groups.any((group) => group.name == 'GLOBAL'), isFalse);
      expect(controller.mode, TunnelMode.rule);
      bridge.data = strategyData(mode: TunnelMode.global);
      await tester.pump(const Duration(seconds: 5));
      expect(controller.groups.any((group) => group.name == 'GLOBAL'), isTrue);
      app.collection = ConfigCollection(
        entries: [strategyEntry],
        selectedId: 'one',
        mode: TunnelMode.direct,
      );
      bridge.data = strategyData(mode: TunnelMode.direct);
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
    'preview mode comes from current snapshot and unknown never becomes saved fallback',
    (tester) async {
      app.collection = ConfigCollection(
        entries: [strategyEntry],
        selectedId: 'one',
        mode: TunnelMode.global,
      );
      bridge.data = strategyData(mode: null);
      controller.setVisible(true);
      await tester.pump();
      expect(controller.current, isTrue);
      expect(controller.mode, isNull);
      expect(controller.groups.any((group) => group.name == 'GLOBAL'), isFalse);
      bridge.data = strategyData(mode: TunnelMode.direct);
      await tester.pump(const Duration(seconds: 5));
      expect(controller.mode, TunnelMode.direct);
      app.state = const AppSnapshot(
        phase: 'STOPPED',
        core: CoreSnapshot(
          generation: 8,
          phase: 'READY',
          purpose: 'PREVIEW',
          configId: 'one',
          revision: 1,
          composition: '["one",1]',
        ),
      );
      app.changed();
      expect(controller.mode, isNull);
      await tester.pump();
      expect(controller.mode, isNull);
      controller.setVisible(false);
    },
  );

  testWidgets(
    'running mode outranks a conflicting strategy read mode and saved fallback',
    (tester) async {
      app.collection = ConfigCollection(
        entries: [strategyEntry],
        selectedId: 'one',
        mode: TunnelMode.rule,
      );
      app.state = const AppSnapshot(
        phase: 'RUNNING',
        configId: 'one',
        revision: 1,
        mode: TunnelMode.global,
        core: vpnCore,
      );
      bridge.data = strategyData(core: vpnCore, mode: TunnelMode.direct);
      controller.setVisible(true);
      await tester.pump();
      expect(controller.mode, TunnelMode.global);
      expect(controller.groups.any((group) => group.name == 'GLOBAL'), isTrue);
      controller.setVisible(false);
    },
  );

  testWidgets('HTTP configuration prepares normally with empty saved content', (
    tester,
  ) async {
    app.collection = ConfigCollection(
      entries: const [
        ConfigEntry(
          id: 'one',
          name: 'HTTP configuration',
          source: 'http://fixture.test/config',
          revision: 1,
          body: '',
        ),
      ],
      selectedId: 'one',
    );
    app.state = const AppSnapshot(phase: 'STOPPED');
    controller.setVisible(true);
    await tester.pump();
    expect(app.commands.single, {
      'action': 'prepareStrategies',
      'id': 'one',
      'revision': 1,
    });
    app.state = const AppSnapshot(phase: 'STOPPED', core: previewCore);
    app.changed();
    await tester.pump();
    expect(controller.canChoose, isTrue);
    expect(app.commands, hasLength(1));
    controller.setVisible(false);
  });

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
        resultMessage: AppMessage('androidErrorStrategyPrepare'),
        core: CoreSnapshot(
          generation: 8,
          purpose: 'PREVIEW',
          configId: 'one',
          revision: 1,
          error: AppMessage('androidErrorStrategyPrepare'),
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

  testWidgets('策略选择携带点击时的完整内核身份并等待实际结果', (tester) async {
    const core = CoreSnapshot(
      processId: 'clicked-process',
      inputId: 'clicked-input',
      generation: 7,
      phase: 'READY',
      purpose: 'PREVIEW',
      configId: 'one',
      revision: 1,
      composition: '["one",1]',
    );
    app.state = const AppSnapshot(phase: 'STOPPED', core: core);
    bridge.data = strategyData(core: core);
    controller.setVisible(true);
    await tester.pump();
    await controller.choose('出口', 'B');
    expect(controller.data!.find('出口')!.now, 'A');
    expect(controller.changingGroup, '出口');
    expect(app.commands.single, {
      'action': 'setStrategy',
      'storageEpoch': 0,
      'id': 'one',
      'revision': 1,
      'processId': core.processId,
      'inputId': core.inputId,
      'generation': 7,
      'composition': core.composition,
      'name': '出口',
      'choice': {'type': 'select', 'member': 'B'},
    });
    await controller.choose('出口', 'A');
    expect(app.commands.length, 1);
    bridge.data = strategyData(now: 'B', core: core);
    app.state = const AppSnapshot(
      phase: 'STOPPED',
      core: core,
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
    expect(controller.data!.generation, previewCore.generation);
    expect(controller.data!.find('出口')!.now, 'B');
    expect(controller.current, isFalse);
    expect(controller.canChoose, isFalse);
  });

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
