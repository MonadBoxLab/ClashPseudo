import 'dart:async';
import 'dart:io';

import 'package:clash_pseudo/src/app/widgets/choice_menu_button.dart';
import 'package:clash_pseudo/src/app/widgets/reading_list.dart';
import 'package:clash_pseudo/src/app/app_controller.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/configs/config_store.dart';
import 'package:clash_pseudo/src/features/diagnostics/nodes_page.dart';
import 'package:clash_pseudo/src/features/diagnostics/resources_page.dart';
import 'package:clash_pseudo/src/features/diagnostics/rules_page.dart';
import 'package:clash_pseudo/src/features/overrides/local_custom_editor.dart';
import 'package:clash_pseudo/src/features/overrides/local_yaml_edit.dart';
import 'package:clash_pseudo/src/features/overrides/override_entry.dart';
import 'package:clash_pseudo/src/features/overrides/provider_form.dart';
import 'package:clash_pseudo/src/features/overrides/proxy_form.dart';
import 'package:clash_pseudo/src/features/overrides/rule_form.dart';
import 'package:clash_pseudo/src/features/strategies/strategy_snapshot.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/definition_provenance.dart';
import 'package:clash_pseudo/src/model/operation_admission.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/readonly_override_store.dart';
import '../settings/preferences_fakes.dart';
import '../../support/local_definitions.dart';
import 'rule_fakes.dart';
import 'runtime_fakes.dart' show core, response;

class _Configs extends ConfigStore {
  _Configs() : super(Directory.systemTemp);
  @override
  Future<ConfigCollection> read() async => ConfigCollection(entries: []);
}

class _Bridge extends AppBridge {
  AppSnapshot state = AppSnapshot(phase: 'RUNNING', core: core(1));
  final commands = <Map<String, Object?>>[];
  Completer<StrategySnapshot>? pendingStrategies;
  int strategyReads = 0;
  StrategySnapshot get data => StrategySnapshot(
    generation: 1,
    configId: 'main',
    revision: 1,
    purpose: 'VPN',
    composition: core(1).composition,
    globalReferenced: false,
    unrestored: const {},
    groups: [
      for (final name in ['Visible', 'Hidden', 'GLOBAL'])
        StrategyGroup(
          name: name,
          rawType: 'select',
          hidden: name == 'Hidden',
          now: 'DIRECT',
          fixed: '',
          members: const [StrategyMember(name: 'DIRECT', type: 'Direct')],
        ),
    ],
  );
  @override
  Future<AppSnapshot> snapshot() async => state;
  @override
  Future<OperationAdmission?> submit(Map<String, Object?> command) async {
    commands.add(command);
    return null;
  }

  @override
  Future<Map<String, dynamic>> nodes(
    CoreSnapshot source,
    Map<String, Object?> query,
  ) async => {
    ...response(source),
    'page': {
      'total': 0,
      'token': 'a' * 64,
      'nextOffset': -1,
      'nodes': <Object>[],
    },
  };
  @override
  Future<Map<String, dynamic>> rules(
    CoreSnapshot source,
    Map<String, Object?> query,
  ) async => rulePage(total: 0);
  @override
  Future<Map<String, dynamic>> resources(CoreSnapshot source) async => {
    ...response(source),
    'resources': <Object>[],
  };
  @override
  Future<StrategySnapshot> strategies(int generation) async {
    strategyReads++;
    return pendingStrategies == null ? data : await pendingStrategies!.future;
  }
}

