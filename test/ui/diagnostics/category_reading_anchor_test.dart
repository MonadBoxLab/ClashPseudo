import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/ui/components/collections/reading_list.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/logic/configs/config_store.dart';
import 'package:clash_pseudo/src/logic/diagnostics/core_collection_page.dart';
import 'package:clash_pseudo/src/ui/diagnostics/nodes/nodes_page.dart';
import 'package:clash_pseudo/src/ui/diagnostics/resources/resources_page.dart';
import 'package:clash_pseudo/src/ui/diagnostics/rules/rules_page.dart';
import 'package:clash_pseudo/src/ui/strategies/strategy_groups_page.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/ui/strategies/strategies_page.dart';
import 'package:clash_pseudo/src/model/strategy_snapshot.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../overrides/definitions/local_definitions_support.dart';
import '../../support/readonly_override_store.dart';
import '../../support/preferences_fakes.dart';
import 'rules/rule_fakes.dart';
import 'configuration/runtime_fakes.dart' show core, response;

class _NonlinearScaler extends TextScaler {
  const _NonlinearScaler();
  @override
  double scale(double size) => size * (size <= 14 ? 2 : 1.6);
  @override
  double get textScaleFactor => 2;
}

class _Configs extends ConfigStore {
  _Configs() : super(Directory.systemTemp);
  @override
  Future<ConfigCollection> read() async => ConfigCollection(entries: []);
}

class _Bridge extends AppBridge {
  int count = 2;
  int epoch = 0;
  Completer<void>? pending;
  bool failed = false;
  int reads = 0;
  @override
  Future<AppSnapshot> snapshot() async =>
      AppSnapshot(phase: 'RUNNING', core: core(1), storageEpoch: epoch);

  Future<void> _wait() async {
    reads++;
    await pending?.future;
    if (failed) throw StateError('Controlled read failure');
  }

  Map<String, dynamic> _page(
    Map<String, Object?> query,
    String key,
    Map<String, dynamic> native,
  ) {
    final rows = DefinitionRows.merge(
      (native[key] as List).map((row) => Map<String, dynamic>.from(row as Map)),
      (query['definitions'] as List? ?? const []).map(
        (row) => Map<String, dynamic>.from(row as Map),
      ),
    );
    final matches = rows
        .where((row) => DefinitionRows.matches(row, query['search'] as String))
        .toList();
    final start = query['offset'] as int;
    final page = matches.skip(start).take(query['limit'] as int).toList();
    return {
      ...native,
      key: page,
      'total': matches.length,
      'nextOffset': start + page.length < matches.length
          ? start + page.length
          : -1,
      'token': DefinitionRows.pageToken(
        native['token'] as String,
        query['localIdentity'] as String? ?? '',
      ),
      if (native['scopes'] case final List scopes)
        'scopes': [
          for (final scope in scopes)
            if (scope is Map && scope['kind'] == 'main')
              {...scope, 'count': rows.length}
            else
              scope,
        ],
    };
  }

  @override
  Future<Map<String, dynamic>> nodes(
    CoreSnapshot source,
    Map<String, Object?> query,
  ) async {
    await _wait();
    return {
      ...response(source),
      'page': _page(query, 'nodes', {
        'total': count,
        'nextOffset': -1,
        'token': 'a' * 64,
        'nodes': [
          for (var i = 0; i < count; i++)
            {
              'name': 'runtime-$i',
              'type': 'Direct',
              'source': 'configuration',
              'sourceKind': 'configuration',
              'sourceVersion': 0,
              'builtin': false,
              'udp': true,
              'history': [],
              'tests': [],
            },
        ],
      }),
    };
  }

  @override
  Future<Map<String, dynamic>> rules(
    CoreSnapshot source,
    Map<String, Object?> query,
  ) async {
    await _wait();
    final value = rulePage(total: count);
    return {
      ...value,
      'page': _page(
        query,
        'rows',
        Map<String, dynamic>.from(value['page'] as Map),
      ),
    };
  }

  @override
  Future<Map<String, dynamic>> resources(CoreSnapshot source) async {
    await _wait();
    return {
      ...response(source),
      'resources': [
        for (var i = 0; i < count; i++)
          {
            'kind': 'proxyProvider',
            'name': 'runtime-$i',
            'vehicleType': 'Inline',
            'source': '',
            'updateSupported': false,
          },
      ],
    };
  }

