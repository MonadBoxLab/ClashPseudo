import 'dart:convert';

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
          const raw = {
            'general': {'mode': 'rule', 'mixed-port': 0},
            'requested': {
              'tun': {'enable': false},
            },
            'actual': {
              'tun': null,
              'listeners': [
                {'name': 'lan-wlan0', 'address': '10.0.2.16', 'port': 7890},
              ],
            },
            'future': [false, null],
            'processId': 'native-configuration-value',
          };
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
          expect(runtime.lines, isEmpty);
          expect(request.actualExited, isFalse);
          final pending = await native.read('runtimeConfig');
          expect(pending['readPending'], isTrue);
          expect(native.calls(ApplicationContract.coreOperationRuntimeConfig), [
            request,
          ]);
          request.signalExit();
          await tester.pump();
          expect(runtime.loading, isFalse);
          expect(runtime.data!['configuration'], raw);
          expect(jsonDecode(runtime.lines.join('\n')), raw);
          expect(runtime.lines, isNot(['null']));
          expect(runtime.data!['processId'], source.processId);
          expect(runtime.data!['purpose'], purpose);
          expect(source.matchesWireIdentity(runtime.data!), isTrue);
          expect(runtime.data!['cancelError'], cancellation);
          expect(runtime.data!['stale'], stale);
          expect(runtime.readError, isNull);
          expect(
            runtime.status,
            stale
                ? RuntimeConfigStatus.stale
                : purpose == 'RUNNING'
                ? RuntimeConfigStatus.live
                : RuntimeConfigStatus.preview,
          );
          expect(runtime.hasCurrentSource, !stale);
          expect(app.commands, isEmpty);
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
    request.complete(
      {
        'general': {'mode': 'rule'},
      },
      terminal: {'error': original},
    );
    await tester.pump();
    expect(runtime.loading, isTrue);
    expect(runtime.readError, isNull);
    request.signalExit();
    await tester.pump();
    expect(runtime.status, RuntimeConfigStatus.failed);
    expect(runtime.loading, isFalse);
    expect(runtime.data, isNull);
    expect(runtime.lines, isEmpty);
    expect(runtime.readError!.detail, contains(original.toString()));
    expect(runtime.hasCurrentSource, isFalse);
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
        expect(runtime.hasCurrentSource, isTrue);
        expect(nodes.current, isTrue);
        expect(rules.current, isTrue);
        expect(resources.current, isTrue);
        final retained = [runtime.data, nodes.data, rules.data, resources.data];
        for (final app in apps) {
          app.publish(app.state.asStale());
        }
        await tester.pump();
        expect(runtime.hasCurrentSource, isFalse);
        expect(runtime.status, RuntimeConfigStatus.failed);
        expect(nodes.current, isFalse);
        expect(rules.current, isFalse);
        expect(resources.current, isFalse);
        expect([
          runtime.data,
          nodes.data,
          rules.data,
          resources.data,
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
        expect(runtime.data, late);
        expect(runtime.hasCurrentSource, isFalse);
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
        expect(runtime.hasCurrentSource, isTrue);
        expect(nodes.current, isTrue);
        expect(rules.current, isTrue);
        expect(resources.current, isTrue);
      },
    );
  });
}
