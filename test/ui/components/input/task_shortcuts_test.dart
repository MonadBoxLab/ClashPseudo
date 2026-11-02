import 'dart:async';

import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/ui/components/input/task_shortcuts.dart';
import 'package:clash_pseudo/src/ui/navigation/app_shell.dart';
import 'package:clash_pseudo/src/ui/navigation/page_route.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/navigation/workspace_window.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/rule_form.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/strategy_group_form.dart';
import 'package:clash_pseudo/src/ui/overview/overview_page.dart';
import 'package:clash_pseudo/src/ui/strategies/strategies_page.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/strategy_fakes.dart';

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

class _ShortcutDeactivationProbe extends StatefulWidget {
  const _ShortcutDeactivationProbe({required this.onDeactivate});

  final VoidCallback onDeactivate;

  @override
  State<_ShortcutDeactivationProbe> createState() =>
      _ShortcutDeactivationProbeState();
}

class _ShortcutDeactivationProbeState
    extends State<_ShortcutDeactivationProbe> {
  @override
  void deactivate() {
    widget.onDeactivate();
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
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
        navigatorObservers: [AppTaskNavigatorObserver()],
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

  testWidgets(
    'retained shortcuts recheck task, interaction and enabled gates',
    (tester) async {
      final eligibility = ValueNotifier((active: true, enabled: true));
      final focus = FocusNode();
      addTearDown(eligibility.dispose);
      addTearDown(focus.dispose);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
      });
      final actions = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: AppTaskScope(
            open: (_) {},
            task: AppTask.overview,
            owner: app,
            child: ValueListenableBuilder(
              valueListenable: eligibility,
              builder: (_, value, _) => AppTaskActivity(
                active: value.active,
                isActiveNow: () => eligibility.value.active,
                child: TaskShortcuts(
                  enabled: value.enabled,
                  onSearch: () => actions.add('search'),
                  onSave: () => actions.add('save'),
                  onEscape: () => actions.add('escape'),
                  child: Scaffold(body: TextField(focusNode: focus)),
                ),
              ),
            ),
          ),
        ),
      );
      focus.requestFocus();
      await tester.pump();
      final shortcut = find.descendant(
        of: find.byType(TaskShortcuts),
        matching: find.byType(CallbackShortcuts),
      );
      final retained = tester
          .widget<CallbackShortcuts>(shortcut)
          .bindings
          .values
          .toList();
      for (final action in retained) {
        action();
      }
      expect(actions, ['search', 'search', 'save', 'save', 'escape']);
      actions.clear();
      app.setInteractive(false);
      for (final action in retained) {
        action();
      }
      expect(actions, isEmpty);
      await tester.pump();
      expect(focus.hasFocus, isFalse);
      expect(tester.widget<CallbackShortcuts>(shortcut).bindings, isEmpty);
      app.setInteractive(true);
      eligibility.value = (active: false, enabled: true);
      for (final action in retained) {
        action();
      }
      expect(
        actions,
        isEmpty,
        reason: 'live authority precedes the next frame',
      );
      await tester.pump();
      for (final action in retained) {
        action();
      }
      expect(actions, isEmpty);
      expect(tester.widget<CallbackShortcuts>(shortcut).bindings, isEmpty);
      expect(focus.canRequestFocus, isFalse);
      eligibility.value = (active: true, enabled: false);
      await tester.pump();
      for (final action in retained) {
        action();
      }
      expect(actions, isEmpty);
      expect(focus.canRequestFocus, isFalse);
      eligibility.value = (active: true, enabled: true);
      await tester.pump();
      retained.first();
      expect(actions, ['search']);
      await tester.pumpWidget(const SizedBox.shrink());
      retained.first();
      expect(actions, ['search']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('shortcut suspension preserves trigger focus and can resume', (
    tester,
  ) async {
    final shortcutsEnabled = ValueNotifier(true);
    final trigger = FocusNode();
    final actions = <String>[];
    addTearDown(shortcutsEnabled.dispose);
    addTearDown(trigger.dispose);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppTaskScope(
            open: (_) {},
            task: AppTask.overview,
            owner: app,
            child: ValueListenableBuilder(
              valueListenable: shortcutsEnabled,
              builder: (_, value, _) => TaskShortcuts(
                shortcutsEnabled: value,
                onSearch: () => actions.add('search'),
                onSave: () => actions.add('save'),
                onEscape: () => actions.add('escape'),
                child: TextButton(
                  focusNode: trigger,
                  onPressed: () {},
                  child: const Text('Menu trigger'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final bindings = find.descendant(
      of: find.byType(TaskShortcuts),
      matching: find.byType(CallbackShortcuts),
    );
    final scope = find.descendant(
      of: find.byType(TaskShortcuts),
      matching: find.byType(FocusScope),
    );
    final retained = tester
        .widget<CallbackShortcuts>(bindings)
        .bindings
        .values
        .toList();
    expect(retained, hasLength(5));
    trigger.requestFocus();
    await tester.pump();
    expect(trigger.hasFocus, isTrue);

    shortcutsEnabled.value = false;
    await tester.pump();
    expect(tester.widget<CallbackShortcuts>(bindings).bindings, isEmpty);
    final focusScope = tester.widget<FocusScope>(scope);
    expect(focusScope.canRequestFocus, isTrue);
    expect(focusScope.descendantsAreFocusable, isTrue);
    expect(focusScope.descendantsAreTraversable, isTrue);
    expect(trigger.canRequestFocus, isTrue);
    trigger.unfocus();
    await tester.pump();
    trigger.requestFocus();
    await tester.pump();
    expect(trigger.hasFocus, isTrue);
    for (final callback in retained) {
      callback();
    }
    await _key(tester, LogicalKeyboardKey.keyF);
    await _key(tester, LogicalKeyboardKey.keyS, command: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(actions, isEmpty);

    shortcutsEnabled.value = true;
    await tester.pump();
    for (final callback in retained) {
      callback();
    }
    expect(actions, ['search', 'search', 'save', 'save', 'escape']);
    expect(trigger.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached shortcuts reject covering routes before a frame', (
    tester,
  ) async {
    final actions = <String>[];
    final focus = FocusNode();
    addTearDown(focus.dispose);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: AppTaskScope(
          open: (_) {},
          task: AppTask.overview,
          owner: app,
          child: TaskShortcuts(
            onSearch: () => actions.add('search'),
            onSave: () => actions.add('save'),
            onEscape: () => actions.add('escape'),
            child: Scaffold(body: TextField(focusNode: focus)),
          ),
        ),
      ),
    );
    final origin = tester.element(find.byType(TaskShortcuts));
    final navigator = Navigator.of(origin);
    final bindings = find.descendant(
      of: find.byType(TaskShortcuts),
      matching: find.byType(CallbackShortcuts),
    );
    final retained = tester
        .widget<CallbackShortcuts>(bindings)
        .bindings
        .values
        .toList();
    expect(retained, hasLength(5));
    focus.requestFocus();
    await tester.pump();
    final popup = DialogRoute<void>(
      context: origin,
      builder: (_) => const AlertDialog(content: Text('Covering route')),
    );
    unawaited(navigator.push(popup));
    for (final callback in retained) {
      callback();
    }
    expect(actions, isEmpty);
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isFalse);
    expect(tester.widget<CallbackShortcuts>(bindings).bindings, isEmpty);
    final scope = tester.widget<FocusScope>(
      find.descendant(
        of: find.byType(TaskShortcuts),
        matching: find.byType(FocusScope),
      ),
    );
    expect(scope.canRequestFocus, isFalse);
    expect(scope.descendantsAreFocusable, isFalse);
    expect(scope.descendantsAreTraversable, isFalse);

    navigator.pop();
    for (final callback in retained) {
      callback();
    }
    expect(actions, ['search', 'search', 'save', 'save', 'escape']);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('deactivated mounted shortcuts reject callbacks and reactivate', (
    tester,
  ) async {
    final key = GlobalKey();
    final actions = <String>[];
    final retained = <VoidCallback>[];
    late State<StatefulWidget> shortcutState;
    var deactivations = 0;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
    });
    Widget host(bool moved) {
      final shortcuts = TaskShortcuts(
        key: key,
        onSearch: () => actions.add('search'),
        onSave: () => actions.add('save'),
        onEscape: () => actions.add('escape'),
        child: _ShortcutDeactivationProbe(
          onDeactivate: () {
            deactivations++;
            expect(shortcutState.mounted, isTrue);
            for (final callback in retained) {
              callback();
            }
          },
        ),
      );
      return MaterialApp(
        home: AppTaskScope(
          open: (_) {},
          task: AppTask.overview,
          owner: app,
          child: Row(
            children: [
              Expanded(child: moved ? const SizedBox.shrink() : shortcuts),
              Expanded(child: moved ? shortcuts : const SizedBox.shrink()),
            ],
          ),
        ),
      );
    }

    await tester.pumpWidget(host(false));
    shortcutState = tester.state(find.byType(TaskShortcuts));
    retained.addAll(
      tester
          .widget<CallbackShortcuts>(
            find.descendant(
              of: find.byType(TaskShortcuts),
              matching: find.byType(CallbackShortcuts),
            ),
          )
          .bindings
          .values,
    );
    expect(retained, hasLength(5));
    await tester.pumpWidget(host(true));
    expect(deactivations, 1);
    expect(tester.state(find.byType(TaskShortcuts)), same(shortcutState));
    expect(actions, isEmpty);
    for (final callback in retained) {
      callback();
    }
    expect(actions, ['search', 'search', 'save', 'save', 'escape']);
    actions.clear();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(deactivations, 2);
    for (final callback in retained) {
      callback();
    }
    expect(actions, isEmpty);
    expect(tester.takeException(), isNull);
  });

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

  testWidgets(
    'root modal remains usable in a narrow window and retains its draft',
    (tester) async {
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
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.element(find.byType(AlertDialog)), same(modal));
      expect(controller.value, value);
      tester.view.physicalSize = const Size(320, 900);
      await tester.pumpAndSettle();
      expect(tester.element(find.byType(AlertDialog)), same(modal));
      expect(controller.value, value);
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      controller.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('IME resize keeps the GUI draft and the save shortcut usable', (
    tester,
  ) async {
    await mount(tester);
    addTearDown(tester.view.resetViewInsets);
    final saved = <String>[];
    await openRule(tester, (rule) async => saved.add(rule));
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
    tester.view.viewInsets = const FakeViewPadding(bottom: 621);
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(RuleFormPage)), same(state));
    expect(tester.widget<TextField>(field).controller, same(controller));
    expect(controller.value, value);
    expect(app.interactive, isTrue);
    tester.view.viewInsets = const FakeViewPadding(bottom: 400);
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(RuleFormPage)), same(state));
    expect(tester.widget<TextField>(field).controller, same(controller));
    expect(controller.value, value);
    expect(field.hitTestable(), findsOneWidget);
    expect(saved, isEmpty);
    tester.view.viewInsets = const FakeViewPadding(bottom: 621);
    await tester.pumpAndSettle();
    await _key(tester, LogicalKeyboardKey.keyS);
    await tester.pumpAndSettle();
    expect(saved, ['DOMAIN,keyboard.test,DIRECT']);
    expect(find.byType(RuleFormPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('GUI draft survives a narrow window and overview asks once', (
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
    final layoutErrors = <FlutterErrorDetails>[];
    final reportError = FlutterError.onError!;
    FlutterError.onError = (details) {
      layoutErrors.add(details);
      reportError(details);
    };
    try {
      tester.view.physicalSize = const Size(200, 200);
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(RuleFormPage)), same(state));
      expect(controller.value, original);
      expect(app.interactive, isTrue);
      expect(app.commands, isEmpty);
      tester.view.physicalSize = const Size(320, 900);
      await tester.pumpAndSettle();
    } finally {
      FlutterError.onError = reportError;
    }
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
    expect(
      tester.takeException(),
      isNull,
      reason: layoutErrors.map((details) => details.toString()).join('\n'),
    );
  });

  Future<FocusedPageRoute<Map<String, Object?>>> openGroup(
    WidgetTester tester,
    Future<void> Function(Map<String, Object?>) save, {
    VoidCallback? onSaveHandled,
  }) async {
    final navigator = Navigator.of(tester.element(find.byType(OverviewPage)));
    final route = FocusedPageRoute<Map<String, Object?>>(
      builder: (_) => StrategyGroupFormPage(
        initialDefinition: const {
          'name': 'controlled',
          'type': 'select',
          'proxies': ['DIRECT'],
        },
        onSave: save,
        onSaveHandled: onSaveHandled,
      ),
    );
    unawaited(navigator.push(route));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);
    return route;
  }

  testWidgets('real shell group save waits through an interactive pause', (
    tester,
  ) async {
    await mount(tester);
    final saving = Completer<void>();
    final saved = <Map<String, Object?>>[];
    final results = <Map<String, Object?>?>[];
    var handled = 0;
    final route = await openGroup(tester, (definition) {
      saved.add(definition);
      return saving.future;
    }, onSaveHandled: () => handled++);
    unawaited(route.popped.then(results.add));
    final context = tester.element(find.byType(StrategyGroupFormPage));
    final state = tester.state(find.byType(StrategyGroupFormPage));
    final source = AppTaskActivity.captureSource(context);
    final active = AppTaskActivity.capture(context);
    await _key(tester, LogicalKeyboardKey.keyS);
    expect(saved, [
      {
        'name': 'controlled',
        'type': 'select',
        'proxies': ['DIRECT'],
      },
    ]);
    app.setInteractive(false);
    saving.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(source(), isTrue);
    expect(active(), isFalse);
    expect(handled, 1);
    expect(results, isEmpty);
    expect(route.isCurrent, isTrue);
    expect(tester.state(find.byType(StrategyGroupFormPage)), same(state));
    expect(find.byType(NavigationBar), findsNothing);
    app.setInteractive(true);
    await tester.pumpAndSettle();
    expect(results, hasLength(1));
    expect(results.single, same(saved.single));
    expect(handled, 1);
    expect(saved, hasLength(1));
    expect(find.byType(StrategyGroupFormPage), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final change in ['inner cover', 'outer cover', 'retired route']) {
    testWidgets('real shell completed group cannot borrow $change on resume', (
      tester,
    ) async {
      await mount(tester);
      final saving = Completer<void>();
      final saved = <Map<String, Object?>>[];
      final results = <Map<String, Object?>?>[];
      var handled = 0;
      final route = await openGroup(tester, (definition) {
        saved.add(definition);
        return saving.future;
      }, onSaveHandled: () => handled++);
      unawaited(route.popped.then(results.add));
      final context = tester.element(find.byType(StrategyGroupFormPage));
      final navigator = Navigator.of(context);
      final source = AppTaskActivity.captureSource(context);
      await _key(tester, LogicalKeyboardKey.keyS);
      app.setInteractive(false);
      saving.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(source(), isTrue);
      expect(handled, 1);
      expect(results, isEmpty);
      final coverNavigator = change == 'outer cover'
          ? Navigator.of(context, rootNavigator: true)
          : navigator;
      final cover = MaterialPageRoute<void>(
        builder: (_) => Scaffold(body: Text('new route $change')),
      );
      if (change == 'retired route') navigator.removeRoute(route);
      unawaited(coverNavigator.push(cover));
      expect(source(), isFalse);
      app.setInteractive(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(cover.isCurrent, isTrue);
      expect(cover.navigator, same(coverNavigator));
      expect(find.text('new route $change'), findsOneWidget);
      expect(saved, hasLength(1));
      expect(handled, 1);
      if (change == 'retired route') {
        expect(route.isActive, isFalse);
        expect(results, [null]);
      } else {
        expect(route.isActive, isTrue);
        expect(results, isEmpty);
      }
      coverNavigator.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(source(), change == 'retired route' ? isFalse : isTrue);
      if (change == 'retired route') {
        expect(find.byType(StrategyGroupFormPage), findsNothing);
        expect(results, [null]);
      } else {
        expect(route.isCurrent, isTrue);
        expect(find.byType(StrategyGroupFormPage), findsOneWidget);
        expect(results, isEmpty);
      }
      expect(saved, hasLength(1));
      expect(handled, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('real shell task source separates pause from task retirement', (
    tester,
  ) async {
    await mount(tester);
    final context = tester.element(find.byType(OverviewPage));
    final scope = AppTaskScope.maybeOf(context)!;
    final source = AppTaskActivity.captureSource(context);
    final active = AppTaskActivity.capture(context);
    expect(source(), isTrue);
    expect(active(), isTrue);
    app.setInteractive(false);
    expect(source(), isTrue);
    expect(active(), isFalse);
    await tester.pump();
    expect(source(), isTrue);
    expect(active(), isFalse);
    app.setInteractive(true);
    scope.open(AppTask.settings);
    expect(source(), isFalse);
    expect(active(), isFalse);
    await tester.pumpAndSettle();
    expect(source(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('captured source reads the same owner and defaults to strict', (
    tester,
  ) async {
    await mount(tester);
    final eligibility = ValueNotifier<(bool, bool?)>((true, true));
    addTearDown(eligibility.dispose);
    late BuildContext origin;
    final navigator = Navigator.of(tester.element(find.byType(OverviewPage)));
    unawaited(
      navigator.push<void>(
        FocusedPageRoute(
          builder: (_) => ValueListenableBuilder(
            valueListenable: eligibility,
            builder: (_, value, _) => AppTaskActivity(
              active: value.$1,
              isActiveNow: () => value.$1,
              isSourceCurrent: value.$2 == null ? null : () => value.$2!,
              child: Builder(
                builder: (context) {
                  origin = context;
                  return const Scaffold(body: Text('source probe'));
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final owner = origin
        .getElementForInheritedWidgetOfExactType<AppTaskActivity>();
    final source = AppTaskActivity.captureSource(origin);
    final active = AppTaskActivity.capture(origin);
    expect(source(), isTrue);
    eligibility.value = (false, true);
    await tester.pump();
    expect(
      origin.getElementForInheritedWidgetOfExactType<AppTaskActivity>(),
      same(owner),
    );
    expect(source(), isTrue);
    expect(active(), isFalse);
    eligibility.value = (false, false);
    await tester.pump();
    expect(source(), isFalse);
    eligibility.value = (false, null);
    await tester.pump();
    expect(source(), isFalse);
    expect(active(), isFalse);
    eligibility.value = (true, null);
    await tester.pump();
    expect(source(), isTrue);
    expect(active(), isTrue);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(source(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'real shell completed covered group leaves only on a new current Overview',
    (tester) async {
      await mount(tester);
      final saving = Completer<void>();
      final saved = <Map<String, Object?>>[];
      final results = <Map<String, Object?>?>[];
      var handled = 0;
      final route = await openGroup(tester, (definition) {
        saved.add(definition);
        return saving.future;
      }, onSaveHandled: () => handled++);
      unawaited(route.popped.then(results.add));
      final state = tester.state(find.byType(StrategyGroupFormPage));
      final context = tester.element(find.byType(StrategyGroupFormPage));
      final navigator = Navigator.of(context);
      final leave = app.overviewLeaveFor(route)!;
      final bindings = find.descendant(
        of: find.byType(StrategyGroupFormPage),
        matching: find.byType(CallbackShortcuts),
      );
      expect(bindings, findsOneWidget);
      final save = tester
          .widget<CallbackShortcuts>(bindings)
          .bindings
          .entries
          .singleWhere(
            (entry) =>
                entry.key is SingleActivator &&
                (entry.key as SingleActivator).trigger ==
                    LogicalKeyboardKey.keyS &&
                (entry.key as SingleActivator).control,
          )
          .value;
      await _key(tester, LogicalKeyboardKey.keyS);
      final cover = MaterialPageRoute<void>(
        builder: (_) => const PopScope<void>(
          canPop: false,
          child: Scaffold(body: Text('guarded cover')),
        ),
      );
      unawaited(navigator.push(cover));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      saving.complete();
      await tester.pump();
      expect(handled, 1);
      expect(await leave(), isFalse);
      app.requestOverview();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(cover.isCurrent, isTrue);
      expect(route.isActive, isTrue);
      expect(results, isEmpty);
      save();
      expect(saved, hasLength(1));
      navigator.pop();
      await tester.pumpAndSettle();
      expect(route.isCurrent, isTrue);
      expect(tester.state(find.byType(StrategyGroupFormPage)), same(state));
      expect(results, isEmpty);
      save();
      await _key(tester, LogicalKeyboardKey.keyS);
      expect(saved, hasLength(1));
      app.requestOverview();
      await tester.pumpAndSettle();
      expect(results, hasLength(1));
      expect(results.single, same(saved.single));
      expect(handled, 1);
      expect(saved, hasLength(1));
      expect(find.byType(StrategyGroupFormPage), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'real shell captured source cannot adopt a replacement controller',
    (tester) async {
      await mount(tester);
      final previous = app;
      addTearDown(previous.dispose);
      final context = tester.element(find.byType(OverviewPage));
      final shell = tester.state(find.byType(AppShell));
      final scope = context
          .getElementForInheritedWidgetOfExactType<AppTaskScope>();
      final activity = context
          .getElementForInheritedWidgetOfExactType<AppTaskActivity>();
      final source = AppTaskActivity.captureSource(context);
      expect(source(), isTrue);
      app = StrategyAppFake(StrategyBridgeFake())
        ..preferencesLoaded = true
        ..overridesLoaded = true;
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [AppTaskNavigatorObserver()],
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
      final current = tester.element(find.byType(OverviewPage));
      expect(current, same(context));
      expect(tester.state(find.byType(AppShell)), same(shell));
      expect(
        current.getElementForInheritedWidgetOfExactType<AppTaskScope>(),
        same(scope),
      );
      expect(
        current.getElementForInheritedWidgetOfExactType<AppTaskActivity>(),
        same(activity),
      );
      expect((scope!.widget as AppTaskScope).owner, same(app));
      expect(source(), isFalse);
      expect(AppTaskActivity.captureSource(current)(), isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