  @override
  Future<StrategySnapshot> strategies(CoreSnapshot coreIdentity) async {
    final generation = coreIdentity.generation;
    await _wait();
    final source = core(generation);
    return StrategySnapshot(
      generation: generation,
      configId: source.configId!,
      revision: source.revision!,
      purpose: source.purpose!,
      composition: source.composition,
      globalReferenced: false,
      unrestored: const {},
      groups: [
        for (var i = 0; i < count; i++)
          StrategyGroup(
            name: 'runtime-$i',
            rawType: 'select',
            hidden: false,
            now: 'DIRECT',
            fixed: '',
            members: const [StrategyMember(name: 'DIRECT', type: 'Direct')],
          ),
      ],
    );
  }
}

String _body(
  String category, {
  bool prepend = false,
  int prependCount = 1,
  int start = 0,
}) {
  final indices = [
    if (prepend)
      for (var i = -prependCount; i < 0; i++) i,
    for (var i = start; i < 80; i++) i,
  ];
  return switch (category) {
    'nodes' =>
      'proxies:\n${[for (final i in indices) '  - {name: local-$i, type: direct}'].join('\n')}\n',
    'groups' =>
      'proxy-groups:\n${[for (final i in indices) '  - {name: local-$i, type: select, proxies: [DIRECT]}'].join('\n')}\n',
    'rules' =>
      'rules:\n${[for (final i in indices) '  - DOMAIN,local-$i.test,DIRECT'].join('\n')}\n',
    _ =>
      'proxy-providers:\n${[for (final i in indices) '  local-$i: {type: inline, payload: []}'].join('\n')}\n',
  };
}

Finder _categoryRow(String category, String label) => category == 'groups'
    ? find.widgetWithText(InkWell, label)
    : find.widgetWithText(ListTile, label);

