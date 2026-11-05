import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:clash_pseudo/src/ui/diagnostics/configuration/runtime_config_controller.dart';
import 'package:clash_pseudo/src/ui/diagnostics/nodes/nodes_controller.dart';
import 'package:clash_pseudo/src/ui/diagnostics/rules/rules_controller.dart';
import 'package:clash_pseudo/src/ui/diagnostics/resources/resources_controller.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dns/dns_controller_test.dart' show runtimeDnsUiApp;
import 'dns/dns_fakes.dart' show dnsCore;
import 'configuration/runtime_fakes.dart'
    show TestApp, TestBridge, core, response;
import 'nodes/node_fakes.dart';
import 'rules/rule_fakes.dart';
import 'resources/resources_test.dart'
    show ResourceApp, ResourceBridge, resourcePage;

void main() {
  for (final purpose in ['RUNNING', 'PREVIEW']) {
    for (final stale in [false, true]) {
      testWidgets(
        '裸 RuntimeConfig FD 正文经 CoreRuntime 到 Controller 保留配置 $purpose stale=$stale',
        (tester) async {
          final app = await runtimeDnsUiApp(tester);
          final native = app.native;
          native.core = dnsCore(purpose: purpose);
          app.syncRuntime();
          final source = native.core;
          final runtime = RuntimeConfigController(app)..setVisible(true);
          addTearDown(() {
            runtime.dispose();
            app.dispose();
          });
          const raw =
              'mode: rule\nmixed-port: 0\n'
              'tun:\n  enable: false\n'
              'authentication:\n  - fixture-user\n'
              'future: [false, null]\nprocessId: native-configuration-value\n';
          const cancellation = {
            'cause': {'message': '原始取消错误'},
            'suppressed': [
              {'message': '原始 suppressed'},
            ],
            'future': [false, null],
          };
          await tester.pump();
          final request = native
              .calls(ApplicationContract.coreOperationRuntimeConfig)
              .single;
          expect(request.identity['processId'], source.processId);
          request.complete(
            raw,
            terminal: {'stale': stale, 'cancelError': cancellation},
          );
          await tester.pump();
          expect(runtime.loading, isTrue);
          expect(runtime.text, isEmpty);
          expect(request.actualExited, isFalse);
          final pending = await native.read('runtimeConfig');
          expect(pending['readPending'], isTrue);
          expect(native.calls(ApplicationContract.coreOperationRuntimeConfig), [
            request,
          ]);
          request.signalExit();
          await tester.pump();
          expect(runtime.loading, isFalse);
          expect(runtime.text, raw);
          expect(runtime.source!.matchesIdentity(source), isTrue);
          expect(runtime.source!.purpose, purpose);
          expect(runtime.cancelError, cancellation);
          expect(runtime.readError, isNull);
          expect(
            runtime.status,
            stale
                ? RuntimeConfigStatus.stale
                : purpose == 'RUNNING'
                ? RuntimeConfigStatus.live
                : RuntimeConfigStatus.preview,
          );
          expect(app.commands, isEmpty);
          runtime.setVisible(false);
        },
      );
    }
  }

  testWidgets('RuntimeConfig FD 原错误与未知字段在 drain 后完整到达 Controller', (
    tester,
  ) async {
    final app = await runtimeDnsUiApp(tester);
    final native = app.native;
    final runtime = RuntimeConfigController(app)..setVisible(true);
    addTearDown(() {
      runtime.dispose();
      app.dispose();
    });
    const original = {
      'code': 'callFailed',
      'message': 'RuntimeConfig 原错误',
      'cause': {'message': '原始 cause'},
      'stack': '原始 stack',
      'suppressed': [
        {'message': '原始 suppressed'},
      ],
      'future': [false, null],
    };
    await tester.pump();
    final request = native
        .calls(ApplicationContract.coreOperationRuntimeConfig)
        .single;
    request.complete('mode: rule\n', terminal: {'error': original});
    await tester.pump();
    expect(runtime.loading, isTrue);
    expect(runtime.readError, isNull);
    request.signalExit();
    await tester.pump();
    expect(runtime.status, RuntimeConfigStatus.failed);
    expect(runtime.loading, isFalse);
    expect(runtime.source, isNull);
    expect(runtime.text, isEmpty);
    expect(runtime.readError!.detail, contains(original.toString()));
    expect(
      runtime.status,
      isNot(anyOf(RuntimeConfigStatus.live, RuntimeConfigStatus.preview)),
    );
    runtime.setVisible(false);
  });

  group('cross-object read ownership', () {
    testWidgets(
      'unconfirmed snapshots revoke current reads without dropping actual feedback',
      (tester) async {
        final runtimeBridge = TestBridge();
        final nodeBridge = NodeBridge();
        final ruleBridge = RuleBridge();
        final resourceBridge = ResourceBridge();
        final runtimeApp = TestApp(runtimeBridge);
        final nodeApp = TestApp(nodeBridge);
        final ruleApp = TestApp(ruleBridge);
        final resourceApp = ResourceApp(resourceBridge);
        final runtime = RuntimeConfigController(runtimeApp)..setVisible(true);
        final nodes = NodesController(nodeApp)..setVisible(true);
        final rules = RulesController(ruleApp)..setVisible(true);
        final resources = ResourcesController(resourceApp)..setVisible(true);
        final apps = [runtimeApp, nodeApp, ruleApp, resourceApp];
        addTearDown(() {
          runtime.dispose();
          nodes.dispose();
          rules.dispose();
          resources.dispose();
          for (final app in apps) {
            app.dispose();
          }
        });
        runtimeBridge.replies.last.complete(response(core(1)));
        nodeBridge.replies.last.complete(page());
        ruleBridge.replies.last.complete(rulePage());
        resourceBridge.replies.last.complete(resourcePage(core(1)));
        await tester.pump();
        expect(runtime.source!.generation, runtimeApp.state.core.generation);
        expect(nodes.current, isTrue);
        expect(rules.current, isTrue);
        expect(resources.current, isTrue);
        final retained = [
          runtime.text,
          nodes.nodes,
          rules.rows,
          resources.resources,
        ];
        for (final app in apps) {
          app.publish(app.state.asStale());
        }
        await tester.pump();
        expect(runtime.status, RuntimeConfigStatus.failed);
        expect(nodes.current, isFalse);
        expect(rules.current, isFalse);
        expect(resources.current, isFalse);
        expect([
          runtime.text,
          nodes.nodes,
          rules.rows,
          resources.resources,
        ], retained);
        await nodes.next();
        await rules.next();
        await resources.update('proxyProvider', 'remote');
        expect(resourceBridge.updates, isEmpty);
        expect(nodeBridge.queries, hasLength(1));
        expect(ruleBridge.queries, hasLength(1));
        for (final app in apps) {
          app.publish(AppSnapshot(phase: 'RUNNING', core: core(1)));
        }
        expect(runtimeBridge.requests, hasLength(2));
        expect(nodeBridge.queries, hasLength(2));
        expect(ruleBridge.queries, hasLength(2));
        expect(resourceBridge.requests, hasLength(2));
        for (final app in apps) {
          app.publish(app.state.asStale());
        }
        final late = {...response(core(1)), 'unknown': 'actual-late-result'};
        runtimeBridge.replies.last.complete(late);
        nodeBridge.replies.last.complete(page());
        ruleBridge.replies.last.complete(rulePage());
        resourceBridge.replies.last.complete(resourcePage(core(1)));
        await tester.pump();
        expect(runtime.text, retained.first);
        expect(runtime.text.toString(), isNot(contains('actual-late-result')));
        expect(
          runtime.status,
          isNot(anyOf(RuntimeConfigStatus.live, RuntimeConfigStatus.preview)),
        );
        expect(nodes.current, isFalse);
        expect(rules.current, isFalse);
        expect(resources.current, isFalse);
        expect(
          runtime.loading ||
              nodes.loading ||
              rules.loading ||
              resources.loading,
          isFalse,
        );
        expect(runtimeBridge.requests, hasLength(2));
        expect(nodeBridge.queries, hasLength(2));
        expect(ruleBridge.queries, hasLength(2));
        expect(resourceBridge.requests, hasLength(2));
        for (final app in apps) {
          app.publish(AppSnapshot(phase: 'RUNNING', core: core(1)));
        }
        runtimeBridge.replies.last.complete(response(core(1)));
        nodeBridge.replies.last.complete(page());
        ruleBridge.replies.last.complete(rulePage());
        resourceBridge.replies.last.complete(resourcePage(core(1)));
        await tester.pump();
        expect(runtime.source!.generation, runtimeApp.state.core.generation);
        expect(nodes.current, isTrue);
        expect(rules.current, isTrue);
        expect(resources.current, isTrue);
        runtime.setVisible(false);
        nodes.setVisible(false);
        rules.setVisible(false);
        resources.setVisible(false);
      },
    );
  });
}
