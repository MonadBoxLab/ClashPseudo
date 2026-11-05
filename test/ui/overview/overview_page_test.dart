import 'dart:async';
import 'dart:convert';

import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:clash_pseudo/src/ui/overview/widgets/status_hero.dart';

import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/navigation/app_shell.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_feedback.dart';
import 'package:clash_pseudo/src/model/connection_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/overview/overview_page.dart';
import 'package:clash_pseudo/src/ui/configs/configs_page.dart';
import 'package:clash_pseudo/src/ui/overview/widgets/traffic_panel.dart';
import 'package:clash_pseudo/src/ui/overview/widgets/power_ripples.dart';
import 'package:clash_pseudo/src/ui/overview/widgets/session_uptime.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';

import '../../support/core_runtime_fixture.dart';

class ViewBridge extends AppBridge {
  int vpnSettingsOpens = 0;
  Completer<void>? vpnSettingsPending;
  @override
  Future<void> openVpnSettings() {
    vpnSettingsOpens++;
    return vpnSettingsPending?.future ?? Future.value();
  }

  @override
  Future<ConnectionSnapshot> recentConnections({
    Map<String, Object?>? detail,
    String? detailOwner,
  }) async => ConnectionSnapshot.fromMap({
    'generation': 0,
    'configId': '',
    'revision': 0,
    'phase': 'STOPPED',
    'fresh': false,
    'connections': [],
  });
  int cleanupReads = 0;
  @override
  Future<Map<String, dynamic>> coreCleanupCandidates() async {
    cleanupReads++;
    return {
      'home': '/core',
      'items': [
        {'path': 'cache.db', 'kind': 'cache'},
      ],
    };
  }

  @override
  Future<void> releaseConnectionDetail({required String owner}) async {}
}

class ViewController extends AppController {
  ViewController() : super(ViewBridge()) {
    loading = false;
    configsLoaded = true;
    state = const AppSnapshot(phase: 'STOPPED');
  }
  final commands = <Map<String, Object?>>[];
  @override
  Future<void> refresh() async {}

  @override
  Future<String?> submit(
    Map<String, Object?> command, {
    bool automatic = false,
  }) async {
    lastCommandAutomatic = automatic;
    lastCommand = Map.of(command);
    commands.add(command);
    return 'operation-${commands.length}';
  }

  void changed() => notifyListeners();
}

ConfigEntry config(String id, {int revision = 1, String body = 'config'}) =>
    ConfigEntry(
      id: id,
      name: '配置 $id',
      source: 'https://example.test/config?token=private',
      revision: revision,
      body: body,
    );

