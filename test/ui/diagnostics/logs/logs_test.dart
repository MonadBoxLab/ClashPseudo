import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:flutter/services.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/navigation/page_route.dart';
import 'package:clash_pseudo/src/ui/components/input/choice_menu_button.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:convert';

import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/diagnostics/logs/logs_controller.dart';
import 'package:clash_pseudo/src/ui/diagnostics/logs/logs_page.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../configuration/runtime_fakes.dart' show TestApp, core;

import 'log_fakes.dart';

Future<void> pumpFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 12; frame++) {
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 400, microseconds: 1));
  for (var frame = 0; frame < 4; frame++) {
    await tester.pump();
  }
}

Future<void> openLogActions(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('log-actions')));
  await pumpFrames(tester);
}

Future<void> openLogNoticeDetails(WidgetTester tester) async {
  expect(find.byType(AlertDialog), findsNothing);
  final strings = lookupAppLocalizations(const Locale('en'));
  final details = find.descendant(
    of: find.byType(SnackBar),
    matching: find.widgetWithText(TextButton, strings.errorDetails),
  );
  expect(details.hitTestable(), findsOneWidget);
  expect(tester.getSize(details).shortestSide, greaterThanOrEqualTo(48));
  await tester.tap(details);
  await pumpFrames(tester);
  expect(find.byType(AlertDialog), findsOneWidget);
}

class EpochLogApp extends TestApp {
  EpochLogApp(super.platform) {
    state = AppSnapshot(
      phase: 'RUNNING',
      core: core(1),
      logSource: logSource(core(1)),
    );
  }

  int epoch = 0;
  @override
  int get storageEpoch => epoch;
}

Widget logsWidget(TestApp app) => MaterialApp(
  navigatorObservers: [AppTaskNavigatorObserver()],
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: CoreLogsPage(app: app),
);