void main() {
  group('all-groups window and accessible card geometry', () {
    _groupWindowTest();
    _groupSemanticsTest();
  });
  group('category readability', _categoryReadabilityTest);
  group('category pagination', _categoryPaginationTest);
  group('category window continuity', _categoryWindowTest);
  group('category local reading anchors', () {
    for (final category in ['nodes', 'rules', 'resources', 'groups']) {
      for (final language in ['en', 'zh']) {
        for (final (width, scaler) in [
          (320.0, const TextScaler.linear(2)),
          (1704.0, const _NonlinearScaler()),
        ]) {
          for (final change in ['runtime', 'original']) {
            testWidgets(
              '$category local reading anchor $change/$language/$width',
              (tester) async {
                tester.view.physicalSize = Size(width, 1000);
                tester.view.devicePixelRatio = 1;
                addTearDown(tester.view.resetPhysicalSize);
                addTearDown(tester.view.resetDevicePixelRatio);
                final bridge = _Bridge();
                final store = ReadOnlyOverrideStore()
                  ..entries = [
                    OverrideEntry(
                      id: 'custom',
                      name: 'custom',
                      kind: ConfigKind.local,
                      role: OverrideRole.localCustom,
                      revision: 1,
                      enabled: false,
                      body: _body(category),
                    ),
                  ];
                final app = AppController(
                  bridge,
                  store: _Configs(),
                  overrideStore: store,
                  preferencesStore: MemoryPreferencesStore(),
                );
                addTearDown(app.dispose);
                await app.refresh();
                final page = switch (category) {
                  'nodes' => NodesPage(app: app),
                  'rules' => RulesPage(app: app),
                  'groups' => StrategyGroupsPage(app: app),
                  _ => ResourcesPage(app: app),
                };
                await tester.pumpWidget(
                  MaterialApp(
                    locale: Locale(language),
                    localizationsDelegates:
                        AppLocalizations.localizationsDelegates,
                    supportedLocales: AppLocalizations.supportedLocales,
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(context).copyWith(textScaler: scaler),
                      child: child!,
                    ),
                    home: page,
                  ),
                );
                await settleLocalDefinitions(tester);
                final name = category == 'rules' ? 'local-20.test' : 'local-20';
                final target = _categoryRow(category, name);
                await tester.scrollUntilVisible(
                  target,
                  500,
                  scrollable: find
                      .descendant(
                        of: find.byType(ReadingList),
                        matching: find.byType(Scrollable),
                      )
                      .first,
                  maxScrolls: 60,
                );
                await tester.ensureVisible(target);
                await tester.pumpAndSettle();
                final rect = tester.getRect(target);
                final list = find.byType(ReadingList);
                final columns = category == 'groups'
                    ? tester
                              .widget<ReadingList>(list)
                              .items
                              .first
                              .semanticChildCount ??
                          1
                    : 1;
                final position = tester
                    .state<ScrollableState>(
                      find
                          .descendant(
                            of: list,
                            matching: find.byType(Scrollable),
                          )
                          .first,
                    )
                    .position;
                Future<void> frames() async {
                  for (final milliseconds in [0, 16, 32, 80]) {
                    await tester.pump(Duration(milliseconds: milliseconds));
                    expect(
                      target,
                      findsOneWidget,
                      reason: '$change frame $milliseconds',
                    );
                    expect(
                      tester.getRect(target),
                      rect,
                      reason: '$change frame $milliseconds',
                    );
                    expect(
                      tester
                          .state<ScrollableState>(
                            find
                                .descendant(
                                  of: list,
                                  matching: find.byType(Scrollable),
                                )
                                .first,
                          )
                          .position,
                      same(position),
                    );
                    expect(tester.takeException(), isNull);
                  }
                }

                Future<void> nextRead({bool afterFailure = false}) async {
                  final previousReads = bridge.reads;
                  expect(find.byIcon(Icons.refresh), findsNothing);
                  final seconds = category == 'groups'
                      ? (afterFailure ? 1 : 5)
                      : (afterFailure ? 5 : 30);
                  await tester.pump(Duration(seconds: seconds));
                  await tester.pump();
                  expect(bridge.reads, previousReads + 1);
                }

                if (change == 'runtime') {
                  // Hold a real bridge read pending through the geometry checks.
                  bridge.pending = Completer<void>();
                  await nextRead();
                  await frames();
                  bridge.count = category == 'nodes' || category == 'rules'
                      ? 20
                      : category == 'groups'
                      ? 2 + ((38 + columns - 1) ~/ columns) * columns
                      : 40;
                  bridge.pending!.complete();
                  bridge.pending = null;
                  await frames();
                  bridge.failed = true;
                  await nextRead();
                  await frames();
                  bridge.failed = false;
                  bridge.count = category == 'groups' ? 2 : 1;
                  await nextRead(afterFailure: true);
                  await frames();
                } else {
                  final start = category == 'groups'
                      ? (10 ~/ columns) * columns
                      : 10;
                  for (final (prepend, first) in [(true, 0), (false, start)]) {
                    store.entries = [
                      OverrideEntry.fromJson({
                        ...store.entries.single.toJson(),
                        'revision': store.entries.single.revision + 1,
                        'body': _body(
                          category,
                          prepend: prepend,
                          prependCount: columns,
                          start: first,
                        ),
                      }),
                    ];
                    await app.refresh();
                    await frames();
                    // Wait for the real compute, even with its spinner offscreen.
                    await settleLocalDefinitions(tester);
                    await frames();
                    final edit = find.descendant(
                      of: target,
                      matching: find.widgetWithIcon(
                        IconButton,
                        Icons.edit_outlined,
                      ),
                    );
                    expect(
                      tester.widget<IconButton>(edit).onPressed,
                      isNotNull,
                      reason: 'the newly parsed source is actually accepted',
                    );
                  }
                }
                await tester.pumpWidget(const SizedBox());
              },
            );
          }
        }
      }
    }
  });
}