void main() {
  late ViewController controller;
  late AppTaskNavigatorObserver taskRoutes;
  setUp(() {
    setMessageLanguage(AppLanguage.zh);
    controller = ViewController();
    taskRoutes = AppTaskNavigatorObserver();
  });
  tearDown(() {
    controller.dispose();
    setMessageLanguage(AppLanguage.system);
  });
  final power = find.byKey(const ValueKey('power-button'));

  Future<void> show(
    WidgetTester tester, {
    bool dark = false,
    double scale = 1,
    Locale locale = const Locale('zh'),
    EdgeInsets padding = EdgeInsets.zero,
    bool active = true,
    bool shell = false,
    bool Function()? isActiveNow,
  }) => tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [taskRoutes],
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      theme: dark ? AppTheme.dark : AppTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale), padding: padding),
        child: child!,
      ),
      home: AppTaskActivity(
        active: active,
        isActiveNow: isActiveNow,
        child: shell
            ? AppShell(controller: controller)
            : OperationFeedback(
                controller: controller,
                child: OverviewPage(controller: controller, active: active),
              ),
      ),
    ),
  );

  AppSnapshot recovery({
    String processId = 'process-one',
    String inputId = 'input-one',
    int generation = 1,
    bool vpnIntent = false,
    bool lanIntent = false,
    AppMessage? error,
  }) => AppSnapshot(
    phase: 'STOPPED',
    generation: 1,
    recoveryRequired: true,
    vpnIntent: vpnIntent,
    lanIntent: lanIntent,
    error:
        error ??
        messages.operationFailed.withDetail('native recovery original'),
    core: CoreSnapshot(
      phase: 'FAILED',
      processId: processId,
      inputId: inputId,
      generation: generation,
      configId: 'one',
      revision: 1,
      composition: 'composition-one',
      purpose: 'RUNNING',
    ),
  );

  Future<void> openRecovery(WidgetTester tester) async {
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    final notice = find.byType(SnackBar);
    expect(notice, findsOneWidget);
    final strings = AppLocalizations.of(tester.element(notice));
    final details = find.descendant(
      of: notice,
      matching: find.widgetWithText(TextButton, strings.errorDetails),
    );
    expect(details.hitTestable(), findsOneWidget);
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('overview-core-recovery')),
      findsOneWidget,
    );
    expect(find.textContaining('native recovery original'), findsOneWidget);
  }

  for (final locale in const [Locale('zh'), Locale('en')]) {
    for (final width in [320.0, 1000.0]) {
      testWidgets('恢复提示不改变 Overview 正文，详情可再次打开 $locale/$width', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1000);
        addTearDown(tester.view.reset);
        controller.collection = ConfigCollection(
          entries: [config('one')],
          selectedId: 'one',
        );
        await show(tester, locale: locale, scale: 2, shell: true);
        await tester.pumpAndSettle();
        final page = tester.state(find.byType(OverviewPage));
        final scroll = tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position;
        final pixels = scroll.pixels;
        final keys = [
          'power-button',
          'config-identity',
          'mode-trigger',
          'network-surface',
          'traffic-download-reading',
          'traffic-upload-reading',
        ];
        final rects = {
          for (final key in keys)
            key: tester.getRect(find.byKey(ValueKey(key))),
        };
        controller.state = recovery();
        controller.changed();
        for (final ms in [0, 16, 100, 320]) {
          await tester.pump(Duration(milliseconds: ms));
          expect(tester.state(find.byType(OverviewPage)), same(page));
          expect(
            tester
                .state<ScrollableState>(find.byType(Scrollable).first)
                .position,
            same(scroll),
          );
          expect(scroll.pixels, pixels);
          for (final entry in rects.entries) {
            expect(
              tester.getRect(find.byKey(ValueKey(entry.key))),
              entry.value,
            );
          }
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.textContaining('native recovery original'), findsNothing);
        }
        await openRecovery(tester);
        final strings = AppLocalizations.of(
          tester.element(find.byType(AlertDialog)),
        );
        expect(find.text(strings.coreRecoveryRestart), findsOneWidget);
        expect(find.text(strings.coreRecoverySelect), findsOneWidget);
        expect(find.text(strings.coreCleanupSelect), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, strings.close));
        await tester.pumpAndSettle();
        controller.changed();
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsNothing);
        final issue = find.byKey(const ValueKey('status-details'));
        await tester.ensureVisible(issue);
        await tester.pumpAndSettle();
        await tester.tap(issue);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('overview-core-recovery')),
          findsNothing,
        );
        expect(controller.commands, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  for (final (vpnIntent, lanIntent, expected) in [
    (false, false, true),
    (false, true, false),
    (true, true, true),
  ]) {
    testWidgets('恢复详情中的 Restart 保留接管意图 $vpnIntent/$lanIntent', (tester) async {
      controller.collection = ConfigCollection(
        entries: [config('one')],
        selectedId: 'one',
      );
      controller.state = recovery(vpnIntent: vpnIntent, lanIntent: lanIntent);
      await show(tester, shell: true);
      await openRecovery(tester);
      final strings = AppLocalizations.of(
        tester.element(find.byType(AlertDialog)),
      );
      await tester.tap(
        find.widgetWithText(FilledButton, strings.coreRecoveryRestart),
      );
      await tester.pumpAndSettle();
      expect(controller.commands, [
        {'action': 'start', 'vpnIntent': expected},
      ]);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('恢复详情中的 Select 打开配置管理', (tester) async {
    controller.state = recovery();
    await show(tester, shell: true);
    await openRecovery(tester);
    final strings = AppLocalizations.of(
      tester.element(find.byType(AlertDialog)),
    );
    await tester.tap(
      find.widgetWithText(TextButton, strings.coreRecoverySelect),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(ConfigsPage), findsOneWidget);
    expect(controller.commands, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('恢复详情保留文件选择、取消和真实 cleanup 提交', (tester) async {
    controller.state = recovery();
    await show(tester, shell: true);
    await openRecovery(tester);
    final parent = tester.element(find.byType(AlertDialog));
    final strings = AppLocalizations.of(
      tester.element(find.byType(AlertDialog)),
    );
    Future<void> choose() async {
      final cleanup = find.widgetWithText(ListTile, strings.coreCleanupSelect);
      await tester.ensureVisible(cleanup);
      await tester.tap(cleanup);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNWidgets(2));
      expect(controller.commands, isEmpty);
      final file = find.byKey(
        const ValueKey<(String, dynamic)>(('cleanup-file', 'cache.db')),
      );
      expect(file, findsOneWidget);
      await tester.tap(
        find.descendant(of: file, matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(file).value, isTrue);
    }

    await choose();
    await tester.tap(find.widgetWithText(TextButton, strings.cancel));
    await tester.pumpAndSettle();
    expect(tester.element(find.byType(AlertDialog)), same(parent));
    expect(controller.commands, isEmpty);
    await choose();
    final confirm = find.widgetWithText(
      FilledButton,
      strings.coreCleanupDeleteSelected,
    );
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    expect(confirm.hitTestable(), findsOneWidget);
    await tester.tap(confirm);
    // cleanup 尚未完成，先结束确认弹窗的过渡，不等待按钮内的进度动画。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.commands.single, {
      'action': 'scheduleCoreCleanup',
      'paths': ['cache.db'],
      'restart': false,
      'storageEpoch': controller.storageEpoch,
    });
    expect((controller.platform as ViewBridge).cleanupReads, 2);
    controller.state = AppSnapshot(
      phase: 'STOPPED',
      recoveryRequired: true,
      generation: 1,
      core: controller.state.core,
      resultId: 'operation-1',
      resultSuccess: true,
      resultMessage: messages.operationFinished,
    );
    controller.changed();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final change in [
    'process',
    'input',
    'generation',
    'foreground',
    'task',
    'page',
  ]) {
    testWidgets('恢复详情的旧动作在来源变化后失效 $change', (tester) async {
      var live = true;
      controller.collection = ConfigCollection(
        entries: [config('one')],
        selectedId: 'one',
      );
      final original = recovery();
      controller.state = original;
      await show(tester, isActiveNow: () => live, shell: true);
      await openRecovery(tester);
      final strings = AppLocalizations.of(
        tester.element(find.byType(AlertDialog)),
      );
      final invoke = tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, strings.coreRecoveryRestart),
          )
          .onPressed!;
      switch (change) {
        case 'process':
          controller.state = recovery(processId: 'process-two');
        case 'input':
          controller.state = recovery(inputId: 'input-two');
        case 'generation':
          controller.state = recovery(generation: 2);
        case 'foreground':
          controller.setForeground(false);
        case 'task':
          live = false;
        case 'page':
          unawaited(
            Navigator.of(tester.element(find.byType(AlertDialog))).push<void>(
              MaterialPageRoute(
                builder: (_) => const Scaffold(body: Text('another page')),
              ),
            ),
          );
      }
      controller.changed();
      invoke();
      controller.state = original;
      if (change == 'foreground') controller.setForeground(true);
      live = true;
      controller.changed();
      invoke();
      await tester.pumpAndSettle();
      expect(controller.commands, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final change in ['process', 'input']) {
    testWidgets('旧恢复提示拒绝同 generation 的 Core 替换 $change', (tester) async {
      final original = recovery();
      controller.state = original;
      await show(tester, shell: true);
      await tester.pumpAndSettle();
      final invoke = tester
          .widget<TextButton>(
            find.descendant(
              of: find.byType(SnackBar),
              matching: find.byType(TextButton),
            ),
          )
          .onPressed!;
      controller.state = recovery(
        processId: change == 'process' ? 'process-two' : 'process-one',
        inputId: change == 'input' ? 'input-two' : 'input-one',
        error: original.errorMessage,
      );
      invoke();
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(controller.commands, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final locale in const [Locale('zh'), Locale('en')]) {
    for (final modeFailed in [false, true]) {
      for (final confirmed in [false, true]) {
        testWidgets(
          '真实 AppRuntime 到 Overview 的 Stop 投影 $locale modeFailed=$modeFailed confirmed=$confirmed',
          (tester) async {
            tester.view.physicalSize = const Size(390, 1000);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final fixture = (await tester.runAsync(
              () => CoreRuntimeFixture.create(),
            ))!;
            final app = AppController(AppBridge(), store: fixture.store);
            final (release, entered) = (await tester.runAsync(
              () async => (Completer<void>(), Completer<void>()),
            ))!;
            addTearDown(() async {
              if (!release.isCompleted) release.complete();
              app.dispose();
              await tester.runAsync(fixture.dispose);
            });
            Map<String, dynamic>? outcome;
            final projectedSnapshots = <Map<String, dynamic>>[];
            fixture.beforePlatformCall = (call) {
              if (call.method != 'snapshot') return null;
              final projection = fixture.bootstrap.runtime.projection;
              final mode = projection['mode'] as Map?;
              final snapshot = <String, dynamic>{
                ...fixture.snapshotMap(),
                'mode': mode?['actual'],
                'modeError': mode?['error'],
                'logSource': projection['logSource'],
                'resultId': outcome == null ? null : 'one',
                'resultSuccess': outcome?['success'],
                'resultMessage': outcome?['message'],
              };
              projectedSnapshots.add(snapshot);
              return PlatformCallResult(snapshot);
            };
            final modeFailure = nativeFailure('java.io.IOException');
            final exitFailure = nativeFailure('java.lang.UnsatisfiedLinkError');
            if (modeFailed) {
              fixture.script(ApplicationContract.coreOperationMode, (request) {
                request.complete(
                  null,
                  terminal: {'complete': false, 'error': modeFailure},
                );
              });
            }
            await tester.runAsync(() async {
              await fixture.startAppRuntime();
              await app.refresh();
            });
            final source = app.state.core;
            final original = fixture.modeProjection!['error'];
            expect(app.state.running, isTrue);
            expect(app.state.modeErrorMessage?.toMap(), original);
            expect(app.errorMessage, isNull);
            expect(app.configsCurrent, isTrue);
            await tester.pumpWidget(
              MaterialApp(
                navigatorObservers: [taskRoutes],
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                locale: locale,
                theme: AppTheme.light,
                home: AppTaskActivity(
                  active: true,
                  child: Scaffold(
                    body: ListenableBuilder(
                      listenable: app,
                      builder: (context, _) => StatusHero(
                        controller: app,
                        runningProgress: app.state.running ? 1 : 0,
                        visible: true,
                        onManage: () {},
                        onImport: () {},
                        onMode: () {},
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump(const Duration(milliseconds: 320));
            final strings = AppLocalizations.of(
              tester.element(find.byType(StatusHero)),
            );
            expect(find.text(strings.statusIssue), findsNothing);
            fixture.onExit = (_) async {
              entered.complete();
              await release.future;
              if (confirmed) {
                fixture.replaceCore(phase: 'EMPTY');
                fixture.phase = 'STOPPED';
                fixture.emit({
                  'processId': source.processId,
                  'phase': ApplicationContract.corePhaseExited,
                  'exited': true,
                });
              }
              return {
                'exited': confirmed,
                if (!confirmed) 'error': exitFailure,
              };
            };
            late FutureProbe<Map<String, dynamic>> stopped;
            await tester.runAsync(() async {
              stopped = FutureProbe(fixture.execute({'action': 'stop'}));
              await Future.any([
                entered.future,
                stopped.done.then((_) {
                  throw StateError(
                    'Stop 在 exit 前结束：${stopped.error ?? stopped.value}',
                  );
                }),
              ]);
              await app.refresh();
            });
            await tester.pump();
            expect(stopped.settled, isFalse);
            expect(app.state.running, isTrue);
            expect(app.state.core.matchesIdentity(source), isTrue);
            expect(app.state.modeErrorMessage?.toMap(), original);
            expect(find.text(strings.statusIssue), findsNothing);
            expect(fixture.exits.single['admittedAt'], fixture.admittedAt);
            expect(fixture.exits.single['deadline'], fixture.deadline);
            await tester.runAsync(() async {
              release.complete();
              await stopped.done;
              outcome = stopped.value;
              await app.refresh();
            });
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 320));
            expect(stopped.error, isNull);
            expect(stopped.replies, 1);
            expect(outcome!['success'], confirmed);
            expect(app.state.resultSuccess, confirmed);
            expect(app.state.core.matchesIdentity(source), isTrue);
            expect(app.state.core.purpose, 'RUNNING');
            if (confirmed) {
              final raw = projectedSnapshots.last;
              expect((raw['core'] as Map)['phase'], 'exited');
              expect(raw['mode'], isNull);
              expect(raw['modeError'], isNull);
              expect(app.state.core.phase, 'EMPTY');
              expect(app.state.running, isFalse);
              expect(app.state.mode, isNull);
              expect(app.state.modeErrorMessage, isNull);
              expect(app.state.resultMessageDescription?.id, 'tunnelStopped');
              expect(find.text(strings.statusIssue), findsNothing);
              expect(find.text(strings.stateStopped), findsOneWidget);
              expect(find.text(strings.statusReady), findsOneWidget);
              expect(
                find.descendant(
                  of: find.byKey(const ValueKey('status-details')),
                  matching: find.byType(InkWell),
                ),
                findsNothing,
              );
              if (modeFailed) {
                final diagnostic = await tester.runAsync(
                  () async => jsonDecode(
                    await fixture.bootstrap.runtime.handle('logs', {
                      'query': {'window': fixture.runtime.logs.source},
                    }) as String,
                  ) as Map,
                );
                expect(diagnostic!['error'], original);
                expectOriginalError(diagnostic['error'], modeFailure);
                expect(diagnostic['stale'], isTrue);
              }
            } else {
              expect(app.state.running, isTrue);
              expect(app.state.core.ready, isTrue);
              expect(app.state.modeErrorMessage?.toMap(), original);
              expect(find.text(strings.stateRunning), findsOneWidget);
              expect(find.text(strings.statusIssue), findsNothing);
              expectOriginalError(outcome, exitFailure);
            }
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }

  for (final locale in const [Locale('zh'), Locale('en')]) {
    for (final width in [320.0, 390.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'whole overview measures plots through sliver intrinsic sizing $locale $width $scale',
          (tester) async {
            tester.view.physicalSize = Size(width, 600);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            await show(
              tester,
              locale: locale,
              scale: scale,
              padding: const EdgeInsets.only(left: 20, right: 12),
            );
            expect(tester.takeException(), isNull);
            final charts = find.byType(TrafficChart);
            expect(charts, findsNWidgets(2));
            final before = [
              for (var i = 0; i < 2; i++) tester.getRect(charts.at(i)),
            ];
            for (var i = 0; i < 2; i++) {
              final chart = tester.widget<TrafficChart>(charts.at(i));
              expect(chart.size.width, closeTo(before[i].width, 0.001));
              expect(before[i].height, inInclusiveRange(80, 112));
            }
            for (final state in const [
              AppSnapshot(),
              AppSnapshot(phase: 'STOPPED'),
            ]) {
              controller.state = state;
              controller.changed();
              for (final ms in [0, 16, 100, 320]) {
                await tester.pump(Duration(milliseconds: ms));
                expect([
                  for (var i = 0; i < 2; i++) tester.getRect(charts.at(i)),
                ], before);
                expect(tester.takeException(), isNull);
              }
            }
            final memory = find.byKey(const ValueKey('traffic-memory'));
            await tester.scrollUntilVisible(
              memory,
              150,
              scrollable: find
                  .descendant(
                    of: find.byType(CustomScrollView),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            );
            await tester.pumpAndSettle();
            expect(memory.hitTestable(), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }

  for (final locale in const [Locale('zh'), Locale('en')]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('button is the center anchor across states $locale $scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(390, 1300);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        controller.collection = ConfigCollection(
          entries: [config('one')],
          selectedId: 'one',
        );
        await show(tester, locale: locale, scale: scale);
        final identity = find.byKey(const ValueKey('config-identity'));
        final mode = find.byKey(const ValueKey('mode-trigger'));
        final uptime = find.byType(SessionUptime);
        final initial = [
          tester.getRect(power),
          tester.getRect(identity),
          tester.getRect(mode),
          tester.getRect(uptime),
          tester.getRect(find.byKey(const ValueKey('network-surface'))),
        ];
        void check() {
          final top = tester.getRect(identity).bottom + 28;
          final bottom = tester.getRect(mode).top - 28;
          final button = tester.getRect(power);
          final tail = tester.getRect(uptime).bottom - button.bottom;
          final centered = ((top + bottom) / 2).clamp(
            top + button.height / 2,
            bottom - button.height / 2 - tail,
          );
          expect(
            button.center.dy,
            closeTo(centered, .01),
            reason: 'Center the power button, not the button and its captions.',
          );
          expect(
            tester.getRect(find.byType(PowerRipples)).center,
            button.center,
          );
          expect(
            tester.getRect(uptime).bottom,
            lessThanOrEqualTo(bottom + .01),
          );
          expect(tester.takeException(), isNull);
        }

        check();
        for (final state in [
          const AppSnapshot(
            phase: 'STOPPED',
            operation: AppMessage('stageWaitingVpnAuth'),
          ),
          const AppSnapshot(phase: 'STARTING'),
          const AppSnapshot(
            phase: 'RUNNING',
            generation: 1,
            configId: 'one',
            revision: 1,
            runningSinceElapsedMs: 1,
            elapsedRealtimeMs: 1000000000000,
          ),
          const AppSnapshot(phase: 'STOPPING'),
          const AppSnapshot(
            phase: 'STOPPED',
            error: AppMessage('downloadFailed'),
          ),
          const AppSnapshot(phase: 'STOPPED'),
        ]) {
          controller.state = state;
          controller.changed();
          for (final ms in [0, 16, 80, 100, 180, 320]) {
            await tester.pump(Duration(milliseconds: ms));
            check();
            expect([
              tester.getRect(power),
              tester.getRect(identity),
              tester.getRect(mode),
              tester.getRect(uptime),
              tester.getRect(find.byKey(const ValueKey('network-surface'))),
            ], initial);
          }
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  for (final dispatching in [false, true]) {
    testWidgets(
      'system-managed Stop remains an independent settings entry ($dispatching)',
      (tester) async {
        controller.configsLoaded = false;
        controller.configErrorMessage = messages.configStoreUnreadable
            .withDetail('config cause');
        controller.platformErrorMessage = const AppMessage(
          'androidErrorReleaseUnconfirmed',
          detail: 'platform cause',
        );
        controller.dispatching = dispatching;
        controller.state = const AppSnapshot(
          phase: 'RUNNING',
          alwaysOn: true,
          writerBusy: true,
          operation: AppMessage('stageWaitingVpnAuth'),
        );
        await show(tester);
        if (dispatching) expect(controller.canToggle, isFalse);
        expect(tester.widget<FilledButton>(power).onPressed, isNotNull);
        final strings = AppLocalizations.of(
          tester.element(find.byType(OverviewPage)),
        );
        await tester.tap(power);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(
          find.widgetWithText(FilledButton, strings.openVpnSettings),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect((controller.platform as ViewBridge).vpnSettingsOpens, 1);
        expect(controller.commands, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'cached overview actions lose live task eligibility before a frame',
    (tester) async {
      var live = true;
      controller.state = const AppSnapshot(phase: 'RUNNING', alwaysOn: true);
      await show(tester, isActiveNow: () => live);
      final state = tester.state(find.byType(OverviewPage));
      final traffic = tester
          .widget<TrafficPanel>(find.byType(TrafficPanel))
          .traffic;
      final invoke = tester.widget<FilledButton>(power).onPressed!;
      live = false;
      invoke();
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect((controller.platform as ViewBridge).vpnSettingsOpens, 0);
      expect(controller.commands, isEmpty);
      expect(traffic.active, isFalse);
      await show(tester, active: false, isActiveNow: () => live);
      expect(tester.state(find.byType(OverviewPage)), same(state));
      expect(
        tester.widget<TrafficPanel>(find.byType(TrafficPanel)).traffic,
        same(traffic),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'late system settings failure cannot reopen feedback on an inactive overview',
    (tester) async {
      final bridge = controller.platform as ViewBridge;
      bridge.vpnSettingsPending = Completer<void>();
      controller.state = const AppSnapshot(phase: 'RUNNING', alwaysOn: true);
      await show(tester);
      final strings = AppLocalizations.of(
        tester.element(find.byType(OverviewPage)),
      );
      await tester.tap(power);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(
        find.widgetWithText(FilledButton, strings.openVpnSettings),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(bridge.vpnSettingsOpens, 1);
      await show(tester, active: false);
      bridge.vpnSettingsPending!.completeError(
        StateError('settings original cause'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(AlertDialog), findsNothing);
      expect(controller.commands, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final exit in ['task', 'background', 'page']) {
    testWidgets('overview import cached submit retires immediately on $exit', (
      tester,
    ) async {
      await show(tester);
      await tester.tap(find.text('导入配置'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.enterText(
        find.byKey(const ValueKey('import-source')),
        'https://example.test/synthetic',
      );
      final strings = AppLocalizations.of(
        tester.element(find.byType(OverviewPage)),
      );
      final submit = tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, strings.downloadAndSave),
          )
          .onPressed!;
      final dialog = find.byType(AlertDialog);
      final dialogState = tester.element(dialog);
      if (exit == 'task') {
        await show(tester, active: false);
      } else if (exit == 'background') {
        controller.setForeground(false);
      } else {
        unawaited(
          Navigator.of(tester.element(dialog)).push<void>(
            MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('new owner')),
            ),
          ),
        );
      }
      submit();
      await tester.pump();
      expect(controller.commands, isEmpty);
      expect(dialogState.mounted, isTrue);
      if (exit == 'page') expect(find.text('new owner'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('empty overview never dispatches a startup command', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('接管已关闭'), findsWidgets);
    expect(
      find.text(
        AppLocalizations.of(tester.element(find.byType(OverviewPage)))
            .statusImportPrompt,
      ),
      findsWidgets,
    );
    expect(tester.widget<FilledButton>(power).onPressed, isNull);
    expect(find.text('导入配置'), findsOneWidget);
    expect(find.text('最近连接'), findsOneWidget);
    expect(find.byTooltip('核实状态'), findsNothing);
    expect(controller.commands, isEmpty);
  });

  testWidgets(
    'connection entry opens a read-only secondary page while stopped',
    (tester) async {
      await show(tester);
      await tester.ensureVisible(find.text('最近连接'));
      await tester.tap(find.text('最近连接'));
      await tester.pumpAndSettle();
      expect(find.text('暂无近期连接'), findsOneWidget);
      expect(controller.commands, isEmpty);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('网络活动'), findsOneWidget);
    },
  );

  testWidgets('unknown is not stopped and can only stop, not start', (
    tester,
  ) async {
    controller.state = const AppSnapshot();
    await show(tester);
    expect(find.text('状态未确认'), findsWidgets);
    expect(find.text('接管已关闭'), findsNothing);
    expect(tester.widget<FilledButton>(power).onPressed, isNotNull);
    expect(power.hitTestable(), findsOneWidget);
    await tester.tap(power);
    await tester.pump();
    expect(controller.commands, [
      {'action': 'stop'},
    ]);
    await tester.tap(find.text('配置管理'));
    await tester.pumpAndSettle();
    expect(find.text('配置'), findsOneWidget);
    expect(controller.commands, [
      {'action': 'stop'},
    ]);
  });

  testWidgets('initial loading does not masquerade as empty saved data', (
    tester,
  ) async {
    controller.loading = true;
    controller.configsLoaded = false;
    controller.state = const AppSnapshot();
    await show(tester);
    expect(find.text('正在获取状态'), findsWidgets);
    expect(find.text('尚未导入配置'), findsNothing);
    await tester.tap(find.text('配置管理'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ConfigsPage), findsOneWidget);
    expect(find.text('配置'), findsOneWidget);
    expect(find.text('配置 · 读取中'), findsNothing);
    expect(controller.configsLoaded, isFalse);
    expect(find.text('尚未保存配置'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('HTTP import executes directly without a confirmation or retry', (
    tester,
  ) async {
    await show(tester);
    final rect = tester.getRect(power);
    await tester.tap(find.text('导入配置'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).first,
      'http://example.test/config?token=private',
    );
    await tester.tap(find.text('下载并保存'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.commands.single, {
      'action': 'import',
      'name': '',
      'source': 'http://example.test/config?token=private',
      'storageEpoch': 0,
    });
    expect(tester.getRect(power), rect);
  });

  testWidgets(
    'unreadable configurations block start but running may still stop',
    (tester) async {
      controller.collection = ConfigCollection(
        entries: [config('one')],
        selectedId: 'one',
      );
      controller.configErrorMessage = messages.configStoreUnreadable;
      await show(tester);
      expect(tester.widget<FilledButton>(power).onPressed, isNull);
      controller.state = const AppSnapshot(
        phase: 'RUNNING',
        configId: 'one',
        revision: 1,
      );
      controller.configErrorMessage = messages.configStoreUnreadable;
      controller.changed();
      await tester.pump();
      expect(tester.widget<FilledButton>(power).onPressed, isNotNull);
      expect(find.text('尚未确认所用配置'), findsOneWidget);
      await tester.tap(power);
      expect(controller.commands.single['action'], 'stop');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('actual configuration and revision are not the saved selection', (
    tester,
  ) async {
    controller.collection = ConfigCollection(
      entries: [config('one'), config('two')],
      selectedId: 'two',
    );
    controller.state = const AppSnapshot(
      phase: 'RUNNING',
      configId: 'one',
      revision: 1,
    );
    await show(tester);
    expect(find.text('配置 one'), findsOneWidget);
    expect(find.text('当前选择：配置 two'), findsWidgets);
    controller.collection = ConfigCollection(
      entries: [config('one', revision: 2)],
      selectedId: 'one',
    );
    controller.changed();
    for (final ms in [0, 16, 80, 200]) {
      await tester.pump(Duration(milliseconds: ms));
      expect(find.semantics.byLabel('运行中版本与已保存版本不同'), findsOneWidget);
    }
    expect(find.text('运行中版本与已保存版本不同'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  }, semanticsEnabled: true);

  testWidgets(
    'normal startup and shutdown never show unknown configuration hint',
    (tester) async {
      controller.collection = ConfigCollection(
        entries: [config('one')],
        selectedId: 'one',
      );
      await show(tester);
      final identity = find.byKey(const ValueKey('config-identity'));
      final height = tester.getSize(identity).height;
      final center = tester.getCenter(power);
      for (final snapshot in const [
        AppSnapshot(
          phase: 'STOPPED',
          operation: AppMessage('stageWaitingVpnAuth'),
        ),
        AppSnapshot(phase: 'STARTING'),
        AppSnapshot(phase: 'RUNNING', configId: 'one', revision: 1),
        AppSnapshot(phase: 'STOPPING'),
        AppSnapshot(phase: 'STOPPED'),
      ]) {
        controller.state = snapshot;
        controller.changed();
        await tester.pump();
        for (final milliseconds in [0, 50, 100, 180]) {
          await tester.pump(Duration(milliseconds: milliseconds));
          expect(find.text('已选配置 · 未确认实际使用'), findsNothing);
          expect(tester.getSize(identity).height, height);
          expect(tester.getCenter(power), center);
        }
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'unknown identity fades in reserved space but not during initial loading',
    (tester) async {
      controller.collection = ConfigCollection(
        entries: [config('one')],
        selectedId: 'one',
      );
      controller.loading = true;
      controller.state = const AppSnapshot();
      await show(tester);
      final identity = find.byKey(const ValueKey('config-identity'));
      final height = tester.getSize(identity).height;
      expect(find.text('已选配置 · 未确认实际使用'), findsNothing);
      controller.loading = false;
      controller.changed();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('已选配置 · 未确认实际使用'), findsWidgets);
      final opacities = tester.widgetList<Opacity>(
        find.descendant(of: identity, matching: find.byType(Opacity)),
      );
      expect(
        opacities.any((widget) => widget.opacity > 0 && widget.opacity < 1),
        isTrue,
      );
      expect(tester.getSize(identity).height, height);
      await tester.pump(const Duration(milliseconds: 150));
      controller.state = const AppSnapshot(phase: 'STOPPED');
      controller.changed();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('已选配置 · 未确认实际使用'), findsOneWidget);
      expect(tester.getSize(identity).height, height);
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('已选配置 · 未确认实际使用'), findsNothing);
      expect(tester.getSize(identity).height, height);
      await tester.pumpWidget(const SizedBox());
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets(
    'command feedback never moves the home layout or replays on navigation',
    (tester) async {
      controller.collection = ConfigCollection(
        entries: [config('one')],
        selectedId: 'one',
      );
      await show(tester);
      final powerRect = tester.getRect(power);
      for (final action in ['start', 'stop', 'setMode', 'select', 'delete']) {
        controller.lastCommand = {'action': action};
        controller.state = AppSnapshot(
          phase: 'STOPPED',
          resultId: action,
          resultSuccess: true,
          resultMessage: messages.modeConfirmed,
        );
        controller.changed();
        await tester.pump();
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text(messages.modeConfirmed.text), findsNothing);
        expect(tester.getRect(power), powerRect);
      }
      for (final message in [
        messages.androidErrorTakeoverStartFailed,
        messages.modeNotConfirmed,
      ]) {
        controller.lastCommand = {'action': 'setMode'};
        controller.state = AppSnapshot(
          phase: 'STOPPED',
          resultId: message.id,
          resultMessage: message,
        );
        controller.changed();
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        final notice = find.byType(SnackBar);
        expect(notice, findsOneWidget);
        expect(
          find.descendant(of: notice, matching: find.text(message.text)),
          findsOneWidget,
        );
        expect(tester.getRect(power), powerRect);
        final strings = AppLocalizations.of(tester.element(notice));
        await tester.tap(
          find.descendant(
            of: notice,
            matching: find.widgetWithText(TextButton, strings.errorDetails),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(message.text),
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        controller.changed();
        await tester.pump();
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.getRect(power), powerRect);
      }
      await tester.tap(find.text('配置管理'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(messages.modeConfirmed.text), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('download failure uses ordinary feedback without resubmission', (
    tester,
  ) async {
    await show(tester);
    final rect = tester.getRect(power);
    controller.lastCommand = {
      'action': 'import',
      'source': 'http://example.test',
    };
    controller.state = AppSnapshot(
      phase: 'STOPPED',
      resultId: 'download-failure',
      resultMessage: messages.downloadFailed,
    );
    controller.changed();
    await tester.pumpAndSettle();
    expect(find.text(messages.downloadFailed.text), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(tester.getRect(power), rect);
    expect(controller.commands, isEmpty);
    await tester.tap(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.widgetWithIcon(IconButton, Icons.close),
      ),
    );
    await tester.pumpAndSettle();
    controller.changed();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.commands, isEmpty);
    expect(tester.getRect(power), rect);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'configuration page does not replay an earlier successful toggle',
    (tester) async {
      controller.state = const AppSnapshot(
        phase: 'STOPPED',
        resultId: 'old',
        resultSuccess: true,
        resultMessage: AppMessage('tunnelStopped'),
      );
      await show(tester);
      await tester.tap(find.text('配置管理'));
      await tester.pumpAndSettle();
      expect(find.text('接管已停止。'), findsNothing);
    },
  );

  testWidgets('startup failure stays stopped; cleanup failure stays unknown', (
    tester,
  ) async {
    controller.collection = ConfigCollection(
      entries: [config('one')],
      selectedId: 'one',
    );
    controller.state = const AppSnapshot(
      phase: 'STOPPED',
      error: AppMessage('androidErrorTakeoverStartFailed'),
    );
    await show(tester);
    await tester.pumpAndSettle();
    expect(find.text('接管已关闭'), findsWidgets);
    expect(find.byType(SnackBar), findsOneWidget);
    await tester.tap(
      find.descendant(of: find.byType(SnackBar), matching: find.text('错误详情')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(messages.androidErrorTakeoverStartFailed.text),
      findsOneWidget,
    );
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(power).onPressed, isNotNull);
    controller.state = const AppSnapshot(
      error: AppMessage('androidErrorReleaseUnconfirmed'),
    );
    controller.changed();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pump(const Duration(milliseconds: 320));
    expect(find.text('状态未确认'), findsWidgets);
    expect(find.text('接管已关闭'), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
    await tester.tap(
      find.descendant(of: find.byType(SnackBar), matching: find.text('错误详情')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(messages.androidErrorReleaseUnconfirmed.text),
      findsOneWidget,
    );
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(power).onPressed, isNotNull);
    expect(power.hitTestable(), findsOneWidget);
    await tester.tap(power);
    await tester.pump();
    expect(controller.commands, [
      {'action': 'stop'},
    ]);
  });

  testWidgets('authorization wait is not ready or native starting', (
    tester,
  ) async {
    controller.state = const AppSnapshot(
      phase: 'STOPPED',
      operation: AppMessage('stageWaitingVpnAuth'),
    );
    await show(tester);
    expect(find.text('正在等待 VPN 授权'), findsWidgets);
    expect(find.text('正在启动'), findsNothing);
    expect(tester.widget<FilledButton>(power).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'failed configuration read does not display an empty collection',
    (tester) async {
      controller.configsLoaded = false;
      controller.configErrorMessage = messages.configStoreUnreadable;
      await show(tester);
      await tester.tap(find.text('配置管理'));
      await tester.pumpAndSettle();
      expect(find.text('尚未保存配置'), findsNothing);
      expect(find.text('配置'), findsOneWidget);
      expect(find.text('配置 · 未更新'), findsNothing);
      final notice = find.byType(SnackBar);
      expect(notice, findsOneWidget);
      final strings = AppLocalizations.of(tester.element(notice));
      expect(
        find.descendant(
          of: notice,
          matching: find.text(messages.configStoreUnreadable.summary(strings)),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: notice,
          matching: find.widgetWithText(TextButton, strings.errorDetails),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(messages.configStoreUnreadable.summary(strings)),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'configuration navigation suspends ripples and restores from source',
    (tester) async {
      controller.collection = ConfigCollection(
        entries: [config('one')],
        selectedId: 'one',
      );
      controller.state = const AppSnapshot(
        phase: 'RUNNING',
        configId: 'one',
        revision: 1,
      );
      await show(tester);
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.text('配置管理'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final paint = tester
          .widgetList<CustomPaint>(
            find.byType(CustomPaint, skipOffstage: false),
          )
          .map((w) => w.painter)
          .whereType<RipplePainter>()
          .single;
      expect(paint.waves, isEmpty);
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'start and stop feedback keep the divider stable at scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        controller.collection = ConfigCollection(
          entries: [config('one')],
          selectedId: 'one',
        );
        await show(tester, scale: scale);
        final surface = find.byKey(const ValueKey('network-surface'));
        final top = tester.getTopLeft(surface);
        for (final snapshot in const [
          AppSnapshot(
            phase: 'STARTING',
            operation: AppMessage('stageStartingTunnel'),
          ),
          AppSnapshot(
            phase: 'RUNNING',
            configId: 'one',
            revision: 1,
            resultSuccess: true,
            resultMessage: AppMessage('tunnelStarted'),
          ),
          AppSnapshot(
            phase: 'STOPPING',
            operation: AppMessage('stageStopping'),
          ),
          AppSnapshot(
            phase: 'STOPPED',
            resultSuccess: true,
            resultMessage: AppMessage('tunnelStopped'),
          ),
        ]) {
          controller.state = snapshot;
          controller.changed();
          await tester.pump();
          for (final milliseconds in [80, 100, 140, 1500]) {
            await tester.pump(Duration(milliseconds: milliseconds));
            expect(tester.getTopLeft(surface), top);
            expect(tester.takeException(), isNull);
          }
        }
        expect(
          tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
          Colors.transparent,
        );
        await tester.pumpWidget(const SizedBox());
        expect(tester.binding.transientCallbackCount, 0);
      },
    );
  }

  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.6, 2.0]) {
      testWidgets('narrow short screen, long name, scale $scale, dark $dark', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        controller.collection = ConfigCollection(
          entries: [
            ConfigEntry(
              id: 'one',
              name: '很长的配置名称' * 12,
              source: 'https://example.test/config?token=private',
              revision: 1,
              body: 'config',
            ),
          ],
          selectedId: 'one',
        );
        await show(tester, dark: dark, scale: scale);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('token=private'), findsNothing);
        await tester.scrollUntilVisible(
          find.text('最近连接'),
          100,
          scrollable: find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(find.text('最近连接').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