CoreLogsController logController(WidgetTester tester) => tester
    .widgetList<ListenableBuilder>(find.byType(ListenableBuilder))
    .map((widget) => widget.listenable)
    .whereType<CoreLogsController>()
    .single;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('日志成功读取后的普通通知不关闭刷新菜单，真实刷新保持原控件位置', (tester) async {
    final bridge = LogBridge();
    final app = logApp(bridge);
    addTearDown(app.dispose);
    await tester.pumpWidget(logsWidget(app));
    bridge.replies.first.complete(
      logResponse(core(1), entries: [entry(1, 'info', 'first-row')], next: 1),
    );
    await tester.pump();
    final controller = logController(tester);
    final button = find.byKey(const ValueKey('log-actions'));
    final buttonRect = tester.getRect(button);
    final searchRect = tester.getRect(find.byType(TextField));
    await openLogActions(tester);
    final refresh = find.byKey(const ValueKey('log-refresh'));
    expect(refresh.hitTestable(), findsOneWidget);
    final actionRect = tester.getRect(refresh);
    expect(actionRect.height, greaterThanOrEqualTo(48));
    controller.setFollow(false);
    await tester.pump();
    expect(controller.loading, isFalse);
    expect(refresh.hitTestable(), findsOneWidget);
    expect(tester.getRect(refresh), actionRect);
    expect(tester.getRect(button), buttonRect);
    expect(tester.getRect(find.byType(TextField)), searchRect);
    controller.setFollow(true);
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump();
    }
    expect(controller.loading, isFalse);
    expect(refresh.hitTestable(), findsOneWidget);
    expect(tester.getRect(refresh), actionRect);
    expect(tester.getRect(button), buttonRect);
    expect(tester.getRect(find.byType(TextField)), searchRect);
    final count = bridge.requests.length;
    await tester.tap(refresh);
    await tester.pump();
    expect(bridge.requests, hasLength(count + 1));
    expect(controller.loading, isTrue);
    expect(tester.getRect(button), buttonRect);
    bridge.replies.last.complete(logResponse(core(1), next: 2));
    await pumpFrames(tester);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('日志读取恢复后拒绝旧错误菜单的详情与刷新 action', (tester) async {
    final bridge = LogBridge();
    final app = logApp(bridge);
    addTearDown(app.dispose);
    await tester.pumpWidget(logsWidget(app));
    bridge.replies.first.completeError(StateError('retired-error-period'));
    await pumpFrames(tester);
    final oldMenu = tester.widget<ChoiceMenuButton<String>>(
      find.ancestor(
        of: find.byKey(const ValueKey('log-actions')),
        matching: find.byType(ChoiceMenuButton<String>),
      ),
    );
    expect(oldMenu.options.containsKey('log-error-details'), isTrue);
    final controller = logController(tester);
    if (!controller.loading) controller.refresh();
    await tester.pump();
    bridge.replies.last.complete(logResponse(core(1)));
    await pumpFrames(tester);
    expect(controller.readError, isNull);
    final count = bridge.requests.length;
    oldMenu.onSelected('log-error-details');
    oldMenu.onSelected('log-refresh');
    expect(bridge.requests, hasLength(count));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('日志连续错误只提示一次，成功后开启新周期并保持搜索与阅读位置', (tester) async {
    final bridge = LogBridge();
    final app = logApp(bridge);
    addTearDown(app.dispose);
    await tester.pumpWidget(logsWidget(app));
    bridge.replies.first.complete(
      logResponse(
        core(1),
        entries: [
          for (var seq = 1; seq <= 100; seq++)
            entry(seq, 'info', 'row-$seq ${'content ' * (seq % 4 + 1)}'),
        ],
        next: 100,
        total: 100,
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'row');
    await tester.showKeyboard(find.byType(TextField));
    final field = tester.widget<TextField>(find.byType(TextField));
    final draft = const TextEditingValue(
      text: 'row',
      selection: TextSelection(baseOffset: 1, extentOffset: 3),
      composing: TextRange(start: 0, end: 3),
    );
    field.controller!.value = draft;
    final controller = logController(tester);
    controller.setFollow(false);
    final scroll = tester.widget<Scrollbar>(find.byType(Scrollbar)).controller!;
    scroll.jumpTo(scroll.position.maxScrollExtent * .4);
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump();
    }
    final viewport = tester.getRect(find.byType(Scrollbar));
    final anchor = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .firstWhere((widget) {
          final rect = tester.getRect(find.byWidget(widget));
          return rect.bottom > viewport.top && rect.top < viewport.bottom;
        })
        .data!;
    final reading = find.byWidgetPredicate(
      (widget) => widget is SelectableText && widget.data == anchor,
    );
    final anchors = [
      find.byType(TextField),
      find.byKey(const ValueKey('log-actions')),
      find.byType(Scrollbar),
      reading,
    ];
    final rects = anchors.map(tester.getRect).toList();
    final refresh = controller.refresh();
    await tester.pump();
    bridge.replies.last.completeError(StateError('first-log-read-original'));
    await refresh;
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < anchors.length; i++) {
        expect(tester.getRect(anchors[i]), rects[i]);
      }
      expect(field.controller!.value, draft);
      expect(field.focusNode!.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(controller.follow, isFalse);
      expect(tester.takeException(), isNull);
    }
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    final strings = lookupAppLocalizations(const Locale('en'));
    final oldRetry = tester
        .widget<TextButton>(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.widgetWithText(TextButton, strings.retry),
          ),
        )
        .onPressed!;
    final close = find.descendant(
      of: find.byType(SnackBar),
      matching: find.byIcon(Icons.close),
    );
    expect(
      tester
          .getSize(find.ancestor(of: close, matching: find.byType(IconButton)))
          .shortestSide,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(close);
    await pumpFrames(tester);
    expect(find.byType(SnackBar), findsNothing);
    final count = bridge.requests.length;
    oldRetry();
    expect(bridge.requests, hasLength(count));
    if (!controller.loading) controller.refresh();
    await tester.pump();
    bridge.replies.last.completeError(StateError('same-period-next-read'));
    await pumpFrames(tester);
    expect(find.byType(SnackBar), findsNothing);
    if (!controller.loading) controller.refresh();
    await tester.pump();
    bridge.replies.last.complete(logResponse(core(1), next: 100, total: 100));
    await tester.pump();
    expect(controller.readError, isNull);
    expect(controller.readErrorSource, isNull);
    if (!controller.loading) controller.refresh();
    await tester.pump();
    bridge.replies.last.completeError(StateError('new-period-original'));
    await pumpFrames(tester);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(field.controller!.value, draft);
    expect(field.focusNode!.hasFocus, isTrue);
    for (var i = 0; i < anchors.length; i++) {
      expect(tester.getRect(anchors[i]), rects[i]);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('清空失败保留同次原结果，后续读取错误不替换已显示提示的详情', (tester) async {
    final bridge = LogBridge();
    final app = logApp(bridge);
    addTearDown(app.dispose);
    await tester.pumpWidget(logsWidget(app));
    bridge.replies.first.complete(
      logResponse(
        core(1),
        entries: [entry(1, 'warning', 'retained-clear-failure-row')],
        next: 1,
        total: 1,
        dropped: 3,
      ),
    );
    await tester.pump();
    await tester.pump();
    final controller = logController(tester);
    final data = controller.data;
    final query = controller.dataQuery;
    final row = find.text('retained-clear-failure-row');
    final anchors = [find.byType(TextField), find.byType(Scrollbar), row];
    final rects = anchors.map(tester.getRect).toList();
    final strings = lookupAppLocalizations(const Locale('en'));
    await tester.tap(find.byTooltip(strings.logClear));
    expect(bridge.requests.last['clear'], isTrue);
    bridge.replies.last.completeError(
      StateError('clear-original-detail: fixture-secret'),
    );
    await pumpFrames(tester);
    expect(controller.data, same(data));
    expect(controller.dataQuery, same(query));
    expect(controller.entries.single['text'], 'retained-clear-failure-row');
    expect(controller.dropped, 3);
    expect(find.byType(AlertDialog), findsNothing);
    final notice = tester.widget<SnackBar>(find.byType(SnackBar));
    await tester.pump(const Duration(milliseconds: 610));
    bridge.replies.last.completeError(StateError('later-poll-detail'));
    await pumpFrames(tester);
    expect(tester.widget<SnackBar>(find.byType(SnackBar)), same(notice));
    expect(
      controller.readError!.technicalDetail(
        lookupAppLocalizations(const Locale('en')),
      ),
      contains('later-poll-detail'),
    );
    for (var i = 0; i < anchors.length; i++) {
      expect(tester.getRect(anchors[i]), rects[i]);
    }
    await openLogNoticeDetails(tester);
    final technical = find.byKey(const ValueKey('operation-technical-details'));
    await tester.ensureVisible(technical);
    await tester.tap(technical);
    await pumpFrames(tester);
    final text = tester
        .widget<SelectableText>(
          find.byKey(const ValueKey('operation-technical-text')),
        )
        .data!;
    expect(text, contains('clear-original-detail: fixture-secret'));
    expect(text, isNot(contains('later-poll-detail')));
    expect(controller.data, same(data));
    expect(controller.dataQuery, same(query));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final replacement in ['identity', 'window', 'epoch']) {
    testWidgets('日志旧来源pending失败不提示为新来源 $replacement', (tester) async {
      final bridge = LogBridge();
      final app = EpochLogApp(bridge);
      addTearDown(app.dispose);
      await tester.pumpWidget(logsWidget(app));
      final oldSource = (
        app.storageEpoch,
        app.state.logSource!.identity,
        app.state.logSource!.logWindow,
      );
      final source = replacement == 'identity'
          ? logSource(core(2))
          : logSource(
              core(1),
              window: replacement == 'window' ? 'replacement-window' : '1',
            );
      if (replacement == 'epoch') app.epoch++;
      app.publish(
        AppSnapshot(phase: 'RUNNING', core: source, logSource: source),
      );
      bridge.replies.first.completeError(
        StateError('old-source-pending-failure'),
      );
      await pumpFrames(tester);
      final controller = logController(tester);
      expect(
        controller.readError!.detail,
        contains('old-source-pending-failure'),
      );
      expect(controller.readErrorSource, oldSource);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      if (!controller.loading) controller.refresh();
      await tester.pump();
      bridge.replies.last.completeError(StateError('current-source-failure'));
      await pumpFrames(tester);
      expect(controller.readErrorSource, (
        app.storageEpoch,
        source.identity,
        source.logWindow,
      ));
      expect(find.byType(SnackBar), findsOneWidget);
      await openLogNoticeDetails(tester);
      final technical = find.byKey(
        const ValueKey('operation-technical-details'),
      );
      await tester.ensureVisible(technical);
      await tester.tap(technical);
      await pumpFrames(tester);
      final text = tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('operation-technical-text')),
          )
          .data!;
      expect(text, contains('current-source-failure'));
      expect(text, isNot(contains('old-source-pending-failure')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('日志来源变化撤销旧提示和菜单action $replacement', (tester) async {
      final bridge = LogBridge();
      final app = EpochLogApp(bridge);
      addTearDown(app.dispose);
      await tester.pumpWidget(logsWidget(app));
      bridge.replies.first.completeError(StateError('retired-source-failure'));
      await pumpFrames(tester);
      final strings = lookupAppLocalizations(const Locale('en'));
      final oldDetails = tester
          .widget<TextButton>(
            find.descendant(
              of: find.byType(SnackBar),
              matching: find.widgetWithText(TextButton, strings.errorDetails),
            ),
          )
          .onPressed!;
      final oldRetry = tester
          .widget<TextButton>(
            find.descendant(
              of: find.byType(SnackBar),
              matching: find.widgetWithText(TextButton, strings.retry),
            ),
          )
          .onPressed!;
      final menu = tester.widget<ChoiceMenuButton<String>>(
        find.ancestor(
          of: find.byKey(const ValueKey('log-actions')),
          matching: find.byType(ChoiceMenuButton<String>),
        ),
      );
      final source = replacement == 'identity'
          ? logSource(core(2))
          : logSource(
              core(1),
              window: replacement == 'window' ? 'replacement-window' : '1',
            );
      if (replacement == 'epoch') app.epoch++;
      app.publish(
        AppSnapshot(phase: 'RUNNING', core: source, logSource: source),
      );
      final count = bridge.requests.length;
      oldDetails();
      oldRetry();
      menu.onSelected('log-error-details');
      menu.onSelected('log-refresh');
      expect(bridge.requests, hasLength(count));
      expect(find.byType(AlertDialog), findsNothing);
      await pumpFrames(tester);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final boundary in ['push', 'pop']) {
    testWidgets(
      'real logs page cached actions retire before the $boundary frame',
      (tester) async {
        final bridge = LogBridge();
        final app = logApp(bridge);
        addTearDown(app.dispose);
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            navigatorObservers: [AppTaskNavigatorObserver()],
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: Text('origin')),
          ),
        );
        navigator.currentState!.push<void>(
          FocusedPageRoute(builder: (_) => CoreLogsPage(app: app)),
        );
        await pumpFrames(tester);
        bridge.replies.last.complete(
          logResponse(
            core(1),
            entries: [entry(1, 'info', 'before original')],
            next: 1,
          ),
        );
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'before');
        final controller =
            (tester
                    .widget<ListenableBuilder>(
                      find.descendant(
                        of: find.byType(CoreLogsPage),
                        matching: find.byWidgetPredicate(
                          (widget) =>
                              widget is ListenableBuilder &&
                              widget.listenable is CoreLogsController,
                        ),
                      ),
                    )
                    .listenable
                as CoreLogsController);
        controller.setFollow(false);
        await tester.pump();
        final strings = lookupAppLocalizations(const Locale('en'));
        VoidCallback button(String tooltip) => tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == tooltip,
              ),
            )
            .onPressed!;
        final searchField = tester.widget<TextField>(find.byType(TextField));
        final search = searchField.onChanged!;
        final clearSearch = button(strings.clearSearch);
        final actions = tester.widget<ChoiceMenuButton<String>>(
          find.ancestor(
            of: find.byKey(const ValueKey('log-actions')),
            matching: find.byType(ChoiceMenuButton<String>),
          ),
        );
        void refresh() => actions.onSelected('log-refresh');
        final clear = button(strings.logClear);
        final latest = button(strings.logBackToLatest);
        final level = tester
            .widget<ChoiceMenuButton<String>>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is ChoiceMenuButton<String> &&
                    widget.options.containsKey('debug'),
              ),
            )
            .onSelected;
        final requestCount = bridge.requests.length;
        if (boundary == 'push') {
          navigator.currentState!.push<void>(
            FocusedPageRoute(
              builder: (_) => const Scaffold(body: Text('new page')),
            ),
          );
        } else {
          navigator.currentState!.pop();
        }
        // No pump: controller._visible is deliberately still the previous frame.
        search('after');
        clearSearch();
        level('debug');
        clear();
        refresh();
        latest();
        expect(controller.search, 'before');
        expect(searchField.controller!.text, 'before');
        expect(controller.level, 'info');
        expect(controller.follow, isFalse);
        expect(bridge.requests, hasLength(requestCount));
        expect(controller.loading, isFalse);
        await pumpFrames(tester);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'local UTF-8 eviction counts are independent and clear in memory',
    (tester) async {
      final bridge = LogBridge();
      final app = logApp(bridge);
      final controller = CoreLogsController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      final body = '界' * (CoreLogsController.byteCapacity ~/ 6);
      bridge.replies.single.complete(
        logResponse(
          core(1),
          entries: [entry(1, 'info', body), entry(2, 'info', body)],
          next: 2,
          total: 987,
          dropped: 7,
        ),
      );
      await tester.pump();
      expect(controller.localDropped, 0);
      await tester.pump(const Duration(milliseconds: 610));
      bridge.replies.last.complete(
        logResponse(
          core(1),
          entries: [entry(3, 'info', 'tail!')],
          next: 3,
          total: 988,
          dropped: 8,
        ),
      );
      await tester.pump();
      expect(controller.entries.map((row) => row['seq']), [2, 3]);
      expect(controller.entries.first['text'], body);
      expect(controller.localDropped, 1);
      expect(controller.dropped, 8);
      expect(
        controller.total,
        988,
        reason: 'core total is not local window length',
      );
      final clear = controller.clear();
      bridge.replies.last.complete(logResponse(core(1), next: 3, cleared: 3));
      await clear;
      expect(controller.entries, isEmpty);
      expect(controller.localDropped, 0);
      controller.setVisible(false);
    },
  );

  testWidgets('queued clear retires without clearing a replacement window', (
    tester,
  ) async {
    final bridge = LogBridge();
    final app = logApp(bridge);
    final controller = CoreLogsController(app)..setVisible(true);
    addTearDown(() {
      controller.dispose();
      app.dispose();
    });
    var completed = false;
    final clearing = controller.clear().then((_) => completed = true);
    expect(bridge.requests.single['clear'], isNull);
    final replacement = logSource(core(1), window: 'replacement');
    app.publish(
      AppSnapshot(phase: 'RUNNING', core: core(1), logSource: replacement),
    );
    await tester.pump();
    expect(completed, isTrue);
    bridge.replies.first.complete(logResponse(core(1)));
    await tester.pump();
    expect(bridge.requests, hasLength(2));
    expect(bridge.requests.every((query) => query['clear'] != true), isTrue);
    bridge.replies.last.complete(
      logResponse(
        replacement,
        entries: [entry(1, 'info', 'new original')],
        next: 1,
      ),
    );
    await clearing;
    await tester.pump();
    expect(controller.entries.single['text'], 'new original');
    expect(controller.canClear, isTrue);
    controller.setVisible(false);
  });

  testWidgets(
    'a captured log window remains clearable with unconfirmed app state',
    (tester) async {
      final bridge = LogBridge();
      final app = logApp(bridge);
      final controller = CoreLogsController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      final clearing = controller.clear();
      app.publish(AppSnapshot(phase: 'UNKNOWN', logSource: logSource(core(1))));
      bridge.replies.first.complete(logResponse(core(1)));
      await tester.pump();
      expect(bridge.requests.last['clear'], isTrue);
      bridge.replies.last.complete(logResponse(core(1), cleared: 10, next: 10));
      await clearing;
      expect(controller.entries, isEmpty);
      expect(controller.canClear, isTrue);
      controller.setVisible(false);
    },
  );

  testWidgets(
    'a captured log window remains clearable after a status read error',
    (tester) async {
      final bridge = LogBridge();
      final app = logApp(bridge);
      final controller = CoreLogsController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      final clearing = controller.clear();
      app.platformErrorMessage = messages.temporaryStatusUnavailable.withDetail(
        'https://user:pass@fixture.test/?token=status',
      );
      app.publish(app.state);
      bridge.replies.first.complete(logResponse(core(1)));
      await tester.pump();
      expect(bridge.requests.last['clear'], isTrue);
      bridge.replies.last.complete(logResponse(core(1), cleared: 10, next: 10));
      await clearing;
      expect(controller.entries, isEmpty);
      expect(controller.canClear, isTrue);
      controller.setVisible(false);
    },
  );

  testWidgets('a submitted clear waits for its actual reply after leaving', (
    tester,
  ) async {
    final bridge = LogBridge();
    final app = logApp(bridge);
    final controller = CoreLogsController(app)..setVisible(true);
    addTearDown(() {
      controller.dispose();
      app.dispose();
    });
    bridge.replies.first.complete(logResponse(core(1)));
    await tester.pump();
    var completed = false;
    final clearing = controller.clear().then((_) => completed = true);
    expect(bridge.requests.last['clear'], isTrue);
    controller.setVisible(false);
    await tester.pump();
    expect(completed, isFalse);
    bridge.replies.last.complete(logResponse(core(1), cleared: 10, next: 10));
    await clearing;
    expect(completed, isTrue);
    expect(bridge.requests, hasLength(2));
  });

  for (final initiallyReduced in [false, true]) {
    testWidgets('日志错误不移动表单，用户打开完整原文 reduced=$initiallyReduced', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = LogBridge();
      final app = logApp(bridge);
      final reduced = ValueNotifier(initiallyReduced);
      addTearDown(app.dispose);
      addTearDown(reduced.dispose);
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [AppTaskNavigatorObserver()],
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => ValueListenableBuilder<bool>(
            valueListenable: reduced,
            child: child,
            builder: (context, reduced, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                disableAnimations: reduced,
              ),
              child: child!,
            ),
          ),
          home: CoreLogsPage(app: app),
        ),
      );
      final failure = StateError(
        List.filled(
          300,
          '原文 https://user:pass@fixture.test/?token=fixture',
        ).join('\n'),
      );
      final anchors = [
        find.byType(TextField),
        find.byType(AppBar),
        find.byKey(const ValueKey('log-actions')),
      ];
      final rects = anchors.map(tester.getRect).toList();
      bridge.replies.first.completeError(failure);
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        for (var i = 0; i < anchors.length; i++) {
          expect(tester.getRect(anchors[i]), rects[i]);
        }
        expect(find.byKey(const ValueKey('log-read-error')), findsNothing);
        expect(
          find.byKey(const ValueKey('log-read-error-motion')),
          findsNothing,
        );
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.textContaining(failure.toString()), findsNothing);
        expect(tester.takeException(), isNull);
      }
      final input = tester.widget<TextField>(find.byType(TextField)).controller;
      await pumpFrames(tester);
      await openLogNoticeDetails(tester);
      expect(find.textContaining(failure.toString()), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
      final technicalDetails = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byKey(const ValueKey('operation-technical-details')),
      );
      await tester.ensureVisible(technicalDetails);
      await pumpFrames(tester);
      expect(technicalDetails.hitTestable(), findsOneWidget);
      await tester.tap(technicalDetails);
      await pumpFrames(tester);
      expect(find.textContaining(failure.toString()), findsOneWidget);
      final reading = find.byKey(const ValueKey('operation-technical-text'));
      final scrollFinder = find
          .ancestor(of: reading, matching: find.byType(Scrollable))
          .first;
      final scroll = tester.state<ScrollableState>(scrollFinder);
      expect(scroll.position.maxScrollExtent, greaterThan(0));
      await tester.drag(scrollFinder, const Offset(0, -100));
      await tester.pump();
      expect(scroll.position.pixels, greaterThan(0));
      final offset = scroll.position.pixels;
      final readingState = tester.state(reading);
      for (final value in [!initiallyReduced, initiallyReduced]) {
        reduced.value = value;
        await tester.pump();
        expect(tester.state(reading), same(readingState));
        expect(tester.state(scrollFinder), same(scroll));
        expect(scroll.position.pixels, closeTo(offset, .5));
        expect(
          tester
              .widget<TextField>(find.byType(TextField, skipOffstage: false))
              .controller,
          same(input),
        );
        expect(find.textContaining(failure.toString()), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'whole oversized logs are skipped without emptying retained text',
    (tester) async {
      final bridge = LogBridge();
      final app = logApp(bridge);
      final controller = CoreLogsController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      const original = 'https://user:pass@example.test/?token=秘密🔐';
      bridge.replies.last.complete(
        logResponse(core(1), entries: [entry(1, 'info', original)], next: 1),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 610));
      bridge.replies.last.complete(
        logResponse(
          core(1),
          entries: [
            entry(2, 'error', 'x' * (CoreLogsController.byteCapacity + 1)),
          ],
          next: 3,
          dropped: 1,
        ),
      );
      await tester.pump();
      expect(controller.entries.single['text'], original);
      final snapshot = controller.data!['logs'] as Map;
      expect(snapshot['entries'], [entry(1, 'info', original)]);
      expect(snapshot['retainedBytes'], utf8.encode(original).length);
      expect(snapshot['windowDropped'], 1);
      expect(controller.dropped, 1);
      expect(
        controller.localDropped,
        1,
        reason: 'the core counter is not the local skip counter',
      );
      await tester.pump(const Duration(milliseconds: 610));
      expect(bridge.requests.last, isEmpty);
      bridge.replies.last.complete(logResponse(core(1), next: 4));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 610));
      expect(bridge.requests.last, isEmpty);
      controller.setVisible(false);
      bridge.replies.last.complete(logResponse(core(1), next: 4));
      await tester.pump();
    },
  );

  testWidgets(
    'clear retains original failure and rejects an older clear watermark',
    (tester) async {
      final bridge = LogBridge();
      final app = logApp(bridge);
      final controller = CoreLogsController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      bridge.replies.last.complete(
        logResponse(core(1), entries: [entry(1, 'info', 'original')], next: 1),
      );
      await tester.pump();
      final failed = controller.clear();
      bridge.replies.last.completeError(
        StateError('https://user:pass@example.test/?token=raw'),
      );
      await failed;
      expect(controller.entries.single['text'], 'original');
      expect(
        controller.error,
        contains('https://user:pass@example.test/?token=raw'),
      );
      final clearing = controller.clear();
      bridge.replies.last.complete(logResponse(core(1), next: 1, cleared: 1));
      await clearing;
      expect(controller.entries, isEmpty);
      expect(controller.error, isNull);
      await tester.pump(const Duration(milliseconds: 610));
      bridge.replies.last.complete(
        logResponse(core(1), entries: [entry(1, 'info', 'old page')], next: 1),
      );
      await tester.pump();
      expect(controller.entries, isEmpty);
      controller.setVisible(false);
    },
  );

  testWidgets(
    'closed log source decoding and bridge query preserve the actual window',
    (tester) async {
      final snapshot = AppSnapshot.fromMap({
        'phase': 'STOPPED',
        'configId': 'new selection',
        'revision': 9,
        'core': {'generation': 8, 'phase': 'EMPTY'},
        'logSource': {
          'generation': 7,
          'phase': 'EMPTY',
          'purpose': 'RUNNING',
          'configId': 'actual session',
          'revision': 2,
          'composition': 'actual composition',
          'logWindow': 'native-window',
        },
      });
      final source = snapshot.logSource!;
      expect(source.ready, isFalse);
      expect(source.configId, 'actual session');
      expect(source.revision, 2);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
        expect(call.method, 'logs');
        expect(call.arguments, {
          'processId': null,
          'inputId': null,
          'networkRevision': 0,
          'configId': 'actual session',
          'revision': 2,
          'purpose': 'RUNNING',
          'generation': 7,
          'composition': 'actual composition',
          'query': {'after': 4, 'limit': 200, 'window': 'native-window'},
        });
        return jsonEncode(logResponse(source, next: 4));
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(AppBridge.channel, null),
      );
      final response = await AppBridge().logs(source, {
        'after': 4,
        'limit': 200,
      });
      expect((response['logs'] as Map)['window'], 'native-window');
    },
  );

  testWidgets('only an absent log window prepares one on-demand preview', (
    tester,
  ) async {
    final bridge = LogBridge();
    final app = logApp(bridge)..state = const AppSnapshot(phase: 'STOPPED');
    app.collection = ConfigCollection(
      entries: const [
        ConfigEntry(
          id: 'main',
          name: 'Fixture',
          kind: ConfigKind.local,
          revision: 1,
          body: '{}',
        ),
      ],
      selectedId: 'main',
    );
    final controller = CoreLogsController(app)..setVisible(true);
    addTearDown(() {
      controller.dispose();
      app.dispose();
    });
    expect(app.commands.single['action'], 'prepareStrategies');
    app.publish(app.state);
    expect(app.commands, hasLength(1));
    final source = logSource(core(2, purpose: 'PREVIEW'));
    app.publish(
      AppSnapshot(
        phase: 'STOPPED',
        core: core(2, purpose: 'PREVIEW'),
        logSource: source,
      ),
    );
    bridge.replies.single.complete(
      logResponse(source, entries: [entry(1, 'info', 'preview log')], next: 1),
    );
    await tester.pump();
    expect(controller.status, CoreLogsStatus.preview);
    expect(app.commands, hasLength(1));
    controller.setVisible(false);
  });

  for (final failed in [false, true]) {
    testWidgets(
      'first open reads ${failed ? 'failed' : 'stopped'} recent window without preparing preview',
      (tester) async {
        final bridge = LogBridge();
        final source = logSource(core(7), recent: true);
        final app = logApp(bridge)
          ..state = AppSnapshot(
            phase: 'STOPPED',
            core: CoreSnapshot(
              generation: 9,
              error: failed ? messages.androidErrorBusy : null,
            ),
            logSource: source,
          );
        app.collection = ConfigCollection(
          entries: const [
            ConfigEntry(
              id: 'selected',
              name: 'Different selection',
              kind: ConfigKind.local,
              revision: 4,
              body: '{}',
            ),
          ],
          selectedId: 'selected',
        );
        final controller = CoreLogsController(app)..setVisible(true);
        addTearDown(() {
          controller.dispose();
          app.dispose();
        });
        expect(app.commands, isEmpty);
        expect(bridge.requests, hasLength(1));
        bridge.replies.single.complete(
          logResponse(
            source,
            entries: [entry(1, 'error', 'stopped or failed session tail')],
            total: 1,
            next: 1,
          ),
        );
        await tester.pump();
        expect(
          controller.entries.single['text'],
          'stopped or failed session tail',
        );
        expect(controller.status.name, 'recent');
        await controller.refresh();
        expect(app.commands, isEmpty);
        expect(bridge.requests, hasLength(2));
        bridge.replies.last.complete(logResponse(source));
        await tester.pump();
        controller.setVisible(false);
      },
    );
  }

  testWidgets(
    'actual window replacement rejects late logs even with the same core identity',
    (tester) async {
      final bridge = LogBridge();
      final app = logApp(bridge);
      final controller = CoreLogsController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      final replacement = logSource(core(1), window: 'replacement');
      app.publish(
        AppSnapshot(phase: 'RUNNING', core: core(1), logSource: replacement),
      );
      bridge.replies.first.complete(
        logResponse(
          core(1),
          entries: [entry(1, 'info', 'old window')],
          next: 1,
        ),
      );
      await tester.pump();
      expect(controller.entries, isEmpty);
      expect(bridge.replies, hasLength(2));
      bridge.replies.last.complete(
        logResponse(
          replacement,
          entries: [entry(1, 'info', 'real replacement')],
          next: 1,
        ),
      );
      await tester.pump();
      expect(controller.entries.single['text'], 'real replacement');
      controller.setVisible(false);
    },
  );

  for (final bytes in [false, true]) {
    testWidgets(
      '${bytes ? 'byte' : 'count'} eviction keeps variable-height reading anchor on every frame',
      (tester) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bridge = LogBridge();
        final app = logApp(bridge);
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
            home: CoreLogsPage(app: app),
          ),
        );
        final count = bytes ? 128 : 1000;
        String text(int seq) {
          final content = bytes
              ? 'variable height 日文 ' * (seq.isEven ? 340 : 350)
              : 'variable height row ' * (seq % 5 + 1);
          return 'reading-$seq $content';
        }

        // Deliver actual 200-row bridge pages. Both budgets are exercised in the
        // controller rather than removing rows from an artificial widget fixture.
        for (var start = 1; start <= count; start += 200) {
          final end = (start + 199).clamp(1, count);
          bridge.replies.last.complete(
            logResponse(
              core(1),
              entries: [
                for (var seq = start; seq <= end; seq++)
                  entry(seq, 'info', text(seq)),
              ],
              total: end,
              next: end,
            ),
          );
          await tester.pump();
          await tester.pump();
          if (end != count) {
            await tester.pump(const Duration(milliseconds: 610));
          }
        }
        final scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar));
        final scroll = scrollbar.controller!;
        scroll.jumpTo(scroll.position.maxScrollExtent * .4);
        await tester.pump();
        await tester.pump();
        final controller = tester
            .widgetList<ListenableBuilder>(find.byType(ListenableBuilder))
            .map((widget) => widget.listenable)
            .whereType<CoreLogsController>()
            .single;
        expect(controller.follow, isFalse);
        final viewport = tester.getRect(find.byType(Scrollbar));
        final candidates = tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .where((widget) {
              final rect = tester.getRect(find.byWidget(widget));
              return rect.bottom > viewport.top && rect.top < viewport.bottom;
            })
            .toList();
        expect(candidates, isNotEmpty);
        final anchor = candidates.first.data!;
        final seq = int.parse(
          anchor.split(' ').first.substring('reading-'.length),
        );
        expect(
          seq,
          greaterThan(10),
          reason: 'the reader must survive head eviction',
        );
        final before = tester.getRect(
          find.byWidgetPredicate(
            (widget) => widget is SelectableText && widget.data == anchor,
          ),
        );
        final appended = bytes ? 12 : 25;
        for (var batch = 0; batch < 2; batch++) {
          await tester.pump(const Duration(milliseconds: 610));
          final start = count + batch * appended;
          bridge.replies.last.complete(
            logResponse(
              core(1),
              entries: [
                for (var seq = start + 1; seq <= start + appended; seq++)
                  entry(seq, 'info', text(seq)),
              ],
              total: count,
              dropped: (batch + 1) * appended,
              next: start + appended,
            ),
          );
          for (var frame = 0; frame < 3; frame++) {
            await tester.pump(
              frame == 2 ? const Duration(milliseconds: 16) : Duration.zero,
            );
            expect(
              tester.getRect(
                find.byWidgetPredicate(
                  (widget) => widget is SelectableText && widget.data == anchor,
                ),
              ),
              before,
              reason: 'eviction batch $batch delivery frame $frame',
            );
            expect(controller.follow, isFalse);
            expect(tester.takeException(), isNull);
          }
        }
        expect(controller.entries.first['seq'], greaterThan(1));
        controller.filter('no matching log fixture');
        await tester.pump();
        expect(find.byType(SelectableText), findsNothing);
        controller.filter('');
        await tester.pump();
        expect(
          scroll.offset,
          0,
          reason: 'filter reset must not revive a previous center',
        );
        controller.setFollow(true);
        for (var frame = 0; frame < 30; frame++) {
          await tester.pump();
        }
        expect(controller.follow, isTrue);
        expect(scroll.offset, closeTo(scroll.position.maxScrollExtent, .5));
        final clearing = controller.clear();
        if (bridge.requests.last['clear'] != true) {
          bridge.replies.last.complete(logResponse(core(1), next: 2000));
          await tester.pump();
        }
        expect(bridge.requests.last['clear'], isTrue);
        bridge.replies.last.complete(
          logResponse(core(1), cleared: 2000, next: 2000),
        );
        await clearing;
        await tester.pump();
        expect(find.byType(SelectableText), findsNothing);
        app.setForeground(false);
        await tester.pumpWidget(const SizedBox());
        for (final reply in bridge.replies) {
          if (!reply.isCompleted) reply.complete(logResponse(core(1)));
        }
        await tester.pump();
        app.dispose();
      },
    );
  }

  testWidgets('locale changes do not replace a pending log read', (
    tester,
  ) async {
    setMessageLanguage(AppLanguage.en);
    addTearDown(() => setMessageLanguage(AppLanguage.system));
    final bridge = LogBridge();
    final app = logApp(bridge);
    app.state = AppSnapshot(
      phase: 'RUNNING',
      core: core(1, error: messages.androidErrorBusy),
      logSource: logSource(core(1)),
    );
    final controller = CoreLogsController(app)..setVisible(true);
    addTearDown(() {
      controller.dispose();
      app.dispose();
    });
    final retained = app.state;
    expect(bridge.requests, hasLength(1));
    setMessageLanguage(AppLanguage.zh);
    app.publish(retained);
    expect(bridge.requests, hasLength(1));
    expect(controller.loading, isTrue);
    expect(app.state, same(retained));
    bridge.replies.single.complete(
      logResponse(core(1), entries: [entry(1, 'info', 'retained')], next: 1),
    );
    await tester.pump();
    expect(controller.status, CoreLogsStatus.live);
    expect(controller.entries.single['text'], 'retained');
    expect(app.commands, isEmpty);
    controller.setVisible(false);
  });

  testWidgets('pending logs drain before a resumed read and never wedge', (
    tester,
  ) async {
    final bridge = LogBridge();
    final app = logApp(bridge);
    final controller = CoreLogsController(app)..setVisible(true);
    addTearDown(() {
      controller.dispose();
      app.dispose();
    });
    app.setForeground(false);
    await tester.pump();
    app.setForeground(true);
    await tester.pump(const Duration(milliseconds: 700));
    expect(bridge.requests, hasLength(1));
    bridge.replies.first.complete(
      logResponse(core(1), entries: [entry(1, 'info', 'old')], next: 1),
    );
    await tester.pump();
    expect(controller.entries.single['text'], 'old');
    expect(controller.data!['generation'], 1);
    expect(bridge.requests, hasLength(2));
    expect(bridge.requests.last, isEmpty);
    bridge.replies.last.complete(
      logResponse(core(1), entries: [entry(2, 'info', 'fresh')], next: 2),
    );
    await tester.pump();
    expect(controller.loading, isFalse);
    expect(controller.entries.map((row) => row['text']), ['old', 'fresh']);
    await tester.pump(const Duration(milliseconds: 700));
    expect(bridge.requests, hasLength(3));
    bridge.replies.last.complete(logResponse(core(1), next: 2));
    await tester.pump();
    controller.setVisible(false);
  });

  testWidgets('becoming ready starts ongoing log polling', (tester) async {
    final bridge = LogBridge();
    final app = logApp(bridge);
    app.publish(const AppSnapshot(phase: 'STOPPED'));
    final controller = CoreLogsController(app)..setVisible(true);
    addTearDown(() {
      controller.dispose();
      app.dispose();
    });
    expect(bridge.requests, isEmpty);
    app.publish(
      AppSnapshot(
        phase: 'RUNNING',
        core: core(1),
        logSource: logSource(core(1)),
      ),
    );
    expect(bridge.requests, hasLength(1));
    bridge.replies.first.complete(logResponse(core(1)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(bridge.requests, hasLength(2));
    bridge.replies.last.complete(logResponse(core(1)));
    await tester.pump();
    controller.setVisible(false);
  });

  testWidgets('local log pages retain at most one MiB of UTF-8 text', (
    tester,
  ) async {
    final bridge = LogBridge();
    final app = logApp(bridge);
    final controller = CoreLogsController(app)..setVisible(true);
    addTearDown(() {
      controller.dispose();
      app.dispose();
    });
    final text = '日' * 2700;
    for (var page = 0; page < 2; page++) {
      bridge.replies.last.complete(
        logResponse(
          core(1),
          entries: [
            for (var index = 1; index <= 100; index++)
              entry(page * 100 + index, 'info', text),
          ],
          total: 100,
          next: (page + 1) * 100,
        ),
      );
      await tester.pump();
      if (page == 0) {
        await tester.pump(const Duration(milliseconds: 700));
      }
    }
    expect(controller.entries.length, 129);
    expect(controller.entries.first['seq'], 72);
    expect(controller.entries.last['seq'], 200);
    controller.clear();
    await tester.pump(const Duration(milliseconds: 700));
    expect(bridge.requests.last, {'clear': true});
    bridge.replies.last.complete(
      logResponse(core(1), entries: [entry(201, 'info', text)], next: 201),
    );
    await tester.pump();
    expect(controller.entries, hasLength(1));
    controller.setVisible(false);
  });

  test('log pages append by sequence and reject mismatched paging', () async {
    final bridge = LogBridge();
    final app = logApp(bridge);
    final controller = CoreLogsController(app, poll: const Duration(hours: 1))
      ..setVisible(true);
    addTearDown(() {
      controller.dispose();
      app.dispose();
    });
    expect(bridge.requests.single, isEmpty);
    bridge.replies.single.complete(
      logResponse(
        core(1),
        entries: [entry(1, 'info', 'started'), entry(2, 'error', 'failed')],
        total: 2,
        next: 2,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.entries, hasLength(2));
    expect(controller.status, CoreLogsStatus.live);

    final refreshing = controller.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(bridge.requests.last, isEmpty);
    bridge.replies.last.complete(
      logResponse(
        logSource(core(1), window: 'wrong-window'),
        entries: [entry(1, 'info', 'x'), entry(3, 'warning', 'y')],
        total: 2,
        next: 2,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await refreshing;
    expect(controller.status, CoreLogsStatus.stale);
    expect(controller.entries.map((row) => row['text']), ['started', 'failed']);
  });

  test(
    'level filtering stays local and clear empties the actual source',
    () async {
      final bridge = LogBridge();
      final app = logApp(bridge);
      final controller = CoreLogsController(app, poll: const Duration(hours: 1))
        ..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      bridge.replies.single.complete(
        logResponse(
          core(1),
          entries: [
            entry(1, 'debug', 'dns lookup'),
            entry(2, 'info', 'connected'),
            entry(3, 'error', 'timeout token=abc'),
          ],
          total: 3,
          next: 3,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      controller.setLevel('warning');
      expect(controller.visible.map((row) => row['seq']), [3]);
      controller.filter('timeout');
      expect(controller.visible, hasLength(1));
      controller.filter('connected');
      expect(controller.visible, isEmpty);
      controller.filter('');
      controller.setLevel('debug');
      final clearing = controller.clear();
      expect(bridge.requests, hasLength(2));
      expect(bridge.requests.last, {'clear': true});
      expect(controller.entries, hasLength(3));
      bridge.replies.last.complete(logResponse(core(1), next: 3, cleared: 3));
      await clearing;
      expect(controller.entries, isEmpty);
      expect(controller.total, 0);
    },
  );

  test('a new core session resets the local window', () async {
    final bridge = LogBridge();
    final app = logApp(bridge);
    final controller = CoreLogsController(app, poll: const Duration(hours: 1))
      ..setVisible(true);
    addTearDown(() {
      controller.dispose();
      app.dispose();
    });
    bridge.replies.single.complete(
      logResponse(
        core(1),
        entries: [entry(1, 'info', 'old')],
        total: 1,
        next: 1,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    app.publish(
      AppSnapshot(
        phase: 'RUNNING',
        core: CoreSnapshot(
          generation: 2,
          phase: 'READY',
          purpose: 'RUNNING',
          configId: 'main',
          revision: 1,
          composition: '["main",1,[99]]',
        ),
        logSource: CoreSnapshot(
          generation: 2,
          phase: 'READY',
          purpose: 'RUNNING',
          configId: 'main',
          revision: 1,
          composition: '["main",1,[99]]',
          logWindow: '2',
        ),
      ),
    );
    expect(controller.entries, isEmpty);
    expect(bridge.requests.last, isEmpty);
  });

  for (final language in ['zh', 'en']) {
    testWidgets('logs $language keep controls stable with new entries', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = LogBridge();
      final app = logApp(bridge);
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: CoreLogsPage(app: app),
        ),
      );
      final search = find.byType(TextField);
      final rect = tester.getRect(search);
      bridge.replies.single.complete(
        logResponse(
          core(1),
          entries: [entry(1, 'info', 'connected to proxy')],
          total: 1,
          next: 1,
        ),
      );
      await tester.pump();
      expect(tester.getRect(search), rect);
      expect(find.textContaining('connected to proxy'), findsOneWidget);

      await tester.enterText(search, 'missing');
      await tester.pump();
      expect(find.textContaining('connected to proxy'), findsNothing);
      expect(tester.getRect(search), rect);
      await tester.enterText(search, '');
      await tester.pump();

      // Wait for the next actual poll, then verify the warning entry and stable header
      // geometry.
      await tester.pump(const Duration(milliseconds: 700));
      expect(bridge.replies, hasLength(2));
      bridge.replies.last.complete(
        logResponse(
          core(1),
          entries: [
            entry(2, 'warning', 'retrying'),
            entry(3, 'error', 'password=[redacted]'),
          ],
          total: 3,
          next: 3,
        ),
      );
      await tester.pump();
      expect(tester.getRect(search), rect);
      expect(find.textContaining('retrying'), findsOneWidget);
      expect(
        find.textContaining('password=[redacted]', skipOffstage: false),
        findsOneWidget,
      );

      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
      expect(tester.takeException(), isNull);
    });
  }
  group('read passthrough', () {
    testWidgets('log grace does not drain reads or complete a queued clear', (
      tester,
    ) async {
      final bridge = LogBridge();
      final app = logApp(bridge);
      final controller = CoreLogsController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      var cleared = false;
      final clearing = controller.clear().then((_) => cleared = true);
      await tester.pump(const Duration(seconds: 6));
      expect(bridge.requests, hasLength(1));
      expect(controller.loading, isTrue);
      expect(controller.readError!.detail, contains('still pending'));
      expect(cleared, isFalse);
      bridge.replies.first.complete(
        logResponse(
          core(1),
          entries: [entry(1, 'info', 'retired-before-clear')],
          next: 1,
        ),
      );
      await tester.pump();
      expect(controller.entries, isEmpty);
      expect(controller.data, isNull);
      expect(bridge.requests, hasLength(2));
      expect(bridge.requests.last['clear'], isTrue);
      await tester.pump(const Duration(seconds: 6));
      expect(cleared, isFalse);
      expect(controller.loading, isTrue);
      expect(controller.canClear, isFalse);
      final clearedPage = logResponse(core(1), next: 1, cleared: 1);
      bridge.replies.last.complete(clearedPage);
      await clearing;
      expect(controller.data, clearedPage);
      expect(controller.entries, isEmpty);
      expect(controller.readError, isNull);
      expect(controller.loading, isFalse);
      await tester.pump(const Duration(milliseconds: 610));
      bridge.replies.last.complete(
        logResponse(
          core(1),
          entries: [entry(1, 'info', 'older-clear-watermark')],
          next: 1,
        ),
      );
      await tester.pump();
      expect(controller.data, clearedPage);
      expect(controller.entries, isEmpty);
      controller.setVisible(false);
    });

    testWidgets(
      'log raw feedback and entries retain unknown data and native errors',
      (tester) async {
        final bridge = LogBridge();
        final app = logApp(bridge);
        addTearDown(app.dispose);
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [AppTaskNavigatorObserver()],
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: CoreLogsPage(app: app),
          ),
        );
        final row = {
          ...entry(1, 'future-level', 'original: fixture-secret'),
          'future': [false, 0, null, <Object?>[]],
        };
        final value = logResponse(core(1), entries: [row], next: 1);
        value['unknown-envelope'] = '${'x' * 20000}tail';
        bridge.replies.first.complete(value);
        await tester.pump();
        final controller = tester
            .widgetList<ListenableBuilder>(find.byType(ListenableBuilder))
            .map((widget) => widget.listenable)
            .whereType<CoreLogsController>()
            .single;
        expect(find.text('original: fixture-secret'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('log-feedback-raw')));
        await pumpFrames(tester);
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
        await tester.tap(find.byKey(const ValueKey('original-text-copy')));
        await tester.pump();
        expect(
          copied,
          const JsonEncoder.withIndent('  ').convert({
            ...value,
            'logs': {
              ...value['logs'] as Map,
              'retainedBytes': utf8.encode(row['text'] as String).length,
            },
          }),
        );
        final rawRoute = ModalRoute.of(
          tester.element(find.byKey(const ValueKey('original-text-copy'))),
        )!;
        await tester.pageBack();
        await tester.pump();
        expect(rawRoute.isActive, isFalse);
        await tester.pump(
          rawRoute.reverseTransitionDuration + const Duration(microseconds: 1),
        );
        await pumpFrames(tester);
        expect(find.byKey(const ValueKey('original-text-copy')), findsNothing);
        final rawRow = find.byKey(const ValueKey('log-raw-1'));
        expect(rawRow.hitTestable(), findsOneWidget);
        await tester.tap(rawRow);
        await pumpFrames(tester);
        await tester.tap(find.byKey(const ValueKey('original-text-copy')));
        await tester.pump();
        expect(copied, const JsonEncoder.withIndent('  ').convert(row));
        await tester.pageBack();
        await pumpFrames(tester);
        await tester.pump(const Duration(milliseconds: 610));
        bridge.replies.last.completeError(
          PlatformFailure(
            code: 'native',
            message: 'original-log-bridge-cause',
            details: messages.androidErrorNativeReadUnavailable
                .withDetail('original-log-native-cause: fixture-secret')
                .toMap(),
          ),
        );
        await tester.pump();
        expect(
          controller.readError?.detail,
          contains('original-log-native-cause: fixture-secret'),
        );
        await tester.pump();
        expect(
          find.textContaining('original-log-native-cause: fixture-secret'),
          findsNothing,
        );
        await pumpFrames(tester);
        expect(find.byType(AlertDialog), findsNothing);
        await openLogActions(tester);
        final errorDetails = find.byKey(const ValueKey('log-error-details'));
        await tester.ensureVisible(errorDetails);
        await pumpFrames(tester);
        expect(errorDetails.hitTestable(), findsOneWidget);
        await tester.tap(errorDetails);
        await pumpFrames(tester);
        expect(find.byType(AlertDialog), findsOneWidget);
        final technicalDetails = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byKey(const ValueKey('operation-technical-details')),
        );
        await tester.ensureVisible(technicalDetails);
        await pumpFrames(tester);
        expect(technicalDetails.hitTestable(), findsOneWidget);
        await tester.tap(technicalDetails);
        await pumpFrames(tester);
        expect(
          find.textContaining('original-log-native-cause: fixture-secret'),
          findsOneWidget,
        );
        expect(
          find.textContaining('original-log-bridge-cause'),
          findsOneWidget,
        );
        final technicalText = tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('operation-technical-text')),
            )
            .data;
        final copy = find.byKey(const ValueKey('operation-technical-copy'));
        await tester.ensureVisible(copy);
        await pumpFrames(tester);
        expect(copy.hitTestable(), findsOneWidget);
        await tester.tap(copy);
        await tester.pump();
        expect(copied, technicalText);
        expect(copied, contains('original-log-native-cause: fixture-secret'));
        expect(copied, contains('original-log-bridge-cause'));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}
