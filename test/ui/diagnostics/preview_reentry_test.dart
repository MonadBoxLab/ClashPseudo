import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/diagnostics/logs/logs_controller.dart';
import 'package:clash_pseudo/src/ui/diagnostics/nodes/nodes_controller.dart';
import 'package:clash_pseudo/src/ui/diagnostics/resources/resources_controller.dart';
import 'package:clash_pseudo/src/ui/diagnostics/rules/rules_controller.dart';
import 'package:clash_pseudo/src/ui/diagnostics/configuration/runtime_config_controller.dart';
import 'package:clash_pseudo/src/ui/strategies/strategy_controller.dart';
import 'package:clash_pseudo/src/model/strategy_snapshot.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/strategy_fakes.dart' show strategyData;
import 'logs/log_fakes.dart' show logResponse, logSource;
import 'nodes/node_fakes.dart' show page;
import 'rules/rule_fakes.dart' show rulePage;
import 'configuration/runtime_fakes.dart' show TestApp, core, response;

class _PreviewBridge extends AppBridge {
  int reads = 0;

  @override
  Future<Map<String, dynamic>> nodes(
    CoreSnapshot source,
    Map<String, Object?> query,
  ) async {
    reads++;
    return {...page(generation: source.generation), ...response(source)};
  }

  @override
  Future<Map<String, dynamic>> rules(
    CoreSnapshot source,
    Map<String, Object?> query,
  ) async {
    reads++;
    return {...rulePage(generation: source.generation), ...response(source)};
  }

  @override
  Future<Map<String, dynamic>> resources(CoreSnapshot source) async {
    reads++;
    return {...response(source), 'resources': <Object?>[]};
  }

  @override
  Future<Map<String, dynamic>> runtimeConfiguration(CoreSnapshot source) async {
    reads++;
    return response(source);
  }

  @override
  Future<Map<String, dynamic>> logs(
    CoreSnapshot source,
    Map<String, Object?> query,
  ) async {
    reads++;
    return logResponse(source);
  }

  @override
  Future<StrategySnapshot> strategies(CoreSnapshot coreIdentity) async {
    final generation = coreIdentity.generation;
    reads++;
    return strategyData(core: core(generation, purpose: 'PREVIEW'));
  }
}

typedef _Reader = ({
  ValueChanged<bool> setVisible,
  VoidCallback dispose,
  bool Function() current,
});

_Reader _reader(String name, TestApp app, {CoreSnapshot? expected}) {
  switch (name) {
    case 'nodes':
      final controller = NodesController(app, expectedSource: expected);
      return (
        setVisible: controller.setVisible,
        dispose: controller.dispose,
        current: () => controller.current,
      );
    case 'rules':
      final controller = RulesController(app, expectedSource: expected);
      return (
        setVisible: controller.setVisible,
        dispose: controller.dispose,
        current: () => controller.current,
      );
    case 'resources':
      final controller = ResourcesController(app, expectedSource: expected);
      return (
        setVisible: controller.setVisible,
        dispose: controller.dispose,
        current: () => controller.current,
      );
    case 'runtime':
      final controller = RuntimeConfigController(app);
      return (
        setVisible: controller.setVisible,
        dispose: controller.dispose,
        current: () => controller.status == RuntimeConfigStatus.preview,
      );
    case 'logs':
      final controller = CoreLogsController(app);
      return (
        setVisible: controller.setVisible,
        dispose: controller.dispose,
        current: () => controller.status == CoreLogsStatus.preview,
      );
    case 'strategies':
      final controller = StrategyController(app);
      return (
        setVisible: controller.setVisible,
        dispose: controller.dispose,
        current: () => controller.current,
      );
    default:
      throw ArgumentError(name);
  }
}

TestApp _app(_PreviewBridge bridge) => TestApp(bridge)
  ..collection = ConfigCollection(
    selectedId: 'main',
    entries: const [
      ConfigEntry(
        id: 'main',
        name: 'controlled',
        kind: ConfigKind.local,
        revision: 1,
        body: 'rules:\n  - MATCH,DIRECT\n',
      ),
    ],
  )
  ..state = const AppSnapshot(phase: 'STOPPED');

AppSnapshot _ready() {
  final source = core(1, purpose: 'PREVIEW');
  return AppSnapshot(
    phase: 'STOPPED',
    core: source,
    logSource: logSource(source),
  );
}

