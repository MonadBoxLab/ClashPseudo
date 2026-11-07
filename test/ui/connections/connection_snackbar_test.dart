import 'dart:async';

import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/connection_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/ui/components/collections/collection_workspace.dart';
import 'package:clash_pseudo/src/ui/connections/connection_controller.dart';
import 'package:clash_pseudo/src/ui/connections/connections_page.dart';
import 'package:clash_pseudo/src/ui/navigation/app_shell.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/connection_fakes.dart' as fixtures;

class _NonlinearScaler extends TextScaler {
  const _NonlinearScaler();
  @override
  double scale(double fontSize) =>
      fontSize <= 14 ? fontSize * 2 : fontSize * 1.6;
  @override
  double get textScaleFactor => 2;
}

ConnectionSnapshot _failed(
  String error, {
  int session = 0,
  CoreSnapshot source = fixtures.core,
}) => ConnectionSnapshot.fromMap({
  'generation': source.generation,
  'configId': source.configId,
  'revision': source.revision,
  'composition': source.composition,
  'purpose': 'RUNNING',
  'sessionGeneration': session,
  'sampleAgeMs': 0,
  'error': error,
  'connections': [fixtures.row('one')],
});

void main() {
  late fixtures.ConnectionBridgeFake bridge;
  late fixtures.ConnectionAppFake app;
  setUp(() {
    bridge = fixtures.ConnectionBridgeFake();
    app = fixtures.ConnectionAppFake(bridge)
      ..preferencesLoaded = true
      ..overridesLoaded = true;
  });
  tearDown(() => app.dispose());

  ConnectionController controller(WidgetTester tester) =>
      (tester.state(find.byType(ConnectionsPage)) as dynamic).controller
          as ConnectionController;

  Future<void> show(
    WidgetTester tester, {
    Size size = const Size(400, 900),
    String language = 'zh',
    TextScaler scaler = TextScaler.noScaling,
    bool dark = false,
    bool reduced = false,
    bool shell = false,
    ValueNotifier<bool>? activity,
    GlobalKey<ScaffoldMessengerState>? rootMessenger,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    final page = shell ? AppShell(controller: app) : ConnectionsPage(app: app);
    final ownedPage = activity == null
        ? page
        : ValueListenableBuilder<bool>(
            valueListenable: activity,
            child: page,
            builder: (_, active, child) => AppTaskActivity(
              active: active,
              isActiveNow: () => activity.value,
              child: child!,
            ),
          );
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: rootMessenger,
        navigatorObservers: [AppTaskNavigatorObserver()],
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale(language),
        theme: dark ? AppTheme.dark : AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: scaler, disableAnimations: reduced),
          child: child!,
        ),
        home: rootMessenger == null ? ownedPage : Scaffold(body: ownedPage),
      ),
    );
    if (shell) {
      await tester.pump();
      tester
          .widget<AppTaskScope>(find.byType(AppTaskScope))
          .open(AppTask.connections);
    }
    await tester.pumpAndSettle();
  }

  Future<void> fail(WidgetTester tester, [String text = '原始读取错误']) async {
    bridge.data = _failed(
      text,
      session: app.state.generation,
      source: app.state.core,
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  }

  Future<void> openActions(WidgetTester tester, {bool detail = false}) async {
    await tester.tap(
      find.byKey(
        ValueKey(
          detail ? 'connection-detail-actions' : 'connection-list-actions',
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder getNotice() => find.byType(SnackBar);
  Finder noticeDetails() =>
      find.descendant(of: getNotice(), matching: find.byType(TextButton));
  Finder closeNotice() =>
      find.descendant(of: getNotice(), matching: find.byType(IconButton));

  for (final language in ['zh', 'en']) {
    for (final active in [true, false]) {
      testWidgets(
        'healthy list and details show actual records without status explanations or error entries $language/$active',
        (tester) async {
          bridge.data = fixtures.snapshot([
            {...fixtures.row('one'), 'active': active},
          ]);
          await show(tester, language: language);
          final strings = lookupAppLocalizations(Locale(language));
          final listError = find.byKey(
            const ValueKey('connection-list-error-details'),
          );
          expect(listError, findsNothing);
          expect(
            find.byKey(const ValueKey('connection-capacity-notice')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey('connection-list-status')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey('connection-list-status-text')),
            findsNothing,
          );
          expect(find.byType(SnackBar), findsNothing);
          await openActions(tester);
          expect(listError, findsNothing);
          expect(
            find.byKey(const ValueKey('connection-clear-inactive')),
            findsOneWidget,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          await tester.tap(find.text('one.fixture.test'));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('connection-detail-error')),
            findsNothing,
          );
          final status = find.byKey(const ValueKey('connection-detail-status'));
          expect(
            find.descendant(
              of: status,
              matching: find.text(
                active ? strings.connectionActive : strings.connectionInactive,
              ),
            ),
            findsOneWidget,
          );
          await tester.tap(status);
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.byTooltip(strings.errorDetails), findsNothing);
          await openActions(tester, detail: true);
          expect(
            find.byKey(const ValueKey('connection-detail-error')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey('connection-disconnect')),
            findsOneWidget,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets(
    'read failure uses a persistent SnackBar without moving filters or list viewport',
    (tester) async {
      await show(tester);
      final viewport = tester.getRect(find.byType(CustomScrollView));
      final filter = tester.getRect(find.text('全部连接'));
      final current = controller(tester);
      await fail(tester);
      expect(getNotice(), findsOneWidget);
      expect(tester.widget<SnackBar>(getNotice()).persist, isTrue);
      expect(find.byKey(const ValueKey('connection-list-error')), findsNothing);
      expect(tester.getRect(find.byType(CustomScrollView)), viewport);
      expect(tester.getRect(find.text('全部连接')), filter);
      expect(controller(tester), same(current));
      expect(current.error, contains('原始读取错误'));
      final state = tester.state(getNotice());
      for (var i = 0; i < 4; i++) {
        await fail(tester, '变化的错误 $i');
        expect(tester.state(getNotice()), same(state));
        expect(current.error, contains('变化的错误 $i'));
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final dismissal in ['close', 'swipe', 'action']) {
    testWidgets(
      '$dismissal keeps the current failure cycle quiet and explicit read success permits a new failure notice',
      (tester) async {
        await show(tester);
        await fail(tester);
        if (dismissal == 'close') {
          await tester.tap(closeNotice());
        } else if (dismissal == 'swipe') {
          await tester.drag(getNotice(), const Offset(0, 400));
        } else {
          await tester.tap(noticeDetails());
        }
        await tester.pumpAndSettle();
        if (dismissal == 'action') {
          expect(find.byType(AlertDialog), findsOneWidget);
          await tester.tap(find.text('关闭'));
          await tester.pumpAndSettle();
        }
        expect(getNotice(), findsNothing);
        expect(controller(tester).error, contains('原始读取错误'));
        await fail(tester, '同轮下一错误');
        expect(getNotice(), findsNothing);
        final current = controller(tester);
        final revision = current.readRevision;
        current.setVisible(false);
        expect(current.errorMessage, isNull);
        expect(current.readRevision, revision);
        current.setVisible(true);
        await tester.pumpAndSettle();
        expect(getNotice(), findsNothing);
        await openActions(tester);
        expect(
          find.byKey(const ValueKey('connection-list-error-details')),
          findsNothing,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        bridge.data = fixtures.snapshot([fixtures.row('one')]);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(current.readFailed, isFalse);
        expect(
          find.byKey(const ValueKey('connection-list-error-details')),
          findsNothing,
        );
        await fail(tester, '恢复后的错误');
        expect(getNotice(), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'action remains available in narrow-screen details and Dialog captures the complete error without later reads overwriting it',
    (tester) async {
      await show(tester);
      await tester.tap(find.text('one.fixture.test'));
      await tester.pumpAndSettle();
      final current = controller(tester);
      final lease = current.detailLease;
      final detailScrollable = find
          .descendant(
            of: find.byKey(const ValueKey('connection-detail-scroll')),
            matching: find.byType(Scrollable),
          )
          .first;
      final scroll = tester.state(detailScrollable);
      await fail(tester, '原始 cause\nSuppressed: 原文\nfuture: [false, null]');
      expect(getNotice(), findsOneWidget);
      expect(
        tester
            .state<CollectionWorkspaceState>(find.byType(CollectionWorkspace))
            .masterVisible,
        isFalse,
      );
      await tester.tap(noticeDetails());
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      current.errorMessage = messages.trafficUpdateFailed.withDetail('下一次错误');
      app.changed();
      await tester.pump();
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
        '原始 cause\nSuppressed: 原文\nfuture: [false, null]',
      );
      expect(current.detailLease, same(lease));
      expect(tester.state(detailScrollable), same(scroll));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'fixed action menu stays unchanged across errors and automatic notices retain search focus, selection, and composing',
    (tester) async {
      await show(tester, size: const Size(320, 900));
      await tester.tap(find.byTooltip('搜索连接'));
      await tester.pumpAndSettle();
      const value = TextEditingValue(
        text: 'one',
        selection: TextSelection(baseOffset: 1, extentOffset: 2),
        composing: TextRange(start: 0, end: 3),
      );
      tester.testTextInput.updateEditingValue(value);
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      final rect = tester.getRect(find.byType(TextField));
      expect(
        find.byKey(const ValueKey('connection-list-error-details')),
        findsNothing,
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      await fail(tester);
      expect(field.focusNode!.hasFocus, isTrue);
      expect(field.controller!.value, value);
      expect(
        find.byKey(const ValueKey('connection-list-actions')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('connection-list-error-details')),
        findsNothing,
      );
      expect(tester.getRect(find.byType(TextField)), rect);
      expect(tester.getBottomLeft(getNotice()).dy, lessThanOrEqualTo(600));
      bridge.data = fixtures.snapshot([fixtures.row('one')]);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(field.focusNode!.hasFocus, isTrue);
      expect(field.controller!.value, value);
      expect(getNotice(), findsNothing);
      expect(
        find.byKey(const ValueKey('connection-list-error-details')),
        findsNothing,
      );
      expect(tester.getRect(find.byType(TextField)), rect);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final change in ['task', 'modal', 'page', 'interactive']) {
    testWidgets(
      '$change coverage removes unseen notices and a valid read reconfirms them on return',
      (tester) async {
        final activity = ValueNotifier(true);
        addTearDown(activity.dispose);
        await show(tester, activity: activity);
        await fail(tester);
        final action = tester.widget<TextButton>(noticeDetails()).onPressed!;
        final navigator = Navigator.of(
          tester.element(find.byType(ConnectionsPage)),
        );
        if (change == 'task') {
          activity.value = false;
        } else if (change == 'interactive') {
          app.setInteractive(false);
        } else if (change == 'modal') {
          unawaited(
            showDialog<void>(
              context: tester.element(find.byType(ConnectionsPage)),
              builder: (_) => const AlertDialog(content: Text('其他任务弹窗')),
            ),
          );
        } else {
          unawaited(
            navigator.push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('其他页面')),
              ),
            ),
          );
        }
        action();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('operation-technical-details')),
          findsNothing,
        );
        expect(getNotice(), findsNothing);
        if (change == 'task') {
          activity.value = true;
        } else if (change == 'interactive') {
          app.setInteractive(true);
        } else {
          navigator.pop();
        }
        await tester.pumpAndSettle();
        await fail(tester, '返回后的有效读取');
        expect(getNotice(), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        action();
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'task exit before post-frame invalidates the pending display callback',
    (tester) async {
      final activity = ValueNotifier(true);
      addTearDown(activity.dispose);
      await show(tester, activity: activity);
      bridge.data = _failed('准备展示');
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => activity.value = false,
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(getNotice(), findsNothing);
      activity.value = true;
      await tester.pumpAndSettle();
      await fail(tester);
      expect(getNotice(), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final replacement in ['core', 'session', 'storageEpoch']) {
    testWidgets(
      '$replacement replacement invalidates old actions and closed callbacks',
      (tester) async {
        await show(tester);
        await fail(tester);
        final action = tester.widget<TextButton>(noticeDetails()).onPressed!;
        final close = tester.widget<IconButton>(closeNotice()).onPressed!;
        app.state = AppSnapshot(
          phase: 'RUNNING',
          generation: replacement == 'session' ? 1 : 0,
          storageEpoch: replacement == 'storageEpoch' ? 1 : 0,
          core: replacement == 'core'
              ? const CoreSnapshot(
                  phase: 'READY',
                  purpose: 'RUNNING',
                  generation: 8,
                  configId: 'one',
                  revision: 1,
                  composition: 'two',
                )
              : fixtures.core,
        );
        app.changed();
        action();
        close();
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        await fail(tester, '新来源失败');
        expect(getNotice(), findsOneWidget);
        action();
        close();
        await tester.pumpAndSettle();
        expect(getNotice(), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'local Messenger preserves other feature feedback and shows one notice across two panes',
    (tester) async {
      final root = GlobalKey<ScaffoldMessengerState>();
      await show(tester, size: const Size(1200, 900), rootMessenger: root);
      root.currentState!.showSnackBar(
        const SnackBar(content: Text('其他功能反馈'), persist: true),
      );
      await tester.tap(find.text('one.fixture.test'));
      await tester.pumpAndSettle();
      await fail(tester);
      expect(getNotice(), findsNWidgets(2));
      expect(noticeDetails(), findsOneWidget);
      app.setInteractive(false);
      await tester.pumpAndSettle();
      expect(getNotice(), findsOneWidget);
      expect(find.text('其他功能反馈'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'cleanup and release failures retain causes in SnackBar without later reads overwriting them',
    (tester) async {
      await show(tester);
      final current = controller(tester);
      final revision = current.readRevision;
      final pending = Completer<ConnectionSnapshot>();
      bridge.pending = pending;
      bridge.clearFailure = StateError('清理原始错误');
      await current.clearInactive();
      await tester.pumpAndSettle();
      expect(current.errorSource, ConnectionErrorSource.clearInactive);
      expect(current.readRevision, revision);
      expect(getNotice(), findsOneWidget);
      pending.complete(bridge.data);
      bridge.pending = null;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      expect(current.readFailed, isFalse);
      expect(getNotice(), findsOneWidget);
      await tester.tap(noticeDetails());
      await tester.pumpAndSettle();
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
        contains('清理原始错误'),
      );
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      current.openDetail(current.data!.records.first);
      bridge.releaseFailure = StateError('释放原始错误');
      current.closeDetail();
      await tester.pumpAndSettle();
      expect(getNotice(), findsOneWidget);
      await tester.tap(noticeDetails());
      await tester.pumpAndSettle();
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
        contains('释放原始错误'),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final sample in [
    (280.0, 600.0, 'zh', TextScaler.noScaling, false),
    (320.0, 900.0, 'en', TextScaler.linear(2), true),
    (599.0, 480.0, 'zh', TextScaler.linear(2), false),
    (600.0, 1000.0, 'en', TextScaler.noScaling, true),
    (839.0, 600.0, 'zh', TextScaler.noScaling, false),
    (840.0, 1000.0, 'en', TextScaler.linear(2), true),
    (1200.0, 900.0, 'zh', const _NonlinearScaler(), false),
    (1600.0, 1200.0, 'en', TextScaler.noScaling, true),
  ]) {
    testWidgets('actual AppShell workspace placement $sample', (tester) async {
      await show(
        tester,
        size: Size(sample.$1, sample.$2),
        language: sample.$3,
        scaler: sample.$4,
        dark: sample.$5,
        reduced: true,
        shell: true,
      );
      await fail(tester);
      expect(getNotice(), findsOneWidget);
      final actionRect = tester.getRect(noticeDetails());
      final closeRect = tester.getRect(closeNotice());
      expect(actionRect.height, greaterThanOrEqualTo(48));
      expect(closeRect.height, greaterThanOrEqualTo(48));
      final material = find
          .descendant(of: getNotice(), matching: find.byType(Material))
          .first;
      final rect = tester.getRect(material);
      expect(rect.width, lessThanOrEqualTo(560));
      if (find.byType(NavigationBar).evaluate().isNotEmpty) {
        expect(
          rect.bottom,
          lessThanOrEqualTo(tester.getTopLeft(find.byType(NavigationBar)).dy),
        );
      }
      if (find.byType(NavigationRail).evaluate().isNotEmpty) {
        expect(
          rect.left,
          greaterThanOrEqualTo(
            tester.getTopRight(find.byType(NavigationRail)).dx,
          ),
        );
      }
      expect(noticeDetails().hitTestable(), findsOneWidget);
      expect(closeNotice().hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'temporary missing errors or stale samples do not end a failure cycle; only successful reads re-enable notices',
    (tester) async {
      await show(tester);
      await fail(tester);
      await tester.tap(closeNotice());
      await tester.pumpAndSettle();
      final current = controller(tester);
      final revision = current.readRevision;
      bridge.data = fixtures.snapshot([fixtures.row('one')], sampleAgeMs: 6000);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(current.errorMessage, isNull);
      expect(current.readRevision, revision);
      await fail(tester, '过期样本之后的失败');
      expect(getNotice(), findsNothing);
      bridge.data = fixtures.snapshot([fixtures.row('one')]);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      await fail(tester, '明确成功之后的失败');
      expect(getNotice(), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'recovery and failure in one frame prevent old closed completion from closing the new cycle notice',
    (tester) async {
      await show(tester);
      await fail(tester);
      final old = tester.widget<TextButton>(noticeDetails()).onPressed!;
      bridge.data = fixtures.snapshot([fixtures.row('one')]);
      await tester.pump(const Duration(seconds: 1));
      bridge.data = _failed('新一轮');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(getNotice(), findsOneWidget);
      old();
      await tester.pumpAndSettle();
      expect(getNotice(), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('dismissed failure remains quiet across task switches', (
    tester,
  ) async {
    await show(tester, shell: true);
    await fail(tester);
    await tester.tap(closeNotice());
    await tester.pumpAndSettle();
    final scope = tester.widget<AppTaskScope>(find.byType(AppTaskScope));
    scope.open(AppTask.settings);
    await tester.pumpAndSettle();
    scope.open(AppTask.connections);
    await tester.pumpAndSettle();
    await fail(tester, '同来源仍失败');
    expect(getNotice(), findsNothing);
    await openActions(tester);
    expect(
      find.byKey(const ValueKey('connection-list-error-details')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'filter menu pauses and resumes the current notice without adding reads',
    (tester) async {
      Future<void> paintNotice() async {
        for (var frame = 0; frame < 3; frame++) {
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
      }

      Future<void> nextRead() async {
        final before = bridge.reads;
        // Stop at the poll instead of consuming the rest of its next interval.
        for (var tick = 0; tick < 100 && bridge.reads == before; tick++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        await tester.pump();
        expect(bridge.reads, before + 1);
      }

      await show(tester, reduced: true);
      bridge.data = _failed('原始读取错误');
      await nextRead();
      // Both notice animations finish before the next one-second poll.
      await paintNotice();
      final reads = bridge.reads;
      final oldDetails = tester.widget<TextButton>(noticeDetails()).onPressed!;
      await tester.tap(find.text('全部连接'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(MenuItemButton), findsNWidgets(3));
      expect(getNotice(), findsNothing);
      expect(bridge.reads, reads);
      oldDetails();
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(bridge.reads, reads);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await paintNotice();
      expect(find.byType(MenuItemButton), findsNothing);
      expect(getNotice().hitTestable(), findsOneWidget);
      expect(noticeDetails().hitTestable(), findsOneWidget);
      expect(bridge.reads, reads);
      final resumed = tester.state(getNotice());
      bridge.data = _failed('菜单关闭后的有效读取');
      await nextRead();
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump();
      }
      expect(getNotice(), findsOneWidget);
      expect(tester.state(getNotice()), same(resumed));
      expect(bridge.reads, reads + 1);

      await tester.tap(closeNotice().hitTestable());
      await paintNotice();
      expect(getNotice(), findsNothing);
      expect(bridge.reads, reads + 1);
      bridge.data = _failed('关闭提示后的同轮失败');
      await nextRead();
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump();
      }
      expect(getNotice(), findsNothing);
      expect(bridge.reads, reads + 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final width in [400.0, 1200.0]) {
    testWidgets(
      'actual AppShell deducts safe area and IME insets once width=$width',
      (tester) async {
        await show(tester, size: Size(width, 900), shell: true);
        tester.view.viewPadding = const FakeViewPadding(
          top: 24,
          bottom: 20,
          left: 8,
          right: 8,
        );
        tester.view.padding = const FakeViewPadding(
          top: 24,
          bottom: 20,
          left: 8,
          right: 8,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('搜索连接'));
        await tester.pumpAndSettle();
        final current = controller(tester);
        final view = find.byType(CustomScrollView);
        final before = tester.getRect(view);
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        tester.view.padding = const FakeViewPadding(top: 24, left: 8, right: 8);
        await tester.pumpAndSettle();
        final after = tester.getRect(view);
        expect(after.top, before.top);
        final navigationTop =
            find.byType(NavigationBar).hitTestable().evaluate().isEmpty
            ? 900.0
            : tester.getTopLeft(find.byType(NavigationBar).hitTestable()).dy;
        expect(
          after.bottom,
          closeTo((navigationTop < 640 ? navigationTop : 640) - 16, .01),
        );
        await fail(tester);
        expect(controller(tester), same(current));
        expect(tester.getRect(view), after);
        final rect = tester.getRect(
          find
              .descendant(of: getNotice(), matching: find.byType(Material))
              .first,
        );
        expect(rect.bottom, lessThanOrEqualTo(640));
        expect(rect.left, greaterThanOrEqualTo(8));
        expect(rect.right, lessThanOrEqualTo(width - 8));
        expect(
          tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
          isTrue,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'middle reading anchor is preserved and closing the notice leaves the last row readable without extra trailing space',
    (tester) async {
      bridge.data = fixtures.snapshot(
        List.generate(80, (i) => fixtures.row(i.toString().padLeft(2, '0'))),
      );
      await show(tester);
      final view = find.byType(CustomScrollView);
      await tester.drag(view, const Offset(0, -800));
      await tester.pumpAndSettle();
      final scroll = tester.widget<CustomScrollView>(view).controller!;
      final viewport = tester.getRect(view);
      final target = tester
          .widgetList<Text>(find.byType(Text))
          .firstWhere(
            (text) =>
                (text.data?.endsWith('.fixture.test') ?? false) &&
                tester.getTopLeft(find.text(text.data!)).dy >= viewport.top,
          )
          .data!;
      final anchor = tester.getRect(find.text(target));
      bridge.fail = true;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(tester.getRect(view), viewport);
      expect(tester.getRect(find.text(target)), anchor);
      expect(tester.widget<CustomScrollView>(view).controller, same(scroll));
      final offset = scroll.offset;
      final extent = scroll.position.maxScrollExtent;
      await tester.tap(closeNotice());
      await tester.pumpAndSettle();
      expect(scroll.offset, offset);
      expect(tester.getRect(find.text(target)), anchor);
      expect(scroll.position.maxScrollExtent, extent);
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final last = find.text('79.fixture.test');
      expect(last.hitTestable(), findsOneWidget);
      final row = find.ancestor(of: last, matching: find.byType(InkWell)).first;
      expect(tester.getRect(row).bottom, closeTo(viewport.bottom, 1));
      expect(tester.getRect(row).top, greaterThanOrEqualTo(viewport.top));
      expect(controller(tester).errorMessage, isNotNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'consecutive resizes retain controller and lease; very short windows defer and then restore unseen notices',
    (tester) async {
      await show(tester, size: const Size(1200, 900));
      await tester.tap(find.text('one.fixture.test'));
      await tester.pumpAndSettle();
      final current = controller(tester);
      final lease = current.detailLease;
      await fail(tester);
      for (final size in [
        const Size(320, 900),
        const Size(840, 600),
        const Size(1600, 1000),
        const Size(280, 80),
      ]) {
        tester.view.physicalSize = size;
        await tester.pump();
        await tester.pumpAndSettle();
        expect(controller(tester), same(current));
        expect(current.detailLease, same(lease));
        expect(tester.takeException(), isNull);
      }
      expect(getNotice(), findsNothing);
      tester.view.physicalSize = const Size(400, 900);
      await tester.pumpAndSettle();
      expect(getNotice(), findsOneWidget);
      await tester.tap(closeNotice());
      await tester.pumpAndSettle();
      expect(find.text('原始数据'), findsNothing);
      expect(current.detailLease, same(lease));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
