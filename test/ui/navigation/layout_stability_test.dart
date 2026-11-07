import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/model/strategy_snapshot.dart';
import 'package:clash_pseudo/src/model/traffic_snapshot.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_feedback.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_notice.dart';
import 'package:clash_pseudo/src/ui/configs/configs_page.dart';
import 'package:clash_pseudo/src/ui/configs/dialogs/import_dialog.dart';
import 'package:clash_pseudo/src/ui/connections/connections_page.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:clash_pseudo/src/ui/navigation/app_shell.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/overview/traffic_controller.dart';
import 'package:clash_pseudo/src/ui/overview/widgets/traffic_panel.dart';
import 'package:clash_pseudo/src/ui/strategies/strategy_popup.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/connection_fakes.dart' as connections;
import '../../support/strategy_fakes.dart' as strategies;
import '../overview/traffic_fakes.dart' as traffic;

void expectListSemantics(WidgetTester tester, Finder list, int count) {
  expect(tester.widget<CustomScrollView>(list).semanticChildCount, count);
  final nodes = tester.widgetList<IndexedSemantics>(
    find.descendant(of: list, matching: find.byType(IndexedSemantics)),
  );
  final ordered =
      nodes
          .map(
            (node) => (node.index, tester.getTopLeft(find.byWidget(node)).dy),
          )
          .toList()
        ..sort((a, b) => a.$2.compareTo(b.$2));
  final indices = ordered.map((entry) => entry.$1).toList();
  expect(indices.toSet().length, indices.length);
  expect(indices, orderedEquals([...indices]..sort()));
  expect(indices.every((index) => index >= 0 && index < count), isTrue);
}

void main() {
  for (final theme in [AppTheme.light, AppTheme.dark]) {
    group(theme.brightness.name, () => _layoutTests(theme));
  }
}

