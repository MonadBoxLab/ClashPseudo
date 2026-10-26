import 'dart:async';

import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/app/widgets/reading_list.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/diagnostics/strategy_groups_page.dart';
import 'package:clash_pseudo/src/features/overrides/definition_form_fields.dart';
import 'package:clash_pseudo/src/features/overrides/override_entry.dart';
import 'package:clash_pseudo/src/features/overrides/strategy_group_form.dart';
import 'package:clash_pseudo/src/features/mode/tunnel_mode.dart';
import 'package:clash_pseudo/src/features/strategies/strategies_page.dart';
import 'package:clash_pseudo/src/features/strategies/strategy_controller.dart';
import 'package:clash_pseudo/src/features/strategies/strategy_popup.dart';
import 'package:clash_pseudo/src/features/strategies/strategy_snapshot.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/definition_provenance.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../support/local_definitions.dart';

import 'package:flutter_test/flutter_test.dart';

import '../strategies/strategy_fakes.dart';

StrategySnapshot _groups({
  bool hidden = true,
  CoreSnapshot core = previewCore,
  List<StrategyGroup>? groups,
}) => StrategySnapshot(
  generation: core.generation,
  configId: core.configId!,
  revision: core.revision!,
  purpose: core.purpose!,
  composition: core.composition,
  mode: TunnelMode.direct,
  globalReferenced: false,
  unrestored: {},
  groups:
      groups ??
      [
        StrategyGroup(
          name: 'Hidden group with a long readable name',
          rawType: 'select',
          hidden: hidden,
          now: 'A',
          fixed: '',
          members: const [
            StrategyMember(name: 'A', type: 'Socks5'),
            StrategyMember(name: 'B', type: 'Direct'),
          ],
        ),
        StrategyGroup(
          name: 'GLOBAL',
          rawType: 'select',
          hidden: true,
          now: 'A',
          fixed: '',
          members: const [
            StrategyMember(name: 'A', type: 'Socks5'),
            StrategyMember(name: 'B', type: 'Direct'),
          ],
        ),
      ],
);

class _DraftApp extends StrategyAppFake {
  _DraftApp(super.bridge) {
    overridesLoaded = true;
    overrides = [_entry('Original local group')];
  }

  int epoch = 0;
  Completer<AppSnapshot?>? reply;
  final saves = <Map<String, Object?>>[];
  bool? localReader;

  @override
  int get storageEpoch => epoch;
  @override
  bool get configsCurrent =>
      configsLoaded &&
      configError == null &&
      state.storageReady &&
      !state.storageRestoring &&
      state.storageEpoch == epoch;

  static OverrideEntry _entry(String group) => OverrideEntry(
    id: 'custom',
    name: 'Local customizations',
    kind: ConfigKind.local,
    revision: 2,
    enabled: false,
    role: OverrideRole.localCustom,
    body:
        'proxy-groups:\n  - name: $group\n    type: select\n    proxies: [DIRECT]\n',
  );

  void restore() {
    epoch++;
    state = AppSnapshot(
      phase: 'STOPPED',
      core: previewCore,
      storageEpoch: epoch,
    );
    overrides = [_entry('Restored local group')];
    changed();
  }

  @override
  Future<AppSnapshot?> submitAndWait(
    Map<String, Object?> command, {
    ValueListenable<bool>? feedbackOwner,
  }) async {
    saves.add(Map.of(command));
    localReader = feedbackOwner?.value;
    return reply?.future ??
        Future.value(
          AppSnapshot(
            resultSuccess: false,
            overrideStatus: 'notSaved',
            resultMessage: messages.localYamlDuplicateName,
          ),
        );
  }
}

