import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';

import 'dart:async';

import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_feedback.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_notice.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/strategies/mode_sheet.dart';
import 'package:clash_pseudo/src/model/tunnel_mode.dart';
import 'package:clash_pseudo/src/ui/overview/overview_page.dart';
import 'package:clash_pseudo/src/ui/overview/widgets/power_ripples.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/locale/model_text.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/preferences_fakes.dart';
import '../../support/readonly_override_store.dart';
import '../app/app_controller_test.dart' show MemoryStore, SnapshotBridge;

const _modeFailureDetail =
    '模式保存失败：https://user:pass@fixture.test/?token=原文🙂\n'
    'Authorization: Bearer fixture';

const _vpnCore = CoreSnapshot(
  processId: 'vpn-process',
  inputId: 'vpn-input',
  generation: 1,
  phase: 'READY',
  purpose: 'RUNNING',
  configId: 'one',
  revision: 1,
  composition: '["one",1]',
);
const _lanCore = CoreSnapshot(
  processId: 'lan-process',
  inputId: 'lan-input',
  generation: 1,
  phase: 'READY',
  purpose: 'RUNNING',
  configId: 'one',
  revision: 1,
  composition: 'lan-composition',
);
const _savedGlobalReceipt = <String, dynamic>{
  'status': 'saved',
  'mode': 'global',
  'storageEpoch': 0,
};
Map<String, dynamic> _appliedModeReceipt(
  CoreSnapshot target,
  TunnelMode mode,
) => {
  'status': 'applied',
  'mode': mode.name,
  'storageEpoch': 0,
  ...target.wireIdentity,
};

class ModeController extends AppController {
  ModeController() : super(AppBridge()) {
    loading = false;
    configsLoaded = true;
    state = const AppSnapshot(phase: 'STOPPED');
  }
  @override
  Future<void> refresh() async {}

  int modeRefreshes = 0;
  @override
  Future<void> refreshMode() async {
    modeRefreshes++;
  }

  int epoch = 0;
  Completer<void>? reply;
  @override
  int get storageEpoch => epoch;
  final commands = <Map<String, Object?>>[];
  @override
  Future<String?> submit(
    Map<String, Object?> command, {
    bool automatic = false,
  }) async {
    lastCommandAutomatic = automatic;
    lastCommand = Map.of(command);
    commands.add(command);
    await reply?.future;
    if (command['action'] != 'stop' && command['storageEpoch'] != epoch) {
      commandErrorMessage = messages.storageUnavailable;
      notifyListeners();
      return null;
    }
    return 'operation-${commands.length}';
  }

  void changed() => notifyListeners();
}

