import 'dart:convert';

import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/diagnostics/nodes_controller.dart';
import 'package:clash_pseudo/src/features/diagnostics/nodes_page.dart';
import 'package:clash_pseudo/src/features/diagnostics/resources_controller.dart';
import 'package:clash_pseudo/src/features/diagnostics/resources_page.dart';
import 'package:clash_pseudo/src/features/diagnostics/rules_controller.dart';
import 'package:clash_pseudo/src/features/diagnostics/rules_page.dart';
import 'package:clash_pseudo/src/features/overrides/override_entry.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/definition_provenance.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/provenance_fakes.dart';
import 'node_fakes.dart' as node;
import 'resources_test.dart'
    as resource
    show ResourceBridge, ResourceApp, resourcePage;
import 'rule_fakes.dart' as rule;
import 'runtime_fakes.dart' show TestApp, core, response;

Map<String, dynamic> _main(String path) => sourceContributorWire(
  kind: 'config',
  id: 'main',
  revision: 1,
  name: 'Main without extra label',
  path: path,
);

Map<String, dynamic> _plugin(String name, String path, {String? role}) =>
    definitionProvenanceWire([
      sourceContributorWire(name: name, path: path, role: role),
    ]);

Map<String, dynamic> _nodes({
  int generation = 1,
  Object? provenance,
  Object? providerProvenance,
  Object? invalidProviderDirectOrigin,
}) => {
  ...response(core(generation)),
  'page': {
    'token': 'a' * 64,
    'total': 3,
    'nextOffset': -1,
    'nodes': [
      {
        'name': 'same-name',
        'type': 'Socks5',
        'source': '',
        'sourceKind': 'configuration',
        'sourceVersion': 0,
        'builtin': false,
        'udp': true,
        'history': [],
        'tests': [],
        'provenance': ?provenance,
      },
      {
        'name': 'same-name',
        'type': 'Direct',
        'source': 'provider',
        'sourceKind': 'proxyProvider',
        'sourceVersion': 1,
        'builtin': false,
        'udp': true,
        'history': [],
        'tests': [],
        'providerProvenance': ?providerProvenance,
        'provenance': ?invalidProviderDirectOrigin,
      },
      {
        'name': 'main-only',
        'type': 'Direct',
        'source': '',
        'sourceKind': 'configuration',
        'sourceVersion': 0,
        'builtin': false,
        'udp': true,
        'history': [],
        'tests': [],
        'provenance': definitionProvenanceWire([_main('/proxies/2')]),
      },
    ],
  },
};

Map<String, dynamic> _rules({
  int generation = 1,
  String pluginName = 'Loaded rule plugin',
}) => rule.rulePage(
  generation: generation,
  total: 2,
  extra: {
    'rows': [
      {
        'index': 1,
        'type': 'Domain',
        'payload': 'same.test',
        'target': 'DIRECT',
        'providers': [],
        'provenance': _plugin(pluginName, '/rules/0'),
      },
      {
        'index': 2,
        'type': 'Domain',
        'payload': 'same.test',
        'target': 'DIRECT',
        'providers': [],
        'provenance': definitionProvenanceWire([_main('/rules/0')]),
      },
    ],
  },
);

Map<String, dynamic> _resources({int generation = 1, Object? provenance}) =>
    resource.resourcePage(
      core(generation),
      rows: [
        {
          'kind': 'proxyProvider',
          'name': 'remote',
          'vehicleType': 'HTTP',
          'source': 'https://provider.test/…',
          'count': 3,
          'updateSupported': true,
          'provenance': ?provenance,
        },
        {
          'kind': 'ruleProvider',
          'name': 'inline',
          'vehicleType': 'Inline',
          'source': '',
          'count': 1,
          'behavior': 'Domain',
          'updateSupported': false,
          'provenance': definitionProvenanceWire([
            _main('/rule-providers/inline'),
          ]),
        },
      ],
    );

Finder _row(Object identity) => find.byWidgetPredicate(
  (widget) =>
      widget is ListTile &&
      widget.key is ValueKey &&
      (widget.key as ValueKey).value == identity,
);

Future<void> _show(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(320, 1500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: page,
    ),
  );
  await tester.pump();
}

