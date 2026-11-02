import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/ui/navigation/app_shell.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/model/strategy_snapshot.dart';
import 'package:clash_pseudo/src/ui/strategies/strategy_controller.dart';
import 'package:clash_pseudo/src/ui/strategies/strategy_popup.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/strategy_fakes.dart';
import '../overrides/definitions/local_definitions_support.dart';

class _DelayStrategyBridge extends StrategyBridgeFake {
  Map<String, dynamic> _identity(CoreSnapshot core) => {
    'processId': core.processId,
    'inputId': core.inputId,
    'networkRevision': core.networkRevision,
    'generation': core.generation,
    'configId': core.configId,
    'revision': core.revision,
    'purpose': core.purpose,
    'composition': core.composition,
  };

  @override
  Future<Map<String, dynamic>> startDelayTest(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) async {
    expectSync(query['id'], matches(RegExp(r'^[0-9a-f]{32}$')));
    final reply = await super.startDelayTest(core, query);
    delayBatch!['id'] = query['id'];
    return {...reply, ..._identity(core)};
  }

  @override
  Future<Map<String, dynamic>> delayTest(
    CoreSnapshot core,
    String batch,
  ) async {
    expectSync(batch, delayBatch!['id']);
    return {...await super.delayTest(core, batch), ..._identity(core)};
  }
}

class _DialogPushObserver extends NavigatorObserver {
  _DialogPushObserver(this.onDialogPush);
  final VoidCallback onDialogPush;
  int pushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is DialogRoute) {
      pushes++;
      onDialogPush();
    }
  }
}

class _EpochPopupApp extends StrategyAppFake {
  _EpochPopupApp(super.bridge) {
    state = const AppSnapshot(
      phase: 'STOPPED',
      core: previewCore,
      storageEpoch: 1,
    );
  }
  int epoch = 1;
  @override
  int get storageEpoch => epoch;
}