void _categoryPaginationTest() {
  for (final category in ['nodes', 'rules']) {
    testWidgets('$category 运行条目增加后，本地条目按统一分页保持可达', (tester) async {
      tester.view.physicalSize = const Size(700, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final bridge = _Bridge();
      final store = ReadOnlyOverrideStore()
        ..entries = [
          OverrideEntry(
            id: 'custom',
            name: 'custom',
            kind: ConfigKind.local,
            role: OverrideRole.localCustom,
            revision: 1,
            enabled: false,
            body: _body(category),
          ),
        ];
      final app = AppController(
        bridge,
        store: _Configs(),
        overrideStore: store,
        preferencesStore: MemoryPreferencesStore(),
      );
      addTearDown(app.dispose);
      await app.refresh();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: category == 'nodes' ? NodesPage(app: app) : RulesPage(app: app),
        ),
      );
      await settleLocalDefinitions(tester);
      final target = _categoryRow(
        category,
        category == 'rules' ? 'local-20.test' : 'local-20',
      );
      final scroll = find
          .descendant(
            of: find.byType(ReadingList),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(target, 400, scrollable: scroll);
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      expect(target, findsOneWidget);
      expect(
        tester.widget<ReadingList>(find.byType(ReadingList)).items,
        hasLength(50),
      );
      bridge.count = 40;
      final previousReads = bridge.reads;
      expect(find.byIcon(Icons.refresh), findsNothing);
      await tester.pump(const Duration(seconds: 30));
      await settleLocalDefinitions(tester);
      expect(bridge.reads, previousReads + 1);
      final strings = lookupAppLocalizations(const Locale('en'));
      expect(find.text(strings.resultRange(1, 50, 120)), findsOneWidget);
      expect(target, findsNothing);
      expect(
        tester.widget<ReadingList>(find.byType(ReadingList)).items,
        hasLength(50),
      );
      await tester.tap(find.widgetWithIcon(IconButton, Icons.chevron_right));
      await settleLocalDefinitions(tester);
      expect(find.text(strings.resultRange(51, 100, 120)), findsOneWidget);
      await tester.scrollUntilVisible(target, 400, scrollable: scroll);
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      expect(target, findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.descendant(
                of: target,
                matching: find.widgetWithIcon(IconButton, Icons.edit_outlined),
              ),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.widgetWithIcon(IconButton, Icons.chevron_left));
      await settleLocalDefinitions(tester);
      expect(find.text(strings.resultRange(1, 50, 120)), findsOneWidget);
      expect(target, findsNothing);
      expect(store.entries.single.enabled, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

void _groupWindowTest() {
  testWidgets(
    'actual all-groups grid keeps its reading card and focus across window changes',
    (tester) async {
      tester.view.physicalSize = const Size(1704, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = _Bridge()..count = 60;
      final app = AppController(
        bridge,
        store: _Configs(),
        overrideStore: ReadOnlyOverrideStore(),
        preferencesStore: MemoryPreferencesStore(),
      );
      addTearDown(app.dispose);
      await app.refresh();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: StrategyGroupsPage(app: app),
        ),
      );
      await settleLocalDefinitions(tester);
      final card = find.byKey(const ValueKey('strategy-card-runtime-20'));
      final scroll = find
          .descendant(
            of: find.byType(ReadingList),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(card, 400, scrollable: scroll);
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      final top = tester.getTopLeft(card).dy;
      final focus = Focus.of(
        tester.element(
          find.descendant(of: card, matching: find.byType(Text)).first,
        ),
      );
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasPrimaryFocus, isTrue);
      tester.view.physicalSize = const Size(700, 1000);
      for (final milliseconds in [0, 16, 80]) {
        await tester.pump(Duration(milliseconds: milliseconds));
        expect(card, findsOneWidget);
        expect(tester.getTopLeft(card).dy, top);
        expect(focus.hasPrimaryFocus, isTrue);
        expect(focus.context, isNotNull);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
}

void _groupSemanticsTest() {
  for (final count in [1, 4]) {
    testWidgets(
      'all-groups card semantics use the actual card bounds count=$count',
      (tester) async {
        tester.view.physicalSize = const Size(1704, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bridge = _Bridge()..count = count;
        final app = AppController(
          bridge,
          store: _Configs(),
          overrideStore: ReadOnlyOverrideStore(),
          preferencesStore: MemoryPreferencesStore(),
        );
        addTearDown(app.dispose);
        await app.refresh();
        final semantics = tester.ensureSemantics();
        try {
          await tester.pumpWidget(
            MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: StrategyGroupsPage(app: app),
            ),
          );
          await settleLocalDefinitions(tester);
          void check(int expected) {
            final ids = <int>{};
            for (var i = 0; i < expected; i++) {
              final card = find.byKey(ValueKey('strategy-card-runtime-$i'));
              final action = find.byKey(ValueKey('strategy-group-runtime-$i'));
              final node = tester.getSemantics(action);
              expect(
                node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
                isTrue,
              );
              expect(
                ids.add(node.id),
                isTrue,
                reason: 'each card has its own action node',
              );
              expect(
                node.rect.width,
                tester.getSize(card).width,
                reason:
                    'blank grid cells must not extend the accessible action',
              );
              expect(node.rect.height, tester.getSize(card).height);
              final indexed = tester.widget<IndexedSemantics>(
                find
                    .ancestor(
                      of: action,
                      matching: find.byType(IndexedSemantics),
                    )
                    .first,
              );
              expect(indexed.index, i);
            }
            expect(
              tester
                  .widget<CustomScrollView>(find.byType(CustomScrollView))
                  .semanticChildCount,
              expected,
            );
          }

          check(count);
          for (final next in [count == 1 ? 4 : 1, 2, count]) {
            bridge.count = next;
            tester
                .widget<StrategiesPage>(find.byType(StrategiesPage))
                .controller
                .retry();
            await tester.pumpAndSettle();
            check(next);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        } finally {
          semantics.dispose();
        }
      },
    );
  }
}

void _categoryReadabilityTest() {
  for (final category in ['nodes', 'rules', 'resources', 'groups']) {
    for (final language in ['en', 'zh']) {
      for (final width in [320.0, 839.0, 840.0, 841.0, 1704.0]) {
        for (final scaler in [
          const TextScaler.linear(2),
          const _NonlinearScaler(),
        ]) {
          testWidgets('$category readable column $language/$width/$scaler', (
            tester,
          ) async {
            tester.view.physicalSize = Size(width, 1000);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final longName = 'local-0 ${'中文 long name e\u0301 👩‍💻 ' * 6}'
                .trimRight();
            final store = ReadOnlyOverrideStore()
              ..entries = [
                OverrideEntry(
                  id: 'custom',
                  name: 'custom',
                  kind: ConfigKind.local,
                  role: OverrideRole.localCustom,
                  revision: 1,
                  enabled: false,
                  body: _body(category).replaceAll('local-0', longName),
                ),
              ];
            final app = AppController(
              _Bridge(),
              store: _Configs(),
              overrideStore: store,
              preferencesStore: MemoryPreferencesStore(),
            );
            addTearDown(app.dispose);
            await app.refresh();
            final page = switch (category) {
              'nodes' => NodesPage(app: app),
              'rules' => RulesPage(app: app),
              'groups' => StrategyGroupsPage(app: app),
              _ => ResourcesPage(app: app),
            };
            await tester.pumpWidget(
              MaterialApp(
                locale: Locale(language),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: scaler),
                  child: child!,
                ),
                home: page,
              ),
            );
            await settleLocalDefinitions(tester);
            final label = category == 'rules' ? '$longName.test' : longName;
            final row = _categoryRow(category, label);
            await tester.scrollUntilVisible(
              row,
              200,
              scrollable: find
                  .descendant(
                    of: find.byType(ReadingList),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            );
            await tester.ensureVisible(row);
            await tester.pumpAndSettle();
            final rect = tester.getRect(row);
            final pane = tester.getRect(
              find.ancestor(of: row, matching: find.byType(Scaffold)).first,
            );
            final expected = pane.width.clamp(0.0, 840.0);
            if (category == 'groups') {
              expect(rect.width, greaterThan(0));
              expect(rect.left, greaterThanOrEqualTo(pane.left));
              expect(rect.right, lessThanOrEqualTo(pane.right));
              final cards = find.byWidgetPredicate(
                (widget) =>
                    widget is InkWell &&
                    widget.key is ValueKey<String> &&
                    (widget.key as ValueKey<String>).value.startsWith(
                      'strategy-group-',
                    ),
              );
              for (final card in cards.evaluate()) {
                expect(
                  tester.getSize(find.byWidget(card.widget)).width,
                  closeTo(rect.width, 1e-9),
                );
              }
            } else {
              expect(rect.width, expected);
              expect(rect.center.dx, pane.center.dx);
            }
            expect(
              tester.getSize(find.byType(ReadingList)).width,
              category == 'groups' ? pane.width : expected,
              reason: 'strategy card 使用实际 grid，其它分类使用可读列宽',
            );
            if (category == 'nodes' || category == 'rules') {
              final previous = tester.getRect(find.byIcon(Icons.chevron_left));
              final next = tester.getRect(
                find.byIcon(Icons.chevron_right).last,
              );
              expect(previous.left, greaterThanOrEqualTo(rect.left));
              expect(next.right, lessThanOrEqualTo(rect.right));
            }
            final semantics = tester.ensureSemantics();
            try {
              await tester.pump();
              expect(
                tester.getSemantics(row).rect.width,
                rect.width,
                reason:
                    'centering cannot leave a full-window accessible hit box',
              );
            } finally {
              semantics.dispose();
            }
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          });
        }
      }
    }
  }
}

void _categoryWindowTest() {
  for (final category in ['nodes', 'rules', 'resources', 'groups']) {
    for (final language in ['en', 'zh']) {
      for (final mode in ['reading', if (category != 'groups') 'search']) {
        testWidgets('$category window continuity $language/$mode', (
          tester,
        ) async {
          tester.view.physicalSize = const Size(1704, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetViewInsets);
          final store = ReadOnlyOverrideStore()
            ..entries = [
              OverrideEntry(
                id: 'custom',
                name: 'custom',
                kind: ConfigKind.local,
                role: OverrideRole.localCustom,
                revision: 1,
                enabled: false,
                body: _body(category),
              ),
            ];
          final app = AppController(
            _Bridge(),
            store: _Configs(),
            overrideStore: store,
            preferencesStore: MemoryPreferencesStore(),
          );
          addTearDown(app.dispose);
          await app.refresh();
          final page = switch (category) {
            'nodes' => NodesPage(app: app),
            'rules' => RulesPage(app: app),
            'groups' => StrategyGroupsPage(app: app),
            _ => ResourcesPage(app: app),
          };
          await tester.pumpWidget(
            MaterialApp(
              locale: Locale(language),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const _NonlinearScaler()),
                child: child!,
              ),
              home: page,
            ),
          );
          await settleLocalDefinitions(tester);
          final scroll = find
              .descendant(
                of: find.byType(ReadingList),
                matching: find.byType(Scrollable),
              )
              .first;
          final scrollState = tester.state<ScrollableState>(scroll);
          final scrollController = scrollState.widget.controller;
          FocusNode focus;
          Finder? row;
          double? top;
          TextEditingController? input;
          TextEditingValue? accepted;
          if (mode == 'reading') {
            var label = category == 'rules' ? 'local-20.test' : 'local-20';
            if (category == 'groups') {
              final groups = tester
                  .widget<StrategiesPage>(find.byType(StrategiesPage))
                  .definitions!;
              final columns = tester
                  .widget<ReadingList>(find.byType(ReadingList))
                  .items
                  .first
                  .semanticChildCount!;
              final index = groups.indexWhere((group) => group.name == label);
              label = groups[index ~/ columns * columns].name;
            }
            row = _categoryRow(category, label);
            await tester.scrollUntilVisible(
              row,
              500,
              scrollable: scroll,
              maxScrolls: 60,
            );
            await tester.ensureVisible(row);
            await tester.pumpAndSettle();
            top = tester.getTopLeft(row).dy;
            final icon = find.descendant(
              of: row,
              matching: find.byIcon(Icons.edit_outlined),
            );
            focus = Focus.of(tester.element(icon));
            focus.requestFocus();
          } else {
            await tester.enterText(find.byType(TextField), '  local-  ');
            tester.testTextInput.updateEditingValue(
              const TextEditingValue(
                text: '  local-  ',
                selection: TextSelection(baseOffset: 2, extentOffset: 7),
                composing: TextRange(start: 2, end: 7),
              ),
            );
            await tester.pump(const Duration(milliseconds: 300));
            await tester.pumpAndSettle();
            final field = tester.widget<EditableText>(
              find.byType(EditableText),
            );
            input = field.controller;
            focus = field.focusNode;
            accepted = input.value;
          }
          await tester.pump();
          expect(focus.hasPrimaryFocus, isTrue);
          for (final width in [841.0, 840.0, 839.0, 700.0, 320.0, 1704.0]) {
            tester.view.physicalSize = Size(width, 1000);
            for (final milliseconds in [0, 16, 80]) {
              await tester.pump(Duration(milliseconds: milliseconds));
              expect(tester.state<ScrollableState>(scroll), same(scrollState));
              expect(
                tester.state<ScrollableState>(scroll).widget.controller,
                same(scrollController),
              );
              expect(focus.hasPrimaryFocus, isTrue);
              if (row != null) {
                expect(row, findsOneWidget);
                expect(
                  tester.getTopLeft(row).dy,
                  top,
                  reason:
                      '$category width=$width ms=$milliseconds '
                      'pixels=${scrollState.position.pixels}',
                );
              } else {
                expect(
                  tester
                      .widget<EditableText>(find.byType(EditableText))
                      .controller,
                  same(input),
                );
                expect(input!.value, accepted);
              }
              expect(tester.takeException(), isNull);
            }
          }
          if (mode == 'search') {
            for (final inset in [360.0, 0.0]) {
              tester.view.viewInsets = FakeViewPadding(bottom: inset);
              for (final milliseconds in [0, 16, 80]) {
                await tester.pump(Duration(milliseconds: milliseconds));
                expect(focus.hasPrimaryFocus, isTrue);
                expect(input!.value, accepted);
                expect(
                  tester.state<ScrollableState>(scroll),
                  same(scrollState),
                );
                expect(tester.takeException(), isNull);
              }
            }
          }
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
}