void _layoutTests(ThemeData theme) {
  setUp(() => setMessageLanguage(AppLanguage.zh));
  tearDown(() => setMessageLanguage(AppLanguage.system));

  Widget host(Widget child, double scale) => MaterialApp(
    navigatorObservers: [AppTaskNavigatorObserver()],
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    theme: theme,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: child!,
    ),
    home: child,
  );

  testWidgets('popup does not collapse toward a source moved by resizing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = strategies.StrategyAppFake(strategies.StrategyBridgeFake());
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [AppTaskNavigatorObserver()],
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: theme,
        home: AppShell(controller: app),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pumpAndSettle();
    final source = find.byKey(
      const ValueKey('strategy-group-出口'),
      skipOffstage: false,
    );
    final anchor = tester.getRect(source);
    await tester.tap(source);
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(520, 844);
    await tester.pumpAndSettle();
    expect(tester.getRect(source), isNot(anchor));
    final popup = find.byType(StrategyPopup);
    final expanded = tester.getRect(popup);
    await tester.tap(find.byTooltip('关闭策略浮窗'));
    for (final ms in [0, 16, 60, 60]) {
      await tester.pump(Duration(milliseconds: ms));
      expect(tester.widget<StrategyPopup>(popup).progress, 1);
      expect(tester.getRect(popup), expanded);
    }
    await tester.pumpAndSettle();
    expect(popup, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'feedback ignores restored and automatic results but reports active failure once',
    (tester) async {
      final app = strategies.StrategyAppFake(strategies.StrategyBridgeFake());
      addTearDown(app.dispose);
      await tester.pumpWidget(
        host(
          OperationFeedback(
            controller: app,
            child: const Scaffold(body: Text('content')),
          ),
          1,
        ),
      );
      app.state = const AppSnapshot(
        phase: 'STOPPED',
        resultId: 'restored',
        resultMessage: AppMessage('androidErrorStrategyPrepare'),
      );
      app.changed();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      app.lastCommand = {'action': 'prepareStrategies'};
      app.lastCommandAutomatic = true;
      app.state = const AppSnapshot(
        phase: 'STOPPED',
        resultId: 'automatic',
        resultMessage: AppMessage('androidErrorStrategyPrepare'),
      );
      app.changed();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      app.lastCommand = {'action': 'prepareStrategies'};
      app.lastCommandAutomatic = false;
      app.state = const AppSnapshot(
        phase: 'STOPPED',
        resultId: 'manual',
        resultMessage: AppMessage('androidErrorStrategyPrepare'),
      );
      app.changed();
      await tester.pumpAndSettle();
      expect(
        find.text(messages.androidErrorStrategyPrepare.text),
        findsOneWidget,
      );
      expect(find.byType(AlertDialog), findsNothing);
      final notice = find.byType(SnackBar);
      expect(notice, findsOneWidget);
      await tester.tap(
        find.descendant(of: notice, matching: find.byType(IconButton)),
      );
      await tester.pumpAndSettle();
      app.changed();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'operation alert uses compact hierarchy and keeps long errors reachable ($scale)',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          host(
            Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showLocalizedOperationMessage(
                    context,
                    (_) => List.filled(40, '配置下载失败（HTTP 404）。').join('\n'),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
            scale,
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        final close = find.widgetWithText(TextButton, '关闭');
        expect(tester.getRect(close).bottom, lessThanOrEqualTo(568));
        expect(find.byIcon(Icons.error_outline), findsNothing);
        expect(find.text('操作未完成'), findsOneWidget);
        expect(find.byType(SelectableText), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      },
    );

    testWidgets('mode entry stays at hero bottom across states ($scale)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = strategies.StrategyAppFake(strategies.StrategyBridgeFake());
      addTearDown(app.dispose);
      await tester.pumpWidget(host(AppShell(controller: app), scale));
      await tester.pumpAndSettle();
      final trigger = find.byKey(const ValueKey('mode-trigger'));
      final surface = find.byKey(const ValueKey('network-surface'));
      final power = find.byKey(const ValueKey('power-button'));
      final before = tester.getRect(trigger);
      final powerBefore = tester.getRect(power);
      expect(tester.getTopLeft(surface).dy - before.bottom, closeTo(24, .01));
      expect(before.left, 24);
      for (final state in const [
        AppSnapshot(phase: 'RUNNING', configId: 'one'),
        AppSnapshot(phase: 'STOPPING', operation: AppMessage('stageStopping')),
        AppSnapshot(error: AppMessage('coreContextUnconfirmed')),
        AppSnapshot(phase: 'STOPPED'),
      ]) {
        app.state = state;
        app.changed();
        for (final ms in [0, 16, 80, 180]) {
          await tester.pump(Duration(milliseconds: ms));
          expect(tester.getRect(trigger), before);
          expect(tester.getRect(power), powerBefore);
          expect(
            tester.getTopLeft(surface).dy - tester.getRect(trigger).bottom,
            closeTo(24, .01),
          );
        }
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('URL validation preserves input and dialog geometry ($scale)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          const OperationNoticeHost(child: Scaffold(body: ImportDialog())),
          scale,
        ),
      );
      await tester.pumpAndSettle();
      final source = find.byType(TextField).first;
      await tester.enterText(source, 'invalid');
      await tester.pumpAndSettle();
      final targets = [
        find.byType(AlertDialog),
        source,
        find.byType(TextField).last,
        find.widgetWithText(FilledButton, '下载并保存'),
      ];
      final controller = tester.widget<TextField>(source).controller!;
      final fieldState = tester.state(source);
      final before = targets.map(tester.getRect).toList();
      final decoration = tester.widget<TextField>(source).decoration!;
      expect(decoration.helper, isNull);
      expect(decoration.helperText, isNull);
      expect(decoration.error, isNull);
      expect(decoration.errorText, isNull);
      await tester.tap(find.text('下载并保存'));
      for (final ms in [0, 16, 80, 180, 300]) {
        await tester.pump(Duration(milliseconds: ms));
        expect(targets.map(tester.getRect).toList(), before);
        expect(tester.widget<TextField>(source).controller, same(controller));
        expect(tester.state(source), same(fieldState));
      }
      expect(controller.text, 'invalid');
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsNothing);
      expect(
        tester.getSemantics(source).getSemanticsData().validationResult,
        SemanticsValidationResult.invalid,
      );
      expect(
        tester
            .widget<TextField>(source)
            .decoration!
            .focusedBorder!
            .borderSide
            .color,
        theme.colorScheme.error,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.byIcon(Icons.close),
        ),
      );
      for (final ms in [0, 16, 80, 180, 300]) {
        await tester.pump(Duration(milliseconds: ms));
        expect(targets.map(tester.getRect).toList(), before);
        expect(tester.widget<TextField>(source).controller, same(controller));
        expect(tester.state(source), same(fieldState));
      }
      expect(find.byType(SnackBar), findsNothing);
      semantics.dispose();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'configuration removal and row resizing above viewport preserve reader ($scale)',
      (tester) async {
        final app = strategies.StrategyAppFake(strategies.StrategyBridgeFake());
        addTearDown(app.dispose);
        final entries = List.generate(
          40,
          (i) => ConfigEntry(
            id: '$i',
            name: 'Config $i',
            source: 'https://example.test/$i',
            revision: 1,
            body: 'rules: []',
          ),
        );
        app.collection = ConfigCollection(entries: entries, selectedId: '0');
        await tester.pumpWidget(host(ConfigsPage(controller: app), scale));
        await tester.pumpAndSettle();
        final list = find.byType(CustomScrollView);
        await tester.drag(list, const Offset(0, -1200));
        await tester.pumpAndSettle();
        final top = tester.getTopLeft(list).dy;
        final anchor = tester
            .widgetList<Text>(find.byType(Text))
            .firstWhere(
              (w) =>
                  w.data?.startsWith('Config ') == true &&
                  tester.getTopLeft(find.text(w.data!)).dy >= top,
            )
            .data!;
        final rect = tester.getRect(find.text(anchor));
        final anchorIndex = entries.indexWhere((entry) => entry.name == anchor);
        expect(anchorIndex, greaterThan(1));
        for (final resized in [
          entries
              .map(
                (entry) => int.parse(entry.id) < anchorIndex - 1
                    ? entry.renamed('${entry.name} ${'长配置名称 ' * 20}')
                    : entry,
              )
              .toList(),
          entries
              .map(
                (entry) => int.parse(entry.id) < anchorIndex - 1
                    ? entry.withSource(
                        'https://${'long-source-' * 8}example.test/config',
                      )
                    : entry,
              )
              .toList(),
          entries,
        ]) {
          app.collection = ConfigCollection(entries: resized, selectedId: '0');
          app.changed();
          for (var frame = 0; frame < 14; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            expect(tester.getRect(find.text(anchor)), rect);
            expectListSemantics(tester, list, entries.length);
            expect(tester.takeException(), isNull);
          }
        }
        app.collection = ConfigCollection(
          entries: entries.skip(2).toList(),
          selectedId: '2',
        );
        app.changed();
        for (final ms in [0, 16, 80, 180]) {
          await tester.pump(Duration(milliseconds: ms));
          expect(tester.getRect(find.text(anchor)), rect);
          expectListSemantics(tester, list, entries.length - 2);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'compact filters retain geometry across selection and failure ($scale)',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bridge = connections.ConnectionBridgeFake();
        final app = connections.ConnectionAppFake(bridge);
        addTearDown(app.dispose);
        bridge.data = connections.snapshot([
          connections.row('one'),
          {...connections.row('two'), 'active': false},
        ]);
        await tester.pumpWidget(host(ConnectionsPage(app: app), scale));
        await tester.pumpAndSettle();
        final lifecycle = find.byType(TextButton).first;
        final rule = find.byTooltip('筛选命中规则');
        final actions = find.byKey(const ValueKey('connection-list-actions'));
        final targets = [
          lifecycle,
          rule,
          find.byType(AppBar),
          find.byType(CustomScrollView),
          actions,
        ];
        final errorAction = find.byKey(
          const ValueKey('connection-list-error-details'),
        );
        expect(errorAction, findsNothing);
        expect(
          find.byKey(const ValueKey('connection-list-error')),
          findsNothing,
        );
        final before = targets.map(tester.getRect).toList();
        expect(tester.getCenter(rule).dy, tester.getCenter(lifecycle).dy);
        expect(tester.getSize(lifecycle).height, greaterThanOrEqualTo(48));
        await tester.tap(lifecycle);
        await tester.pumpAndSettle();
        await tester.tap(find.text('不活跃'));
        await tester.pumpAndSettle();
        await tester.tap(rule);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Domain · fixture.test'));
        await tester.pumpAndSettle();
        expect(targets.map(tester.getRect).toList(), before);
        expect(find.byTooltip('暂停刷新'), findsNothing);
        expect(find.byTooltip('继续刷新'), findsNothing);
        bridge.fail = true;
        await tester.pump(const Duration(seconds: 1));
        for (final ms in [0, 16, 80, 180]) {
          await tester.pump(Duration(milliseconds: ms));
          expect(targets.map(tester.getRect).toList(), before);
          expect(tester.takeException(), isNull);
        }
        expect(errorAction, findsNothing);
        expect(actions.hitTestable(), findsOneWidget);
        expect(tester.getSize(actions).height, greaterThanOrEqualTo(48));
        expect(
          tester.getRect(actions).bottom,
          lessThanOrEqualTo(tester.getRect(lifecycle).top),
        );
        for (final filter in [lifecycle, rule]) {
          expect(
            find.descendant(
              of: filter,
              matching: find.byIcon(Icons.error_outline_rounded),
            ),
            findsNothing,
          );
        }
        expect(find.byType(SnackBar), findsOneWidget);
        expect(
          find
              .descendant(
                of: find.byType(SnackBar),
                matching: find.byType(TextButton),
              )
              .hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('connection-list-error')),
          findsNothing,
        );
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        expect(errorAction, findsNothing);
        expect(targets.map(tester.getRect).toList(), before);
        await tester.tap(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.widgetWithText(TextButton, '错误详情'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.byType(MenuItemButton), findsNothing);
        expect(find.textContaining('Bad state: unavailable'), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey('operation-technical-details')),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<SelectableText>(
                find.byKey(const ValueKey('operation-technical-text')),
              )
              .data,
          StateError('unavailable').toString(),
        );
        final copy = find.byKey(const ValueKey('operation-technical-copy'));
        await tester.ensureVisible(copy);
        await tester.pumpAndSettle();
        expect(copy.hitTestable(), findsOneWidget);
        await tester.tap(copy);
        await tester.pumpAndSettle();
        expect(copied, StateError('unavailable').toString());
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(targets.map(tester.getRect).toList(), before);
        bridge.fail = false;
        await tester.pump(const Duration(seconds: 2));
        expect(targets.map(tester.getRect).toList(), before);
        for (final ms in [0, 16, 80, 180]) {
          await tester.pump(Duration(milliseconds: ms));
          expect(targets.map(tester.getRect).toList(), before);
          expect(tester.takeException(), isNull);
        }
        expect(find.byType(SnackBar), findsNothing);
        await tester.tap(actions);
        await tester.pumpAndSettle();
        expect(errorAction, findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(targets.map(tester.getRect).toList(), before);
        expect(find.text('已暂停刷新'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'insertion above the first connection does not add a leading divider or move rows ($scale)',
      (tester) async {
        final bridge = connections.ConnectionBridgeFake();
        final app = connections.ConnectionAppFake(bridge);
        addTearDown(app.dispose);
        final old = [connections.row('one'), connections.row('two')];
        bridge.data = connections.snapshot(old);
        await tester.pumpWidget(host(ConnectionsPage(app: app), scale));
        await tester.pumpAndSettle();
        final first = find.text('one.fixture.test');
        final second = find.text('two.fixture.test');
        final before = [tester.getRect(first), tester.getRect(second)];
        bridge.data = connections.snapshot([
          {...connections.row('new'), 'start': '2026-10-17T10:00:00Z'},
          ...old,
        ]);
        await tester.pump(const Duration(seconds: 1));
        for (final ms in [0, 16, 80, 180]) {
          await tester.pump(Duration(milliseconds: ms));
          expect([tester.getRect(first), tester.getRect(second)], before);
          expectListSemantics(tester, find.byType(CustomScrollView), 3);
          final rows = find.descendant(
            of: find.byType(CustomScrollView),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics && widget.properties.button == true,
            ),
          );
          expect(rows.evaluate().length, greaterThanOrEqualTo(2));
          for (final row in rows.evaluate()) {
            final presentation = find.byWidgetPredicate(
              (widget) =>
                  widget is Column &&
                  widget.children.any((child) => identical(child, row.widget)),
            );
            expect(presentation, findsOneWidget);
            final children = tester.widget<Column>(presentation).children;
            expect(children[0], same(row.widget));
            final rowRect = tester.getRect(find.byWidget(row.widget));
            final dividers = find.descendant(
              of: presentation,
              matching: find.byType(Divider),
            );
            for (final divider in dividers.evaluate()) {
              expect(
                tester.getRect(find.byWidget(divider.widget)).top,
                greaterThanOrEqualTo(rowRect.bottom - .01),
              );
            }
          }
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'connection updates and failure leave detail geometry intact ($scale)',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bridge = connections.ConnectionBridgeFake();
        final app = connections.ConnectionAppFake(bridge);
        addTearDown(app.dispose);
        await tester.pumpWidget(host(ConnectionsPage(app: app), scale));
        await tester.pumpAndSettle();
        await tester.tap(find.text('one.fixture.test'));
        await tester.pumpAndSettle();
        final detailStatus = find.byKey(
          const ValueKey('connection-detail-status'),
        );
        final detailScaffolds = find.ancestor(
          of: detailStatus,
          matching: find.byType(Scaffold),
        );
        expect(detailScaffolds, findsNWidgets(2));
        final detail = detailScaffolds.first;
        expect(detail, findsOneWidget);
        final protocol = find.descendant(
          of: detail,
          matching: find.text('TCP'),
        );
        expect(protocol, findsOneWidget);
        final statusInk = find.ancestor(
          of: detailStatus,
          matching: find.byType(InkWell),
        );
        expect(statusInk, findsNothing);
        expect(
          find.ancestor(
            of: detailStatus,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics && widget.properties.button == true,
            ),
          ),
          findsNothing,
        );
        final statusSlot = find
            .ancestor(of: detailStatus, matching: find.byType(SizedBox))
            .first;
        final actions = find.byKey(const ValueKey('connection-detail-actions'));
        final actionBefore = tester.getRect(actions);
        final toolbar = find.descendant(
          of: detail,
          matching: find.byType(AppBar),
        );
        final toolbarBefore = tester.getRect(toolbar);
        final errorAction = find.byKey(
          const ValueKey('connection-detail-error'),
        );
        expect(errorAction, findsNothing);
        final protocolBefore = tester.getRect(protocol);
        final statusBefore = tester.getRect(detailStatus);
        expect(protocolBefore.left, lessThan(statusBefore.left));
        if (scale == 1) {
          expect(protocolBefore.center.dy, closeTo(statusBefore.center.dy, 1));
        } else {
          expect(protocolBefore.bottom, lessThanOrEqualTo(statusBefore.top));
        }
        final labels = ['分流结果', '流量', '时间', '连接信息'];
        final before = labels.map((s) => tester.getRect(find.text(s))).toList();
        final changed = connections.row(
          'one',
          download: 9999999999,
          host: '${'long-host-' * 20}.fixture.test',
        );
        changed['chains'] = List.generate(20, (i) => 'node-$i');
        changed['rulePayload'] = 'long-rule-' * 50;
        changed['futureField'] = {'original': '完整反馈'};
        bridge.data = connections.snapshot([changed]);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(statusInk, findsNothing);
        expect(errorAction, findsNothing);
        expect(tester.getSize(statusSlot).height, greaterThanOrEqualTo(48));
        expect(
          labels.map((s) => tester.getRect(find.text(s))).toList(),
          before,
        );
        expect(find.byTooltip('部分长字段已截短'), findsNothing);
        expect(tester.getRect(protocol), protocolBefore);
        expect(tester.getRect(detailStatus), statusBefore);
        await tester.tap(actions);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('connection-disconnect')));
        await tester.pump();
        app.state = const AppSnapshot(
          phase: 'RUNNING',
          core: connections.core,
          resultId: 'close-1',
          connectionStatus: 'failed',
        );
        app.changed();
        await tester.pumpAndSettle();
        expect(statusInk, findsNothing);
        expect(errorAction, findsNothing);
        expect(tester.getRect(actions), actionBefore);
        expect(tester.getRect(toolbar), toolbarBefore);
        expect(find.byType(AlertDialog), findsNothing);
        final noticeAction = find.descendant(
          of: find.byType(SnackBar),
          matching: find.byType(TextButton),
        );
        expect(noticeAction.hitTestable(), findsOneWidget);
        expect(tester.getSize(noticeAction).height, greaterThanOrEqualTo(48));
        await tester.tap(noticeAction);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        await tester.tap(actions);
        await tester.pumpAndSettle();
        expect(errorAction, findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(
          labels.map((s) => tester.getRect(find.text(s))).toList(),
          before,
        );
        expect(tester.getRect(actions), actionBefore);
        expect(tester.getRect(toolbar), toolbarBefore);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'traffic magnitude units and unknown preserve panel geometry ($scale)',
      (tester) async {
        final bridge = traffic.TrafficBridge();
        final app = traffic.TrafficApp(bridge);
        addTearDown(app.dispose);
        final observation = TrafficController(app)..setVisible(true);
        await tester.pumpWidget(
          host(
            Scaffold(
              body: SingleChildScrollView(
                child: SizedBox(
                  width: 390,
                  child: TrafficPanel(
                    traffic: observation,
                    visible: true,
                    width: 390,
                    onOpen: () {},
                  ),
                ),
              ),
            ),
            scale,
          ),
        );
        await tester.pumpAndSettle();
        final targets = [
          find.byType(TrafficPanel),
          find.text('下载'),
          find.text('上传'),
          find.byType(TrafficChart).first,
        ];
        final rects = targets.map(tester.getRect).toList();
        for (final value in [0, 1023, 1024, 999999999999999, null]) {
          bridge.value = TrafficSnapshot.fromMap({
            'generation': 7,
            'configId': 'one',
            'revision': 1,
            'sessionGeneration': 1,
            'phase': 'RUNNING',
            'fresh': true,
            'failed': false,
            'elapsedMs': 1000,
            'sampledAt': 1000,
            'upload': value,
            'download': value,
            'activeCount': value,
            'points': <Object>[],
          });
          await tester.pump(const Duration(seconds: 1));
          await tester.pump();
          expect(targets.map(tester.getRect).toList(), rects);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        observation.dispose();
      },
    );
  }

  testWidgets(
    'popup retains reading anchor across structural updates and never revives',
    (tester) async {
      final bridge = strategies.StrategyBridgeFake();
      final app = strategies.StrategyAppFake(bridge);
      addTearDown(app.dispose);
      StrategySnapshot data(List<String> names) => StrategySnapshot(
        generation: 7,
        configId: 'one',
        revision: 1,
        purpose: 'PREVIEW',
        composition: strategies.previewCore.composition,
        globalReferenced: false,
        unrestored: {},
        groups: [
          StrategyGroup(
            name: 'Group',
            rawType: 'select',
            hidden: false,
            now: 'member-0',
            fixed: '',
            members: names
                .map((n) => StrategyMember(name: n, type: 'Direct'))
                .toList(),
          ),
        ],
      );
      final names = List.generate(100, (i) => 'member-$i');
      bridge.data = data(names);
      await tester.pumpWidget(host(AppShell(controller: app), 1));
      await tester.pumpAndSettle();
      final rail = find.byType(NavigationRail);
      final destination = rail.evaluate().isEmpty
          ? find.byType(NavigationDestination).at(1)
          : find
                .ancestor(
                  of: find.descendant(of: rail, matching: find.text('策略')),
                  matching: find.byWidgetPredicate(
                    (widget) => widget is InkResponse,
                  ),
                )
                .first;
      await tester.tap(destination);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('strategy-group-Group')));
      await tester.pumpAndSettle();
      final popup = find.byType(StrategyPopup);
      final rect = tester.getRect(popup);
      final list = find.descendant(
        of: popup,
        matching: find.byType(CustomScrollView),
      );
      await tester.drag(list, const Offset(0, -800));
      await tester.pumpAndSettle();
      final top = tester.getTopLeft(list).dy;
      final label = tester
          .widgetList<Text>(
            find.descendant(of: popup, matching: find.byType(Text)),
          )
          .firstWhere(
            (w) =>
                w.data?.startsWith('member-') == true &&
                tester.getTopLeft(find.text(w.data!)).dy >= top,
          )
          .data!;
      final member = find.descendant(of: popup, matching: find.text(label));
      final before = tester.getRect(member);
      for (final next in [
        ['new', ...names],
        names.reversed.toList(),
        names.skip(2).toList(),
      ]) {
        bridge.data = data(next);
        await tester.pump(const Duration(seconds: 5));
        for (final ms in [0, 16, 80, 180]) {
          await tester.pump(Duration(milliseconds: ms));
          expect(tester.getRect(popup), rect);
          expect(tester.getRect(member), before);
          expectListSemantics(tester, list, next.length);
        }
      }
      app.state = const AppSnapshot(
        phase: 'STOPPED',
        core: CoreSnapshot(
          generation: 7,
          phase: 'READY',
          configId: 'other',
          revision: 1,
          purpose: 'PREVIEW',
        ),
      );
      app.changed();
      await tester.pump();
      app.state = const AppSnapshot(
        phase: 'STOPPED',
        core: strategies.previewCore,
      );
      app.changed();
      await tester.pumpAndSettle();
      expect(tester.getRect(popup), rect);
      final tile = find
          .ancestor(of: member, matching: find.byType(InkWell))
          .first;
      expect(tester.widget<InkWell>(tile).onTap, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