void main() {
  late StrategyBridgeFake bridge;
  late StrategyAppFake app;
  late AppTaskNavigatorObserver taskRoutes;
  setUp(() {
    taskRoutes = AppTaskNavigatorObserver();
    bridge = _DelayStrategyBridge();
    app = StrategyAppFake(bridge);
  });
  tearDown(() => app.dispose());

  Future<void> show(
    WidgetTester tester, {
    bool dark = false,
    double scale = 1,
    bool animations = false,
    Locale locale = const Locale('zh'),
    BrandColor brand = BrandColor.cinnabar,
    double? width,
    NavigatorObserver? observer,
  }) async {
    if (width != null) {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    setMessageLanguage(
      locale.languageCode == 'zh' ? AppLanguage.zh : AppLanguage.en,
    );
    addTearDown(() => setMessageLanguage(AppLanguage.system));
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [taskRoutes, ?observer],
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        theme: AppTheme.forBrightness(
          dark ? Brightness.dark : Brightness.light,
          brand,
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: !animations,
          ),
          child: child!,
        ),
        home: AppShell(controller: app),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder destination(WidgetTester tester, int index) {
    final bar = find.byType(NavigationBar);
    if (bar.evaluate().isNotEmpty) {
      return find
          .byType(NavigationDestination)
          .at(
            index == 2
                ? tester.widget<NavigationBar>(bar).destinations.length - 1
                : index,
          );
    }
    final rail = find.byType(NavigationRail);
    final label =
        tester
                .widget<NavigationRail>(rail)
                .destinations[index == 2
                    ? tester.widget<NavigationRail>(rail).destinations.length -
                          1
                    : index]
                .label
            as Text;
    return find
        .ancestor(
          of: find.descendant(of: rail, matching: find.text(label.data!)),
          matching: find.byWidgetPredicate((widget) => widget is InkResponse),
        )
        .first;
  }

  Future<void> strategies(WidgetTester tester) async {
    await tester.tap(destination(tester, 1));
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, String name) async {
    final group = find.byKey(ValueKey('strategy-group-$name'));
    await tester.scrollUntilVisible(
      group,
      180,
      scrollable: find.descendant(
        of: find.byKey(const PageStorageKey('strategies-scroll')),
        matching: find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(group);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'popup member failures retain complete selectable and copyable originals',
    (tester) async {
      final original =
          'https://fixture.test/?token=原文🙂\n'
              'Caused by: socket failure\nSuppressed: cleanup failure\n' *
          8;
      String? copied;
      var copies = 0;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = call.arguments['text'] as String;
          copies++;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await show(tester, scale: 2, width: 320, locale: const Locale('en'));
      await strategies(tester);
      await open(tester, '出口');
      final surface = tester.getRect(
        find.byKey(const ValueKey('strategy-member-surface-0')),
      );
      for (final slot in [
        'strategy-member-marks-0',
        'strategy-delay-result-0',
      ]) {
        final rect = tester.getRect(find.byKey(ValueKey(slot)));
        expect(rect.width, greaterThan(0));
        expect(rect.left, greaterThanOrEqualTo(surface.left));
        expect(rect.right, lessThanOrEqualTo(surface.right));
      }
      expect(
        tester
            .getSize(find.byKey(const ValueKey('strategy-member-name-0')))
            .width,
        greaterThan(0),
      );
      await tester.tap(find.byKey(const ValueKey('strategy-delay-0')));
      await tester.pump();
      expect(bridge.delayStarts.single['members'], ['A']);
      bridge.delayBatch!['state'] = 'done';
      bridge.delayBatch!['members'] = [
        {'name': 'A', 'type': 'Socks5', 'status': 'failed', 'error': original},
      ];
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      final result = find.byKey(const ValueKey('strategy-delay-result-0'));
      final strings = AppLocalizations.of(tester.element(result));
      expect(
        find.descendant(of: result, matching: find.text(strings.delayFailed)),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Tooltip>(
              find.descendant(of: result, matching: find.byType(Tooltip)),
            )
            .message,
        isNot(contains(original)),
      );
      final heading = find
          .ancestor(
            of: find.byKey(const ValueKey('strategy-popup-title')),
            matching: find.byType(InkWell),
          )
          .first;
      await tester.ensureVisible(heading);
      await tester.tap(heading);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.byKey(const ValueKey('operation-technical-text')),
        findsNothing,
      );
      expect(find.textContaining(original, findRichText: true), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('operation-technical-details')),
      );
      await tester.pumpAndSettle();
      final text = find.byKey(const ValueKey('operation-technical-text'));
      expect(tester.widget<SelectableText>(text).data, 'A\n$original');
      final copy = find.byKey(const ValueKey('operation-technical-copy'));
      await tester.ensureVisible(copy);
      final cachedCopy = tester.widget<TextButton>(copy).onPressed!;
      await tester.tap(copy);
      await tester.pump();
      expect(copied, 'A\n$original');
      expect(copies, 1);
      Navigator.of(tester.element(text)).pop();
      cachedCopy();
      await tester.pumpAndSettle();
      expect(copies, 1);
      expect(find.byType(StrategyPopup), findsOneWidget);
      expect(app.commands, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final reduced in [false, true]) {
    testWidgets(
      'keyboard popup traversal, Enter and Escape restore captured focus reduced=$reduced',
      (tester) async {
        await show(tester, animations: !reduced);
        await strategies(tester);
        final card = find.byKey(const ValueKey('strategy-group-出口'));
        bool ownsFocus(Finder target) {
          final owner = tester.element(target);
          final focused = FocusManager.instance.primaryFocus?.context;
          if (focused is! Element) return false;
          var inside = identical(focused, owner);
          focused.visitAncestorElements((ancestor) {
            inside = inside || identical(ancestor, owner);
            return !inside;
          });
          return inside;
        }

        Future<void> tabTo(Finder target) async {
          for (var count = 0; count < 60 && !ownsFocus(target); count++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pump();
          }
          expect(ownsFocus(target), isTrue, reason: debugDescribeFocusTree());
        }

        await tabTo(card);
        final sourceFocus = FocusManager.instance.primaryFocus;
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        final popup = find.byType(StrategyPopup);
        expect(popup, findsOneWidget);
        final strings = AppLocalizations.of(tester.element(popup));
        final close = find.ancestor(
          of: find.byTooltip(strings.closeStrategyPopup),
          matching: find.byType(IconButton),
        );
        await tabTo(close);
        final closeFocus = FocusManager.instance.primaryFocus;
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(ownsFocus(popup), isTrue);
        expect(FocusManager.instance.primaryFocus, isNot(same(closeFocus)));
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(FocusManager.instance.primaryFocus, same(closeFocus));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(popup, findsNothing);
        expect(FocusManager.instance.primaryFocus, same(sourceFocus));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(popup, findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(popup, findsNothing);
        expect(FocusManager.instance.primaryFocus, same(sourceFocus));
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(popup, findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(popup, findsNothing);
        expect(FocusManager.instance.primaryFocus, same(sourceFocus));
        expect(app.commands, isEmpty);
        expect(bridge.delayStarts, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final reason in [
    'group-missing',
    'type-changed',
    'not-selectable',
    'member-missing',
    'unknown-code',
  ]) {
    testWidgets(
      'unrestored reason $reason resolves in summary and retained popup',
      (tester) async {
        final original = strategyData();
        bridge.data = StrategySnapshot(
          generation: original.generation,
          configId: original.configId,
          revision: original.revision,
          purpose: original.purpose,
          composition: original.composition,
          globalReferenced: original.globalReferenced,
          unrestored: {'出口': reason},
          groups: original.groups,
        );
        final locale = ValueNotifier(const Locale('en'));
        addTearDown(locale.dispose);
        await tester.pumpWidget(
          ValueListenableBuilder<Locale>(
            valueListenable: locale,
            builder: (_, value, _) => MaterialApp(
              navigatorObservers: [taskRoutes],
              locale: value,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: child!,
              ),
              home: AppShell(controller: app),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await strategies(tester);
        String label(AppLocalizations strings) => switch (reason) {
          'group-missing' => strings.strategyGroupMissing,
          'type-changed' => strings.strategyTypeChanged,
          'not-selectable' => strings.strategyNotSelectable,
          'member-missing' => strings.strategyMemberMissing,
          _ => strings.resultUnconfirmed,
        };
        final en = lookupAppLocalizations(const Locale('en'));
        await openNoticeDetails(tester);
        await tester.tap(
          find.byKey(const ValueKey('operation-technical-details')),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining(en.unrestoredLine('出口', label(en))),
          findsOneWidget,
        );
        final summary = tester.element(find.byType(AlertDialog));
        locale.value = const Locale('zh');
        await tester.pumpAndSettle();
        final zh = lookupAppLocalizations(const Locale('zh'));
        expect(tester.element(find.byType(AlertDialog)), same(summary));
        expect(
          find.textContaining(zh.unrestoredLine('出口', label(zh))),
          findsOneWidget,
        );
        await tester.tap(find.text(zh.close));
        await tester.pumpAndSettle();
        await open(tester, '出口');
        final popup = tester.state(find.byType(StrategyPopup));
        await tester.tap(find.text(zh.popupNotRestoredShort));
        await tester.pumpAndSettle();
        final detail = tester.element(find.byType(AlertDialog));
        for (final strings in [zh, en, zh]) {
          locale.value = Locale(strings.localeName);
          await tester.pumpAndSettle();
          expect(tester.state(find.byType(StrategyPopup)), same(popup));
          expect(tester.element(find.byType(AlertDialog)), same(detail));
          expect(
            find.text(strings.popupNotRestored(label(strings))),
            findsOneWidget,
          );
          expect(find.textContaining(reason), findsNothing);
          expect(bridge.data.unrestored['出口'], reason);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final dark in [false, true]) {
    for (final width in [320.0, 800.0]) {
      for (final brand in BrandColor.values) {
        testWidgets(
          'navigation destinations rotate all brand roles dark=$dark brand=$brand width=$width',
          (tester) async {
            await show(tester, dark: dark, brand: brand, width: width);
            final scheme = AppTheme.forBrightness(
              dark ? Brightness.dark : Brightness.light,
              brand,
            ).colorScheme;
            final colors = [scheme.primary, scheme.secondary, scheme.tertiary];
            expect(colors.toSet(), hasLength(3));
            final anchors = [
              for (var i = 0; i < 3; i++)
                tester.getRect(destination(tester, i)),
            ];
            for (final selected in [0, 1, 2, 0]) {
              await tester.tap(destination(tester, selected));
              for (final elapsed in [
                Duration.zero,
                const Duration(milliseconds: 16),
                const Duration(milliseconds: 250),
              ]) {
                await tester.pump(elapsed);
                final icons = find.byType(NavigationBar).evaluate().isNotEmpty
                    ? tester
                          .widget<NavigationBar>(find.byType(NavigationBar))
                          .destinations
                          .cast<NavigationDestination>()
                          .map((item) => (item.icon, item.selectedIcon))
                          .toList()
                    : tester
                          .widget<NavigationRail>(find.byType(NavigationRail))
                          .destinations
                          .map((item) => (item.icon, item.selectedIcon))
                          .toList();
                expect(icons.length, inInclusiveRange(3, 5));
                final roles = [
                  colors[0],
                  colors[1],
                  if (icons.length >= 4) colors[1],
                  if (icons.length >= 5) colors[2],
                  colors[2],
                ];
                for (var i = 0; i < icons.length; i++) {
                  expect((icons[i].$1 as Icon).color, roles[i]);
                  expect((icons[i].$2 as Icon).color, roles[i]);
                }
                for (var i = 0; i < anchors.length; i++) {
                  expect(tester.getRect(destination(tester, i)), anchors[i]);
                }
              }
              await tester.pumpAndSettle();
            }
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
      testWidgets(
        'navigation uses neutral tonal layers on both pages dark=$dark width=$width',
        (tester) async {
          await show(tester, dark: dark, width: width);
          final palette = HomePalette(dark);
          void check() {
            if (width >= 600) {
              final context = tester.element(find.byType(NavigationRail));
              final theme = NavigationRailTheme.of(context);
              expect(theme.backgroundColor, palette.surface);
              expect(theme.backgroundColor, isNot(palette.background));
              expect(theme.indicatorColor, palette.soft);
              expect(theme.elevation, 0);
              final scaffold = tester.widget<Scaffold>(
                find.byType(Scaffold).first,
              );
              expect(scaffold.bottomNavigationBar, isNull);
              expect(find.byType(NavigationBar), findsNothing);
              expect(
                tester.getSize(find.byKey(const ValueKey('app-pages'))).height,
                tester.getSize(find.byType(Scaffold).first).height,
              );
            } else {
              final context = tester.element(find.byType(NavigationBar));
              final theme = NavigationBarTheme.of(context);
              expect(theme.backgroundColor, palette.surface);
              expect(theme.backgroundColor, isNot(palette.background));
              expect(theme.indicatorColor, palette.soft);
              expect(theme.elevation, 0);
              expect(theme.surfaceTintColor, Colors.transparent);
              final bottom = tester
                  .widget<Scaffold>(find.byType(Scaffold).first)
                  .bottomNavigationBar!;
              expect(
                tester.getSize(find.byWidget(bottom)).height,
                greaterThan(0),
              );
              expect(
                find.descendant(
                  of: find.byWidget(bottom),
                  matching: find.byType(SingleChildScrollView),
                ),
                findsOneWidget,
              );
              expect(
                find.descendant(
                  of: find.byWidget(bottom),
                  matching: find.byType(NavigationBar),
                ),
                findsOneWidget,
              );
            }
          }

          check();
          await strategies(tester);
          check();
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('unloaded strategy explains state without inventing failure', (
    tester,
  ) async {
    app.state = const AppSnapshot(phase: 'STOPPED');
    await show(tester);
    await tester.tap(destination(tester, 1));
    await tester.pump();
    expect(find.text('重试加载策略'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('策略尚未加载。'), findsNothing);
    expect(find.text('加载策略'), findsNothing);
    expect(find.byTooltip('刷新'), findsOneWidget);
    expect(app.commands.single['action'], 'prepareStrategies');
    await dismissNotice(tester);
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(app.commands.length, 2);
    final load = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '刷新',
    );
    final beforeBusy = tester.getRect(load);
    app.dispatching = true;
    app.changed();
    await tester.pump();
    expect(tester.getRect(load), beforeBusy);
    expect(tester.widget<IconButton>(load).onPressed, isNull);
    expect(find.text('重试加载策略'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('正在加载策略…'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'known failure displays reason and explicit retry without looping',
    (tester) async {
      app.state = const AppSnapshot(
        phase: 'STOPPED',
        core: CoreSnapshot(
          phase: 'EMPTY',
          configId: 'one',
          revision: 1,
          error: AppMessage('androidErrorStrategyPrepare'),
        ),
      );
      app.commandErrorMessage = null;
      await show(tester);
      await strategies(tester);
      await openNoticeDetails(tester);
      await tester.pumpAndSettle();
      expect(
        find.text(messages.androidErrorStrategyPrepare.text),
        findsOneWidget,
      );
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('策略尚未加载。'), findsNothing);
      expect(find.text('加载策略'), findsNothing);
      expect(find.byTooltip('刷新'), findsOneWidget);
      expect(app.commands, isEmpty);
      await tester.pump(const Duration(seconds: 30));
      expect(app.commands, isEmpty);
      await dismissNotice(tester);
      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();
      expect(app.commands.single['action'], 'prepareStrategies');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('first query failure retains automatic retry explanation', (
    tester,
  ) async {
    bridge.failRead = true;
    await show(tester);
    await strategies(tester);
    await openNoticeDetails(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('应用在前台时会自动重试'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    bridge.failRead = false;
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('策略尚未加载。'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.textContaining('应用在前台时会自动重试'), findsNothing);
    expect(find.byKey(const ValueKey('strategy-group-出口')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'capacity navigation keeps lazy strategy reading and the configuration task',
    (tester) async {
      await show(tester);
      expect(
        tester.widget<NavigationRail>(find.byType(NavigationRail)).destinations,
        hasLength(5),
      );
      expect(bridge.reads, 0);
      expect(app.commands, isEmpty);
      await strategies(tester);
      expect(bridge.reads, 1);
      expect(find.byKey(const ValueKey('strategy-group-隐藏')), findsNothing);
      expect(find.byKey(const ValueKey('strategy-group-GLOBAL')), findsNothing);
      expect(find.byTooltip('管理配置'), findsNothing);
      expect(find.byIcon(Icons.folder_open_outlined), findsNothing);
      await tester.tap(destination(tester, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('配置管理').last);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      expect(bridge.reads, 1);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(bridge.reads, 1);
      await strategies(tester);
      expect(bridge.reads, 2);
      await tester.tap(destination(tester, 0));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10));
      expect(bridge.reads, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'open strategy popup expires on epoch replacement even when all core identity fields match',
    (tester) async {
      app.dispose();
      final epochApp = _EpochPopupApp(bridge);
      app = epochApp;
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await show(tester, scale: 2);
      await strategies(tester);
      await open(tester, '出口');
      final popup = find.byKey(const ValueKey('strategy-popup-出口'));
      final member = find.byKey(const ValueKey('strategy-member-1'));
      final popupRect = tester.getRect(popup);
      final memberRect = tester.getRect(member);
      final oldTap = tester.widget<InkWell>(member).onTap!;
      expect(
        tester.widget<StrategyPopup>(find.byType(StrategyPopup)).storageEpoch,
        1,
      );
      epochApp.epoch = 2;
      app.state = const AppSnapshot(
        phase: 'STOPPED',
        core: previewCore,
        storageEpoch: 2,
      );
      app.collection = ConfigCollection(
        entries: [
          ConfigEntry(
            id: strategyEntry.id,
            name: strategyEntry.name,
            source: strategyEntry.source,
            revision: strategyEntry.revision,
            body: 'restored same id and revision',
          ),
        ],
        selectedId: strategyEntry.id,
      );
      app.changed();
      oldTap(); // A callback already queued before the replacement frame is stale too.
      for (final elapsed in [
        Duration.zero,
        const Duration(milliseconds: 16),
        const Duration(milliseconds: 80),
      ]) {
        await tester.pump(elapsed);
        expect(tester.getRect(popup), popupRect);
        expect(tester.getRect(member), memberRect);
        expect(tester.widget<InkWell>(member).onTap, isNull);
      }
      expect(find.text('已失效 · 请重新打开'), findsOneWidget);
      expect(app.commands, isEmpty);
      expect(bridge.data.find('出口')!.now, 'A');
      await tester.tap(find.byTooltip('关闭策略浮窗'));
      await tester.pumpAndSettle();
      await open(tester, '出口');
      expect(
        tester.widget<StrategyPopup>(find.byType(StrategyPopup)).storageEpoch,
        2,
      );
      await tester.ensureVisible(member);
      await tester.tap(member);
      await tester.pump();
      expect(app.commands.single, {
        'action': 'setStrategy',
        'storageEpoch': 2,
        'id': 'one',
        'revision': 1,
        'generation': 7,
        'composition': '["one",1]',
        'name': '出口',
        'choice': {'type': 'select', 'member': 'B'},
      });
      expect(bridge.data.find('出口')!.now, 'A');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'choice waits for actual result and keeps the member panel open',
    (tester) async {
      await show(tester);
      await strategies(tester);
      await open(tester, '出口');
      final memberA = find.byKey(const ValueKey('strategy-member-0'));
      final memberB = find.byKey(const ValueKey('strategy-member-1'));
      await tester.ensureVisible(memberB);
      final card = find.byKey(const ValueKey('strategy-card-出口'));
      final sourceBefore = tester.getRect(card);
      final popup = find.byKey(const ValueKey('strategy-popup-出口'));
      final popupBefore = tester.getTopLeft(popup);
      await tester.tap(memberB);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('正在切换…'), findsOneWidget);
      expect(tester.getRect(card), sourceBefore);
      expect(tester.getTopLeft(popup), popupBefore);
      expect(
        find.descendant(
          of: memberA,
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: memberB,
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsNothing,
      );
      bridge.data = strategyData(now: 'B');
      app.state = const AppSnapshot(
        phase: 'STOPPED',
        core: previewCore,
        resultId: 'done',
        resultSuccess: true,
      );
      app.changed();
      await tester.pumpAndSettle();
      expect(find.byType(StrategyPopup), findsOneWidget);
      expect(
        find.descendant(
          of: memberB,
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      expect(app.commands.single['action'], 'setStrategy');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'load balance is readable without a fictitious single selection',
    (tester) async {
      await show(tester);
      await strategies(tester);
      await open(tester, '均衡');
      expect(find.text('负载均衡 · 2'), findsOneWidget);
      expect(find.byKey(const ValueKey('strategy-automatic')), findsNothing);
      expect(find.byIcon(Icons.check_rounded), findsNothing);
      expect(
        tester
            .widget<InkWell>(find.byKey(const ValueKey('strategy-member-0')))
            .onTap,
        isNull,
      );
      expect(app.commands, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'closing a waiting panel does not cancel or resubmit the choice',
    (tester) async {
      await show(tester);
      await strategies(tester);
      await open(tester, '出口');
      await tester.tap(find.byKey(const ValueKey('strategy-member-1')));
      await tester.pump();
      expect(find.text('正在切换…'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭策略浮窗'));
      await tester.pumpAndSettle();
      expect(find.byType(StrategyPopup), findsNothing);
      expect(app.commands, hasLength(1));
      bridge.data = strategyData(now: 'B');
      app.state = const AppSnapshot(
        phase: 'STOPPED',
        core: previewCore,
        resultId: 'late',
        resultSuccess: true,
      );
      app.changed();
      await tester.pumpAndSettle();
      expect(app.commands, hasLength(1));
      await open(tester, '出口');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('strategy-member-1')),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('popup follows its card instead of the bottom edge', (
    tester,
  ) async {
    await show(tester);
    await strategies(tester);
    final card = tester.getRect(
      find.byKey(const ValueKey('strategy-group-出口')),
    );
    await open(tester, '出口');
    final popup = tester.getRect(
      find.byKey(const ValueKey('strategy-popup-出口')),
    );
    expect(popup.left, card.left);
    expect(popup.top, card.top);
    expect(popup.bottom, lessThan(588));
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.textContaining('不会自动启动'), findsNothing);
    expect(find.textContaining('已有连接保持'), findsNothing);
    final reads = bridge.reads;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(bridge.reads, greaterThan(reads));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('popup flips above a low card and stays inside resized screen', (
    tester,
  ) async {
    await show(tester);
    await strategies(tester);
    await open(tester, '均衡');
    final card = tester.getRect(
      find.byKey(const ValueKey('strategy-group-均衡')),
    );
    final popup = find.byKey(const ValueKey('strategy-popup-均衡'));
    expect(tester.getRect(popup).overlaps(card), isTrue);
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpAndSettle();
    final bounds = tester.getRect(popup);
    expect(bounds.left, greaterThanOrEqualTo(12));
    expect(bounds.right, lessThanOrEqualTo(308));
    expect(bounds.top, greaterThanOrEqualTo(12));
    expect(bounds.bottom, lessThanOrEqualTo(588));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final width in [320.0, 1000.0]) {
    testWidgets(
      'member groups can be selected but never opened recursively width=$width',
      (tester) async {
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        bridge.data = StrategySnapshot(
          generation: 7,
          configId: 'one',
          revision: 1,
          purpose: 'PREVIEW',
          composition: '["one",1]',
          globalReferenced: false,
          unrestored: {},
          groups: [
            StrategyGroup(
              name: '父组',
              rawType: 'select',
              hidden: false,
              now: '自动',
              fixed: '',
              members: const [
                StrategyMember(name: '出口', type: 'Socks5'),
                StrategyMember(name: '自动', type: 'url-test'),
              ],
            ),
            ...strategyData().groups,
          ],
        );
        await show(tester);
        await strategies(tester);
        await open(tester, '父组');
        expect(find.byTooltip('展开出口'), findsNothing);
        expect(find.byTooltip('展开自动'), findsNothing);
        expect(find.byIcon(Icons.chevron_right), findsNothing);
        final popup = find.byKey(const ValueKey('strategy-popup-父组'));
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('strategy-member-0')),
            matching: find.text('Socks5'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('strategy-member-1')),
            matching: find.text('A'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('strategy-member-1')));
        await tester.pump();
        expect(app.commands.single['name'], '父组');
        expect(app.commands.single['choice'], {
          'type': 'select',
          'member': '自动',
        });
        expect(popup, findsOneWidget);
        expect(find.byType(StrategyPopup), findsOneWidget);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        expect(find.byType(StrategyPopup), findsNothing);
        expect(app.commands, hasLength(1));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('popup default caller retains its source task and can close', (
    tester,
  ) async {
    final controller = StrategyController(app)..setVisible(true);
    addTearDown(controller.dispose);
    late BuildContext source;
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [taskRoutes],
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => AppTaskActivity(
          active: true,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              source = context;
              return const SizedBox(
                width: 120,
                height: 80,
                child: Text('source anchor'),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final popup = showStrategyPopup(
      context: source,
      controller: controller,
      name: '出口',
    );
    await tester.pumpAndSettle();
    expect(find.byType(StrategyPopup), findsOneWidget);
    expect(app.commands, isEmpty);
    await tester.tap(find.byTooltip('关闭策略浮窗'));
    await tester.pumpAndSettle();
    await popup;
    expect(find.byType(StrategyPopup), findsNothing);
    expect(app.commands, isEmpty);
    expect(tester.takeException(), isNull);
    controller.setVisible(false);
    await tester.pumpWidget(const SizedBox());
  });

  for (final mismatch in ['route', 'task']) {
    testWidgets('popup cannot borrow an owner from another $mismatch', (
      tester,
    ) async {
      final controller = StrategyController(app)..setVisible(true);
      addTearDown(controller.dispose);
      late BuildContext source;
      late BuildContext owner;
      Widget anchor(bool isSource) => Builder(
        builder: (context) {
          if (isSource) {
            source = context;
          } else {
            owner = context;
          }
          return SizedBox(
            width: 120,
            height: 80,
            child: Text(isSource ? 'source anchor' : 'foreign owner'),
          );
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [taskRoutes],
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => AppTaskActivity(
            active: true,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
          ),
          home: Scaffold(
            body: mismatch == 'route'
                ? anchor(true)
                : Row(
                    children: [
                      AppTaskActivity(active: false, child: anchor(true)),
                      AppTaskActivity(active: true, child: anchor(false)),
                    ],
                  ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (mismatch == 'route') {
        Navigator.of(source).push<void>(
          MaterialPageRoute(builder: (_) => Scaffold(body: anchor(false))),
        );
        await tester.pumpAndSettle();
        expect(ModalRoute.of(source), isNot(same(ModalRoute.of(owner))));
        expect(
          source.getElementForInheritedWidgetOfExactType<AppTaskActivity>(),
          same(
            owner.getElementForInheritedWidgetOfExactType<AppTaskActivity>(),
          ),
        );
      } else {
        expect(ModalRoute.of(source), same(ModalRoute.of(owner)));
        expect(
          source.getElementForInheritedWidgetOfExactType<AppTaskActivity>(),
          isNot(
            same(
              owner.getElementForInheritedWidgetOfExactType<AppTaskActivity>(),
            ),
          ),
        );
      }
      expect(controller.active, isTrue);
      expect(AppTaskActivity.isActive(owner), isTrue);
      if (mismatch == 'task') {
        expect(AppTaskActivity.isActive(source), isFalse);
      }
      final routes = taskRoutes.stack.length;
      final popup = showStrategyPopup(
        context: source,
        ownerContext: owner,
        controller: controller,
        name: '出口',
      );
      await tester.pumpAndSettle();
      expect(find.byType(StrategyPopup), findsNothing);
      expect(taskRoutes.stack, hasLength(routes));
      expect(ModalRoute.of(owner)?.isCurrent, isTrue);
      expect(app.commands, isEmpty);
      expect(tester.takeException(), isNull);
      await popup;
      controller.setVisible(false);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('hidden toggle persists across tabs and expires an old popup', (
    tester,
  ) async {
    await show(tester);
    await strategies(tester);
    expect(find.byKey(const ValueKey('strategy-group-隐藏')), findsNothing);
    await tester.tap(find.byTooltip('显示隐藏策略组'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('strategy-group-GLOBAL')), findsNothing);
    await tester.tap(destination(tester, 0));
    await tester.pumpAndSettle();
    await strategies(tester);
    expect(find.byTooltip('不显示隐藏策略组'), findsOneWidget);
    await open(tester, '隐藏');
    final popup = tester.widget<StrategyPopup>(find.byType(StrategyPopup));
    popup.controller.setShowHidden(false);
    await tester.pumpAndSettle();
    expect(find.text('已失效 · 请重新打开'), findsOneWidget);
    popup.controller.setShowHidden(true);
    await tester.pumpAndSettle();
    expect(find.text('已失效 · 请重新打开'), findsOneWidget);
    final member = find.byKey(const ValueKey('strategy-member-0'));
    expect(tester.widget<InkWell>(member).onTap, isNull);
    expect(app.commands, isEmpty);
    await tester.tap(find.byTooltip('关闭策略浮窗'));
    await tester.pumpAndSettle();
    await open(tester, '隐藏');
    expect(tester.widget<InkWell>(member).onTap, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('old popup cannot select a same-named replacement group', (
    tester,
  ) async {
    await show(tester);
    await strategies(tester);
    await open(tester, '出口');
    const replacement = CoreSnapshot(
      generation: 8,
      phase: 'READY',
      purpose: 'PREVIEW',
      composition: '["one",1]',
      configId: 'one',
      revision: 1,
    );
    bridge.data = strategyData(core: replacement);
    app.state = const AppSnapshot(phase: 'STOPPED', core: replacement);
    app.changed();
    await tester.pumpAndSettle();
    expect(find.text('已失效 · 请重新打开'), findsOneWidget);
    expect(find.byKey(const ValueKey('strategy-member-0')), findsOneWidget);
    expect(
      tester
          .widget<InkWell>(find.byKey(const ValueKey('strategy-member-0')))
          .onTap,
      isNull,
    );
    expect(app.commands, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('opening and closing morph the source without moving the grid', (
    tester,
  ) async {
    await show(tester, animations: true);
    await strategies(tester);
    final card = find.byKey(const ValueKey('strategy-group-出口'));
    final original = tester.getRect(card);
    final sourceOpacity = find
        .ancestor(of: card, matching: find.byType(Opacity))
        .first;
    await tester.tap(card);
    await tester.pump();
    expect(tester.widget<Opacity>(sourceOpacity).opacity, 0);
    final reveal = find.byKey(const ValueKey('strategy-reveal-出口'));
    double paintedWidth() => tester
        .widget<ClipRRect>(reveal)
        .clipper!
        .getClip(tester.getSize(reveal))
        .width;
    expect(paintedWidth(), closeTo(original.width, .01));
    await tester.pump(const Duration(milliseconds: 70));
    expect(paintedWidth(), greaterThan(original.width));
    expect(paintedWidth(), lessThan(420));
    await tester.pumpAndSettle();
    expect(paintedWidth(), 420);
    expect(tester.getRect(card), original);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    expect(tester.widget<Opacity>(sourceOpacity).opacity, 0);
    expect(paintedWidth(), lessThan(420));
    await tester.pumpAndSettle();
    expect(find.byType(StrategyPopup), findsNothing);
    expect(tester.widget<Opacity>(sourceOpacity).opacity, 1);
    expect(tester.getRect(card), original);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final invalidateSource in [false, true]) {
    testWidgets(
      'retired popup surface fades without collapsing into its old card source=$invalidateSource',
      (tester) async {
        await show(tester, animations: true);
        await strategies(tester);
        await open(tester, '出口');
        if (invalidateSource) {
          app.setForeground(false);
        } else {
          tester.view.physicalSize = const Size(700, 900);
          addTearDown(tester.view.resetPhysicalSize);
        }
        await tester.pump();
        final surface = find.byKey(
          const ValueKey('strategy-fallback-opacity-出口'),
        );
        expect(tester.widget<Opacity>(surface).opacity, 1);
        await tester.binding.handlePopRoute();
        await tester.pump();
        final member = find.byKey(const ValueKey('strategy-member-0'));
        expect(tester.widget<InkWell>(member).onTap, isNull);
        await tester.pump(const Duration(milliseconds: 70));
        expect(tester.widget<Opacity>(surface).opacity, greaterThan(0));
        expect(tester.widget<Opacity>(surface).opacity, lessThan(1));
        final reveal = find.byKey(const ValueKey('strategy-reveal-出口'));
        final clip = tester.widget<ClipRRect>(reveal);
        expect(
          clip.clipper!.getClip(tester.getSize(reveal)).width,
          tester.getSize(reveal).width,
        );
        await tester.pumpAndSettle();
        expect(find.byType(StrategyPopup), findsNothing);
        expect(app.commands, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'own feedback push preserves the delay before its first dialog build',
    (tester) async {
      final observer = _DialogPushObserver(() {
        expect(find.byType(AlertDialog), findsNothing);
        app.changed(); // Real controller notification after push, before builder.
      });
      await show(tester, observer: observer);
      await strategies(tester);
      await open(tester, '出口');
      await tester.tap(find.byKey(const ValueKey('strategy-delay-0')));
      await tester.pump();
      expect(bridge.delayStarts, hasLength(1));
      final heading = find
          .ancestor(
            of: find.byKey(const ValueKey('strategy-popup-title')),
            matching: find.byType(InkWell),
          )
          .first;
      await tester.tap(heading);
      await tester.pumpAndSettle();
      expect(observer.pushes, 1);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(bridge.delayCancels, isEmpty);
      bridge.finishDelay({'A': ('success', 0)});
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(bridge.delayCancels, isEmpty);
      await tester.tap(find.widgetWithText(TextButton, '关闭').hitTestable());
      await tester.pumpAndSettle();
      expect(find.byType(StrategyPopup), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(StrategyPopup),
          matching: find.text('0 ms'),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<InkWell>(find.byKey(const ValueKey('strategy-member-1')))
            .onTap,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'cached popup member and probe callbacks lose authority before reverse paints',
    (tester) async {
      await show(tester, animations: true);
      await strategies(tester);
      await open(tester, '出口');
      final member = tester
          .widget<InkWell>(find.byKey(const ValueKey('strategy-member-1')))
          .onTap!;
      final probe = tester
          .widget<IconButton>(find.byKey(const ValueKey('strategy-delay-0')))
          .onPressed!;
      Navigator.of(tester.element(find.byType(StrategyPopup))).pop();
      member();
      probe();
      expect(app.commands, isEmpty);
      expect(bridge.delayStarts, isEmpty);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      expect(find.byType(StrategyPopup), findsOneWidget);
      expect(
        tester
            .widget<InkWell>(find.byKey(const ValueKey('strategy-member-1')))
            .onTap,
        isNull,
      );
      await tester.pumpAndSettle();
      expect(find.byType(StrategyPopup), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('interrupted opening restores source and permits reopening', (
    tester,
  ) async {
    await show(tester, animations: true);
    await strategies(tester);
    final card = find.byKey(const ValueKey('strategy-group-出口'));
    await tester.tap(card);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Opacity>(
            find.ancestor(of: card, matching: find.byType(Opacity)).first,
          )
          .opacity,
      1,
    );
    await open(tester, '出口');
    expect(find.byType(StrategyPopup), findsOneWidget);
    expect(app.commands, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'background and context replacement during morph leave no hidden source',
    (tester) async {
      await show(tester, animations: true);
      await strategies(tester);
      final card = find.byKey(const ValueKey('strategy-group-出口'));
      await tester.tap(card);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      app.setForeground(false);
      const replacement = CoreSnapshot(
        generation: 8,
        phase: 'READY',
        purpose: 'PREVIEW',
        composition: '["one",1]',
        configId: 'one',
        revision: 1,
      );
      bridge.data = strategyData(core: replacement);
      app.state = const AppSnapshot(phase: 'STOPPED', core: replacement);
      app.changed();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('strategy-member-0')), findsOneWidget);
      expect(
        tester
            .widget<InkWell>(find.byKey(const ValueKey('strategy-member-0')))
            .onTap,
        isNull,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      app.setForeground(true);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Opacity>(
              find.ancestor(of: card, matching: find.byType(Opacity)).first,
            )
            .opacity,
        1,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'empty group and large member lists retain usable close and scroll',
    (tester) async {
      bridge.data = StrategySnapshot(
        generation: 7,
        configId: 'one',
        revision: 1,
        purpose: 'PREVIEW',
        composition: '["one",1]',
        globalReferenced: false,
        unrestored: {},
        groups: [
          StrategyGroup(
            name: '空组',
            rawType: 'select',
            hidden: false,
            now: '',
            fixed: '',
            members: [],
          ),
          StrategyGroup(
            name: '大量成员',
            rawType: 'select',
            hidden: false,
            now: '节点0',
            fixed: '',
            members: List.generate(
              100,
              (i) => StrategyMember(name: '节点$i', type: 'Socks5'),
            ),
          ),
        ],
      );
      await show(tester);
      await strategies(tester);
      await open(tester, '空组');
      expect(find.text('手动选择 · 0'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭策略浮窗'));
      await tester.pumpAndSettle();
      await open(tester, '大量成员');
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('strategy-member-99')),
        400,
        maxScrolls: 30,
        scrollable: find.descendant(
          of: find.byType(StrategyPopup),
          matching: find.byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          ),
        ),
      );
      final scroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(StrategyPopup),
          matching: find.byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          ),
        ),
      );
      final offset = scroll.position.pixels;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(scroll.position.pixels, offset);
      await tester.tap(find.byTooltip('关闭策略浮窗'));
      await tester.pumpAndSettle();
      expect(find.byType(StrategyPopup), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('read failure removes selection and disables member changes', (
    tester,
  ) async {
    await show(tester);
    await strategies(tester);
    await open(tester, '出口');
    bridge.failRead = true;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.text('更新失败 · 查看原因'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsNothing);
    expect(
      tester
          .widget<InkWell>(find.byKey(const ValueKey('strategy-member-1')))
          .onTap,
      isNull,
    );
    expect(app.commands, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('many groups keep scroll position after returning from a popup', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    bridge.data = StrategySnapshot(
      generation: 7,
      configId: 'one',
      revision: 1,
      purpose: 'PREVIEW',
      composition: '["one",1]',
      globalReferenced: false,
      unrestored: {},
      groups: List.generate(
        50,
        (i) => StrategyGroup(
          name: '策略$i',
          rawType: 'select',
          hidden: false,
          now: 'A',
          fixed: '',
          members: const [StrategyMember(name: 'A', type: 'Socks5')],
        ),
      ),
    );
    await show(tester);
    await strategies(tester);
    await open(tester, '策略49');
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const PageStorageKey('strategies-scroll')),
        matching: find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        ),
      ),
    );
    final offset = scroll.position.pixels;
    expect(offset, greaterThan(0));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, offset);
    expect(
      find.byKey(const ValueKey('strategy-group-策略49')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final dark in [false, true]) {
    test('navigation and member selection use neutral surfaces dark=$dark', () {
      final theme = dark ? AppTheme.dark : AppTheme.light;
      final palette = HomePalette(dark);
      expect(theme.navigationBarTheme.backgroundColor, palette.surface);
      expect(theme.navigationBarTheme.indicatorColor, palette.soft);
      expect(theme.colorScheme.surfaceContainerHighest, palette.soft);
      // The six rendered brand/brightness cases above check icon roles in both
      // selection states; a global primary icon override would erase them.
    });
    testWidgets(
      'long names and unrestored warning remain scrollable dark=$dark',
      (tester) async {
        tester.view.physicalSize = const Size(320, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final name = List.filled(10, '很长的策略名称🌐').join();
        final member = List.filled(10, 'long-node-name🌐').join();
        bridge.data = StrategySnapshot(
          generation: 7,
          configId: 'one',
          revision: 1,
          purpose: 'PREVIEW',
          composition: '["one",1]',
          globalReferenced: false,
          unrestored: {name: 'member-missing'},
          groups: [
            StrategyGroup(
              name: name,
              rawType: 'select',
              hidden: false,
              now: member,
              fixed: '',
              members: [StrategyMember(name: member, type: 'Socks5')],
            ),
          ],
        );
        await show(tester, dark: dark, scale: 2);
        await strategies(tester);
        expect(find.textContaining('部分选择未恢复'), findsOneWidget);
        await open(tester, name);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('strategy-member-0')),
          180,
          scrollable: find.descendant(
            of: find.byType(StrategyPopup),
            matching: find.byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('strategy-member-0')), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
    testWidgets(
      'strategy cards and automatic sheet fit short double-text screen dark=$dark',
      (tester) async {
        tester.view.physicalSize = const Size(320, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await show(tester, dark: dark, scale: 2);
        await strategies(tester);
        await open(tester, '自动');
        expect(find.byType(StrategyPopup), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('strategy-member-1')),
          120,
          scrollable: find.descendant(
            of: find.byType(StrategyPopup),
            matching: find.byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(
          find.byKey(const ValueKey('strategy-automatic')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('strategy-automatic')));
        await tester.pump();
        expect(app.commands.single['choice'], {
          'type': 'url-test',
          'member': null,
        });
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('group and member delay tests report real results in place', (
    tester,
  ) async {
    await show(tester);
    await strategies(tester);
    await open(tester, '出口');
    final popup = find.byKey(const ValueKey('strategy-popup-出口'));
    final before = tester.getRect(popup);
    final status = find.byKey(const ValueKey('strategy-delay-group'));
    await tester.tap(status);
    await tester.pump();
    expect(bridge.delayStarts, [
      {'id': bridge.delayStarts.single['id'], 'group': '出口'},
    ]);
    expect(find.text('已完成 0/2'), findsOneWidget);
    expect(tester.getRect(popup), before);
    bridge.finishDelay({'A': ('success', 42), 'B': ('timeout', null)});
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(find.text('42 ms'), findsOneWidget);
    expect(find.text('超时'), findsOneWidget);
    expect(find.text('测试完成'), findsOneWidget);
    expect(
      find.byTooltip(
        '测试完成\n目标：https://www.gstatic.com/generate_204 · HTTP 延迟，非 ICMP',
      ),
      findsOneWidget,
    );
    expect(tester.getRect(popup), before);
    await tester.tap(find.byKey(const ValueKey('strategy-popup-status')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        '目标：https://www.gstatic.com/generate_204 · HTTP 延迟，非 ICMP',
      ),
      findsWidgets,
    );
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(tester.getRect(popup), before);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('member delay test targets one member without choosing it', (
    tester,
  ) async {
    await show(tester);
    await strategies(tester);
    await open(tester, '出口');
    await tester.tap(find.byKey(const ValueKey('strategy-delay-0')));
    await tester.pump();
    expect(bridge.delayStarts, [
      {
        'id': bridge.delayStarts.single['id'],
        'group': '出口',
        'members': ['A'],
      },
    ]);
    expect(app.commands, isEmpty);
    expect(find.text('测试中'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('closing and expiry cancel the batch without resurrecting it', (
    tester,
  ) async {
    await show(tester);
    await strategies(tester);
    await open(tester, '出口');
    await tester.tap(find.byKey(const ValueKey('strategy-delay-group')));
    await tester.pump();
    await tester.tap(find.byTooltip('关闭策略浮窗'));
    await tester.pumpAndSettle();
    expect(bridge.delayCancels, [bridge.delayStarts.single['id']]);
    await open(tester, '出口');
    expect(find.text('已完成 0/2'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed start keeps a fixed result slot and allows retry', (
    tester,
  ) async {
    bridge.failDelayStart = true;
    await show(tester);
    await strategies(tester);
    await open(tester, '出口');
    final popup = find.byKey(const ValueKey('strategy-popup-出口'));
    final before = tester.getRect(popup);
    await tester.tap(find.byKey(const ValueKey('strategy-delay-group')));
    await tester.pump();
    await tester.pump();
    expect(find.text('无法启动延迟测试'), findsOneWidget);
    expect(tester.getRect(popup), before);
    bridge.failDelayStart = false;
    await tester.tap(find.byKey(const ValueKey('strategy-delay-group')));
    await tester.pump();
    expect(find.text('已完成 0/2'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'ordinary busy state preserves a delay batch but background cancels it',
    (tester) async {
      await show(tester);
      await strategies(tester);
      await open(tester, '出口');
      await tester.tap(find.byKey(const ValueKey('strategy-delay-group')));
      await tester.pump();
      app.dispatching = true;
      app.changed();
      await tester.pump();
      expect(bridge.delayCancels, isEmpty);
      app.dispatching = false;
      app.changed();
      await tester.pump();
      expect(bridge.delayCancels, isEmpty);
      // The app may stop producing frames in the background, or return before
      // the next frame. Cancellation must happen synchronously in either case.
      app.setForeground(false);
      expect(bridge.delayCancels, [bridge.delayStarts.single['id']]);
      app.setForeground(true);
      await tester.pump();
      expect(bridge.delayStarts, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final dark in [false, true]) {
    for (final started in [false, true]) {
      for (final memberOnly in [false, true]) {
        testWidgets(
          'same-source foreground permits a new manual delay dark=$dark started=$started member=$memberOnly',
          (tester) async {
            tester.view.physicalSize = const Size(320, 640);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            await show(tester, dark: dark, scale: 2);
            await strategies(tester);
            await open(tester, '出口');
            final keys = [
              'strategy-popup-出口',
              'strategy-delay-group',
              'strategy-member-name-0',
              'strategy-member-marks-0',
              'strategy-delay-result-0',
              'strategy-delay-0',
            ];
            final before = {
              for (final key in keys)
                key: tester.getRect(find.byKey(ValueKey(key))),
            };
            void stable() {
              for (final key in keys) {
                expect(tester.getRect(find.byKey(ValueKey(key))), before[key]);
              }
              expect(tester.takeException(), isNull);
            }

            final group = find.byKey(const ValueKey('strategy-delay-group'));
            if (started) {
              await tester.tap(group);
              await tester.pump();
              bridge.finishDelay({
                'A': ('success', 12),
                'B': ('running', null),
              });
              bridge.delayBatch!['state'] = 'running';
              await tester.pump(const Duration(milliseconds: 700));
              await tester.pump();
              expect(find.text('12 ms'), findsOneWidget);
              stable();
            }
            final count = bridge.delayStarts.length;
            app.setForeground(false);
            await tester.pump();
            stable();
            expect(
              bridge.delayCancels,
              started ? [bridge.delayStarts.single['id']] : isEmpty,
            );
            expect(find.text('12 ms'), started ? findsOneWidget : findsNothing);
            expect(tester.widget<IconButton>(group).onPressed, isNull);
            app.setForeground(true);
            await tester.pump();
            stable();
            await tester.pump(const Duration(milliseconds: 16));
            stable();
            await tester.pump(const Duration(seconds: 3));
            stable();
            expect(bridge.delayStarts, hasLength(count));
            expect(find.text('12 ms'), started ? findsOneWidget : findsNothing);
            if (started) {
              final strings = AppLocalizations.of(tester.element(group));
              expect(
                tester
                    .widget<Text>(
                      find.byKey(const ValueKey('strategy-popup-status')),
                    )
                    .data,
                strings.delayExpired,
              );
            }
            final action = memberOnly
                ? find.byKey(const ValueKey('strategy-delay-0'))
                : group;
            expect(tester.widget<IconButton>(action).onPressed, isNotNull);
            await tester.tap(action);
            await tester.pump();
            stable();
            expect(bridge.delayStarts, hasLength(count + 1));
            expect(bridge.delayStarts.last, {
              'id': bridge.delayStarts.last['id'],
              'group': '出口',
              if (memberOnly) 'members': ['A'],
            });
            expect(app.commands, isEmpty);
            expect(find.text('12 ms'), findsNothing);
            bridge.finishDelay({
              'A': ('success', 24),
              if (!memberOnly) 'B': ('timeout', null),
            });
            await tester.pump(const Duration(milliseconds: 700));
            await tester.pump();
            stable();
            expect(find.text('24 ms'), findsOneWidget);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }

  testWidgets(
    'cancellation preserves a settled delay and expiry clears it in place',
    (tester) async {
      await show(tester);
      await strategies(tester);
      await open(tester, '出口');
      final popup = find.byKey(const ValueKey('strategy-popup-出口'));
      final member = find.byKey(const ValueKey('strategy-member-0'));
      final before = tester.getRect(popup);
      final memberBefore = tester.getRect(member);
      await tester.tap(find.byKey(const ValueKey('strategy-delay-group')));
      await tester.pump();
      bridge.finishDelay({'A': ('success', 12), 'B': ('cancelled', null)});
      bridge.delayBatch!['state'] = 'cancelled';
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      final strings = AppLocalizations.of(tester.element(popup));
      expect(find.text('12 ms'), findsOneWidget);
      expect(find.text(strings.delayCancelled), findsNWidgets(2));
      expect(tester.getRect(popup), before);
      expect(tester.getRect(member), memberBefore);
      final cancelledBatch = bridge.delayBatch!;
      expect(bridge.delayCancels, [cancelledBatch['id']]);
      await tester.tap(find.byKey(const ValueKey('strategy-delay-group')));
      await tester.pump();
      final activeBatch = bridge.delayBatch!;
      expect(activeBatch, isNot(same(cancelledBatch)));
      expect(activeBatch['id'], isNot(cancelledBatch['id']));
      expect(bridge.delayStarts, hasLength(2));
      final initialReads = bridge.delayReads;
      expect(initialReads, 1);
      bridge.finishDelay({'A': ('success', 12), 'B': ('success', 18)});
      bridge.delayBatch!['state'] = 'running';
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(bridge.delayReads, initialReads + 1);
      expect(find.text('12 ms'), findsOneWidget);
      expect(find.text('18 ms'), findsOneWidget);
      expect(bridge.delayCancels, [cancelledBatch['id']]);
      bridge.finishDelay({'A': ('expired', null), 'B': ('expired', null)});
      bridge.delayBatch!['state'] = 'expired';
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(find.text('12 ms'), findsNothing);
      expect(find.text(strings.delayExpired), findsNWidgets(3));
      expect(tester.getRect(popup), before);
      expect(tester.getRect(member), memberBefore);
      expect(bridge.delayReads, initialReads + 2);
      expect(bridge.delayCancels, [cancelledBatch['id'], activeBatch['id']]);
      expect(bridge.delayStarts, hasLength(2));
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final dark in [false, true]) {
    for (final language in ['zh', 'en']) {
      for (final narrow in [false, true]) {
        testWidgets(
          'strategy toolbar and trailing slots stay stable dark=$dark language=$language narrow=$narrow',
          (tester) async {
            tester.view.physicalSize = narrow
                ? const Size(320, 640)
                : const Size(480, 800);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final groupName = language == 'zh'
                ? '很长的自动策略组名称🌐保持完整标题'
                : 'A long automatic strategy group 🌐 title';
            final nodeName = language == 'zh'
                ? '很长的真实节点名称🌐用于检查等待与结果'
                : 'A long real member name 🌐 that remains readable';
            StrategySnapshot data({
              String fixed = '',
              String? now,
              CoreSnapshot core = previewCore,
            }) => StrategySnapshot(
              generation: core.generation,
              configId: core.configId!,
              revision: core.revision!,
              purpose: core.purpose!,
              composition: core.composition,
              globalReferenced: false,
              unrestored: {},
              groups: [
                StrategyGroup(
                  name: groupName,
                  rawType: 'url-test',
                  hidden: false,
                  now: now ?? nodeName,
                  fixed: fixed,
                  members: [
                    StrategyMember(name: nodeName, type: 'Socks5'),
                    const StrategyMember(name: 'DIRECT', type: 'Direct'),
                  ],
                ),
              ],
            );
            bridge.data = data();
            await show(
              tester,
              dark: dark,
              scale: narrow ? 2 : 1,
              locale: Locale(language),
            );
            await strategies(tester);
            final cardName = find.byKey(ValueKey('strategy-name-$groupName'));
            final current = find.byKey(ValueKey('strategy-current-$groupName'));
            final pin = find.byKey(ValueKey('strategy-pin-$groupName'));
            expect(
              tester.getTopLeft(current).dx,
              tester.getTopLeft(cardName).dx,
            );
            final beforeCurrent = tester.getRect(current);
            final beforePin = tester.getRect(pin);
            bridge.data = data(fixed: nodeName);
            app.state = const AppSnapshot(
              phase: 'STOPPED',
              core: previewCore,
              resultId: 'fixed',
              resultSuccess: true,
            );
            app.changed();
            await tester.pump();
            await tester.pump();
            expect(tester.getRect(current), beforeCurrent);
            expect(tester.getRect(pin), beforePin);
            expect(
              tester.getTopLeft(pin).dx,
              greaterThan(tester.getTopLeft(current).dx),
            );
            bridge.data = data();
            app.state = const AppSnapshot(
              phase: 'STOPPED',
              core: previewCore,
              resultId: 'unfixed',
              resultSuccess: true,
            );
            app.changed();
            await tester.pump();
            expect(tester.getRect(current), beforeCurrent);
            expect(tester.getRect(pin), beforePin);
            bridge.data = data(fixed: nodeName);
            app.state = const AppSnapshot(
              phase: 'STOPPED',
              core: previewCore,
              resultId: 'fixed-again',
              resultSuccess: true,
            );
            app.changed();
            await tester.pump();
            expect(tester.getRect(current), beforeCurrent);
            expect(tester.getRect(pin), beforePin);
            await open(tester, groupName);
            final popup = find.byKey(ValueKey('strategy-popup-$groupName'));
            final strings = AppLocalizations.of(tester.element(popup));
            final groupAction = find.byKey(
              const ValueKey('strategy-delay-group'),
            );
            final close = find.ancestor(
              of: find.byTooltip(strings.closeStrategyPopup),
              matching: find.byType(IconButton),
            );
            expect(
              tester.widget<IconButton>(groupAction).tooltip,
              strings.delayTestGroup,
            );
            expect(
              find.widgetWithText(TextButton, strings.delayTestGroup),
              findsNothing,
            );
            expect(tester.getRect(groupAction).top, tester.getRect(close).top);
            expect(
              tester.getRect(groupAction).right,
              lessThanOrEqualTo(tester.getRect(close).left),
            );
            final member = find.byKey(const ValueKey('strategy-member-0'));
            await tester.scrollUntilVisible(
              member,
              150,
              scrollable: find
                  .descendant(of: popup, matching: find.byType(Scrollable))
                  .first,
            );
            await tester.pumpAndSettle();
            final name = find.byKey(const ValueKey('strategy-member-name-0'));
            final result = find.byKey(
              const ValueKey('strategy-delay-result-0'),
            );
            final test = find.byKey(const ValueKey('strategy-delay-0'));
            final surface = find.byKey(
              const ValueKey('strategy-member-surface-0'),
            );
            final marks = find.byKey(const ValueKey('strategy-member-marks-0'));
            final beforeMarks = tester.getRect(marks);
            final beforePopup = tester.getRect(popup);
            final beforeGroupAction = tester.getRect(groupAction);
            final beforeClose = tester.getRect(close);
            final beforeName = tester.getRect(name);
            final beforeResult = tester.getRect(result);
            final beforeTest = tester.getRect(test);
            final beforeSurface = tester.getRect(surface);
            expect(beforeSurface.contains(beforeTest.center), isTrue);
            expect(
              tester.widget<Material>(surface).color,
              Theme.of(tester.element(surface))
                  .colorScheme
                  .surfaceContainerHighest,
            );
            void stable() {
              expect(tester.getRect(popup), beforePopup);
              expect(tester.getRect(groupAction), beforeGroupAction);
              expect(tester.getRect(close), beforeClose);
              expect(tester.getRect(marks), beforeMarks);
              expect(tester.getRect(name), beforeName);
              expect(tester.getRect(result), beforeResult);
              expect(tester.getRect(test), beforeTest);
              expect(tester.getRect(surface), beforeSurface);
              expect(tester.takeException(), isNull);
            }

            await tester.tap(test);
            await tester.pump();
            stable();
            expect(app.commands, isEmpty);
            expect(bridge.delayStarts.single['members'], [nodeName]);
            await tester.pump(const Duration(milliseconds: 16));
            stable();
            bridge.finishDelay({nodeName: ('success', 42)});
            await tester.pump(const Duration(milliseconds: 700));
            await tester.pump();
            stable();
            expect(find.text('42 ms'), findsOneWidget);
            await tester.tap(groupAction);
            await tester.pump();
            stable();
            bridge.finishDelay({
              nodeName: ('failed', null),
              'DIRECT': ('timeout', null),
            });
            await tester.pump(const Duration(milliseconds: 700));
            await tester.pump();
            stable();
            expect(
              find.descendant(
                of: result,
                matching: find.text(strings.delayFailed),
              ),
              findsOneWidget,
            );
            bridge.failDelayStart = true;
            await tester.tap(groupAction);
            await tester.pump();
            stable();
            bridge.failDelayStart = false;
            await tester.tap(test);
            await tester.pump();
            stable();
            bridge.delayBatch!['state'] = 'cancelled';
            bridge.delayBatch!['members'] = [
              {'name': nodeName, 'type': 'Socks5', 'status': 'cancelled'},
            ];
            await tester.pump(const Duration(milliseconds: 700));
            await tester.pump();
            stable();
            expect(
              find.descendant(
                of: result,
                matching: find.text(strings.delayCancelled),
              ),
              findsOneWidget,
            );
            await tester.tap(test);
            await tester.pump();
            stable();
            bridge.delayBatch!['state'] = 'expired';
            bridge.delayBatch!['members'] = [
              {'name': nodeName, 'type': 'Socks5', 'status': 'expired'},
            ];
            await tester.pump(const Duration(milliseconds: 700));
            await tester.pump();
            stable();
            expect(
              find.descendant(
                of: result,
                matching: find.text(strings.delayExpired),
              ),
              findsOneWidget,
            );
            bridge.data = data(fixed: 'DIRECT', now: 'DIRECT');
            app.state = const AppSnapshot(
              phase: 'STOPPED',
              core: previewCore,
              resultId: 'changed',
              resultSuccess: true,
            );
            app.changed();
            await tester.pump();
            stable();
            await tester.pump(const Duration(milliseconds: 16));
            stable();
            const replacement = CoreSnapshot(
              generation: 8,
              phase: 'READY',
              purpose: 'PREVIEW',
              composition: '["one",1]',
              configId: 'one',
              revision: 1,
            );
            bridge.data = data(core: replacement);
            app.state = const AppSnapshot(phase: 'STOPPED', core: replacement);
            app.changed();
            await tester.pump();
            stable();
            expect(tester.widget<IconButton>(groupAction).onPressed, isNull);
            await tester.pump(const Duration(milliseconds: 16));
            stable();
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }

  for (final dark in [false, true]) {
    testWidgets(
      'delay actions stay reachable at 320 wide double text dark=$dark',
      (tester) async {
        tester.view.physicalSize = const Size(320, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await show(tester, dark: dark, scale: 2);
        await strategies(tester);
        await open(tester, '出口');
        final popup = find.byKey(const ValueKey('strategy-popup-出口'));
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(
          find.byKey(const ValueKey('strategy-delay-group')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('strategy-delay-group')));
        await tester.pump();
        expect(find.text('已完成 0/2'), findsOneWidget);
        await tester.ensureVisible(
          find.byKey(const ValueKey('strategy-delay-0')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getRect(popup).width, lessThanOrEqualTo(420));
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