const _entry = OverrideEntry(
  id: 'custom',
  name: 'Renamed dedicated plugin',
  kind: ConfigKind.local,
  role: OverrideRole.localCustom,
  revision: 4,
  enabled: false,
  body: '''proxies: [{name: local-node, type: direct}]
rules: ["MATCH,DIRECT"]
proxy-providers: {local-proxy-provider: {type: inline, payload: []}}
rule-providers: {local-rule-provider: {type: inline, payload: []}}
''',
);

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  late _Bridge bridge;
  late ReadOnlyOverrideStore store;
  late AppController app;
  setUp(() {
    bridge = _Bridge();
    store = ReadOnlyOverrideStore()..entries = [_entry];
    app = AppController(
      bridge,
      store: _Configs(),
      overrideStore: store,
      preferencesStore: MemoryPreferencesStore(),
    );
  });
  tearDown(() => app.dispose());

  Widget page(String kind) => switch (kind) {
    'nodes' => NodesPage(app: app),
    'rules' => RulesPage(app: app),
    _ => ResourcesPage(app: app),
  };
  Future<void> show(WidgetTester tester, Widget child) async {
    await app.refresh();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    );
    await settleLocalDefinitions(tester);
  }

  Future<void> restore() async {
    store.entries = [
      OverrideEntry.fromJson({..._entry.toJson(), 'body': '{}\n'}),
    ];
    bridge.state = AppSnapshot(
      phase: 'RUNNING',
      core: core(1),
      storageEpoch: 1,
    );
    await app.refresh();
  }

  for (final kind in ['nodes', 'rules', 'resources']) {
    testWidgets(
      '$kind opens only its real form without selecting or saving anything',
      (tester) async {
        await show(tester, page(kind));
        await tester.tap(find.byKey(const ValueKey('local-custom-add')));
        await settleLocalDefinitions(tester);
        if (kind == 'resources') {
          await tester.tap(find.text(en.providerProxyFormTitle));
          await settleLocalDefinitions(tester);
          expect(
            tester
                .widget<ProviderFormPage>(find.byType(ProviderFormPage))
                .ruleProvider,
            isFalse,
          );
        } else if (kind == 'nodes') {
          expect(find.byType(ProxyFormPage), findsOneWidget);
        } else {
          final form = tester.widget<RuleFormPage>(find.byType(RuleFormPage));
          expect(form.targets, [
            'DIRECT',
            'REJECT',
            'Visible',
            'Hidden',
            'GLOBAL',
          ]);
          expect(form.ruleProviders, ['set']);
          expect(form.subRules, ['branch']);
          expect(form.restrictTargets, isFalse);
        }
        expect(find.text(en.localCustomDisabled), findsOneWidget);
        expect(bridge.commands, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      '$kind local list includes disabled direct definitions for that section only',
      (tester) async {
        await show(tester, page(kind));
        expect(
          find.byKey(const ValueKey('local-custom-definitions')),
          findsNothing,
        );
        expect(find.byType(CustomScrollView), findsOneWidget);
        final expected = kind == 'nodes'
            ? ['local-node']
            : kind == 'rules'
            ? ['MATCH,DIRECT']
            : ['local-proxy-provider', 'local-rule-provider'];
        for (final value in expected) {
          expect(find.text(value), findsOneWidget);
        }
        for (final value in [
          'local-node',
          'MATCH,DIRECT',
          'local-proxy-provider',
          'local-rule-provider',
        ]) {
          if (!expected.contains(value)) expect(find.text(value), findsNothing);
        }
        expect(
          find.byIcon(Icons.delete_outline),
          findsNWidgets(expected.length),
        );
        expect(bridge.commands, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      '$kind search filters disabled local originals without a runtime preview',
      (tester) async {
        bridge.state = const AppSnapshot(phase: 'STOPPED');
        await show(tester, page(kind));
        final search = find.byType(TextField);
        final wanted = kind == 'nodes'
            ? 'local-node'
            : kind == 'rules'
            ? 'MATCH,DIRECT'
            : 'local-proxy-provider';
        await tester.enterText(search, '  ${wanted.toUpperCase()}  ');
        await settleLocalDefinitions(tester);
        expect(find.text(wanted), findsOneWidget);
        if (kind == 'resources') {
          expect(find.text('local-rule-provider'), findsNothing);
        }
        await tester.enterText(search, 'not-in-any-definition');
        await settleLocalDefinitions(tester);
        expect(find.byIcon(Icons.delete_outline), findsNothing);
        await tester.tap(find.byTooltip(en.clearSearch));
        await settleLocalDefinitions(tester);
        expect(find.text(wanted), findsOneWidget);
        expect(bridge.commands, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      '$kind old-render creation callback cannot acquire a restored epoch',
      (tester) async {
        await show(tester, page(kind));
        final add = find.byKey(const ValueKey('local-custom-add'));
        if (kind == 'resources') {
          final old = tester.widget<ChoiceMenuButton<LocalYamlSection>>(add);
          await restore();
          await settleLocalDefinitions(tester);
          old.onSelected(LocalYamlSection.ruleProviders);
        } else {
          final old = tester.widget<IconButton>(add).onPressed!;
          await restore();
          await settleLocalDefinitions(tester);
          old();
        }
        await settleLocalDefinitions(tester);
        expect(find.byType(ProxyFormPage), findsNothing);
        expect(find.byType(RuleFormPage), findsNothing);
        expect(find.byType(ProviderFormPage), findsNothing);
        expect(bridge.commands, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'resource popup retains the opening epoch through a real restore while open',
    (tester) async {
      await show(tester, ResourcesPage(app: app));
      await tester.tap(find.byKey(const ValueKey('local-custom-add')));
      await settleLocalDefinitions(tester);
      final oldSelection = tester
          .widget<MenuItemButton>(
            find.widgetWithText(MenuItemButton, en.providerRuleFormTitle),
          )
          .onPressed!;
      await restore();
      await settleLocalDefinitions(tester);
      expect(find.byType(MenuItemButton), findsNothing);
      oldSelection();
      await settleLocalDefinitions(tester);
      expect(find.byType(ProviderFormPage), findsNothing);
      expect(bridge.commands, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final (kind, body, name) in [
    (
      'nodes',
      'proxies: [{name: future-node, type: future-type}]\n',
      'future-node',
    ),
    (
      'resources',
      'proxy-providers: {future-provider: {type: future-type}}\n',
      'future-provider',
    ),
    ('rules', 'rules: ["FINAL,DIRECT"]\n', 'FINAL,DIRECT'),
  ]) {
    testWidgets(
      '$kind unsupported original is explained without changing its source',
      (tester) async {
        store.entries = [
          OverrideEntry.fromJson({..._entry.toJson(), 'body': body}),
        ];
        await show(tester, page(kind));
        await tester.tap(find.widgetWithText(ListTile, name));
        await settleLocalDefinitions(tester);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text(en.localYamlUnsupportedEdit), findsOneWidget);
        expect(find.byType(ProxyFormPage), findsNothing);
        expect(find.byType(ProviderFormPage), findsNothing);
        expect(find.byType(RuleFormPage), findsNothing);
        expect(store.entries.single.body, body);
        expect(bridge.commands, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text(en.close));
        await settleLocalDefinitions(tester);
        expect(
          tester
              .widget<IconButton>(
                find.ancestor(
                  of: find.byIcon(Icons.delete_outline),
                  matching: find.byType(IconButton),
                ),
              )
              .onPressed,
          isNotNull,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'local original loading labels require exact source revision and path without moving the row',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      store.entries = [
        OverrideEntry.fromJson({..._entry.toJson(), 'enabled': true}),
      ];
      SourceContribution origin({
        String id = 'custom',
        int revision = 4,
        String path = '/proxies/0',
      }) => SourceContribution.fromMap({
        'kind': 'plugin',
        'id': id,
        'revision': revision,
        'name': _entry.name,
        'role': 'localCustom',
        'path': path,
      });
      final sources = ValueNotifier<List<SourceContribution>>([origin()]);
      addTearDown(sources.dispose);
      await show(
        tester,
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 1000),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: ValueListenableBuilder<List<SourceContribution>>(
              valueListenable: sources,
              builder: (context, value, _) => LocalDefinitions(
                app: app,
                sections: const {LocalYamlSection.proxies},
                loadedSource: core(1),
                loadedContributors: value,
                builder: (context, rows) => ReadingList(
                  identity: app.storageEpoch,
                  header: const SizedBox.shrink(),
                  items: rows,
                ),
              ),
            ),
          ),
        ),
      );
      final row = find.widgetWithText(ListTile, 'local-node');
      final rect = tester.getRect(row);
      expect(find.textContaining(en.localOriginalContributes), findsOneWidget);
      for (final value in [
        [origin(revision: 3)],
        [origin(id: 'another')],
        [origin(path: '/proxies/1')],
        <SourceContribution>[],
        [origin()],
      ]) {
        sources.value = value;
        for (final milliseconds in [0, 16, 100]) {
          await tester.pump(Duration(milliseconds: milliseconds));
          expect(tester.getRect(row), rect);
          expect(tester.takeException(), isNull);
        }
        expect(
          find.textContaining(en.localOriginalContributes),
          value.length == 1 &&
                  value.single.revision == 4 &&
                  value.single.id == 'custom' &&
                  value.single.path == '/proxies/0'
              ? findsOneWidget
              : findsNothing,
        );
      }
      bridge.state = AppSnapshot(phase: 'RUNNING', core: core(2));
      await app.refresh();
      await settleLocalDefinitions(tester);
      expect(find.textContaining(en.localOriginalContributes), findsNothing);
      expect(find.textContaining(en.localOriginalUnconfirmed), findsOneWidget);
      expect(tester.getRect(row), rect);
      expect(tester.widget<ListTile>(row).onTap, isNotNull);
      expect(bridge.commands, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'editing a disabled local rule offers every actual group and local rule provider',
    (tester) async {
      await show(tester, RulesPage(app: app));
      await tester.tap(find.widgetWithText(ListTile, 'MATCH,DIRECT'));
      await settleLocalDefinitions(tester);
      final form = tester.widget<RuleFormPage>(find.byType(RuleFormPage));
      expect(form.initialRule, 'MATCH,DIRECT');
      expect(
        form.targets,
        containsAll(['DIRECT', 'REJECT', 'Visible', 'Hidden', 'GLOBAL']),
      );
      expect(form.ruleProviders, containsAll(['set', 'local-rule-provider']));
      expect(bridge.strategyReads, 1);
      expect(bridge.commands, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final editing in [false, true]) {
    testWidgets(
      'optional runtime suggestions cannot block local rule ${editing ? 'editing' : 'creation'}',
      (tester) async {
        bridge.pendingStrategies = Completer<StrategySnapshot>();
        await show(tester, RulesPage(app: app));
        await tester.tap(
          editing
              ? find.widgetWithText(ListTile, 'MATCH,DIRECT')
              : find.byKey(const ValueKey('local-custom-add')),
        );
        await tester.pump();
        expect(bridge.strategyReads, 1);
        bridge.pendingStrategies!.completeError(StateError('read unavailable'));
        await settleLocalDefinitions(tester);
        expect(find.byType(AlertDialog), findsNothing);
        final form = tester.widget<RuleFormPage>(find.byType(RuleFormPage));
        expect(form.initialRule, editing ? 'MATCH,DIRECT' : null);
        expect(form.targets, ['DIRECT', 'REJECT']);
        expect(form.restrictTargets, isFalse);
        expect(store.entries.single, _entry);
        expect(bridge.commands, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final invalidation in ['store', 'runtime']) {
    testWidgets(
      'failed optional rule suggestions retain the captured $invalidation gate',
      (tester) async {
        bridge.pendingStrategies = Completer<StrategySnapshot>();
        await show(tester, RulesPage(app: app));
        await tester.tap(find.byKey(const ValueKey('local-custom-add')));
        await tester.pump();
        expect(bridge.strategyReads, 1);
        if (invalidation == 'store') {
          await restore();
        } else {
          bridge.state = AppSnapshot(phase: 'RUNNING', core: core(2));
          await app.refresh();
        }
        bridge.pendingStrategies!.completeError(StateError('read unavailable'));
        await settleLocalDefinitions(tester);
        expect(find.byType(RuleFormPage), findsNothing);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text(en.strategyContextChangedRetry), findsOneWidget);
        expect(bridge.commands, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'local edit suggestions cannot cross a pending runtime identity',
    (tester) async {
      bridge.pendingStrategies = Completer<StrategySnapshot>();
      await show(tester, RulesPage(app: app));
      await tester.tap(find.widgetWithText(ListTile, 'MATCH,DIRECT'));
      await tester.pump();
      expect(bridge.strategyReads, 1);
      bridge.state = AppSnapshot(phase: 'RUNNING', core: core(2));
      await app.refresh();
      bridge.pendingStrategies!.complete(bridge.data);
      await settleLocalDefinitions(tester);
      expect(find.byType(RuleFormPage), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(en.strategyContextChangedRetry), findsOneWidget);
      expect(bridge.commands, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'rule suggestions cannot cross source identity while the query is pending',
    (tester) async {
      bridge.pendingStrategies = Completer<StrategySnapshot>();
      await show(tester, RulesPage(app: app));
      await tester.tap(find.byKey(const ValueKey('local-custom-add')));
      await tester.pump();
      expect(bridge.strategyReads, 1);
      bridge.state = AppSnapshot(phase: 'RUNNING', core: core(2));
      await app.refresh();
      bridge.pendingStrategies!.complete(bridge.data);
      await settleLocalDefinitions(tester);
      expect(find.byType(RuleFormPage), findsNothing);
      expect(bridge.commands, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'provider members and geo drilldowns do not acquire local write controls',
    (tester) async {
      for (final child in [
        NodesPage(app: app, provider: 'feed', expectedSource: core(1)),
        RulesPage(app: app, provider: 'set', expectedSource: core(1)),
        ResourcesPage(app: app, geoName: 'geosite', expectedSource: core(1)),
      ]) {
        await show(tester, child);
        expect(find.byKey(const ValueKey('local-custom-add')), findsNothing);
        expect(
          find.byKey(const ValueKey('local-custom-definitions')),
          findsNothing,
        );
        expect(bridge.commands, isEmpty);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
}
