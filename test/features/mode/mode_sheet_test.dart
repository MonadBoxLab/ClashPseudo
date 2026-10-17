import 'package:clash_pseudo/app/app_controller.dart';
import 'package:clash_pseudo/app/app_theme.dart';
import 'package:clash_pseudo/app/widgets/operation_feedback.dart';
import 'package:clash_pseudo/features/configs/config_entry.dart';
import 'package:clash_pseudo/features/mode/mode_sheet.dart';
import 'package:clash_pseudo/features/mode/tunnel_mode.dart';
import 'package:clash_pseudo/features/overview/overview_page.dart';
import 'package:clash_pseudo/features/overview/widgets/power_ripples.dart';
import 'package:clash_pseudo/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class ModeController extends AppController {
  ModeController() : super(AppBridge()) {
    loading = false;
    configsLoaded = true;
    state = const AppSnapshot(phase: 'STOPPED');
  }
  final commands = <Map<String, Object?>>[];
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

void main() {
  late ModeController controller;
  setUp(() => controller = ModeController());
  tearDown(() => controller.dispose());
  Future<void> show(
    WidgetTester tester, {
    double scale = 1,
    bool dark = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
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
              tester.getSize(find.text(mode.description)).height,
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
          operation: '正在保存模式',
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
          resultMessage: '无法保存模式，请重试。',
        );
        controller.changed();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('无法保存模式，请重试。'), findsOneWidget);
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
    expect(controller.commands.single, {'action': 'setMode', 'mode': 'global'});
    expect(find.text('正在确认全局模式…'), findsNothing);
    expect(controller.collection.mode, TunnelMode.rule);
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
        operation: '正在切换运行模式',
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
      resultMessage: '模式已保存供下次启动使用；本次切换未确认。',
    );
    controller.changed();
    await tester.pump();
    expect(find.byType(ModeSheet), findsOneWidget);
    expect(find.text('正在确认直连模式…'), findsNothing);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('本次切换未确认'), findsWidgets);
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
        modeError: '模式读取失败',
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
          expect(
            button.style!.backgroundColor!.resolve({}),
            mode == TunnelMode.rule ? colors.surfaceContainer : colors.surface,
          );
          expect(
            tester.widget<Text>(find.text(mode.description)).style!.color,
            colors.onSurfaceVariant,
          );
        }
        expect(find.byIcon(Icons.check), findsOneWidget);
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
