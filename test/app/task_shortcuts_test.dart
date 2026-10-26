import 'dart:async';

import 'package:clash_pseudo/src/app/app_shell.dart';
import 'package:clash_pseudo/src/app/app_task.dart';
import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/app/workspace_window.dart';
import 'package:clash_pseudo/src/features/overrides/rule_form.dart';
import 'package:clash_pseudo/src/features/overview/overview_page.dart';
import 'package:clash_pseudo/src/features/strategies/strategies_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/strategies/strategy_fakes.dart';

Future<void> _key(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool command = false,
}) async {
  final modifier = command
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(modifier);
  await tester.pump();
}

void main() {
  late StrategyAppFake app;

  setUp(() {
    app = StrategyAppFake(StrategyBridgeFake())
      ..preferencesLoaded = true
      ..overridesLoaded = true;
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        builder: (context, child) =>
            WorkspaceWindow(controller: app, child: child!),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppShell(controller: app),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openRule(
    WidgetTester tester,
    Future<void> Function(String) save,
  ) async {
    final navigator = Navigator.of(tester.element(find.byType(OverviewPage)));
    unawaited(
      navigator.push<void>(
        FocusedPageRoute(
          builder: (_) => RuleFormPage(
            initialRule: 'DOMAIN,initial.test,DIRECT',
            targets: const ['DIRECT'],
            onSave: save,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);
  }

  testWidgets('Ctrl and Cmd find use the same task through carrier changes', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Strategies'),
      ),
    );
    await tester.pumpAndSettle();
    await _key(tester, LogicalKeyboardKey.keyF);
    final field = find.descendant(
      of: find.byType(StrategiesPage),
      matching: find.byType(TextField),
    );
    expect(field, findsOneWidget);
    final controller = tester.widget<TextField>(field).controller!;
    final state = tester.state(find.byType(StrategiesPage));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'retained query',
        selection: TextSelection.collapsed(offset: 8),
        composing: TextRange(start: 0, end: 8),
      ),
    );
    await tester.pump();
    final value = controller.value;
    final focus = FocusManager.instance.primaryFocus;
    for (final width in [1000.0, 599.0, 600.0, 320.0]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.state(find.byType(StrategiesPage)), same(state));
      expect(tester.widget<TextField>(field).controller, same(controller));
      expect(controller.value, value);
      expect(FocusManager.instance.primaryFocus, same(focus));
      expect(app.commands, isEmpty);
      expect(tester.takeException(), isNull);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(field, findsNothing);
    await _key(tester, LogicalKeyboardKey.keyF, command: true);
    expect(field, findsOneWidget);
  });

  testWidgets(
    'GUI save shortcut shares validation and prevents duplicate submission',
    (tester) async {
      await mount(tester);
      final saving = Completer<void>();
      final saved = <String>[];
      await openRule(tester, (rule) {
        saved.add(rule);
        return saving.future;
      });
      await _key(tester, LogicalKeyboardKey.keyS);
      expect(saved, ['DOMAIN,initial.test,DIRECT']);
      await _key(tester, LogicalKeyboardKey.keyS, command: true);
      expect(saved, hasLength(1));
      saving.complete();
      await tester.pumpAndSettle();
      expect(find.byType(RuleFormPage), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
    },
  );

  testWidgets('saved GUI waits for interaction before closing its route', (
    tester,
  ) async {
    await mount(tester);
    final saving = Completer<void>();
    await openRule(tester, (_) => saving.future);
    await _key(tester, LogicalKeyboardKey.keyS);
    app.setInteractive(false);
    saving.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(RuleFormPage), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    app.setInteractive(true);
    await tester.pumpAndSettle();
    expect(find.byType(RuleFormPage), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('workspace navigation remains in the accessible route tree', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await mount(tester);
    for (final width in [1000.0, 320.0, 1704.0]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpAndSettle();
      final navigation = find.byType(
        width >= 600 ? NavigationRail : NavigationBar,
      );
      final settings = find.descendant(
        of: navigation,
        matching: find.text('Settings'),
      );
      expect(
        tester.getSemantics(settings).getSemanticsData().label,
        contains('Settings'),
      );
      await tester.tap(settings);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp('Overview')), findsWidgets);
      expect(tester.takeException(), isNull);
    }
    semantics.dispose();
  });

  testWidgets('root modal retains its draft outside supported bounds', (
    tester,
  ) async {
    await mount(tester);
    final controller = TextEditingController.fromValue(
      const TextEditingValue(
        text: 'retained modal',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    final context = tester.element(find.byType(OverviewPage));
    unawaited(
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          content: TextField(controller: controller),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Dismiss'),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final modal = tester.element(find.byType(AlertDialog));
    final value = controller.value;
    tester.view.physicalSize = const Size(200, 200);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      tester.element(find.byType(AlertDialog, skipOffstage: false)),
      same(modal),
    );
    expect(controller.value, value);
    tester.view.physicalSize = const Size(320, 900);
    await tester.pumpAndSettle();
    expect(tester.element(find.byType(AlertDialog)), same(modal));
    expect(controller.value, value);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    controller.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('IME capacity gates the workspace and preserves the GUI draft', (
    tester,
  ) async {
    await mount(tester);
    addTearDown(tester.view.resetViewInsets);
    var saves = 0;
    await openRule(tester, (_) async => saves++);
    final field = find.byType(TextField).last;
    await tester.tap(field);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'keyboard.test',
        selection: TextSelection(baseOffset: 2, extentOffset: 8),
        composing: TextRange(start: 2, end: 8),
      ),
    );
    await tester.pump();
    final controller = tester.widget<TextField>(field).controller!;
    final value = controller.value;
    final state = tester.state(find.byType(RuleFormPage));
    final strings = AppLocalizations.of(
      tester.element(find.byType(RuleFormPage)),
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 621);
    await tester.pumpAndSettle();
    expect(find.text(strings.enlargeWindow), findsOneWidget);
    expect(find.byType(RuleFormPage), findsNothing);
    expect(
      tester.state(find.byType(RuleFormPage, skipOffstage: false)),
      same(state),
    );
    await _key(tester, LogicalKeyboardKey.keyS);
    expect(saves, 0);
    expect(controller.value, value);
    tester.view.viewInsets = const FakeViewPadding(bottom: 400);
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(RuleFormPage)), same(state));
    expect(tester.widget<TextField>(field).controller, same(controller));
    expect(controller.value, value);
    expect(field.hitTestable(), findsOneWidget);
    expect(saves, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('GUI draft survives unsupported bounds and overview asks once', (
    tester,
  ) async {
    await mount(tester);
    await openRule(
      tester,
      (_) async => fail('Navigation must not save the draft'),
    );
    final field = find.byType(TextField).last;
    await tester.tap(field);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'retained.test',
        selection: TextSelection.collapsed(offset: 8),
        composing: TextRange(start: 0, end: 8),
      ),
    );
    await tester.pump();
    final controller = tester.widget<TextField>(field).controller!;
    final original = controller.value;
    final state = tester.state(find.byType(RuleFormPage));
    tester.view.physicalSize = const Size(200, 200);
    await tester.pumpAndSettle();
    expect(find.byType(RuleFormPage), findsNothing);
    expect(
      tester.state(find.byType(RuleFormPage, skipOffstage: false)),
      same(state),
    );
    expect(controller.value, original);
    await _key(tester, LogicalKeyboardKey.keyS);
    expect(app.commands, isEmpty);
    tester.view.physicalSize = const Size(320, 900);
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(RuleFormPage)), same(state));
    expect(controller.value, original);
    app.requestOverview();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    app.requestOverview();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Continue editing'));
    await tester.pumpAndSettle();
    expect(find.byType(RuleFormPage), findsOneWidget);
    expect(controller.text, original.text);
    app.requestOverview();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(RuleFormPage), findsNothing);
    expect(
      tester.widget<AppTaskScope>(find.byType(AppTaskScope)).task,
      AppTask.overview,
    );
    expect(app.commands, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