void main() {
  late ModeController controller;
  late AppTaskNavigatorObserver taskRoutes;
  setUp(() {
    taskRoutes = AppTaskNavigatorObserver();
    setMessageLanguage(AppLanguage.zh);
    controller = ModeController();
  });
  tearDown(() {
    controller.dispose();
    setMessageLanguage(AppLanguage.system);
  });
  Future<void> show(
    WidgetTester tester, {
    double scale = 1,
    bool dark = false,
    Locale locale = const Locale('zh'),
    bool Function()? isTaskActive,
    bool workspaceNavigator = false,
    AppController? owner,
  }) async {
    final app = owner ?? controller;
    final workspaceRoutes = workspaceNavigator
        ? AppTaskNavigatorObserver()
        : null;
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [taskRoutes],
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        theme: dark ? AppTheme.dark : AppTheme.light,
        builder: (context, child) => AppTaskActivity(
          active: true,
          isActiveNow: isTaskActive,
          isActiveWithPopup: (_) => isTaskActive?.call() ?? true,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: scale == 2,
            ),
            child: child!,
          ),
        ),
        home: OperationNoticeHost(
          child: OperationFeedback(
            controller: app,
            child: workspaceNavigator
                ? Navigator(
                    observers: [workspaceRoutes!],
                    onGenerateRoute: (_) => MaterialPageRoute<void>(
                      builder: (_) => OverviewPage(controller: app),
                    ),
                  )
                : OverviewPage(controller: app),
          ),
        ),
      ),
    );
  }

  Future<void> open(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const ValueKey('mode-trigger')));
    await tester.tap(find.byKey(const ValueKey('mode-trigger')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  void expectWorkspaceErrorRoute(WidgetTester tester) {
    final reader = ModalRoute.of(
      tester.element(find.byType(OperationFeedback)),
    )!;
    final sheet = ModalRoute.of(tester.element(find.byType(ModeSheet)))!;
    final dialog = ModalRoute.of(tester.element(find.byType(AlertDialog)))!;
    expect(sheet.navigator, isNot(same(reader.navigator)));
    expect(dialog.navigator, same(reader.navigator));
    expect(sheet, isA<PopupRoute<dynamic>>());
    expect(sheet.isActive, isTrue);
    expect(sheet.isCurrent, isTrue);
    expect(dialog.isCurrent, isTrue);
    expect(AppTaskActivity.routeIsActive(reader), isFalse);
    expect(AppTaskActivity.routeIsActive(reader, ownedPopup: dialog), isTrue);
  }

  AppSnapshot lanSnapshot({
    TunnelMode? mode,
    String corePhase = 'ready',
    String? resultId,
    bool resultSuccess = false,
    Map<String, dynamic>? modeResult,
  }) => AppSnapshot.fromMap({
    'phase': 'STOPPED',
    'storageReady': true,
    'storageEpoch': 0,
    'lanRunning': corePhase == 'ready',
    'mode': mode?.name,
    'resultId': resultId,
    'resultSuccess': resultSuccess,
    'modeResult': modeResult,
    'core': {..._lanCore.wireIdentity, 'phase': corePhase},
  });

  testWidgets('LAN mode waits for actual and returns to fallback after exit', (
    tester,
  ) async {
    controller.collection = ConfigCollection(
      entries: [],
      mode: TunnelMode.direct,
    );
    controller.state = lanSnapshot();
    await show(tester);
    await tester.pumpAndSettle();
    final strings = AppLocalizations.of(
      tester.element(find.byType(OverviewPage)),
    );
    expect(find.text(strings.modeRunningUnconfirmed), findsOneWidget);
    expect(find.text(strings.modeSavedIdle(strings.modeDirect)), findsNothing);
    expect(controller.canChangeMode, isFalse);
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('mode-trigger')))
          .onPressed,
      isNull,
    );
    expect(
      tester.widget<PowerRipples>(find.byType(PowerRipples)).emitting,
      isFalse,
    );
    expect(find.byType(SnackBar), findsNothing);

    controller.state = lanSnapshot(mode: TunnelMode.global);
    controller.changed();
    await tester.pumpAndSettle();
    expect(find.text(strings.modeRunning(strings.modeGlobal)), findsOneWidget);
    expect(controller.canChangeMode, isTrue);
    await open(tester);
    final global = find.byKey(const ValueKey('mode-global'));
    Color? background(Finder button) => tester
        .widget<OutlinedButton>(button)
        .style!
        .backgroundColor!
        .resolve({});
    expect(background(global), AppTheme.light.colorScheme.surfaceContainer);
    expect(
      find.text('${strings.modeDirect} · ${strings.modeFallbackLabel}'),
      findsOneWidget,
    );

    controller.state = lanSnapshot();
    controller.changed();
    await tester.pumpAndSettle();
    for (final mode in TunnelMode.values) {
      final button = find.byKey(ValueKey('mode-${mode.name}'));
      expect(background(button), AppTheme.light.colorScheme.surface);
      expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
    }
    expect(find.byType(SnackBar), findsNothing);

    controller.state = const AppSnapshot(phase: 'STOPPED');
    controller.changed();
    await tester.pumpAndSettle();
    final direct = find.byKey(const ValueKey('mode-direct'));
    expect(background(direct), AppTheme.light.colorScheme.surfaceContainer);
    expect(tester.widget<OutlinedButton>(direct).onPressed, isNotNull);
    await tester.tap(direct);
    await tester.pumpAndSettle();
    expect(find.byType(ModeSheet), findsNothing);
    expect(controller.commands, isEmpty);
    expect(
      find.text(strings.modeSavedIdle(strings.modeDirect)),
      findsOneWidget,
    );
  });

  for (final actual in [TunnelMode.direct, TunnelMode.global, null]) {
    testWidgets(
      'LAN fallback selection submits and closes only after actual confirmation $actual',
      (tester) async {
        controller.collection = ConfigCollection(
          entries: [],
          mode: TunnelMode.direct,
        );
        controller.state = lanSnapshot(mode: TunnelMode.global);
        await show(tester);
        await open(tester);
        await tester.tap(find.byKey(const ValueKey('mode-direct')));
        await tester.pump();
        expect(controller.commands, [
          {'action': 'setMode', 'mode': 'direct', 'storageEpoch': 0},
        ]);
        expect(find.byType(ModeSheet), findsOneWidget);
        controller.state = lanSnapshot(
          mode: actual,
          resultId: 'operation-1',
          resultSuccess: true,
          modeResult: _appliedModeReceipt(_lanCore, TunnelMode.direct),
        );
        controller.changed();
        await tester.pumpAndSettle();
        expect(
          find.byType(ModeSheet),
          actual == TunnelMode.direct ? findsNothing : findsOneWidget,
        );
        expect(controller.collection.mode, TunnelMode.direct);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  Future<void> openErrorDetails(
    WidgetTester tester,
    String summary, {
    String? detail,
    bool local = true,
  }) async {
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    final notice = find.byType(SnackBar);
    expect(notice, findsOneWidget);
    expect(
      find.descendant(of: find.byType(ModeSheet), matching: notice),
      local ? findsOneWidget : findsNothing,
    );
    expect(
      find.descendant(of: notice, matching: find.text(summary)),
      findsOneWidget,
    );
    final strings = AppLocalizations.of(
      tester.element(find.byType(OperationFeedback)),
    );
    final details = find.descendant(
      of: notice,
      matching: find.widgetWithText(TextButton, strings.errorDetails),
    );
    expect(details, findsOneWidget);
    expect(tester.getSize(details).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(details).height, greaterThanOrEqualTo(48));
    await tester.tap(details.hitTestable());
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expectWorkspaceErrorRoute(tester);
    if (detail != null) {
      final technical = find.byKey(
        const ValueKey('operation-technical-details'),
      );
      await tester.ensureVisible(technical);
      await tester.tap(technical);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('operation-technical-text')),
            )
            .data,
        detail,
      );
    }
  }

  testWidgets(
    'mode opening captures its epoch before the deferred route build and never borrows restore permissions',
    (tester) async {
      controller.epoch = 1;
      controller.state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 1);
      await show(tester, scale: 2, workspaceNavigator: true);
      final trigger = find.byKey(const ValueKey('mode-trigger'));
      await tester.ensureVisible(trigger);
      await tester.tap(trigger);
      controller.epoch = 2;
      controller.collection = ConfigCollection(
        entries: [],
        mode: TunnelMode.global,
      );
      controller.state = const AppSnapshot(
        phase: 'STOPPED',
        resultId: 'restore',
        resultSuccess: true,
        storageEpoch: 2,
      );
      controller.changed();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<ModeSheet>(find.byType(ModeSheet)).storageEpoch, 1);
      final buttons = [
        for (final mode in TunnelMode.values)
          find.byKey(ValueKey('mode-${mode.name}')),
      ];
      final anchors = [for (final button in buttons) tester.getRect(button)];
      await tester.ensureVisible(find.byKey(const ValueKey('mode-global')));
      final scrolled = [for (final button in buttons) tester.getRect(button)];
      controller.reply = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('mode-global')));
      for (final elapsed in [
        Duration.zero,
        const Duration(milliseconds: 16),
        const Duration(milliseconds: 80),
      ]) {
        await tester.pump(elapsed);
        expect(find.byType(ModeSheet), findsOneWidget);
        expect([
          for (final button in buttons) tester.getRect(button),
        ], scrolled);
        for (final button in buttons) {
          expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
        }
      }
      controller.reply!.complete();
      await tester.pumpAndSettle();
      expect(controller.commands.single, {
        'action': 'setMode',
        'mode': 'global',
        'storageEpoch': 1,
      });
      expect(controller.collection.mode, TunnelMode.global);
      expect(find.text(messages.storageUnavailable.text), findsWidgets);
      await openErrorDetails(
        tester,
        messages.storageUnavailable.text,
        local: false,
      );
      await tester.tap(find.text('关闭').hitTestable());
      await tester.pumpAndSettle();
      expect(find.byType(ModeSheet), findsOneWidget);
      expect([for (final button in buttons) tester.getRect(button)], scrolled);
      expect(
        anchors.map((rect) => rect.size),
        scrolled.map((rect) => rect.size),
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final locale in const [Locale('zh'), Locale('en')]) {
    testWidgets(
      'nullable fallback and actual-mode info stay anchored ${locale.languageCode}',
      (tester) async {
        tester.view.physicalSize = const Size(320, 960);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await show(tester, scale: 2, locale: locale);
        final strings = AppLocalizations.of(
          tester.element(find.byType(OverviewPage)),
        );
        expect(find.text(strings.modeFollowConfigIdle), findsWidgets);
        expect(find.text(strings.modeSavedUnconfirmed), findsNothing);
        await open(tester);
        final buttons = [
          for (final mode in TunnelMode.values)
            find.byKey(ValueKey('mode-${mode.name}')),
        ];
        final rows = [for (final button in buttons) tester.getRect(button)];
        final title = find.descendant(
          of: find.byType(ModeSheet),
          matching: find.text(strings.modeTitle),
        );
        final titleRect = tester.getRect(title);
        for (final button in buttons) {
          expect(
            tester
                .widget<OutlinedButton>(button)
                .style!
                .backgroundColor!
                .resolve({}),
            AppTheme.light.colorScheme.surface,
          );
        }
        controller.state = const AppSnapshot(
          phase: 'RUNNING',
          generation: 1,
          configId: 'one',
          revision: 1,
          core: _vpnCore,
          mode: TunnelMode.global,
        );
        controller.collection = ConfigCollection(
          entries: [],
          mode: TunnelMode.rule,
        );
        controller.changed();
        for (final elapsed in [
          Duration.zero,
          const Duration(milliseconds: 16),
          const Duration(milliseconds: 80),
        ]) {
          await tester.pump(elapsed);
          expect(tester.getRect(title), titleRect);
          expect([for (final button in buttons) tester.getRect(button)], rows);
        }
        expect(
          find.descendant(
            of: find.byType(ModeSheet),
            matching: find.byIcon(Icons.info_outline),
          ),
          findsNothing,
        );
        expect(
          find.text('${strings.modeRule} · ${strings.modeFallbackLabel}'),
          findsOneWidget,
        );
        controller.state = const AppSnapshot(
          phase: 'RUNNING',
          generation: 1,
          configId: 'one',
          revision: 1,
          core: _vpnCore,
          modeError: AppMessage(
            'androidErrorModeUnconfirmed',
            detail: 'original mode read error',
          ),
        );
        controller.changed();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.getRect(title), titleRect);
        expect([for (final button in buttons) tester.getRect(button)], rows);
        expect(
          find.descendant(
            of: find.byType(ModeSheet),
            matching: find.byIcon(Icons.error_outline),
          ),
          findsNothing,
        );
        final notice = find.descendant(
          of: find.byType(ModeSheet),
          matching: find.byType(SnackBar),
        );
        expect(notice, findsOneWidget);
        await tester.tap(
          find.descendant(
            of: notice,
            matching: find.text(strings.errorDetails),
          ),
        );
        await tester.pumpAndSettle();
        final technical = find.byKey(
          const ValueKey('operation-technical-details'),
        );
        await tester.ensureVisible(technical);
        await tester.pumpAndSettle();
        await tester.tap(technical);
        await tester.pumpAndSettle();
        expect(find.text('original mode read error'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final width in [320.0, 390.0, 440.0]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets(
        'mode explanations have uniform rows width=$width scale=$scale',
        (tester) async {
          tester.view.physicalSize = Size(width, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await show(tester, scale: scale);
          await open(tester);
          final rows = [
            for (final mode in TunnelMode.values)
              tester.getSize(find.byKey(ValueKey('mode-${mode.name}'))).height,
          ];
          final descriptions = [
            for (final mode in TunnelMode.values)
              tester
                  .getSize(
                    find.text(
                      mode.description(
                        AppLocalizations.of(
                          tester.element(find.byType(ModeSheet)),
                        ),
                      ),
                    ),
                  )
                  .height,
          ];
          expect(rows.toSet(), hasLength(1));
          expect(descriptions.toSet(), hasLength(1));
          expect(tester.takeException(), isNull);
          expect(find.byTooltip('模式状态与说明'), findsNothing);
        },
      );
    }
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'mode geometry stays fixed through waiting selection and errors scale=$scale',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await show(tester, scale: scale, workspaceNavigator: true);
        await open(tester);
        final sheet = find.byType(BottomSheet);
        final buttons = [
          for (final mode in TunnelMode.values)
            find.byKey(ValueKey('mode-${mode.name}')),
        ];
        final rect = tester.getRect(sheet);
        final rows = [for (final button in buttons) tester.getRect(button)];
        await tester.ensureVisible(buttons[1]);
        final scrolled = [for (final button in buttons) tester.getRect(button)];
        await tester.tap(buttons[1]);
        for (final milliseconds in [0, 16, 80, 180]) {
          await tester.pump(Duration(milliseconds: milliseconds));
          expect(tester.getRect(sheet), rect);
          expect([
            for (final button in buttons) tester.getRect(button),
          ], scrolled);
        }
        expect(find.text('正在确认全局模式…'), findsNothing);
        controller.collection = ConfigCollection(
          entries: [],
          mode: TunnelMode.global,
        );
        controller.state = const AppSnapshot(
          phase: 'STOPPED',
          operation: AppMessage('stageSwitchingMode'),
        );
        controller.changed();
        await tester.pump();
        expect(tester.getRect(sheet), rect);
        expect([
          for (final button in buttons) tester.getSize(button),
        ], rows.map((r) => r.size).toList());
        controller.state = const AppSnapshot(
          phase: 'STOPPED',
          resultId: 'operation-1',
          resultMessage: AppMessage(
            'configSaveFailed',
            detail: _modeFailureDetail,
          ),
        );
        controller.changed();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.getRect(sheet), rect);
        expect([
          for (final button in buttons) tester.getRect(button),
        ], scrolled);
        await openErrorDetails(
          tester,
          messages.configSaveFailed.text,
          detail: _modeFailureDetail,
        );
        expect(find.text(messages.configSaveFailed.text), findsOneWidget);
        expect(tester.getRect(sheet), rect);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(tester.getRect(sheet), rect);
        expect([
          for (final button in buttons) tester.getRect(button),
        ], scrolled);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'cached mode choice is revoked synchronously when the sheet reverses',
    (tester) async {
      await show(tester);
      await open(tester);
      final button = find.byKey(const ValueKey('mode-global'));
      final oldChoose = tester.widget<OutlinedButton>(button).onPressed!;
      Navigator.of(tester.element(button)).pop();
      oldChoose();
      await tester.pumpAndSettle();
      expect(controller.commands, isEmpty);
      expect(find.byType(ModeSheet), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late successful mode receipt cannot pop a new current route', (
    tester,
  ) async {
    await show(tester);
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('mode-global')));
    await tester.pump();
    final context = tester.element(find.byType(ModeSheet));
    controller.collection = ConfigCollection(
      entries: [],
      mode: TunnelMode.global,
    );
    controller.state = const AppSnapshot(
      phase: 'STOPPED',
      resultId: 'operation-1',
      resultSuccess: true,
      modeResult: _savedGlobalReceipt,
    );
    controller.changed();
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => const Scaffold(body: Text('New current page')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('New current page'), findsOneWidget);
    expect(find.byType(ModeSheet, skipOffstage: false), findsOneWidget);
    expect(controller.commands, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('mode callbacks and scheduled success read live task ownership', (
    tester,
  ) async {
    var active = true;
    await show(tester, isTaskActive: () => active);
    await open(tester);
    final oldChoose = tester
        .widget<OutlinedButton>(find.byKey(const ValueKey('mode-global')))
        .onPressed!;
    active = false;
    oldChoose();
    expect(controller.commands, isEmpty);
    active = true;
    await tester.tap(find.byKey(const ValueKey('mode-global')));
    await tester.pump();
    controller.collection = ConfigCollection(
      entries: [],
      mode: TunnelMode.global,
    );
    controller.state = const AppSnapshot(
      phase: 'STOPPED',
      resultId: 'operation-1',
      resultSuccess: true,
      modeResult: _savedGlobalReceipt,
    );
    controller.changed();
    active = false; // No declarative rebuild before the pending post-frame pop.
    await tester.pumpAndSettle();
    expect(find.byType(ModeSheet), findsOneWidget);
    expect(controller.commands, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  void replaceEmptyContext(String invalidation, {String? resultId}) {
    if (invalidation == 'epoch') controller.epoch++;
    controller.state = AppSnapshot(
      phase: 'STOPPED',
      storageEpoch: controller.epoch,
      resultId: resultId,
      resultSuccess: resultId != null,
      modeResult: resultId == null ? null : _savedGlobalReceipt,
      core: switch (invalidation) {
        'ready' => const CoreSnapshot(
          processId: 'preview-process',
          inputId: 'preview-input',
          generation: 7,
          phase: 'READY',
          configId: 'one',
          revision: 1,
          composition: 'one:1',
          purpose: 'PREVIEW',
        ),
        'partial' => const CoreSnapshot(
          generation: 0,
          phase: 'EMPTY',
          configId: 'new source',
        ),
        'phase' => const CoreSnapshot(generation: 0, phase: 'PREPARING'),
        _ => const CoreSnapshot(generation: 0, phase: 'EMPTY'),
      },
    );
  }

  for (final invalidation in ['ready', 'partial', 'phase', 'epoch']) {
    testWidgets('cached EMPTY mode choice rejects new $invalidation context', (
      tester,
    ) async {
      await show(tester);
      await open(tester);
      final choose = tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('mode-global')))
          .onPressed!;
      replaceEmptyContext(invalidation);
      // Exercise the captured callback without a rebuild adopting the new source.
      choose();
      expect(controller.commands, isEmpty);
      expect(find.byType(ModeSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      'scheduled EMPTY mode success rejects new $invalidation context',
      (tester) async {
        await show(tester);
        await open(tester);
        await tester.tap(find.byKey(const ValueKey('mode-global')));
        await tester.pump();
        controller.collection = ConfigCollection(
          entries: [],
          mode: TunnelMode.global,
        );
        controller.state = const AppSnapshot(
          phase: 'STOPPED',
          resultId: 'operation-1',
          resultSuccess: true,
          modeResult: _savedGlobalReceipt,
        );
        controller.changed();
        replaceEmptyContext(invalidation, resultId: 'operation-1');
        await tester.pumpAndSettle();
        expect(controller.commands, hasLength(1));
        expect(find.byType(ModeSheet), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'identified mode callback still requires its exact core identity',
    (tester) async {
      replaceEmptyContext('ready');
      await show(tester);
      await open(tester);
      final choose = tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('mode-global')))
          .onPressed!;
      controller.state = const AppSnapshot(
        phase: 'STOPPED',
        core: CoreSnapshot(
          processId: 'replacement-preview-process',
          inputId: 'replacement-preview-input',
          generation: 8,
          phase: 'READY',
          configId: 'one',
          revision: 1,
          composition: 'one:1',
          purpose: 'PREVIEW',
        ),
      );
      choose();
      expect(controller.commands, isEmpty);
      expect(find.byType(ModeSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'own mode detail dialog covers actions only for its actual lifetime',
    (tester) async {
      controller.state = const AppSnapshot(
        phase: 'RUNNING',
        generation: 1,
        configId: 'one',
        revision: 1,
        core: _vpnCore,
        mode: TunnelMode.rule,
        modeError: AppMessage('androidErrorModeUnconfirmed'),
      );
      await show(tester);
      await open(tester);
      final button = find.byKey(const ValueKey('mode-global'));
      final oldChoose = tester.widget<OutlinedButton>(button).onPressed!;
      final notice = find.descendant(
        of: find.byType(ModeSheet),
        matching: find.byType(SnackBar),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(
        find.descendant(of: notice, matching: find.text('错误详情')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      oldChoose();
      expect(controller.commands, isEmpty);
      await tester.tap(find.widgetWithText(TextButton, '关闭').hitTestable());
      await tester.pumpAndSettle();
      oldChoose();
      await tester.pump();
      expect(controller.commands.single['mode'], 'global');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('stopped preselection waits for saved result then closes', (
    tester,
  ) async {
    await show(tester);
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('mode-global')));
    await tester.pump();
    expect(controller.commands.single, {
      'action': 'setMode',
      'mode': 'global',
      'storageEpoch': 0,
    });
    expect(find.text('正在确认全局模式…'), findsNothing);
    expect(controller.collection.mode, isNull);
    controller.collection = ConfigCollection(
      entries: [],
      mode: TunnelMode.global,
    );
    controller.state = const AppSnapshot(
      phase: 'STOPPED',
      resultId: 'operation-1',
      resultSuccess: true,
      modeResult: _savedGlobalReceipt,
    );
    controller.changed();
    await tester.pumpAndSettle();
    expect(find.byType(ModeSheet), findsNothing);
    expect(find.text('全局模式 · 未运行'), findsWidgets);
  });

  testWidgets(
    'running selection waits for actual readback and pauses covered waves',
    (tester) async {
      controller.state = const AppSnapshot(
        phase: 'RUNNING',
        generation: 1,
        configId: 'one',
        revision: 1,
        core: _vpnCore,
        mode: TunnelMode.rule,
      );
      await show(tester);
      await tester.pump(const Duration(seconds: 3));
      await open(tester);
      final paint = tester
          .widgetList<CustomPaint>(
            find.byType(CustomPaint, skipOffstage: false),
          )
          .map((w) => w.painter)
          .whereType<RipplePainter>()
          .single;
      expect(paint.waves, isEmpty);
      await tester.tap(find.byKey(const ValueKey('mode-global')));
      controller.collection = ConfigCollection(
        entries: [],
        mode: TunnelMode.global,
      );
      controller.state = const AppSnapshot(
        phase: 'RUNNING',
        generation: 1,
        configId: 'one',
        revision: 1,
        core: _vpnCore,
        mode: TunnelMode.rule,
        operation: AppMessage('stageSwitchingMode'),
      );
      controller.changed();
      await tester.pump();
      expect(find.text('已保存：全局；供下次启动使用。'), findsNothing);
      expect(find.byType(ModeSheet), findsOneWidget);
      controller.state = AppSnapshot(
        phase: 'RUNNING',
        generation: 1,
        configId: 'one',
        revision: 1,
        core: _vpnCore,
        mode: TunnelMode.global,
        resultId: 'operation-1',
        resultSuccess: true,
        modeResult: _appliedModeReceipt(_vpnCore, TunnelMode.global),
      );
      controller.changed();
      await tester.pump();
      await tester
          .pump(); // Begin the reverse transition scheduled after the frame.
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(ModeSheet), findsNothing);
      await tester.pumpWidget(const SizedBox());
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  AppSnapshot runtimeModeSnapshot({
    required CoreSnapshot core,
    TunnelMode mode = TunnelMode.rule,
    bool vpn = true,
    Map<String, dynamic>? receipt,
  }) => AppSnapshot(
    phase: vpn ? 'RUNNING' : 'STOPPED',
    generation: core.generation,
    configId: core.configId,
    revision: core.revision,
    core: core,
    vpnIntent: vpn,
    lanIntent: !vpn,
    lanRunning: !vpn,
    mode: mode,
    resultId: receipt == null ? null : 'operation-1',
    resultSuccess: receipt != null,
    modeResult: receipt,
  );

  for (final vpn in [false, true]) {
    for (final actualFirst in [false, true]) {
      testWidgets(
        'mode closes only after both explicit receipt and actual vpn=$vpn actualFirst=$actualFirst',
        (tester) async {
          final target = vpn ? _vpnCore : _lanCore;
          final receipt = _appliedModeReceipt(target, TunnelMode.global);
          controller.state = runtimeModeSnapshot(core: target, vpn: vpn);
          controller.collection = ConfigCollection(
            entries: [],
            mode: TunnelMode.rule,
          );
          await show(tester);
          await open(tester);
          await tester.tap(find.byKey(const ValueKey('mode-global')));
          await tester.pump();
          controller.collection = ConfigCollection(
            entries: [],
            mode: TunnelMode.global,
          );
          controller.state = runtimeModeSnapshot(
            core: target,
            vpn: vpn,
            mode: actualFirst ? TunnelMode.global : TunnelMode.rule,
            receipt: actualFirst ? null : receipt,
          );
          controller.changed();
          await tester.pump();
          expect(find.byType(ModeSheet), findsOneWidget);
          expect(
            tester
                .widget<OutlinedButton>(
                  find.byKey(const ValueKey('mode-direct')),
                )
                .onPressed,
            isNull,
          );
          controller.state = runtimeModeSnapshot(
            core: target,
            vpn: vpn,
            mode: TunnelMode.global,
            receipt: receipt,
          );
          controller.changed();
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.byType(ModeSheet), findsNothing);
          expect(controller.commands, hasLength(1));
          expect(controller.state.resultSuccess, isTrue);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  const reconnectedCore = CoreSnapshot(
    processId: 'reconnected-process',
    inputId: 'reconnected-input',
    generation: 2,
    phase: 'READY',
    purpose: 'RUNNING',
    configId: 'one',
    revision: 1,
    composition: '["one",1]',
  );
  const unrelatedCore = CoreSnapshot(
    processId: 'unrelated-process',
    inputId: 'unrelated-input',
    generation: 3,
    phase: 'READY',
    purpose: 'RUNNING',
    configId: 'one',
    revision: 1,
    composition: '["one",1]',
  );
  for (final unrelated in [false, true]) {
    testWidgets(
      'mode reconnect follows only the receipt target unrelated=$unrelated',
      (tester) async {
        controller.state = runtimeModeSnapshot(core: _vpnCore);
        controller.collection = ConfigCollection(
          entries: [],
          mode: TunnelMode.rule,
        );
        await show(tester);
        await open(tester);
        await tester.tap(find.byKey(const ValueKey('mode-global')));
        await tester.pump();
        controller.state = const AppSnapshot(
          phase: 'STOPPED',
          writerBusy: true,
          operationId: 'operation-1',
        );
        controller.changed();
        await tester.pump();
        expect(controller.hasLocalFeedbackOwner, isTrue);
        controller.collection = ConfigCollection(
          entries: [],
          mode: TunnelMode.global,
        );
        final receipt = _appliedModeReceipt(reconnectedCore, TunnelMode.global);
        controller.state = runtimeModeSnapshot(
          core: unrelated ? unrelatedCore : reconnectedCore,
          mode: TunnelMode.global,
          receipt: receipt,
        );
        controller.changed();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.byType(ModeSheet),
          unrelated ? findsOneWidget : findsNothing,
        );
        expect(controller.commands, hasLength(1));
        if (unrelated) {
          expect(controller.hasLocalFeedbackOwner, isFalse);
          expect(
            tester
                .widget<OutlinedButton>(
                  find.byKey(const ValueKey('mode-direct')),
                )
                .onPressed,
            isNotNull,
          );
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'mode projection timeout releases choices and retries the producer without failing the completed operation',
    (tester) async {
      controller.state = runtimeModeSnapshot(core: _vpnCore);
      controller.collection = ConfigCollection(
        entries: [],
        mode: TunnelMode.rule,
      );
      await show(tester);
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('mode-global')));
      await tester.pump();
      controller.collection = ConfigCollection(
        entries: [],
        mode: TunnelMode.global,
      );
      controller.state = runtimeModeSnapshot(
        core: _vpnCore,
        receipt: _appliedModeReceipt(_vpnCore, TunnelMode.global),
      );
      controller.changed();
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const ValueKey('mode-direct')))
            .onPressed,
        isNull,
      );
      await tester.pump(
        const Duration(
          milliseconds: ApplicationContract.operationUiGraceMs + 1,
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byType(ModeSheet), findsOneWidget);
      expect(controller.state.resultSuccess, isTrue);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const ValueKey('mode-direct')))
            .onPressed,
        isNotNull,
      );
      final strings = AppLocalizations.of(
        tester.element(find.byType(ModeSheet)),
      );
      final notice = find.descendant(
        of: find.byType(ModeSheet),
        matching: find.byType(SnackBar),
      );
      expect(notice, findsOneWidget);
      expect(
        find.descendant(
          of: notice,
          matching: find.text(messages.temporaryModeUnknown.summary(strings)),
        ),
        findsOneWidget,
      );
      expect(controller.modeRefreshes, 0);
      final retry = find.descendant(
        of: notice,
        matching: find.text(strings.retry),
      );
      expect(retry.hitTestable(), findsOneWidget);
      await tester.tap(retry);
      await tester.pump();
      expect(controller.modeRefreshes, 1);
      expect(controller.commands, hasLength(1));
      expect(controller.state.resultSuccess, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  AppController receiptApp(SnapshotBridge bridge) {
    final app = AppController(
      bridge,
      store: MemoryStore(),
      overrideStore: ReadOnlyOverrideStore(),
      preferencesStore: MemoryPreferencesStore(),
    );
    addTearDown(app.dispose);
    return app;
  }

  testWidgets(
    'mode sheet displays original causes of actual submission rejection',
    (tester) async {
      final bridge = SnapshotBridge()
        ..submitResult = () async =>
            throw StateError('mode admission rejected');
      final app = receiptApp(bridge);
      await app.refresh();
      await show(tester, workspaceNavigator: true, owner: app);
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('mode-global')));
      final strings = AppLocalizations.of(
        tester.element(find.byType(ModeSheet)),
      );
      await openErrorDetails(
        tester,
        messages.requestNotAccepted.summary(strings),
        detail: 'Bad state: mode admission rejected',
      );
      expect(bridge.commands, hasLength(1));
      expect(find.byType(ModeSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'actual failure without a message shows a generic failure notice',
    (tester) async {
      var snapshot = const AppSnapshot(phase: 'STOPPED');
      final bridge = SnapshotBridge()..read = () async => snapshot;
      final app = receiptApp(bridge);
      await app.refresh();
      await show(tester, workspaceNavigator: true, owner: app);
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('mode-global')));
      await tester.pump();
      expect(bridge.commands, hasLength(1));
      expect(app.hasLocalFeedbackOwner, isTrue);
      snapshot = const AppSnapshot(phase: 'STOPPED', resultId: 'operation-1');
      await app.refresh();
      await tester.pumpAndSettle();
      final notice = find.descendant(
        of: find.byType(ModeSheet),
        matching: find.byType(SnackBar),
      );
      expect(notice, findsOneWidget);
      expect(
        find.descendant(
          of: notice,
          matching: find.text(
            messages.operationFailed.summary(
              AppLocalizations.of(tester.element(find.byType(ModeSheet))),
            ),
          ),
        ),
        findsOneWidget,
      );
      expect(
        app.feedbackHandledLocally(
          app.lastCommand!,
          submissionFailed: false,
          resultId: 'operation-1',
        ),
        isTrue,
      );
      expect(find.byType(ModeSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('failed apply keeps sheet open and actual selection unchanged', (
    tester,
  ) async {
    controller.state = const AppSnapshot(
      phase: 'RUNNING',
      generation: 1,
      configId: 'one',
      revision: 1,
      core: _vpnCore,
      mode: TunnelMode.rule,
    );
    await show(tester, workspaceNavigator: true);
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('mode-direct')));
    controller.collection = ConfigCollection(
      entries: [],
      mode: TunnelMode.direct,
    );
    controller.state = const AppSnapshot(
      phase: 'RUNNING',
      generation: 1,
      configId: 'one',
      revision: 1,
      core: _vpnCore,
      mode: TunnelMode.rule,
      resultId: 'operation-1',
      resultMessage: AppMessage('modeNotConfirmed', detail: _modeFailureDetail),
    );
    controller.changed();
    await tester.pump();
    expect(find.byType(ModeSheet), findsOneWidget);
    expect(find.text('正在确认直连模式…'), findsNothing);
    await tester.pump(const Duration(milliseconds: 300));
    await openErrorDetails(
      tester,
      messages.modeNotConfirmed.text,
      detail: _modeFailureDetail,
    );
    expect(find.text(messages.modeNotConfirmed.text), findsWidgets);
    expect(controller.state.mode, TunnelMode.rule);
    expect(controller.collection.mode, TunnelMode.direct);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('mode-direct')))
          .onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
  });

  for (final failed in [false, true]) {
    testWidgets(
      'open mode sheet waits for decoded startup mode before actual or failure failed=$failed',
      (tester) async {
        controller.collection = ConfigCollection(
          entries: [],
          mode: TunnelMode.global,
        );
        await show(tester);
        await open(tester);
        Map<String, dynamic> snapshot(String phase) => {
          'phase': phase == 'loading' ? 'STARTING' : 'RUNNING',
          'storageReady': true,
          'storageEpoch': 0,
          'core': {
            'phase': phase,
            'purpose': 'RUNNING',
            'processId': 'mode-process',
            'inputId': 'mode-input',
            'generation': 1,
            'networkRevision': 1,
            'configId': 'one',
            'revision': 1,
            'composition': '["one",1]',
          },
          'mode': null,
          'modeError': null,
        };
        for (final phase in ['loading', 'ready']) {
          controller.state = AppSnapshot.fromMap(snapshot(phase));
          controller.changed();
          await tester.pump();
          expect(controller.state.modeErrorMessage, isNull);
          expect(find.byType(SnackBar), findsNothing);
          await tester.pump(const Duration(seconds: 5));
          expect(find.byType(SnackBar), findsNothing);
          for (final mode in TunnelMode.values) {
            final button = tester.widget<OutlinedButton>(
              find.byKey(ValueKey('mode-${mode.name}')),
            );
            expect(
              button.style!.backgroundColor!.resolve({}),
              AppTheme.light.colorScheme.surface,
            );
          }
        }
        controller.state = AppSnapshot.fromMap({
          ...snapshot('ready'),
          'mode': failed ? null : 'direct',
          'modeError': failed
              ? messages.temporaryModeUnknown
                    .withDetail(_modeFailureDetail)
                    .toMap()
              : null,
        });
        controller.changed();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(ModeSheet), findsOneWidget);
        if (failed) {
          expect(find.byType(SnackBar), findsOneWidget);
          expect(controller.state.modeErrorMessage!.detail, _modeFailureDetail);
        } else {
          expect(find.byType(SnackBar), findsNothing);
          expect(controller.state.mode, TunnelMode.direct);
          final direct = tester.widget<OutlinedButton>(
            find.byKey(const ValueKey('mode-direct')),
          );
          expect(
            direct.style!.backgroundColor!.resolve({}),
            AppTheme.light.colorScheme.surfaceContainer,
          );
          expect(direct.onPressed, isNotNull);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'unknown mode does not masquerade as preference or prevent stopping',
    (tester) async {
      controller.collection = ConfigCollection(
        entries: [],
        mode: TunnelMode.global,
      );
      controller.state = const AppSnapshot(
        phase: 'RUNNING',
        generation: 1,
        configId: 'one',
        revision: 1,
        core: _vpnCore,
        modeError: AppMessage('androidErrorModeUnconfirmed'),
      );
      await show(tester);
      expect(find.text('运行模式未确认'), findsWidgets);
      expect(find.text('全局模式'), findsNothing);
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('mode-trigger')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('power-button')))
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'mode sheet uses neutral surfaces and distinct icons dark=$dark',
      (tester) async {
        await show(tester, dark: dark);
        await open(tester);
        final colors = (dark ? AppTheme.dark : AppTheme.light).colorScheme;
        expect(
          tester.widget<BottomSheet>(find.byType(BottomSheet)).backgroundColor,
          colors.surface,
        );
        final palette = ModePalette(dark);
        for (final (mode, icon, category) in [
          (TunnelMode.rule, Icons.alt_route_rounded, palette.rule),
          (TunnelMode.global, Icons.public_outlined, palette.global),
          (TunnelMode.direct, Icons.arrow_forward_rounded, palette.direct),
        ]) {
          final finder = find.byKey(ValueKey('mode-${mode.name}'));
          final button = tester.widget<OutlinedButton>(finder);
          expect(
            find.descendant(of: finder, matching: find.byIcon(icon)),
            findsOneWidget,
          );
          expect(
            tester
                .widget<Icon>(
                  find.descendant(of: finder, matching: find.byIcon(icon)),
                )
                .color,
            category,
          );
          final background = Color.alphaBlend(
            category.withValues(alpha: .10),
            colors.surface,
          );
          final luminances = [
            category.computeLuminance(),
            background.computeLuminance(),
          ]..sort();
          expect(
            (luminances.last + .05) / (luminances.first + .05),
            greaterThanOrEqualTo(3),
          );
          expect(button.style!.side!.resolve({})!.color, colors.outlineVariant);
          expect(
            button.style!.shape!.resolve({}),
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          );
          expect(button.style!.backgroundColor!.resolve({}), colors.surface);
          expect(
            tester
                .widget<Text>(
                  find.text(
                    mode.description(
                      AppLocalizations.of(
                        tester.element(find.byType(ModeSheet)),
                      ),
                    ),
                  ),
                )
                .style!
                .color,
            colors.onSurfaceVariant,
          );
        }
        expect(find.byIcon(Icons.check), findsNothing);
        final rule = find.byKey(const ValueKey('mode-rule'));
        final originalRect = tester.getRect(rule);
        controller.collection = ConfigCollection(
          entries: [],
          mode: TunnelMode.rule,
        );
        controller.changed();
        await tester.pump();
        expect(tester.getRect(rule), originalRect);
        expect(find.byIcon(Icons.check), findsNothing);
        expect(
          tester
              .widget<OutlinedButton>(rule)
              .style!
              .backgroundColor!
              .resolve({}),
          colors.surfaceContainer,
        );
        final strings = AppLocalizations.of(tester.element(rule));
        final ruleLabel = find.descendant(
          of: rule,
          matching: find.text(TunnelMode.rule.label(strings)),
        );
        expect(
          tester.widget<Text>(ruleLabel).style!.fontWeight,
          FontWeight.w700,
        );
        final direct = find.byKey(const ValueKey('mode-direct'));
        final directLabel = find.descendant(
          of: direct,
          matching: find.text(TunnelMode.direct.label(strings)),
        );
        expect(
          tester.widget<Text>(directLabel).style!.fontWeight,
          FontWeight.w400,
        );
        await tester.tap(direct);
        await tester.pump();
        expect(find.byIcon(Icons.check), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );

    for (final scale in [1.0, 2.0]) {
      testWidgets('mode sheet fits short screen dark=$dark scale=$scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await show(tester, scale: scale, dark: dark);
        await open(tester);
        await tester.ensureVisible(find.byKey(const ValueKey('mode-direct')));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('mode-direct')).hitTestable(),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
