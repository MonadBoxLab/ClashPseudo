import 'dart:async';
import 'dart:io';

import 'package:clash_pseudo/src/app/app_controller.dart';
import 'package:clash_pseudo/src/features/configs/config_store.dart';

import 'package:clash_pseudo/src/app/app_task.dart';
import 'package:clash_pseudo/src/app/app_shell.dart';
import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/app/widgets/choice_menu_button.dart';
import 'package:clash_pseudo/src/features/configs/config_text_page.dart';
import 'package:clash_pseudo/src/features/settings/applications_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import '../features/strategies/strategy_fakes.dart';

class _NavigationBridge extends StrategyBridgeFake {
  int readinessCalls = 0;
  Future<void> Function()? onReady;

  @override
  Future<void> uiReady() async {
    readinessCalls++;
    await onReady?.call();
  }

  @override
  Future<Uint8List?> applicationIcon(String package) async => null;

  @override
  Future<List<Map<String, dynamic>>> applications() async => [
    {
      'package': 'test.navigation',
      'label': 'Navigation test app',
      'uid': 10001,
      'system': false,
    },
  ];
}

void main() {
  late StrategyAppFake app;
  late _NavigationBridge bridge;
  late GlobalKey<NavigatorState> navigator;
  final strings = lookupAppLocalizations(const Locale('en'));

  setUp(() {
    bridge = _NavigationBridge();
    app = StrategyAppFake(bridge)
      ..preferencesLoaded = true
      ..overridesLoaded = true;
    navigator = GlobalKey<NavigatorState>();
    addTearDown(app.dispose);
  });

  Future<void> mount(WidgetTester tester, {AppController? controller}) async {
    addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.light,
        home: AppShell(controller: controller ?? app),
      ),
    );
    await tester.pumpAndSettle();
  }

  AppTask selected(WidgetTester tester) {
    final rail = tester.widget<NavigationRail>(
      find.byType(NavigationRail, skipOffstage: false),
    );
    final label = (rail.destinations[rail.selectedIndex!].label as Text).data;
    return {
      strings.overview: AppTask.overview,
      strings.strategies: AppTask.strategies,
      strings.connectionsNavigation: AppTask.connections,
      strings.configurationsNavigation: AppTask.configurations,
      strings.settings: AppTask.settings,
    }[label]!;
  }

  Future<void> settings(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text(strings.settings),
      ),
    );
    await tester.pumpAndSettle();
    expect(selected(tester), AppTask.settings);
  }

  Future<MaterialPageRoute<void>> push(WidgetTester tester, Widget page) async {
    final route = MaterialPageRoute<void>(builder: (_) => page);
    unawaited(navigator.currentState!.push(route));
    await tester.pumpAndSettle();
    return route;
  }

  Future<MaterialPageRoute<void>> editor(
    WidgetTester tester, {
    String name = 'Navigation draft',
    bool dirty = true,
  }) async {
    final route = await push(
      tester,
      ConfigTextPage(app: app, initialName: name, initialText: 'rules: []\n'),
    );
    if (dirty) {
      tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!.text =
          '# retained draft\nrules: []\n';
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    }
    return route;
  }

  Future<void> request(WidgetTester tester) async {
    app.requestOverview();
    await tester.pumpAndSettle();
  }

  Future<void> answer(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text(label)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> platformOverview(WidgetTester tester) async {
    const codec = StandardMethodCodec();
    final response = Completer<ByteData?>();
    tester.binding.channelBuffers.push(
      AppBridge.channel.name,
      codec.encodeMethodCall(const MethodCall('openOverview')),
      response.complete,
    );
    expect(codec.decodeEnvelope((await response.future)!), isTrue);
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'brand rotation retains navigation, editor draft and focus $brightness',
      (tester) async {
        final brand = ValueNotifier(BrandColor.cinnabar);
        addTearDown(brand.dispose);
        addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
        await tester.pumpWidget(
          ValueListenableBuilder(
            valueListenable: brand,
            builder: (_, value, _) => MaterialApp(
              navigatorKey: navigator,
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: AppTheme.forBrightness(brightness, value),
              home: AppShell(controller: app),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await settings(tester);
        final route = await editor(tester);
        final document = tester
            .widget<CodeEditor>(find.byType(CodeEditor))
            .controller!;
        await tester.tap(find.byType(CodeEditor));
        await tester.pumpAndSettle();
        final focus = tester.binding.focusManager.primaryFocus;
        expect(focus, isNotNull);
        expect(
          focus!.context!.findAncestorWidgetOfExactType<CodeEditor>(),
          isNotNull,
        );
        final selection = document.selection;
        for (final value in BrandColor.values) {
          brand.value = value;
          await tester.pumpAndSettle();
          final bar = tester.widget<NavigationRail>(
            find.byType(NavigationRail, skipOffstage: false),
          );
          final colors = AppTheme.forBrightness(brightness, value).colorScheme;
          for (final destination in bar.destinations) {
            final label = (destination.label as Text).data;
            final color = label == strings.overview
                ? colors.primary
                : label == strings.strategies ||
                      label == strings.connectionsNavigation
                ? colors.secondary
                : colors.tertiary;
            expect((destination.icon as Icon).color, color);
            expect((destination.selectedIcon as Icon).color, color);
          }
          expect(selected(tester), AppTask.settings);
          expect(route.isCurrent, isTrue);
          expect(
            tester.widget<CodeEditor>(find.byType(CodeEditor)).controller,
            same(document),
          );
          expect(document.text, '# retained draft\nrules: []\n');
          expect(document.selection, selection);
          expect(tester.binding.focusManager.primaryFocus, same(focus));
          expect(app.commands, isEmpty);
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  testWidgets('UI-ready handshake acknowledges a cold platform overview once', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('overview-ready-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final startup = AppController(bridge, store: ConfigStore(directory));
    addTearDown(startup.dispose);
    bridge.onReady = () => platformOverview(tester);
    await tester.runAsync(startup.initialize);
    expect(bridge.readinessCalls, 1);
    expect(startup.commandErrorMessage, isNull);
    await mount(tester, controller: startup);
    expect(selected(tester), AppTask.overview);
    expect(startup.takeOverviewRequest(), isFalse);
    await settings(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(selected(tester), AppTask.settings);
    expect(startup.lastCommand, isNull);
  });

  testWidgets('warm platform overview is acknowledged without a VPN command', (
    tester,
  ) async {
    await app.initialize();
    await mount(tester);
    await settings(tester);
    await platformOverview(tester);
    await tester.pumpAndSettle();
    expect(selected(tester), AppTask.overview);
    expect(app.commands, isEmpty);
  });

  testWidgets('cold overview request is consumed once without a command', (
    tester,
  ) async {
    app.requestOverview();
    await mount(tester);
    expect(selected(tester), AppTask.overview);
    expect(app.takeOverviewRequest(), isFalse);
    await settings(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(selected(tester), AppTask.settings);
    expect(app.commands, isEmpty);
  });

  testWidgets('warm overview request switches the existing root tab', (
    tester,
  ) async {
    await mount(tester);
    await settings(tester);
    await request(tester);
    expect(selected(tester), AppTask.overview);
    expect(navigator.currentState!.canPop(), isFalse);
    expect(app.commands, isEmpty);
  });

  testWidgets('ordinary secondary routes unwind before selecting overview', (
    tester,
  ) async {
    await mount(tester);
    await settings(tester);
    final first = await push(
      tester,
      const Scaffold(body: Text('First secondary')),
    );
    final second = await push(
      tester,
      const Scaffold(body: Text('Second secondary')),
    );
    await request(tester);
    expect(first.isActive, isFalse);
    expect(second.isActive, isFalse);
    expect(selected(tester), AppTask.overview);
    expect(navigator.currentState!.canPop(), isFalse);
  });

  for (final blocked in [false, true]) {
    testWidgets(
      'overview consumes choice-menu history before guarded routes blocked=$blocked',
      (tester) async {
        await mount(tester);
        await settings(tester);
        final parent = await push(
          tester,
          const Scaffold(body: Text('DNS parent')),
        );
        var rejected = 0;
        var selections = 0;
        final route = await push(
          tester,
          PopScope<void>(
            canPop: !blocked,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) rejected++;
            },
            child: Scaffold(
              body: Center(
                child: ChoiceMenuButton<String>(
                  options: const {'A': 'DNS A', 'AAAA': 'DNS AAAA'},
                  value: 'A',
                  onSelected: (_) => selections++,
                  child: const Text('DNS type'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('DNS type'));
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNWidgets(2));
        expect(route.willHandlePopInternally, isTrue);
        await request(tester);
        expect(find.byType(MenuItemButton), findsNothing);
        expect(route.willHandlePopInternally, isFalse);
        expect(route.isActive, blocked);
        expect(parent.isActive, blocked);
        expect(selected(tester), blocked ? AppTask.settings : AppTask.overview);
        expect(selections, 0);
        // One menu-closing attempt, then at most one unchanged route veto.
        expect(rejected, blocked ? 2 : 1);
        await tester.pump(const Duration(seconds: 1));
        expect(rejected, blocked ? 2 : 1);
        expect(app.commands, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('menu closing frame cannot pop a replacement route', (
    tester,
  ) async {
    await mount(tester);
    await settings(tester);
    MaterialPageRoute<void>? replacement;
    var replacementScheduled = false;
    final route = await push(
      tester,
      PopScope<void>(
        onPopInvokedWithResult: (didPop, _) {
          if (didPop || replacementScheduled) return;
          replacementScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            replacement = MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('New route')),
            );
            unawaited(navigator.currentState!.push(replacement!));
          });
        },
        child: Scaffold(
          body: ChoiceMenuButton<String>(
            options: const {'A': 'DNS A'},
            value: 'A',
            onSelected: (_) => fail('Navigation must not select a DNS type'),
            child: const Text('DNS type'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('DNS type'));
    await tester.pumpAndSettle();
    expect(route.willHandlePopInternally, isTrue);
    await request(tester);
    expect(replacement, isNotNull);
    expect(replacement!.isCurrent, isTrue);
    expect(route.isActive, isTrue);
    expect(selected(tester), AppTask.settings);
    expect(app.takeOverviewRequest(), isFalse);
    expect(app.commands, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cancelling unsaved text consumes navigation without a later jump',
    (tester) async {
      await mount(tester);
      await settings(tester);
      final route = await editor(tester);
      final text = tester
          .widget<CodeEditor>(find.byType(CodeEditor))
          .controller!;
      await request(tester);
      expect(find.text(strings.discardEditsTitle), findsOneWidget);
      expect(route.isActive, isTrue);
      expect(selected(tester), AppTask.settings);
      await answer(tester, strings.continueEditing);
      expect(text.text, '# retained draft\nrules: []\n');
      expect(route.isCurrent, isTrue);
      expect(app.takeOverviewRequest(), isFalse);
      // An independent Back retains cancellation of the earlier system request.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await answer(tester, strings.discard);
      expect(route.isActive, isFalse);
      expect(selected(tester), AppTask.settings);
      final later = await push(
        tester,
        const Scaffold(body: Text('Later route')),
      );
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(later.isActive, isFalse);
      expect(selected(tester), AppTask.settings);
      expect(app.commands, isEmpty);
    },
  );

  testWidgets('confirmed unsaved text exits all original secondary levels', (
    tester,
  ) async {
    await mount(tester);
    await settings(tester);
    final parent = await push(
      tester,
      const Scaffold(body: Text('Configuration parent')),
    );
    final route = await editor(tester);
    await request(tester);
    await answer(tester, strings.discard);
    expect(route.isActive, isFalse);
    expect(parent.isActive, isFalse);
    expect(selected(tester), AppTask.overview);
    expect(app.commands, isEmpty);
  });

  testWidgets(
    'find mode closes and the same request still honors the draft guard',
    (tester) async {
      await mount(tester);
      await settings(tester);
      final route = await editor(tester);
      final findController = tester
          .widget<CodeEditor>(find.byType(CodeEditor))
          .findController!;
      findController.findMode();
      await tester.pumpAndSettle();
      await request(tester);
      expect(find.text(strings.discardEditsTitle), findsOneWidget);
      expect(findController.value, isNull);
      await answer(tester, strings.continueEditing);
      expect(route.isCurrent, isTrue);
      expect(selected(tester), AppTask.settings);
    },
  );

  testWidgets(
    'duplicate requests during a confirmation do not queue another exit',
    (tester) async {
      await mount(tester);
      await settings(tester);
      final route = await editor(tester);
      await request(tester);
      final dialog = tester.element(find.byType(AlertDialog));
      await request(tester);
      await request(tester);
      expect(tester.element(find.byType(AlertDialog)), same(dialog));
      await answer(tester, strings.continueEditing);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(AlertDialog), findsNothing);
      expect(route.isCurrent, isTrue);
      expect(selected(tester), AppTask.settings);
      expect(app.takeOverviewRequest(), isFalse);
    },
  );

  for (final acceptLower in [false, true]) {
    testWidgets(
      'stacked dirty editors honor each actual guard lower=$acceptLower',
      (tester) async {
        await mount(tester);
        await settings(tester);
        final lower = await editor(tester, name: 'Lower draft');
        final upper = await editor(tester, name: 'Upper draft');
        await request(tester);
        await answer(tester, strings.discard);
        expect(upper.isActive, isFalse);
        expect(lower.isActive, isTrue);
        expect(find.text(strings.discardEditsTitle), findsOneWidget);
        await answer(
          tester,
          acceptLower ? strings.discard : strings.continueEditing,
        );
        expect(lower.isActive, isNot(acceptLower));
        expect(
          selected(tester),
          acceptLower ? AppTask.overview : AppTask.settings,
        );
        expect(app.commands, isEmpty);
      },
    );
  }

  testWidgets(
    'maybePop handled=true never stands in for actual route removal',
    (tester) async {
      await mount(tester);
      await settings(tester);
      var rejected = 0;
      final route = await push(
        tester,
        PopScope<void>(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) rejected++;
          },
          child: const Scaffold(body: Text('Unregistered guard')),
        ),
      );
      await request(tester);
      expect(rejected, 1);
      expect(route.isCurrent, isTrue);
      expect(selected(tester), AppTask.settings);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(selected(tester), AppTask.settings);
    },
  );

  testWidgets('a guard returning true without popping cannot switch the root', (
    tester,
  ) async {
    await mount(tester);
    await settings(tester);
    final route = await push(tester, const Scaffold(body: Text('Guard owner')));
    Future<bool> noPop() async => true;
    app.registerOverviewLeave(route, noPop);
    await request(tester);
    expect(route.isCurrent, isTrue);
    expect(selected(tester), AppTask.settings);
    app.unregisterOverviewLeave(route, noPop);
  });

  testWidgets('disposed shell cannot resume an outstanding leave future', (
    tester,
  ) async {
    await mount(tester);
    await settings(tester);
    final route = await push(
      tester,
      const Scaffold(body: Text('Outstanding guard')),
    );
    final decision = Completer<bool>();
    Future<bool> leave() => decision.future;
    app.registerOverviewLeave(route, leave);
    await request(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    decision.complete(true);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(app.takeOverviewRequest(), isFalse);
    app.unregisterOverviewLeave(route, leave);
  });

  for (final accept in [false, true]) {
    testWidgets(
      'application access draft respects navigation confirmation accept=$accept',
      (tester) async {
        await mount(tester);
        await settings(tester);
        final route = await push(tester, ApplicationsPage(app: app));
        await tester.tap(find.byKey(const ValueKey('access-except')));
        await tester.pumpAndSettle();
        await request(tester);
        expect(find.text(strings.discardChanges), findsOneWidget);
        await answer(
          tester,
          accept ? strings.discard : strings.continueEditing,
        );
        expect(route.isActive, isNot(accept));
        expect(selected(tester), accept ? AppTask.overview : AppTask.settings);
        expect(app.commands, isEmpty);
      },
    );
  }
}