Future<void> _frames(WidgetTester tester, void Function() check) async {
  for (final duration in [
    Duration.zero,
    const Duration(milliseconds: 16),
    const Duration(milliseconds: 100),
  ]) {
    await tester.pump(duration);
    check();
    expect(tester.takeException(), isNull);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'nodes parse real origins; disk rename cannot rewrite loaded names or provider boundaries',
    (tester) async {
      final bridge = node.NodeBridge();
      final app = TestApp(bridge);
      final controller = NodesController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      bridge.replies.single.complete(
        _nodes(
          provenance: _plugin(
            'Actually loaded node plugin',
            '/proxies/1',
            role: 'localCustom',
          ),
          providerProvenance: _plugin(
            'Provider definition plugin',
            '/proxy-providers/provider',
          ),
        ),
      );
      await tester.pump();
      final top = controller.nodes.first['provenance'] as DefinitionProvenance;
      final provider =
          controller.nodes[1]['providerProvenance'] as DefinitionProvenance;
      expect(top.plugins.single.name, 'Actually loaded node plugin');
      expect(top.plugins.single.path, '/proxies/1');
      expect(top.plugins.single.isLocalCustom, isTrue);
      expect(controller.nodes[1]['provenance'], isNull);
      expect(controller.nodes[1]['sourceKind'], 'proxyProvider');
      expect(controller.nodes[1]['source'], 'provider');
      expect(provider.plugins.single.name, 'Provider definition plugin');
      app.overrides = const [
        OverrideEntry(
          id: 'plugin',
          name: 'Latest disk rename',
          kind: ConfigKind.local,
          revision: 3,
          body: '{}',
          role: OverrideRole.localCustom,
        ),
      ];
      app.overridesLoaded = true;
      app.publish(app.state);
      await tester.pump();
      expect(bridge.queries, hasLength(1));
      expect(top.plugins.single.name, 'Actually loaded node plugin');
      expect(app.overrides.single.name, 'Latest disk rename');
      expect(
        jsonEncode(controller.nodes),
        isNot(contains('Latest disk rename')),
      );
      expect(app.commands, isEmpty);
    },
  );

  testWidgets(
    'malformed/unknown/node-provider origins never publish a replacement identity',
    (tester) async {
      final bridge = node.NodeBridge();
      final app = TestApp(bridge);
      final controller = NodesController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      final valid = _plugin('Captured name', '/proxies/0');
      bridge.replies.single.complete(_nodes(provenance: valid));
      await tester.pump();
      final retained = controller.nodes;
      for (final bad in [
        definitionProvenanceWire([
          {...sourceContributorWire(), 'kind': 'unknown'},
        ]),
        definitionProvenanceWire([
          {...sourceContributorWire(), 'revision': 0},
        ]),
        _plugin('Wrong definition section', '/rules/0'),
      ]) {
        final refresh = controller.refresh();
        await tester.pump();
        bridge.replies.last.complete(_nodes(provenance: bad));
        await refresh;
        await tester.pump();
        expect(controller.failed, isTrue);
        expect(controller.current, isFalse);
        expect(controller.canPage, isFalse);
        expect(controller.nodes, same(retained));
      }
      final refresh = controller.refresh();
      await tester.pump();
      bridge.replies.last.complete(
        _nodes(provenance: valid, invalidProviderDirectOrigin: valid),
      );
      await refresh;
      await tester.pump();
      expect(controller.failed, isTrue);
      expect(controller.nodes, same(retained));
      expect(app.commands, isEmpty);
    },
  );

  testWidgets(
    'duplicate rule text keeps final position and source-local index',
    (tester) async {
      final bridge = rule.RuleBridge();
      final app = TestApp(bridge);
      final controller = RulesController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      bridge.replies.single.complete(_rules());
      await tester.pump();
      expect(controller.current, isTrue);
      expect(controller.rows.map((row) => row['payload']), [
        'same.test',
        'same.test',
      ]);
      expect(controller.rows.map((row) => row['index']), [1, 2]);
      final first = controller.rows[0]['provenance'] as DefinitionProvenance;
      final second = controller.rows[1]['provenance'] as DefinitionProvenance;
      expect(first.plugins.single.path, '/rules/0');
      expect(second.contributors.single.path, '/rules/0');
      expect(second.plugins, isEmpty);
      expect(first.contributors.single.kind, ContributorKind.plugin);
      expect(second.contributors.single.kind, ContributorKind.config);
      expect(bridge.queries.single['offset'], 0);
      expect(bridge.queries.single['token'], '');
    },
  );

  testWidgets(
    'provider rules retain content origin independently from definition contributors',
    (tester) async {
      final bridge = rule.RuleBridge();
      final app = TestApp(bridge);
      final controller = RulesController(
        app,
        provider: 'set',
        expectedSource: core(1),
      )..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      final provenance = _plugin('Plugin defining set', '/rule-providers/set');
      bridge.replies.single.complete(
        rule.rulePage(
          kind: 'provider',
          name: 'set',
          total: 1,
          origin: 'cache-source',
          extra: {
            'providerProvenance': provenance,
            'scopes': [
              {
                'kind': 'provider',
                'name': 'set',
                'count': 1,
                'provenance': provenance,
              },
            ],
            'rows': [
              {
                'index': 1,
                'type': 'Classical',
                'payload': 'DOMAIN,provider.test',
                'target': '',
                'providers': ['set'],
              },
            ],
          },
        ),
      );
      await tester.pump();
      expect(controller.current, isTrue);
      expect(controller.origin, 'cache-source');
      expect(
        controller.providerProvenance!.plugins.single.name,
        'Plugin defining set',
      );
      expect(controller.rows.single['provenance'], isNull);
      expect(
        (controller.scopes.single['provenance'] as DefinitionProvenance)
            .plugins
            .single
            .path,
        '/rule-providers/set',
      );
      app.publish(AppSnapshot(phase: 'RUNNING', core: core(2)));
      await tester.pump();
      expect(controller.sourceExpired, isTrue);
      expect(controller.current, isFalse);
      app.publish(AppSnapshot(phase: 'RUNNING', core: core(1)));
      await tester.pump();
      expect(controller.sourceExpired, isTrue);
      expect(bridge.queries, hasLength(1));
    },
  );

  testWidgets(
    'resources parse minimal contributors without replacing URL or permitting malformed rereads',
    (tester) async {
      final bridge = resource.ResourceBridge();
      final app = resource.ResourceApp(bridge);
      final controller = ResourcesController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      bridge.replies.single.complete(
        _resources(
          provenance: _plugin(
            'Loaded resource plugin',
            '/proxy-providers/remote',
          ),
        ),
      );
      await tester.pump();
      final retained = controller.resources;
      expect(controller.current, isTrue);
      expect(controller.resources.first['source'], 'https://provider.test/…');
      expect(
        (controller.resources.first['provenance'] as DefinitionProvenance)
            .plugins
            .single
            .name,
        'Loaded resource plugin',
      );
      expect(jsonEncode(controller.resources), isNot(contains('fields')));
      final refresh = controller.refresh();
      await tester.pump();
      bridge.replies.last.complete(
        _resources(provenance: _plugin('Wrong section', '/proxies/0')),
      );
      await refresh;
      await tester.pump();
      expect(controller.current, isFalse);
      expect(controller.status, ResourcesStatus.failed);
      expect(controller.resources, same(retained));
      await controller.update('proxyProvider', 'remote');
      expect(bridge.updates, isEmpty);
    },
  );

  testWidgets(
    'nodes keep row/search anchors through waiting, failure, retry and new long source names',
    (tester) async {
      final bridge = node.NodeBridge();
      final app = TestApp(bridge);
      addTearDown(app.dispose);
      await _show(tester, NodesPage(app: app));
      bridge.replies.single.complete(
        _nodes(provenance: definitionProvenanceWire([_main('/proxies/0')])),
      );
      await tester.pumpAndSettle();
      final first = _row(('configuration', '', 'same-name'));
      final second = _row(('proxyProvider', 'provider', 'same-name'));
      final search = find.byType(TextField);
      final before = tester.getRect(first);
      final next = tester.getRect(second);
      final searchRect = tester.getRect(search);
      void unchanged() {
        expect(tester.getRect(first), before);
        expect(tester.getRect(second), next);
        expect(tester.getRect(search), searchRect);
      }

      expect(find.textContaining('Configuration'), findsNothing);
      app.publish(AppSnapshot(phase: 'RUNNING', core: core(2)));
      await _frames(tester, unchanged);
      bridge.replies.last.completeError(StateError('controlled read failure'));
      await _frames(tester, unchanged);
      await tester.tap(find.widgetWithIcon(IconButton, Icons.refresh));
      await _frames(tester, unchanged);
      final name = '运行时记录的长插件名称' * 6;
      bridge.replies.last.complete(
        _nodes(
          generation: 2,
          provenance: _plugin(name, '/proxies/0', role: 'localCustom'),
          providerProvenance: _plugin(
            'Provider definition still distinct',
            '/proxy-providers/provider',
          ),
        ),
      );
      await _frames(tester, unchanged);
      expect(find.textContaining(name), findsOneWidget);
      await tester.tap(first);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(SelectableText, name), findsOneWidget);
      expect(find.text('Local customizations'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'rule source names do not move duplicate rows during read and context recovery',
    (tester) async {
      final bridge = rule.RuleBridge();
      final app = TestApp(bridge);
      addTearDown(app.dispose);
      await _show(tester, RulesPage(app: app));
      bridge.replies.single.complete(_rules(pluginName: 'Short loaded name'));
      await tester.pumpAndSettle();
      // Distinguish duplicate declarations by displayed ordinal; reading keys
      // additionally carry source identity.
      final first = find.widgetWithText(ListTile, '1');
      final second = find.widgetWithText(ListTile, '2');
      final firstRect = tester.getRect(first);
      final secondRect = tester.getRect(second);
      final searchRect = tester.getRect(find.byType(TextField));
      void unchanged() {
        expect(tester.getRect(first), firstRect);
        expect(tester.getRect(second), secondRect);
        expect(tester.getRect(find.byType(TextField)), searchRect);
      }

      app.publish(AppSnapshot(phase: 'RUNNING', core: core(2)));
      await _frames(tester, unchanged);
      bridge.replies.last.completeError(StateError('controlled failure'));
      await _frames(tester, unchanged);
      await tester.tap(find.widgetWithIcon(IconButton, Icons.refresh));
      await _frames(tester, unchanged);
      final name =
          'Long name captured by the replacement composition / 插件名称' * 3;
      bridge.replies.last.complete(_rules(generation: 2, pluginName: name));
      await _frames(tester, unchanged);
      await tester.tap(first);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(SelectableText, name), findsOneWidget);
      expect(find.text('Contributing plugins'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'resource original metadata slot stays fixed when plugin participation appears',
    (tester) async {
      final bridge = resource.ResourceBridge();
      final app = resource.ResourceApp(bridge);
      addTearDown(app.dispose);
      await _show(tester, ResourcesPage(app: app));
      bridge.replies.single.complete(
        _resources(
          provenance: definitionProvenanceWire([
            _main('/proxy-providers/remote'),
          ]),
        ),
      );
      await tester.pumpAndSettle();
      final first = _row('proxyProvider/remote');
      final second = _row('ruleProvider/inline');
      final firstRect = tester.getRect(first);
      final secondRect = tester.getRect(second);
      final searchRect = tester.getRect(find.byType(TextField));
      void unchanged() {
        expect(tester.getRect(first), firstRect);
        expect(tester.getRect(second), secondRect);
        expect(tester.getRect(find.byType(TextField)), searchRect);
      }

      app.publish(AppSnapshot(phase: 'RUNNING', core: core(2)));
      await _frames(tester, unchanged);
      bridge.replies.last.completeError(StateError('controlled failure'));
      await _frames(tester, unchanged);
      await tester.tap(find.widgetWithIcon(IconButton, Icons.refresh));
      await _frames(tester, unchanged);
      final name = 'Loaded provider definition plugin with a long name / 本地来源';
      bridge.replies.last.complete(
        _resources(
          generation: 2,
          provenance: _plugin(
            name,
            '/proxy-providers/remote',
            role: 'localCustom',
          ),
        ),
      );
      await _frames(tester, unchanged);
      expect(find.text('https://provider.test/…'), findsOneWidget);
      final countLabel = AppLocalizations.of(tester.element(first))
          .resourceCountValue(3);
      expect(
        tester
            .widgetList<Text>(
              find.descendant(of: first, matching: find.byType(Text)),
            )
            .any((text) => text.data?.startsWith(countLabel) == true),
        isTrue,
        reason: 'plugin participation must not move the actual count behind an ellipsized suffix',
      );
      await tester.tap(first);
      await tester.pumpAndSettle();
      expect(find.text('Definition contributors'), findsOneWidget);
      expect(find.widgetWithText(SelectableText, name), findsOneWidget);
      expect(find.textContaining('https://provider.test/…'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
