import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/app/app_controller.dart';
import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/app/widgets/operation_feedback.dart';
import 'package:clash_pseudo/src/features/connections/connection_snapshot.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/overview/overview_page.dart';
import 'package:clash_pseudo/src/features/overview/widgets/traffic_panel.dart';
import 'package:clash_pseudo/src/features/overview/widgets/power_ripples.dart';
import 'package:clash_pseudo/src/features/overview/widgets/session_uptime.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:flutter_test/flutter_test.dart';

class ViewBridge extends AppBridge {
  @override
  Future<ConnectionSnapshot> recentConnections({
    Map<String, Object?>? detail,
  }) async => ConnectionSnapshot.fromMap({
    'generation': 0,
    'configId': '',
    'revision': 0,
    'phase': 'STOPPED',
    'fresh': false,
    'connections': [],
  });
  @override
  Future<void> releaseConnectionDetail() async {}
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
  setUp(() {
    setMessageLanguage(AppLanguage.zh);
    controller = ViewController();
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
  }) => tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      theme: dark ? AppTheme.dark : AppTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale), padding: padding),
        child: child!,
      ),
      home: OperationFeedback(
        controller: controller,
        child: OverviewPage(controller: controller),
      ),
    ),
  );

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

  testWidgets('empty overview never dispatches a startup command', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('接管已关闭'), findsWidgets);
    expect(find.text('导入完整配置后，即可启动'), findsWidgets);
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

  testWidgets('unknown is not stopped and cannot start', (tester) async {
    controller.state = const AppSnapshot();
    await show(tester);
    expect(find.text('状态未确认'), findsWidgets);
    expect(find.text('接管已关闭'), findsNothing);
    expect(tester.widget<FilledButton>(power).onPressed, isNull);
    await tester.tap(find.text('配置管理'));
    await tester.pumpAndSettle();
    expect(find.text('配置'), findsOneWidget);
    expect(controller.commands, isEmpty);
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
    expect(find.text('配置 · 读取中'), findsOneWidget);
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
      'replace': false,
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
      expect(find.text('配置身份未确认'), findsOneWidget);
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
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text(message.text), findsOneWidget);
        expect(tester.getRect(power), powerRect);
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(messages.downloadFailed.text), findsOneWidget);
    expect(tester.getRect(power), rect);
    expect(controller.commands, isEmpty);
    await tester.tap(find.text('关闭'));
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
    expect(find.text('接管已关闭'), findsWidgets);
    await tester.tap(find.text('状态异常 · 查看详情').hitTestable().first);
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
    expect(find.text('状态未确认'), findsWidgets);
    expect(find.text('接管已关闭'), findsNothing);
    await tester.tap(find.text('状态异常 · 查看详情').hitTestable().first);
    await tester.pumpAndSettle();
    expect(
      find.text(messages.androidErrorReleaseUnconfirmed.text),
      findsOneWidget,
    );
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(power).onPressed, isNull);
    expect(controller.commands, isEmpty);
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
      expect(find.text('配置 · 未更新'), findsOneWidget);
      await tester.tap(find.byTooltip('配置读取失败'));
      await tester.pumpAndSettle();
      expect(find.text('无法读取已保存配置，原文件未被修改。'), findsOneWidget);
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
