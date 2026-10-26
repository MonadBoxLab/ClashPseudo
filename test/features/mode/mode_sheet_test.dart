import 'dart:async';

import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/app/app_controller.dart';
import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/app/widgets/operation_feedback.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/mode/mode_sheet.dart';
import 'package:clash_pseudo/src/features/mode/tunnel_mode.dart';
import 'package:clash_pseudo/src/features/overview/overview_page.dart';
import 'package:clash_pseudo/src/features/overview/widgets/power_ripples.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:flutter_test/flutter_test.dart';

class ModeController extends AppController {
  ModeController() : super(AppBridge()) {
    loading = false;
    configsLoaded = true;
    state = const AppSnapshot(phase: 'STOPPED');
  }
  @override
  Future<void> refresh() async {}

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
  setUp(() {
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
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        theme: dark ? AppTheme.dark : AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: scale == 2,
          ),
          child: child!,
        ),
        home: OperationFeedback(
          controller: controller,
          child: OverviewPage(controller: controller),
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

  testWidgets(
    'mode opening captures its epoch before the deferred route build and never borrows restore permissions',
    (tester) async {
      controller.epoch = 1;
      await show(tester, scale: 2);
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
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(ModeSheet),
            matching: find.byIcon(Icons.error_outline),
          ),
          findsNothing,
        );
        final info = find.descendant(
          of: find.byType(ModeSheet),
          matching: find.byIcon(Icons.info_outline),
        );
        expect(
          tester.widget<Icon>(info).color,
          Theme.of(tester.element(info)).colorScheme.primary,
        );
        controller.state = const AppSnapshot(
          phase: 'RUNNING',
          modeError: AppMessage('androidErrorModeUnconfirmed'),
        );
        controller.changed();
        await tester.pump();
        expect(tester.getRect(title), titleRect);
        expect([for (final button in buttons) tester.getRect(button)], rows);
        expect(
          find.descendant(
            of: find.byType(ModeSheet),
            matching: find.byIcon(Icons.error_outline),
          ),
          findsOneWidget,
        );
        final failure = find.descendant(
          of: find.byType(ModeSheet),
          matching: find.byIcon(Icons.error_outline),
        );
        expect(
          tester.widget<Icon>(failure).color,
          Theme.of(tester.element(failure)).colorScheme.error,
        );
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
        await show(tester, scale: scale);
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
          resultId: 'failed',
          resultMessage: AppMessage('configSaveFailed'),
        );
        controller.changed();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(AlertDialog), findsOneWidget);
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
      resultId: 'one',
      resultSuccess: true,
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
        mode: TunnelMode.rule,
        operation: AppMessage('stageSwitchingMode'),
      );
      controller.changed();
      await tester.pump();
      expect(find.text('已保存：全局；供下次启动使用。'), findsNothing);
      expect(find.byType(ModeSheet), findsOneWidget);
      controller.state = const AppSnapshot(
        phase: 'RUNNING',
        mode: TunnelMode.global,
        resultId: 'one',
        resultSuccess: true,
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

  testWidgets('failed apply keeps sheet open and actual selection unchanged', (
    tester,
  ) async {
    controller.state = const AppSnapshot(
      phase: 'RUNNING',
      mode: TunnelMode.rule,
    );
    await show(tester);
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('mode-direct')));
    controller.collection = ConfigCollection(
      entries: [],
      mode: TunnelMode.direct,
    );
    controller.state = const AppSnapshot(
      phase: 'RUNNING',
      mode: TunnelMode.rule,
      resultId: 'failed',
      resultMessage: AppMessage('modeNotConfirmed'),
    );
    controller.changed();
    await tester.pump();
    expect(find.byType(ModeSheet), findsOneWidget);
    expect(find.text('正在确认直连模式…'), findsNothing);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text(messages.modeNotConfirmed.text), findsWidgets);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('mode-direct')))
          .onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'unknown mode does not masquerade as preference or prevent stopping',
    (tester) async {
      controller.collection = ConfigCollection(
        entries: [],
        mode: TunnelMode.global,
      );
      controller.state = const AppSnapshot(
        phase: 'RUNNING',
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
        expect(find.byIcon(Icons.check), findsOneWidget);
        expect(
          tester
              .widget<OutlinedButton>(rule)
              .style!
              .backgroundColor!
              .resolve({}),
          colors.surfaceContainer,
        );
        expect(
          tester.widget<Icon>(find.byIcon(Icons.check)).color,
          colors.primary,
        );
        await tester.tap(find.byKey(const ValueKey('mode-direct')));
        await tester.pump();
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('mode-rule')),
            matching: find.byIcon(Icons.check),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('mode-direct')),
            matching: find.byIcon(Icons.check),
          ),
          findsNothing,
        );
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