void _expectPrepares(TestApp app, int count) {
  expect(app.commands, hasLength(count));
  for (final command in app.commands) {
    expect(command, {
      'action': 'prepareStrategies',
      'id': 'main',
      'revision': 1,
    });
  }
}

void main() {
  for (final name in [
    'nodes',
    'rules',
    'resources',
    'runtime',
    'logs',
    'strategies',
  ]) {
    for (final boundary in ['visible retirement', 'local editor return']) {
      testWidgets('$name prepares again after clean $boundary', (tester) async {
        final bridge = _PreviewBridge();
        final app = _app(bridge);
        final reader = _reader(name, app);
        addTearDown(() {
          reader.dispose();
          app.dispose();
        });
        reader.setVisible(true);
        _expectPrepares(app, 1);
        app.publish(_ready());
        await tester.pump();
        expect(bridge.reads, 1);
        expect(reader.current(), isTrue);
        if (boundary == 'local editor return') reader.setVisible(false);
        // Retire the preview after override change or idle release while retaining the
        // selected main ID and revision.
        app.publish(
          const AppSnapshot(
            phase: 'STOPPED',
            core: CoreSnapshot(generation: 1),
          ),
        );
        if (boundary == 'local editor return') reader.setVisible(true);
        await tester.pump();
        _expectPrepares(app, 2);
        expect(reader.current(), isFalse);
        // Keep the failed attempt settled until another ready source appears.
        app.publish(
          const AppSnapshot(
            phase: 'STOPPED',
            core: CoreSnapshot(generation: 1),
            resultId: 'unaccepted-preview',
          ),
        );
        await tester.pump(const Duration(seconds: 2));
        _expectPrepares(app, 2);
      });
    }

    for (final boundary in ['hidden', 'background']) {
      testWidgets(
        '$name reentry can prepare a source retired before reading at $boundary',
        (tester) async {
          final bridge = _PreviewBridge();
          final app = _app(bridge);
          final reader = _reader(name, app);
          addTearDown(() {
            reader.dispose();
            app.dispose();
          });
          reader.setVisible(true);
          _expectPrepares(app, 1);
          if (boundary == 'hidden') {
            reader.setVisible(false);
          } else {
            app.setForeground(false);
          }
          app.publish(_ready());
          app.publish(
            const AppSnapshot(
              phase: 'STOPPED',
              core: CoreSnapshot(generation: 1),
            ),
          );
          await tester.pump();
          expect(bridge.reads, 0);
          _expectPrepares(app, 1);
          if (boundary == 'hidden') {
            reader.setVisible(true);
          } else {
            app.setForeground(true);
          }
          await tester.pump();
          _expectPrepares(app, 2);
        },
      );
    }

    testWidgets(
      '$name never loops a failed or unconfirmed prepare on reentry',
      (tester) async {
        final bridge = _PreviewBridge();
        final app = _app(bridge);
        final reader = _reader(name, app);
        addTearDown(() {
          reader.dispose();
          app.dispose();
        });
        reader.setVisible(true);
        _expectPrepares(app, 1);
        for (final phase in ['EMPTY', 'FAILED', 'UNKNOWN']) {
          reader.setVisible(false);
          app.publish(
            AppSnapshot(
              phase: 'STOPPED',
              core: CoreSnapshot(
                generation: 1,
                phase: phase,
                configId: 'main',
                revision: 1,
                error: messages.coreContextUnconfirmed,
              ),
            ),
          );
          reader.setVisible(true);
          await tester.pump(const Duration(seconds: 2));
          _expectPrepares(app, 1);
        }
        expect(bridge.reads, 0);
      },
    );
  }

  for (final name in ['nodes', 'rules', 'resources']) {
    testWidgets('$name captured-source expiry is permanent across reentry', (
      tester,
    ) async {
      final bridge = _PreviewBridge();
      final app = _app(bridge)..state = _ready();
      final reader = _reader(name, app, expected: app.state.core);
      addTearDown(() {
        reader.dispose();
        app.dispose();
      });
      reader.setVisible(true);
      await tester.pump();
      expect(reader.current(), isTrue);
      reader.setVisible(false);
      app.publish(const AppSnapshot(phase: 'STOPPED'));
      reader.setVisible(true);
      await tester.pump();
      expect(reader.current(), isFalse);
      app.publish(_ready());
      await tester.pump();
      expect(reader.current(), isFalse);
      expect(bridge.reads, 1);
      _expectPrepares(app, 0);
    });
  }
}