void main() {
  const hiddenName = 'Hidden group with a long readable name';
  late StrategyBridgeFake bridge;
  late StrategyAppFake app;
  late StrategyController controller;
  setUp(() {
    bridge = StrategyBridgeFake()..data = _groups();
    app = StrategyAppFake(bridge);
    controller = StrategyController(app, allGroups: true);
  });
  tearDown(() {
    controller.dispose();
    app.dispose();
  });

  Future<void> show(
    WidgetTester tester, {
    bool dark = false,
    double scale = 1,
    bool animations = false,
    VoidCallback? onAdd,
  }) async {
    tester.view.physicalSize = const Size(320, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: dark ? AppTheme.dark : AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: !animations,
          ),
          child: child!,
        ),
        home: StrategiesPage(
          controller: controller,
          active: true,
          onAdd: onAdd,
        ),
      ),
    );
    await settleLocalDefinitions(tester);
  }

  Finder card(String name) => find.byKey(ValueKey('strategy-group-$name'));
  Finder attributes(String name) =>
      find.byKey(ValueKey('strategy-attributes-$name'));
  Finder source(String name) => find.byKey(ValueKey('strategy-source-$name'));

  Future<void> showOverview(
    WidgetTester tester, {
    double scale = 1,
    double width = 320,
    bool dark = false,
    String language = 'en',
  }) async {
    tester.view.physicalSize = Size(width, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: dark ? AppTheme.dark : AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: StrategyGroupsPage(app: app),
      ),
    );
    await settleLocalDefinitions(tester);
  }

  Future<void> showDraft(WidgetTester tester, _DraftApp draft) async {
    tester.view.physicalSize = const Size(320, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: StrategyGroupsPage(app: draft),
      ),
    );
    await settleLocalDefinitions(tester);
  }

  Finder draftName() => find.descendant(
    of: find.byWidgetPredicate(
      (widget) => widget is DefinitionTextField && widget.id == 'group/name',
    ),
    matching: find.byType(TextField),
  );

  testWidgets(
    'new group uses the real form and retains input through save rejection',
    (tester) async {
      final draft = _DraftApp(bridge);
      addTearDown(draft.dispose);
      await showDraft(tester, draft);
      await tester.tap(find.byTooltip('Add strategy group'));
      await settleLocalDefinitions(tester);
      final form = tester.widget<StrategyGroupFormPage>(
        find.byType(StrategyGroupFormPage),
      );
      expect(
        form.members,
        containsAll(['DIRECT', 'REJECT', hiddenName, 'GLOBAL', 'A', 'B']),
      );
      expect(form.providers, isEmpty);
      await tester.ensureVisible(draftName());
      await tester.enterText(draftName(), 'Kept draft');
      await settleLocalDefinitions(tester);
      final nameRect = tester.getRect(draftName());
      final save = find.byKey(const ValueKey('definition-save:group'));
      final saveRect = tester.getRect(save);
      final body = draft.overrides.single.body;
      final pending = Completer<AppSnapshot?>();
      draft.reply = pending;
      await tester.tap(save);
      for (final elapsed in [Duration.zero, const Duration(milliseconds: 16)]) {
        await tester.pump(elapsed);
        expect(tester.getRect(draftName()), nameRect);
        expect(tester.getRect(save), saveRect);
        expect(tester.widget<TextField>(draftName()).enabled, isFalse);
        expect(tester.widget<FilledButton>(save).onPressed, isNull);
      }
      expect(draft.saves.single, {
        'action': 'saveLocalDefinition',
        'id': 'custom',
        'revision': 2,
        'storageEpoch': 0,
        'name': 'Local customizations',
        'section': 'strategyGroups',
        'definition': {'type': 'select', 'name': 'Kept draft'},
      });
      expect(draft.localReader, isTrue);
      pending.complete(
        AppSnapshot(
          resultSuccess: false,
          overrideStatus: 'notSaved',
          resultMessage: messages.localYamlDuplicateName,
        ),
      );
      await settleLocalDefinitions(tester);
      expect(tester.getRect(draftName()), nameRect);
      expect(tester.getRect(save), saveRect);
      expect(
        tester.widget<TextField>(draftName()).controller!.text,
        'Kept draft',
      );
      expect(tester.widget<TextField>(draftName()).enabled, isTrue);
      expect(draft.overrides.single.body, body);
      expect(draft.overrides.single.enabled, isFalse);
      expect(find.byType(StrategyGroupFormPage), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await settleLocalDefinitions(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        tester.widget<TextField>(draftName()).controller!.text,
        'Kept draft',
      );
      await tester.tap(find.widgetWithText(TextButton, 'Discard'));
      await settleLocalDefinitions(tester);
      expect(find.byType(StrategyGroupsPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'same-id revision restore keeps the new-group draft but revokes its writes',
    (tester) async {
      final draft = _DraftApp(bridge);
      addTearDown(draft.dispose);
      await showDraft(tester, draft);
      await tester.tap(find.byTooltip('Add strategy group'));
      await settleLocalDefinitions(tester);
      await tester.ensureVisible(draftName());
      await tester.enterText(draftName(), 'Retained old input');
      await settleLocalDefinitions(tester);
      final nameRect = tester.getRect(draftName());
      final save = find.byKey(const ValueKey('definition-save:group'));
      final saveRect = tester.getRect(save);
      draft.restore();
      expect(draft.canEdit, isTrue);
      for (final elapsed in [
        Duration.zero,
        const Duration(milliseconds: 16),
        const Duration(milliseconds: 80),
      ]) {
        await tester.pump(elapsed);
        expect(tester.getRect(draftName()), nameRect);
        expect(tester.getRect(save), saveRect);
        expect(
          tester.widget<TextField>(draftName()).controller!.text,
          'Retained old input',
        );
      }
      await tester.tap(save);
      await settleLocalDefinitions(tester);
      expect(draft.saves, isEmpty);
      expect(
        tester.widget<TextField>(draftName()).controller!.text,
        'Retained old input',
      );
      expect(draft.overrides.single.id, 'custom');
      expect(draft.overrides.single.revision, 2);
      expect(draft.overrides.single.body, contains('Restored local group'));
      expect(tester.getRect(draftName()), nameRect);
      expect(tester.getRect(save), saveRect);
      await tester.tap(find.byType(BackButton));
      await settleLocalDefinitions(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'old rendered add cannot open a draft with a freshly restored epoch',
    (tester) async {
      final draft = _DraftApp(bridge);
      addTearDown(draft.dispose);
      await showDraft(tester, draft);
      final callback = tester
          .widget<StrategiesPage>(find.byType(StrategiesPage))
          .onAdd!;
      draft.restore();
      expect(draft.canEdit, isTrue);
      callback();
      await settleLocalDefinitions(tester);
      expect(find.byType(StrategyGroupFormPage), findsNothing);
      final strings = AppLocalizations.of(
        tester.element(find.byType(AlertDialog)),
      );
      expect(find.text(strings.storageContextChanged), findsWidgets);
      expect(draft.saves, isEmpty);
      await tester.tap(find.text(strings.close));
      await settleLocalDefinitions(tester);
      await tester.tap(find.byTooltip('Add strategy group'));
      await settleLocalDefinitions(tester);
      expect(find.byType(StrategyGroupFormPage), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await settleLocalDefinitions(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'properties show every actual contributor without granting writes and retire stale runtime status',
    (tester) async {
      bridge.data = _groups(
        groups: [
          StrategyGroup(
            name: 'Attributed group',
            rawType: 'select',
            hidden: false,
            now: 'DIRECT',
            fixed: '',
            members: const [],
            provenance: DefinitionProvenance.fromValue({
              'contributors': [
                {
                  'kind': 'plugin',
                  'id': 'remote',
                  'revision': 1,
                  'name': 'Remote source',
                  'path': '/proxy-groups/0',
                },
                {
                  'kind': 'plugin',
                  'id': 'dedicated',
                  'revision': 1,
                  'name': 'Dedicated source',
                  'role': 'localCustom',
                  'path': '/proxy-groups/0',
                },
                {'kind': 'config', 'path': '/proxy-groups/0'},
              ],
            }),
          ),
        ],
      );
      await showOverview(tester, width: 700, scale: 1.3);
      await tester.tap(card('Attributed group'));
      await settleLocalDefinitions(tester);
      final en = lookupAppLocalizations(const Locale('en'));
      expect(find.text('1. Remote source'), findsOneWidget);
      expect(find.text('2. Dedicated source'), findsOneWidget);
      expect(find.byKey(const ValueKey('group-properties-edit')), findsNothing);
      expect(find.text(en.strategyGroupRuntimePropertiesOnly), findsOneWidget);
      final status = find.byKey(
        const ValueKey('group-properties-runtime-state'),
      );
      final rect = tester.getRect(status);
      final name = tester.element(
        find.byKey(const ValueKey('group-properties-name')),
      );
      expect(find.text(en.runtimeConfigPreview), findsOneWidget);
      app.state = const AppSnapshot(phase: 'STOPPED');
      app.changed();
      for (final ms in [0, 16, 100]) {
        await tester.pump(Duration(milliseconds: ms));
        expect(tester.getRect(status), rect);
        expect(find.text(en.coreSnapshotStale), findsWidgets);
        expect(tester.takeException(), isNull);
      }
      await showOverview(tester, width: 700, scale: 1.3, language: 'zh');
      final zh = lookupAppLocalizations(const Locale('zh'));
      expect(
        tester.element(find.byKey(const ValueKey('group-properties-name'))),
        same(name),
      );
      expect(find.text(zh.provenancePlugins(2)), findsOneWidget);
      expect(find.text(zh.strategyGroupRuntimePropertiesOnly), findsOneWidget);
      expect(find.text('1. Remote source'), findsOneWidget);
      expect(find.text('2. Dedicated source'), findsOneWidget);
      expect(find.byKey(const ValueKey('group-properties-edit')), findsNothing);
      expect(app.commands, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'properties cannot reopen a same-name definition from a changed original body',
    (tester) async {
      final draft = _DraftApp(bridge);
      addTearDown(draft.dispose);
      bridge.data = _groups(
        groups: [
          StrategyGroup(
            name: 'Original local group',
            rawType: 'select',
            hidden: false,
            now: 'DIRECT',
            fixed: '',
            members: const [StrategyMember(name: 'DIRECT', type: 'Direct')],
          ),
        ],
      );
      await showDraft(tester, draft);
      await tester.tap(card('Original local group'));
      await settleLocalDefinitions(tester);
      final original = draft.overrides.single;
      draft.overrides = [
        OverrideEntry.fromJson({
          ...original.toJson(),
          'body': '${original.body}changed: true\n',
        }),
      ];
      draft.changed();
      await settleLocalDefinitions(tester);
      await tester.tap(find.byKey(const ValueKey('group-properties-edit')));
      await settleLocalDefinitions(tester);
      expect(find.byType(StrategyGroupFormPage), findsNothing);
      final strings = AppLocalizations.of(
        tester.element(find.byType(AlertDialog)),
      );
      expect(find.text(strings.overrideChangedReopen), findsOneWidget);
      expect(draft.saves, isEmpty);
      expect(draft.overrides.single.revision, original.revision);
      expect(draft.overrides.single.body, endsWith('changed: true\n'));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final language in ['en', 'zh']) {
    testWidgets(
      'properties use readable width and lazy 4096 members at 2x $language',
      (tester) async {
        bridge.data = _groups(
          groups: [
            StrategyGroup(
              name: 'Readable long group with 4096 members 长名称',
              rawType: 'select',
              hidden: false,
              now: 'member-0',
              fixed: '',
              members: [
                for (var index = 0; index < 4096; index++)
                  StrategyMember(name: 'member-$index', type: 'Socks5'),
              ],
            ),
          ],
        );
        await showOverview(tester, language: language, scale: 2, width: 1704);
        await tester.tap(card(bridge.data.groups.single.name));
        await settleLocalDefinitions(tester);
        final content = find.byKey(const ValueKey('group-properties-content'));
        expect(tester.getSize(content).width, 840);
        expect(tester.getCenter(content).dx, 852);
        expect(find.text('member-0'), findsWidgets);
        expect(find.text('member-4095'), findsNothing);
        expect(find.byType(SelectableText).evaluate().length, lessThan(100));
        tester.view.physicalSize = const Size(280, 1100);
        await settleLocalDefinitions(tester);
        expect(tester.getSize(content).width, 280);
        expect(tester.takeException(), isNull);
        final scroll = tester.state<ScrollableState>(
          find.descendant(of: content, matching: find.byType(Scrollable)).first,
        );
        scroll.position.jumpTo(scroll.position.maxScrollExtent);
        await settleLocalDefinitions(tester);
        await tester.scrollUntilVisible(
          find.text('member-4095'),
          800,
          maxScrolls: 30,
          scrollable: find
              .descendant(of: content, matching: find.byType(Scrollable))
              .first,
        );
        expect(find.text('member-4095'), findsOneWidget);
        expect(find.byType(SelectableText).evaluate().length, lessThan(100));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'old category row cannot borrow restored direct definitions before or after rebuild',
    (tester) async {
      final draft = _DraftApp(bridge);
      addTearDown(draft.dispose);
      await showDraft(tester, draft);
      final original = find.widgetWithText(ListTile, 'Original local group');
      await tester.ensureVisible(original);
      await settleLocalDefinitions(tester);
      final old = tester.widget<ListTile>(original).onTap!;
      draft.restore();
      expect(draft.canEdit, isTrue);
      old();
      await settleLocalDefinitions(tester);
      expect(find.byType(StrategyGroupFormPage), findsNothing);
      old();
      await settleLocalDefinitions(tester);
      expect(find.byType(StrategyGroupFormPage), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byTooltip('More actions'), findsNothing);
      expect(find.text('Original local group'), findsNothing);
      final restored = find.widgetWithText(ListTile, 'Restored local group');
      await tester.ensureVisible(restored);
      await tester.tap(restored);
      await settleLocalDefinitions(tester);
      expect(
        tester
            .widget<StrategyGroupFormPage>(find.byType(StrategyGroupFormPage))
            .initialDefinition!['name'],
        'Restored local group',
      );
      expect(draft.saves, isEmpty);
      await tester.tap(find.byType(BackButton));
      await settleLocalDefinitions(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'secondary route owns and releases the existing strategy reader',
    (tester) async {
      app.overridesLoaded = true;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => StrategyGroupsPage(app: app),
                  ),
                ),
                child: const Text('Open all groups'),
              ),
            ),
          ),
        ),
      );
      expect(bridge.reads, 0);
      await tester.tap(find.text('Open all groups'));
      await settleLocalDefinitions(tester);
      final page = tester.element(find.byType(StrategyGroupsPage));
      final reader = tester
          .widget<StrategiesPage>(find.byType(StrategiesPage))
          .controller;
      expect(reader.allGroups, isTrue);
      expect(reader.active, isTrue);
      expect(card('GLOBAL'), findsOneWidget);
      expect(app.commands, isEmpty);
      final reads = bridge.reads;
      Navigator.of(page).push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('Covered')),
        ),
      );
      await settleLocalDefinitions(tester);
      expect(reader.active, isFalse);
      await tester.pump(const Duration(seconds: 5));
      expect(bridge.reads, reads);
      Navigator.of(page).pop();
      await settleLocalDefinitions(tester);
      expect(reader.active, isTrue);
      expect(bridge.reads, reads + 1);
      Navigator.of(page).pop();
      await settleLocalDefinitions(tester);
      expect(find.byType(StrategyGroupsPage), findsNothing);
      expect(reader.active, isFalse);
      final afterClose = bridge.reads;
      await tester.pump(const Duration(seconds: 10));
      expect(bridge.reads, afterClose);
      expect(app.commands, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'direct definitions share category scrolling without a Hub menu',
    (tester) async {
      final epoch = ValueNotifier(1);
      addTearDown(epoch.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ValueListenableBuilder<int>(
            valueListenable: epoch,
            builder: (_, value, _) => StrategiesPage(
              controller: controller,
              active: true,
              localDefinitions: [
                ReadingListItem(
                  id: 'direct-definition',
                  builder: (context) => Text('direct-definition-$value'),
                ),
              ],
            ),
          ),
        ),
      );
      await settleLocalDefinitions(tester);
      final scroll = find.byType(CustomScrollView);
      expect(scroll, findsOneWidget);
      expect(find.byTooltip('More actions'), findsNothing);
      expect(
        find.descendant(of: scroll, matching: find.text('direct-definition-1')),
        findsOneWidget,
      );
      epoch.value = 2;
      for (final elapsed in [Duration.zero, const Duration(milliseconds: 16)]) {
        await tester.pump(elapsed);
        expect(find.byTooltip('More actions'), findsNothing);
        expect(find.text('direct-definition-1'), findsNothing);
        expect(
          find.descendant(
            of: scroll,
            matching: find.text('direct-definition-2'),
          ),
          findsOneWidget,
        );
      }
      controller.setVisible(false);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final language in ['en', 'zh']) {
    for (final width in [280.0, 320.0, 700.0]) {
      for (final scale in [1.0, 1.3, 2.0]) {
        for (final dark in [false, true]) {
          testWidgets(
            'actual plugin icon does not move group/card anchors $language/$width/$scale/$dark',
            (tester) async {
              StrategyGroup group(String name, bool plugins) => StrategyGroup(
                name: name,
                rawType: 'select',
                hidden: name == 'GLOBAL',
                now: 'DIRECT',
                fixed: '',
                members: const [StrategyMember(name: 'DIRECT', type: 'Direct')],
                provenance: DefinitionProvenance.fromValue({
                  'contributors': [
                    if (plugins) ...[
                      {
                        'kind': 'plugin',
                        'id': 'remote',
                        'revision': 4,
                        'name': 'A very long plugin name 不显示在卡片',
                        'path': '/proxy-groups/0',
                      },
                      {
                        'kind': 'plugin',
                        'id': 'custom',
                        'revision': 2,
                        'name': 'Saved custom',
                        'role': 'localCustom',
                        'path': '/proxy-groups/1',
                      },
                    ],
                    {'kind': 'config', 'path': '/proxy-groups/0'},
                  ],
                }),
              );
              bridge.data = _groups(groups: [group('GLOBAL', false)]);
              // Use loaded composition provenance separately from saved local
              // definitions.
              app.overridesLoaded = true;
              app.overrides = [_DraftApp._entry('GLOBAL')];
              await showOverview(
                tester,
                scale: scale,
                width: width,
                dark: dark,
                language: language,
              );
              final anchors = [
                card('GLOBAL'),
                source('GLOBAL'),
                find.byKey(const ValueKey('strategy-current-GLOBAL')),
              ];
              final before = anchors.map(tester.getRect).toList();
              expect(
                find.descendant(
                  of: source('GLOBAL'),
                  matching: find.byType(Icon),
                ),
                findsNothing,
              );
              final strings = lookupAppLocalizations(Locale(language));
              for (final contributed in [true, false, true]) {
                bridge.data = _groups(groups: [group('GLOBAL', contributed)]);
                await tester.pump(const Duration(seconds: 5));
                for (final ms in [0, 16, 80, 250]) {
                  await tester.pump(Duration(milliseconds: ms));
                  expect(anchors.map(tester.getRect).toList(), before);
                  expect(
                    find.descendant(
                      of: source('GLOBAL'),
                      matching: find.byIcon(Icons.extension_outlined),
                    ),
                    contributed ? findsOneWidget : findsNothing,
                  );
                  expect(
                    find.descendant(
                      of: source('GLOBAL'),
                      matching: find.byType(Text),
                    ),
                    findsNothing,
                  );
                  expect(
                    find.byTooltip(strings.strategyGroupPluginContribution),
                    contributed ? findsOneWidget : findsNothing,
                  );
                  expect(tester.takeException(), isNull);
                }
              }
              await tester.pumpWidget(const SizedBox.shrink());
            },
          );
        }
      }
    }
  }

  for (final dark in [false, true]) {
    testWidgets(
      'all groups retain explicit attributes and stable fixed slots at 320 double text dark=$dark',
      (tester) async {
        await showOverview(tester, scale: 2, dark: dark);
        expect(find.text('All strategy groups'), findsOneWidget);
        expect(card(hiddenName), findsOneWidget);
        expect(card('GLOBAL'), findsOneWidget);
        expect(find.byTooltip('Show hidden groups'), findsNothing);
        expect(find.byTooltip('Hide hidden groups'), findsNothing);
        expect(find.byTooltip('Test group'), findsNothing);
        expect(
          find.descendant(
            of: attributes(hiddenName),
            matching: find.text('Hidden'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: attributes('GLOBAL'),
            matching: find.text('Hidden · Global group'),
          ),
          findsOneWidget,
        );
        await tester.ensureVisible(card(hiddenName));
        final name = find.byKey(ValueKey('strategy-name-$hiddenName'));
        final nameRect = tester.getRect(name);
        final slotRect = tester.getRect(attributes(hiddenName));
        bridge.data = _groups(hidden: false);
        await tester.pump(const Duration(seconds: 5));
        for (final elapsed in [
          Duration.zero,
          const Duration(milliseconds: 16),
        ]) {
          await tester.pump(elapsed);
          expect(tester.getRect(name), nameRect);
          expect(tester.getRect(attributes(hiddenName)), slotRect);
          expect(card(hiddenName), findsOneWidget);
        }
        expect(
          find.descendant(
            of: attributes(hiddenName),
            matching: find.text('Hidden'),
          ),
          findsNothing,
        );
        bridge.failRead = true;
        await tester.pump(const Duration(seconds: 5));
        await tester.pump();
        expect(tester.getRect(name), nameRect);
        expect(tester.getRect(attributes(hiddenName)), slotRect);
        bridge.failRead = false;
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(tester.getRect(name), nameRect);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('all-groups cards show the reliable source and open properties', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: StrategyGroupsPage(app: app),
      ),
    );
    await settleLocalDefinitions(tester);
    bridge.data = _groups(
      groups: [
        StrategyGroup(
          name: 'local group',
          rawType: 'select',
          hidden: false,
          now: 'A',
          fixed: '',
          provenance: DefinitionProvenance.fromValue({
            'contributors': [
              {
                'kind': 'plugin',
                'id': 'local',
                'revision': 2,
                'name': 'Local plugin',
                'role': 'localCustom',
                'path': '/proxy-groups/0',
              },
              {'kind': 'config', 'path': '/proxy-groups/0'},
            ],
          }),
          members: const [
            StrategyMember(name: 'A', type: 'Socks5'),
            StrategyMember(name: 'B', type: 'Direct'),
          ],
        ),
        StrategyGroup(
          name: 'main group',
          rawType: 'select',
          hidden: false,
          now: 'A',
          fixed: '',
          provenance: DefinitionProvenance.fromValue({
            'contributors': [
              {'kind': 'config', 'path': '/proxy-groups/0'},
            ],
          }),
          members: const [StrategyMember(name: 'A', type: 'Socks5')],
        ),
        StrategyGroup(
          name: 'GLOBAL',
          rawType: 'select',
          hidden: true,
          now: 'A',
          fixed: '',
          members: const [StrategyMember(name: 'A', type: 'Socks5')],
        ),
        StrategyGroup(
          name: 'unknown group',
          rawType: 'select',
          hidden: false,
          now: 'A',
          fixed: '',
          members: const [StrategyMember(name: 'A', type: 'Socks5')],
        ),
      ],
    );
    await tester.pump(const Duration(seconds: 5));
    await settleLocalDefinitions(tester);
    expect(
      find.descendant(
        of: source('local group'),
        matching: find.byIcon(Icons.extension_outlined),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Plugin contribution'), findsOneWidget);
    expect(
      tester
          .widget<Icon>(
            find.descendant(
              of: source('local group'),
              matching: find.byIcon(Icons.extension_outlined),
            ),
          )
          .semanticLabel,
      'Plugin contribution',
    );
    for (final name in [
      'local group',
      'main group',
      'GLOBAL',
      'unknown group',
    ]) {
      expect(
        find.descendant(of: source(name), matching: find.byType(Text)),
        findsNothing,
      );
      expect(tester.getSize(source(name)), const Size(20, 20));
      if (name != 'local group') {
        expect(
          find.descendant(
            of: source(name),
            matching: find.byIcon(Icons.extension_outlined),
          ),
          findsNothing,
        );
      }
    }
    expect(find.byTooltip('Test group'), findsNothing);

    await tester.ensureVisible(card('main group'));
    await tester.tap(card('main group'));
    await settleLocalDefinitions(tester);
    final strings = AppLocalizations.of(
      tester.element(find.byKey(const ValueKey('group-properties-name'))),
    );
    expect(find.byType(StrategyPopup), findsNothing);
    expect(find.text(strings.strategyGroupDefinitionTitle), findsOneWidget);
    expect(find.text(strings.strategyGroupSourceReadOnly), findsOneWidget);
    expect(find.byKey(const ValueKey('group-properties-edit')), findsNothing);
    expect(app.commands, isEmpty);
    await tester.tap(find.byType(BackButton));
    await settleLocalDefinitions(tester);
    expect(card('main group'), findsOneWidget);

    await tester.ensureVisible(card('GLOBAL'));
    await tester.tap(card('GLOBAL'));
    await settleLocalDefinitions(tester);
    expect(find.text(strings.strategyGroupSourceReadOnly), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'properties page shows actual attributes without inventing fields',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: StrategyGroupsPage(app: app),
        ),
      );
      await settleLocalDefinitions(tester);
      await tester.ensureVisible(card(hiddenName));
      await tester.tap(card(hiddenName));
      await settleLocalDefinitions(tester);
      final strings = AppLocalizations.of(
        tester.element(find.byKey(const ValueKey('group-properties-name'))),
      );
      expect(find.text(strings.strategyGroupAttributesHeading), findsOneWidget);
      expect(find.text(strings.strategyGroupSourceReadOnly), findsOneWidget);
      expect(find.text(strings.strategyChoiceSelect), findsWidgets);
      expect(find.text(strings.proxyTrue), findsOneWidget);
      expect(find.text('A'), findsWidgets);
      expect(find.text('B'), findsWidgets);
      expect(find.byKey(const ValueKey('group-properties-edit')), findsNothing);
      expect(app.commands, isEmpty);
      await tester.tap(find.byType(BackButton));
      await settleLocalDefinitions(tester);
      expect(bridge.reads, greaterThan(0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('all-groups empty state does not claim mode filtering', (
    tester,
  ) async {
    bridge.data = _groups(groups: []);
    await show(tester);
    expect(find.text('No strategy groups'), findsOneWidget);
    expect(find.textContaining('visible in the current mode'), findsNothing);
    expect(find.byType(StrategyPopup), findsNothing);
    expect(app.commands, isEmpty);
    controller.setVisible(false);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'all-groups loading and retry preserve the add action and title',
    (tester) async {
      final pending = Completer<StrategySnapshot>();
      bridge.pendingRead = pending;
      var adds = 0;
      await show(tester, scale: 2, onAdd: () => adds++);
      final add = find.byTooltip('Add strategy group');
      final title = find.text('All strategy groups');
      final addRect = tester.getRect(add);
      final titleRect = tester.getRect(title);
      pending.completeError(StateError('read failed'));
      for (final elapsed in [Duration.zero, const Duration(milliseconds: 16)]) {
        await tester.pump(elapsed);
        expect(tester.getRect(add), addRect);
        expect(tester.getRect(title), titleRect);
      }
      bridge.pendingRead = null;
      await tester.tap(find.text('Load strategies'));
      await settleLocalDefinitions(tester);
      expect(tester.getRect(add), addRect);
      expect(tester.getRect(title), titleRect);
      expect(card('GLOBAL'), findsOneWidget);
      await tester.tap(add);
      expect(adds, 1);
      app.dispatching = true;
      app.changed();
      await tester.pump();
      expect(tester.getRect(add), addRect);
      expect(tester.getRect(title), titleRect);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton &&
                    widget.tooltip == 'Add strategy group',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      controller.setVisible(false);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
