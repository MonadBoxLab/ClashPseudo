import 'dart:async';

import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/ui/components/reading/original_text_view.dart';
import 'package:clash_pseudo/src/ui/diagnostics/resources/resources_page.dart';
import 'package:clash_pseudo/src/ui/diagnostics/result_page_bar.dart';
import 'package:clash_pseudo/src/ui/diagnostics/rules/rules_page.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/provider/provider_form.dart';
import 'package:clash_pseudo/src/ui/components/input/task_shortcuts.dart';
import 'package:clash_pseudo/src/ui/configs/configs_page.dart';
import 'package:clash_pseudo/src/ui/connections/connections_page.dart';
import 'package:clash_pseudo/src/ui/navigation/app_shell.dart';
import 'package:clash_pseudo/src/ui/navigation/page_route.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/overview/overview_page.dart';
import 'package:clash_pseudo/src/ui/settings/settings_page.dart';
import 'package:clash_pseudo/src/ui/strategies/strategies_page.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/strategy_fakes.dart';
import '../diagnostics/configuration/runtime_fakes.dart' show response;
import '../diagnostics/rules/rule_fakes.dart' show rulePage;

class _InsetsBridge extends StrategyBridgeFake {
  @override
  Future<Map<String, dynamic>> resources(CoreSnapshot core) async => {
    ...response(core),
    'resources': [
      for (var i = 0; i < 40; i++)
        {
          'kind': 'geo',
          'name': 'inset-resource-$i',
          'vehicleType': 'File',
          'source': '',
          'fileStatus': 'present',
          'bytes': 17,
          'updateSupported': false,
        },
    ],
  };

  @override
  Future<Map<String, dynamic>> rules(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) async => {
    ...rulePage(total: 2, generation: core.generation),
    ...response(core),
  };
}

void main() {
  group('navigation_motion', () {
    late StrategyAppFake app;

    setUp(() {
      app = StrategyAppFake(StrategyBridgeFake())
        ..preferencesLoaded = true
        ..overridesLoaded = true;
    });

    Future<void> mount(
      WidgetTester tester, {
      bool reduceMotion = false,
      Size size = const Size(1000, 900),
      double scale = 1,
      String language = 'en',
      StrategyBridgeFake? bridge,
    }) async {
      if (bridge != null) {
        app.dispose();
        app = StrategyAppFake(bridge)
          ..preferencesLoaded = true
          ..overridesLoaded = true;
      }
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        app.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [AppTaskNavigatorObserver()],
          theme: AppTheme.light,
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: reduceMotion,
              textScaler: TextScaler.linear(scale),
            ),
            child: child!,
          ),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> open(WidgetTester tester, AppTask task) async {
      tester.widget<AppTaskScope>(find.byType(AppTaskScope)).open(task);
      await tester.pump();
    }

    Finder page(Type type) => find.byType(type, skipOffstage: false);

    Opacity opacity(WidgetTester tester, Type type) => tester.widget<Opacity>(
      find
          .ancestor(
            of: page(type),
            matching: find.byType(Opacity, skipOffstage: false),
          )
          .first,
    );

    bool active(WidgetTester tester, Type type) =>
        AppTaskActivity.isActive(tester.element(page(type)));

    group('focused_insets', () {
      for (final scene in [
        (
          name: 'portrait',
          size: const Size(390, 860),
          padding: const EdgeInsets.fromLTRB(0, 24, 0, 42),
        ),
        (
          name: 'landscape-cutout',
          size: const Size(900, 600),
          padding: const EdgeInsets.fromLTRB(44, 24, 28, 34),
        ),
      ]) {
        void insets(WidgetTester tester, {double keyboard = 0}) {
          tester.view.viewPadding = FakeViewPadding(
            left: scene.padding.left,
            top: scene.padding.top,
            right: scene.padding.right,
            bottom: scene.padding.bottom,
          );
          tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
          tester.view.padding = FakeViewPadding(
            left: scene.padding.left,
            top: scene.padding.top,
            right: scene.padding.right,
            bottom: (scene.padding.bottom - keyboard).clamp(0, double.infinity),
          );
        }

        Rect available(WidgetTester tester) {
          final window = MediaQueryData.fromView(tester.view);
          return (window.padding + window.viewInsets).deflateRect(
            Offset.zero & window.size,
          );
        }

        void inside(WidgetTester tester, Finder target) {
          final bounds = tester.getRect(target);
          final safe = available(tester);
          expect(bounds.left, greaterThanOrEqualTo(safe.left));
          expect(bounds.top, greaterThanOrEqualTo(safe.top));
          expect(bounds.right, lessThanOrEqualTo(safe.right));
          expect(bounds.bottom, lessThanOrEqualTo(safe.bottom));
        }

        for (final scale in [1.0, 2.0]) {
          testWidgets(
            'form save bar avoids system bars and retains the IME draft ${scene.name} $scale',
            (tester) async {
              await mount(tester, size: scene.size, scale: scale);
              insets(tester);
              await tester.pumpAndSettle();
              final overview = tester.state(page(OverviewPage));
              final navigator = Navigator.of(
                tester.element(page(OverviewPage)),
              );
              final route = FocusedPageRoute<void>(
                builder: (_) => ProviderFormPage(
                  ruleProvider: false,
                  initialName: 'inset provider',
                  initialDefinition: const {'type': 'inline', 'payload': []},
                  onSave: (_, _) async =>
                      fail('This regression must not submit a save'),
                ),
              );
              unawaited(navigator.push(route));
              await tester.pumpAndSettle();
              final form = find.byType(ProviderFormPage);
              final state = tester.state(form);
              final save = find.byKey(
                const ValueKey('definition-save:provider'),
              );
              final before = tester.getRect(save);
              inside(tester, save);
              expect(before.bottom, available(tester).bottom - 12);
              final field = find
                  .descendant(of: form, matching: find.byType(TextField))
                  .first;
              final controller = tester.widget<TextField>(field).controller!;
              expect(controller.text, 'inset provider');
              await tester.showKeyboard(field);
              const draft = TextEditingValue(
                text: 'inset provider draft',
                selection: TextSelection(baseOffset: 2, extentOffset: 8),
                composing: TextRange(start: 2, end: 8),
              );
              tester.testTextInput.updateEditingValue(draft);
              await tester.pump();
              final editor = tester.state(
                find.descendant(of: field, matching: find.byType(EditableText)),
              );
              for (final keyboard in [180.0, 260.0, 0.0]) {
                insets(tester, keyboard: keyboard);
                await tester.pumpAndSettle();
                inside(tester, save);
                expect(
                  tester.getRect(save).bottom,
                  available(tester).bottom - 12,
                );
                expect(tester.state(form), same(state));
                expect(
                  tester.state(
                    find.descendant(
                      of: field,
                      matching: find.byType(EditableText),
                    ),
                  ),
                  same(editor),
                );
                expect(controller.value, draft);
                expect(ModalRoute.of(tester.element(form)), same(route));
                expect(Navigator.of(tester.element(form)), same(navigator));
                expect(tester.state(page(OverviewPage)), same(overview));
                expect(tester.takeException(), isNull);
              }
              expect(tester.getRect(save), before);
              expect(app.commands, isEmpty);
            },
          );
        }

        testWidgets(
          'final resource item sits fully above the system bar ${scene.name}',
          (tester) async {
            await mount(tester, size: scene.size, bridge: _InsetsBridge());
            insets(tester);
            await tester.pumpAndSettle();
            final navigator = Navigator.of(tester.element(page(OverviewPage)));
            final route = FocusedPageRoute<void>(
              builder: (_) => ResourcesPage(app: app),
            );
            unawaited(navigator.push(route));
            await tester.pumpAndSettle();
            final resources = find.byType(ResourcesPage);
            final state = tester.state(resources);
            final last = find.widgetWithText(ListTile, 'inset-resource-39');
            final scrollable = find
                .descendant(
                  of: find.descendant(
                    of: resources,
                    matching: find.byType(CustomScrollView),
                  ),
                  matching: find.byWidgetPredicate(
                    (widget) =>
                        widget is Scrollable &&
                        widget.axisDirection == AxisDirection.down,
                  ),
                )
                .first;
            await tester.scrollUntilVisible(last, 600, scrollable: scrollable);
            await tester.pumpAndSettle();
            inside(tester, last);
            final position = tester.state<ScrollableState>(scrollable).position;
            final before = tester.getRect(last);
            app.changed();
            await tester.pumpAndSettle();
            expect(tester.getRect(last), before);
            expect(
              tester.state<ScrollableState>(scrollable).position,
              same(position),
            );
            expect(tester.state(resources), same(state));
            expect(ModalRoute.of(tester.element(resources)), same(route));
            expect(app.commands, isEmpty);
            expect(tester.takeException(), isNull);
          },
        );

        testWidgets(
          'rule pagination controls sit fully above the system bar ${scene.name}',
          (tester) async {
            await mount(tester, size: scene.size, bridge: _InsetsBridge());
            insets(tester);
            await tester.pumpAndSettle();
            final navigator = Navigator.of(tester.element(page(OverviewPage)));
            final route = FocusedPageRoute<void>(
              builder: (_) => RulesPage(app: app),
            );
            unawaited(navigator.push(route));
            await tester.pumpAndSettle();
            final rules = find.byType(RulesPage);
            final state = tester.state(rules);
            final strings = AppLocalizations.of(tester.element(rules));
            final previous = find.byTooltip(strings.previousPage);
            final next = find.byTooltip(strings.nextPage);
            final label = find.byKey(const ValueKey('result-page-range'));
            expect(find.byType(ResultPageBar), findsOneWidget);
            expect(
              tester.widget<Text>(label).data,
              strings.resultRange(1, 2, 2),
            );
            for (final target in [previous, label, next]) {
              inside(tester, target);
            }
            final footer = find.descendant(
              of: find.byType(ResultPageBar),
              matching: find.byType(Row),
            );
            expect(tester.getRect(footer).bottom, available(tester).bottom);
            final before = [previous, label, next].map(tester.getRect).toList();
            app.changed();
            await tester.pumpAndSettle();
            expect(
              [previous, label, next].map(tester.getRect).toList(),
              before,
            );
            expect(tester.state(rules), same(state));
            expect(ModalRoute.of(tester.element(rules)), same(route));
            expect(app.commands, isEmpty);
            expect(tester.takeException(), isNull);
          },
        );

        testWidgets(
          'final technical text line sits fully above the system bar ${scene.name}',
          (tester) async {
            await mount(tester, size: scene.size);
            insets(tester);
            await tester.pumpAndSettle();
            final navigator = Navigator.of(tester.element(page(OverviewPage)));
            final original = '${'technical\n' * 1638}last technical row';
            final route = FocusedPageRoute<void>(
              builder: (_) => Scaffold(
                appBar: AppBar(title: const Text('Technical original')),
                body: OriginalTextView(text: original),
              ),
            );
            unawaited(navigator.push(route));
            await tester.pumpAndSettle();
            final reader = find.byType(OriginalTextView);
            final state = tester.state(reader);
            final list = find.byKey(const ValueKey('original-text-blocks'));
            final scrollable = find
                .descendant(
                  of: list,
                  matching: find.byWidgetPredicate(
                    (widget) =>
                        widget is Scrollable &&
                        widget.axisDirection == AxisDirection.down,
                  ),
                )
                .first;
            final last = find.text('last technical row');
            await tester.scrollUntilVisible(
              last,
              600,
              scrollable: scrollable,
              maxScrolls: 100,
            );
            await tester.pumpAndSettle();
            inside(tester, last);
            expect(tester.getRect(list).bottom, available(tester).bottom);
            final before = tester.getRect(last);
            final position = tester.state<ScrollableState>(scrollable).position;
            app.changed();
            await tester.pumpAndSettle();
            expect(tester.getRect(last), before);
            expect(
              tester.state<ScrollableState>(scrollable).position,
              same(position),
            );
            expect(tester.state(reader), same(state));
            expect(tester.widget<OriginalTextView>(reader).text, original);
            expect(ModalRoute.of(tester.element(reader)), same(route));
            expect(app.commands, isEmpty);
            expect(tester.takeException(), isNull);
          },
        );

        testWidgets(
          'ordinary pages consume bottom system insets once ${scene.name}',
          (tester) async {
            await mount(tester, size: scene.size);
            insets(tester);
            await tester.pumpAndSettle();
            final navigator = Navigator.of(tester.element(page(OverviewPage)));
            final route = MaterialPageRoute<void>(
              builder: (_) => const Scaffold(
                body: SafeArea(
                  child: SizedBox.expand(
                    key: ValueKey('ordinary-safe-content'),
                  ),
                ),
              ),
            );
            unawaited(navigator.push(route));
            await tester.pumpAndSettle();
            final content = find.byKey(const ValueKey('ordinary-safe-content'));
            inside(tester, content);
            final navigation = find.byType(NavigationBar);
            if (navigation.evaluate().isNotEmpty) {
              expect(
                tester.getRect(content).bottom,
                tester.getRect(navigation).top,
              );
              expect(MediaQuery.paddingOf(tester.element(content)).bottom, 0);
              expect(tester.getRect(content).left, available(tester).left);
            } else {
              final rail = find.byType(NavigationRail);
              expect(rail, findsOneWidget);
              expect(tester.getRect(content).left, tester.getRect(rail).right);
              expect(tester.getRect(rail).left, available(tester).left);
              expect(tester.getRect(content).bottom, available(tester).bottom);
            }
            expect(tester.getRect(content).right, available(tester).right);
            expect(ModalRoute.of(tester.element(content)), same(route));
            expect(tester.takeException(), isNull);
          },
        );
      }
    });

    for (final size in [
      const Size(411, 914),
      const Size(700, 900),
      const Size(1200, 900),
    ]) {
      testWidgets(
        'settings groups use current column coordinates directly when returning from a subpage $size',
        (tester) async {
          await mount(tester, size: size);
          await open(tester, AppTask.settings);
          await tester.pumpAndSettle();
          final settings = page(SettingsPage);
          final state = tester.state(settings);
          final strings = AppLocalizations.of(tester.element(settings));
          final list = find.descendant(
            of: settings,
            matching: find.byType(CustomScrollView, skipOffstage: false),
            skipOffstage: false,
          );
          final scrollable = find
              .descendant(
                of: settings,
                matching: find.byType(Scrollable, skipOffstage: false),
                skipOffstage: false,
              )
              .first;
          final position = tester.state<ScrollableState>(scrollable).position;
          for (final (target, group) in [
            (find.byKey(const ValueKey('settings-lan-proxy')), 1),
            (find.text(strings.overridePlugins), 2),
            (find.byKey(const ValueKey('settings-lan-proxy')), 1),
          ]) {
            await tester.scrollUntilVisible(
              target,
              200,
              scrollable: scrollable,
            );
            await tester.pumpAndSettle();
            final pixels = position.pixels;
            await tester.tap(target);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(active(tester, SettingsPage), isFalse);
            await tester.binding.handlePopRoute();
            for (final ms in [0, 16, 40, 80, 180, 300]) {
              await tester.pump(Duration(milliseconds: ms));
              final section = find.byKey(
                ValueKey('settings-section:$group'),
                skipOffstage: false,
              );
              final viewport = tester.renderObject<RenderBox>(list);
              final box = tester.renderObject<RenderBox>(section);
              final width = viewport.size.width;
              final columns = width >= 840 ? 2 : 1;
              final columnWidth = (width - (columns - 1) * 24) / columns;
              expect(box.size.width, closeTo(columnWidth, .01));
              expect(
                box.localToGlobal(Offset.zero, ancestor: viewport).dx,
                closeTo((group % columns) * (columnWidth + 24), .01),
              );
              expect(tester.state(settings), same(state));
              expect(
                tester.state<ScrollableState>(scrollable).position,
                same(position),
              );
              expect(position.pixels, pixels);
              expect(tester.takeException(), isNull);
            }
            expect(active(tester, SettingsPage), isTrue);
            expect(target.hitTestable(), findsOneWidget);
          }
          expect(app.commands, isEmpty);
        },
      );
    }

    testWidgets(
      'retained task crossfade reverses without duplicate page states',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await mount(tester);
          final overview = tester.state(page(OverviewPage));
          final strategies = tester.state(page(StrategiesPage));
          final controller = tester
              .widget<StrategiesPage>(page(StrategiesPage))
              .controller;
          await open(tester, AppTask.strategies);
          await tester.pump(const Duration(milliseconds: 70));
          final leaving = opacity(tester, OverviewPage).opacity;
          final entering = opacity(tester, StrategiesPage).opacity;
          expect(leaving, inExclusiveRange(0, 1));
          expect(entering, inExclusiveRange(0, 1));
          expect(active(tester, OverviewPage), isFalse);
          expect(active(tester, StrategiesPage), isTrue);
          expect(
            TickerMode.valuesOf(tester.element(page(OverviewPage))).enabled,
            isTrue,
          );
          expect(
            TickerMode.valuesOf(tester.element(page(StrategiesPage))).enabled,
            isTrue,
          );
          expect(
            tester.widget<OverviewPage>(page(OverviewPage)).active,
            isFalse,
          );
          final oldHit = tester.widget<IgnorePointer>(
            find
                .ancestor(
                  of: page(OverviewPage),
                  matching: find.byType(IgnorePointer),
                )
                .first,
          );
          final oldFocus = tester.widget<ExcludeFocus>(
            find
                .ancestor(
                  of: page(OverviewPage),
                  matching: find.byType(ExcludeFocus),
                )
                .first,
          );
          final oldSemantics = tester.widget<ExcludeSemantics>(
            find
                .ancestor(
                  of: page(OverviewPage),
                  matching: find.byType(ExcludeSemantics),
                )
                .first,
          );
          expect(oldHit.ignoring, isTrue);
          expect(oldFocus.excluding, isTrue);
          expect(oldSemantics.excluding, isTrue);
          await open(tester, AppTask.overview);
          expect(opacity(tester, OverviewPage).opacity, closeTo(leaving, .001));
          expect(
            opacity(tester, StrategiesPage).opacity,
            closeTo(entering, .001),
          );
          expect(active(tester, StrategiesPage), isFalse);
          expect(active(tester, OverviewPage), isTrue);
          await tester.pump(const Duration(milliseconds: 60));
          expect(opacity(tester, OverviewPage).opacity, greaterThan(leaving));
          expect(opacity(tester, StrategiesPage).opacity, lessThan(entering));
          await tester.pumpAndSettle();
          expect(page(OverviewPage), findsOneWidget);
          expect(page(StrategiesPage), findsOneWidget);
          expect(tester.state(page(OverviewPage)), same(overview));
          expect(tester.state(page(StrategiesPage)), same(strategies));
          expect(
            tester.widget<StrategiesPage>(page(StrategiesPage)).controller,
            same(controller),
          );
          for (final type in [OverviewPage, StrategiesPage]) {
            expect(
              find.ancestor(
                of: page(type),
                matching: find.byType(AnimatedSwitcher),
              ),
              findsNothing,
            );
          }
          expect(
            TickerMode.valuesOf(tester.element(page(StrategiesPage))).enabled,
            isFalse,
            reason: 'a fully offstage retained task has no visual ticks',
          );
          final origin = tester.element(page(OverviewPage));
          final popup = DialogRoute<void>(
            context: origin,
            builder: (_) => const AlertDialog(content: Text('covered task')),
          );
          unawaited(Navigator.of(origin, rootNavigator: true).push(popup));
          await tester.pumpAndSettle();
          expect(active(tester, OverviewPage), isFalse);
          expect(
            tester.widget<OverviewPage>(page(OverviewPage)).active,
            isTrue,
          );
          expect(AppTaskActivity.isActive(origin, ownedPopup: popup), isTrue);
          expect(
            TickerMode.valuesOf(origin).enabled,
            isTrue,
            reason: 'Popup coverage does not freeze visible task geometry',
          );
          popup.navigator!.pop();
          await tester.pumpAndSettle();
          expect(app.commands, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );

    testWidgets('live task authority retires callbacks before the next frame', (
      tester,
    ) async {
      await mount(tester);
      final origin = tester.element(page(OverviewPage));
      final open = tester.widget<AppTaskScope>(find.byType(AppTaskScope)).open;
      final oldOpen = tester
          .widget<OverviewPage>(page(OverviewPage))
          .onOpenTask!;
      var calls = 0;
      void cachedAction() {
        if (AppTaskActivity.isActive(origin)) calls++;
      }

      cachedAction();
      expect(calls, 1);
      open(AppTask.strategies);
      await tester
          .idle(); // Flush task-selection Futures, deliberately no frame.
      expect(tester.widget<OverviewPage>(page(OverviewPage)).active, isTrue);
      cachedAction();
      expect(calls, 1);
      oldOpen(AppTask.settings);
      await tester.idle();
      await tester.pump();
      expect(
        tester.widget<AppTaskScope>(find.byType(AppTaskScope)).task,
        AppTask.strategies,
      );
      final strategies = tester.element(page(StrategiesPage));
      app.setInteractive(false);
      expect(AppTaskActivity.isActive(strategies), isFalse);
      app.setInteractive(true);
      expect(AppTaskActivity.isActive(strategies), isTrue);
      final route = MaterialPageRoute<void>(builder: (_) => const Scaffold());
      unawaited(Navigator.of(strategies).push(route));
      expect(AppTaskActivity.isActive(strategies), isFalse);
      await tester.pumpAndSettle();
      route.navigator!.pop();
      expect(AppTaskActivity.isActive(strategies), isTrue);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'all five task states retain the same internal navigation path',
      (tester) async {
        await mount(tester);
        final types = [
          OverviewPage,
          StrategiesPage,
          ConnectionsPage,
          ConfigsPage,
          SettingsPage,
        ];
        final states = {
          for (final type in types) type: tester.state(page(type)),
        };
        final navigator = Navigator.of(tester.element(page(OverviewPage)));
        final root = ModalRoute.of(tester.element(page(OverviewPage)));
        final strategyController = tester
            .widget<StrategiesPage>(page(StrategiesPage))
            .controller;
        for (final task in AppTask.values.followedBy(AppTask.values.reversed)) {
          await open(tester, task);
          await tester.pump(const Duration(milliseconds: 24));
          for (final type in types) {
            expect(page(type), findsOneWidget);
            expect(tester.state(page(type)), same(states[type]));
            expect(Navigator.of(tester.element(page(type))), same(navigator));
            expect(ModalRoute.of(tester.element(page(type))), same(root));
          }
          expect(
            tester.widget<StrategiesPage>(page(StrategiesPage)).controller,
            same(strategyController),
          );
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    for (final rootNavigator in [false, true]) {
      testWidgets(
        'owned popup qualifies only its live original page root=$rootNavigator',
        (tester) async {
          await mount(tester);
          final inner = Navigator.of(tester.element(page(OverviewPage)));
          const key = ValueKey('owned-popup-origin');
          final originRoute = FocusedPageRoute<void>(
            builder: (_) => const Scaffold(key: key, body: Text('origin')),
          );
          unawaited(inner.push(originRoute));
          await tester.pumpAndSettle();
          final origin = tester.element(find.byKey(key));
          final navigator = Navigator.of(origin, rootNavigator: rootNavigator);
          final popup = DialogRoute<void>(
            context: origin,
            builder: (_) =>
                const AlertDialog(content: Text('owned confirmation')),
          );
          unawaited(navigator.push(popup));
          expect(AppTaskActivity.isActive(origin), isFalse);
          expect(AppTaskActivity.isActive(origin, ownedPopup: popup), isTrue);
          await tester.pumpAndSettle();
          // Snapshot false does not revoke the explicit, still-owned confirmation.
          expect(
            origin.findAncestorWidgetOfExactType<AppTaskActivity>()!.active,
            isFalse,
          );
          expect(AppTaskActivity.isActive(origin, ownedPopup: popup), isTrue);
          app.setInteractive(false);
          expect(AppTaskActivity.isActive(origin, ownedPopup: popup), isFalse);
          app.setInteractive(true);
          expect(AppTaskActivity.isActive(origin, ownedPopup: popup), isTrue);

          final nextPage = MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('different page')),
          );
          unawaited(navigator.push(nextPage));
          expect(AppTaskActivity.isActive(origin, ownedPopup: popup), isFalse);
          await tester.pumpAndSettle();
          final unrelatedPopup = DialogRoute<void>(
            context: origin,
            builder: (_) => const AlertDialog(content: Text('new page popup')),
          );
          unawaited(navigator.push(unrelatedPopup));
          expect(
            AppTaskActivity.isActive(origin, ownedPopup: unrelatedPopup),
            isFalse,
            reason: 'a current Popup cannot bridge a newer PageRoute',
          );
          await tester.pumpAndSettle();
          navigator.pop();
          await tester.pumpAndSettle();
          navigator.pop();
          await tester.pumpAndSettle();
          expect(AppTaskActivity.isActive(origin, ownedPopup: popup), isTrue);
          var calls = 0;
          void cachedPopupAction() {
            if (AppTaskActivity.isActive(origin, ownedPopup: popup)) calls++;
          }

          cachedPopupAction();
          expect(calls, 1);
          navigator.pop();
          // No frame: the popup's old buttons cannot authorize new actions.
          cachedPopupAction();
          expect(calls, 1);
          expect(AppTaskActivity.isActive(origin, ownedPopup: popup), isFalse);
          expect(AppTaskActivity.isActive(origin), isTrue);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 16));
          cachedPopupAction();
          expect(calls, 1);
          await tester.pumpAndSettle();
          inner.pop();
          expect(AppTaskActivity.isActive(origin), isFalse);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final replace in [false, true]) {
      testWidgets(
        'owned popup loses removed/replaced origin before frame $replace',
        (tester) async {
          await mount(tester);
          final navigator = Navigator.of(tester.element(page(OverviewPage)));
          const key = ValueKey('removed-popup-origin');
          final originRoute = FocusedPageRoute<void>(
            builder: (_) => const Scaffold(key: key),
          );
          unawaited(navigator.push(originRoute));
          await tester.pumpAndSettle();
          final origin = tester.element(find.byKey(key));
          final popup = DialogRoute<void>(
            context: origin,
            builder: (_) => const AlertDialog(content: Text('confirmation')),
          );
          unawaited(navigator.push(popup));
          await tester.pumpAndSettle();
          expect(AppTaskActivity.isActive(origin, ownedPopup: popup), isTrue);
          if (replace) {
            navigator.replace(
              oldRoute: originRoute,
              newRoute: MaterialPageRoute<void>(
                builder: (_) => const Scaffold(),
              ),
            );
          } else {
            navigator.removeRoute(originRoute);
          }
          expect(AppTaskActivity.isActive(origin, ownedPopup: popup), isFalse);
          await tester.pumpAndSettle();
          navigator.pop();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'no activity ancestor remains compatible, unobserved popup fails closed',
      (tester) async {
        await mount(tester);
        const rootKey = ValueKey('unobserved-root');
        await tester.pumpWidget(
          MaterialApp(home: const Scaffold(key: rootKey)),
        );
        await tester.pumpAndSettle();
        final root = tester.element(find.byKey(rootKey));
        expect(AppTaskActivity.isActive(root), isTrue);
        final navigator = Navigator.of(root);
        const originKey = ValueKey('unobserved-origin');
        final route = FocusedPageRoute<void>(
          builder: (_) => const Scaffold(key: originKey),
        );
        unawaited(navigator.push(route));
        await tester.pumpAndSettle();
        final origin = tester.element(find.byKey(originKey));
        final popup = DialogRoute<void>(
          context: origin,
          builder: (_) => const AlertDialog(content: Text('unobserved popup')),
        );
        unawaited(navigator.push(popup));
        expect(AppTaskActivity.isActive(origin, ownedPopup: popup), isFalse);
        await tester.pumpAndSettle();
        navigator.pop();
        await tester.pumpAndSettle();
        navigator.pop();
        expect(AppTaskActivity.isActive(origin), isFalse);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'reduced motion changes task eligibility and paint in one frame',
      (tester) async {
        await mount(tester, reduceMotion: true);
        final state = tester.state(page(OverviewPage));
        await open(tester, AppTask.settings);
        expect(opacity(tester, OverviewPage).opacity, 0);
        expect(opacity(tester, SettingsPage).opacity, 1);
        expect(active(tester, OverviewPage), isFalse);
        expect(active(tester, SettingsPage), isTrue);
        await open(tester, AppTask.overview);
        expect(opacity(tester, OverviewPage).opacity, 1);
        expect(tester.state(page(OverviewPage)), same(state));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'focused Material route exits before its reverse transition ends',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await mount(tester);
          var searched = 0;
          final focus = FocusNode();
          addTearDown(focus.dispose);
          final navigator = Navigator.of(tester.element(page(OverviewPage)));
          const editorKey = ValueKey('retiring-material-editor');
          final route = FocusedPageRoute<void>(
            builder: (_) => Scaffold(
              key: editorKey,
              body: TaskShortcuts(
                onSearch: () => searched++,
                child: TextField(
                  focusNode: focus,
                  decoration: const InputDecoration(
                    labelText: 'retiring editor',
                  ),
                ),
              ),
            ),
          );
          unawaited(navigator.push(route));
          await tester.pumpAndSettle();
          final routeElement = tester.element(find.byType(TextField));
          final shortcuts = tester.widget<CallbackShortcuts>(
            find
                .ancestor(
                  of: find.byType(TextField),
                  matching: find.byType(CallbackShortcuts),
                )
                .first,
          );
          final oldSearch =
              shortcuts.bindings[const SingleActivator(
                LogicalKeyboardKey.keyF,
                control: true,
              )]!;
          focus.requestFocus();
          await tester.pump();
          expect(focus.hasFocus, isTrue);
          expect(find.bySemanticsLabel('retiring editor'), findsOneWidget);
          final semanticsTree = find.semantics.byPredicate(
            (_) => true,
            view: tester.view,
          );
          expect(semanticsTree.roots, hasLength(1));
          final root = semanticsTree.roots.single;
          expect(root.parent, isNull);
          expect(root.attached, isTrue);
          expect(semanticsTree.evaluate(), isNotEmpty);
          final editorSemantics = find.semantics.byLabel(
            'retiring editor',
            view: tester.view,
          );
          expect(editorSemantics.evaluate(), hasLength(1));
          expect(active(tester, OverviewPage), isFalse);
          navigator.pop();
          expect(AppTaskActivity.isActive(routeElement), isFalse);
          oldSearch();
          expect(
            searched,
            0,
            reason: 'a captured callback must inspect the live route',
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 40));
          expect(
            routeElement.mounted,
            isTrue,
            reason: 'the SDK is still painting the exit',
          );
          expect(AppTaskActivity.isActive(routeElement), isFalse);
          expect(focus.hasFocus, isFalse);
          expect(semanticsTree.roots, hasLength(1));
          expect(semanticsTree.roots.single, same(root));
          expect(root.parent, isNull);
          expect(root.attached, isTrue);
          expect(semanticsTree.evaluate(), isNotEmpty);
          expect(editorSemantics.evaluate(), isEmpty);
          final routeActivity = routeElement
              .findAncestorWidgetOfExactType<AppTaskActivity>()!;
          final semanticsGate = find.descendant(
            of: find.byWidget(routeActivity),
            matching: find.ancestor(
              of: find.byKey(editorKey),
              matching: find.byType(ExcludeSemantics),
            ),
          );
          expect(semanticsGate, findsOneWidget);
          expect(
            tester.widget<ExcludeSemantics>(semanticsGate).excluding,
            isTrue,
          );
          expect(find.byType(TextField).hitTestable(), findsNothing);
          oldSearch();
          expect(searched, 0);
          await tester.pumpAndSettle();
          expect(routeElement.mounted, isFalse);
          oldSearch();
          expect(searched, 0);
          expect(active(tester, OverviewPage), isTrue);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );

    testWidgets(
      'carrier reversals retain focused route and draft during resize',
      (tester) async {
        await mount(tester);
        final navigator = Navigator.of(tester.element(page(OverviewPage)));
        final text = TextEditingController.fromValue(
          const TextEditingValue(
            text: 'retained navigation draft',
            selection: TextSelection(baseOffset: 2, extentOffset: 9),
          ),
        );
        final focus = FocusNode();
        addTearDown(text.dispose);
        addTearDown(focus.dispose);
        final route = FocusedPageRoute<void>(
          builder: (_) => Scaffold(
            body: TextField(controller: text, focusNode: focus),
          ),
        );
        unawaited(navigator.push(route));
        await tester.pumpAndSettle();
        focus.requestFocus();
        await tester.pump();
        final element = tester.element(find.byType(TextField));
        final value = text.value;
        for (final size in [
          const Size(700, 479),
          const Size(599, 480),
          const Size(1000, 900),
          const Size(320, 479),
          const Size(700, 479),
        ]) {
          tester.view.physicalSize = size;
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 32));
          expect(navigator, same(route.navigator));
          expect(route.isCurrent, isTrue);
          expect(tester.element(find.byType(TextField)), same(element));
          expect(text.value, value);
          expect(focus.hasFocus, isTrue);
          expect(find.byType(NavigationRail), findsNothing);
          expect(find.byType(NavigationBar), findsNothing);
          expect(tester.takeException(), isNull, reason: '$size');
        }
        navigator.pop();
        await tester.pumpAndSettle();
        expect(active(tester, OverviewPage), isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    for (final language in ['en', 'zh']) {
      testWidgets(
        '700x479 double text navigation fits during reversal $language',
        (tester) async {
          await mount(
            tester,
            size: const Size(700, 479),
            scale: 2,
            language: language,
          );
          await open(tester, AppTask.settings);
          await tester.pumpAndSettle();
          final settings = tester.state(page(SettingsPage));
          final route = ModalRoute.of(tester.element(page(SettingsPage)));
          for (final size in [
            const Size(700, 479),
            const Size(701, 480),
            const Size(599, 479),
            const Size(1000, 900),
            const Size(700, 479),
            const Size(600, 480),
          ]) {
            tester.view.physicalSize = size;
            await tester.pump();
            for (final elapsed in [16, 32, 80]) {
              await tester.pump(Duration(milliseconds: elapsed));
              expect(tester.state(page(SettingsPage)), same(settings));
              expect(
                ModalRoute.of(tester.element(page(SettingsPage))),
                same(route),
              );
              expect(app.interactive, isTrue);
              expect(
                tester.takeException(),
                isNull,
                reason: '$size/$elapsed/$language',
              );
            }
          }
          await tester.pumpAndSettle();
          expect(app.commands, isEmpty);
        },
      );
    }
  });
  group('task_navigation_motion', () {
    late StrategyAppFake app;

    setUp(() {
      app = StrategyAppFake(StrategyBridgeFake())
        ..preferencesLoaded = true
        ..overridesLoaded = true;
    });

    Future<void> mount(
      WidgetTester tester, {
      bool reducedMotion = false,
      double scale = 1,
      Size size = const Size(1000, 900),
      String language = 'en',
      ThemeData? theme,
      ValueNotifier<bool>? motionUpdates,
    }) async {
      final motion = motionUpdates ?? ValueNotifier(reducedMotion);
      if (motionUpdates == null) addTearDown(motion.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [AppTaskNavigatorObserver()],
          theme: theme ?? AppTheme.light,
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => ValueListenableBuilder(
            valueListenable: motion,
            builder: (context, reduced, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations: reduced,
                textScaler: TextScaler.linear(scale),
              ),
              child: child!,
            ),
            child: child,
          ),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> choose(WidgetTester tester, AppTask task) async {
      tester.widget<AppTaskScope>(find.byType(AppTaskScope)).open(task);
      await tester.pump();
    }

    double opacity(WidgetTester tester, AppTask task) => tester
        .widget<Opacity>(
          find
              .descendant(
                of: find.byKey(ValueKey(task), skipOffstage: false),
                matching: find.byType(Opacity, skipOffstage: false),
                skipOffstage: false,
              )
              .first,
        )
        .opacity;

    testWidgets(
      'task reversal keeps one page and controller, revokes old UI now',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await mount(tester);
          final overview = tester.state(find.byType(OverviewPage));
          final strategies = tester.state(
            find.byType(StrategiesPage, skipOffstage: false),
          );
          final controller = tester
              .widget<StrategiesPage>(
                find.byType(StrategiesPage, skipOffstage: false),
              )
              .controller;
          final oldOpen = tester
              .widget<OverviewPage>(find.byType(OverviewPage))
              .onOpenTask!;

          await choose(tester, AppTask.strategies);
          expect(
            tester.widget<OverviewPage>(find.byType(OverviewPage)).active,
            isFalse,
          );
          expect(find.byType(OverviewPage).hitTestable(), findsNothing);
          expect(
            tester
                .widget<ExcludeFocus>(
                  find
                      .ancestor(
                        of: find.byType(OverviewPage),
                        matching: find.byType(ExcludeFocus),
                      )
                      .first,
                )
                .excluding,
            isTrue,
          );
          expect(
            tester
                .widget<ExcludeSemantics>(
                  find
                      .ancestor(
                        of: find.byType(OverviewPage),
                        matching: find.byType(ExcludeSemantics),
                      )
                      .first,
                )
                .excluding,
            isTrue,
          );
          expect(
            AppTaskActivity.isActive(tester.element(find.byType(OverviewPage))),
            isFalse,
          );
          oldOpen(AppTask.settings);
          await tester.pump(const Duration(milliseconds: 80));
          expect(
            tester.widget<AppTaskScope>(find.byType(AppTaskScope)).task,
            AppTask.strategies,
          );
          final fading = opacity(tester, AppTask.overview);
          expect(fading, inExclusiveRange(0, 1));
          expect(opacity(tester, AppTask.strategies), inExclusiveRange(0, 1));

          await choose(tester, AppTask.overview);
          expect(opacity(tester, AppTask.overview), closeTo(fading, .001));
          expect(
            tester.widget<StrategiesPage>(find.byType(StrategiesPage)).active,
            isFalse,
          );
          await tester.pump(const Duration(milliseconds: 16));
          expect(opacity(tester, AppTask.overview), greaterThan(fading));
          await choose(tester, AppTask.strategies);
          await tester.pump(const Duration(milliseconds: 16));
          await choose(tester, AppTask.overview);
          await tester.pumpAndSettle();
          expect(tester.state(find.byType(OverviewPage)), same(overview));
          expect(
            tester.state(find.byType(StrategiesPage, skipOffstage: false)),
            same(strategies),
          );
          expect(
            tester
                .widget<StrategiesPage>(
                  find.byType(StrategiesPage, skipOffstage: false),
                )
                .controller,
            same(controller),
          );
          expect(
            find.byType(StrategiesPage, skipOffstage: false),
            findsOneWidget,
          );
          expect(opacity(tester, AppTask.overview), 1);
          expect(opacity(tester, AppTask.strategies), 0);
          expect(app.commands, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );

    testWidgets(
      'focused Material route retains path, draft and focus during resize',
      (tester) async {
        await mount(tester);
        final navigator = Navigator.of(
          tester.element(find.byType(OverviewPage)),
        );
        final document = TextEditingController();
        final focus = FocusNode();
        addTearDown(document.dispose);
        addTearDown(focus.dispose);
        const fieldKey = ValueKey('focused-navigation-draft');
        final route = FocusedPageRoute<void>(
          settings: const RouteSettings(name: '/retained-editor'),
          builder: (_) => Scaffold(
            body: TaskShortcuts(
              child: TextField(
                key: fieldKey,
                controller: document,
                focusNode: focus,
              ),
            ),
          ),
        );
        unawaited(navigator.push(route));
        await tester.pumpAndSettle();
        final field = find.byKey(fieldKey);
        final state = tester.state(field);
        focus.requestFocus();
        await tester.pump();
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'retained route draft',
            selection: TextSelection(baseOffset: 2, extentOffset: 8),
            composing: TextRange(start: 2, end: 8),
          ),
        );
        await tester.pump();
        final value = document.value;
        expect(route, isA<MaterialPageRoute<void>>());
        expect(
          tester
              .widget<OverviewPage>(
                find.byType(OverviewPage, skipOffstage: false),
              )
              .active,
          isFalse,
        );
        for (final size in [
          const Size(700, 479),
          const Size(320, 600),
          const Size(1000, 900),
          const Size(599, 479),
          const Size(700, 479),
        ]) {
          tester.view.physicalSize = size;
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 16));
          expect(route.isCurrent, isTrue);
          expect(ModalRoute.of(tester.element(field)), same(route));
          expect(tester.state(field), same(state));
          expect(document.value, value);
          expect(focus.hasFocus, isTrue);
          expect(find.byType(NavigationRail), findsNothing);
          expect(find.byType(NavigationBar), findsNothing);
          expect(tester.takeException(), isNull);
        }
        navigator.pop();
        await tester.pumpAndSettle();
        expect(
          tester.widget<OverviewPage>(find.byType(OverviewPage)).active,
          isTrue,
        );
      },
    );

    testWidgets(
      'popped focused route rejects retained shortcut before reverse ends',
      (tester) async {
        await mount(tester);
        final navigator = Navigator.of(
          tester.element(find.byType(OverviewPage)),
        );
        var saves = 0;
        const pageKey = ValueKey('exiting-navigation-page');
        final route = FocusedPageRoute<void>(
          builder: (_) => Scaffold(
            key: pageKey,
            body: TaskShortcuts(
              onSave: () => saves++,
              child: const TextField(autofocus: true),
            ),
          ),
        );
        unawaited(navigator.push(route));
        await tester.pumpAndSettle();
        final callbacks = tester.widget<CallbackShortcuts>(
          find.descendant(
            of: find.byKey(pageKey),
            matching: find.byType(CallbackShortcuts),
          ),
        );
        final save =
            callbacks.bindings[const SingleActivator(
              LogicalKeyboardKey.keyS,
              control: true,
            )]!;
        save();
        expect(saves, 1);
        navigator.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        final page = find.byKey(pageKey, skipOffstage: false);
        expect(page, findsOneWidget);
        expect(route.isCurrent, isFalse);
        expect(AppTaskActivity.isActive(tester.element(page)), isFalse);
        expect(page.hitTestable(), findsNothing);
        save();
        expect(saves, 1);
        await tester.pumpAndSettle();
        save();
        expect(saves, 1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'navigation extents have intermediate frames and reverse in place',
      (tester) async {
        await mount(tester);
        final state = tester.state(find.byType(OverviewPage));
        final navigator = Navigator.of(
          tester.element(find.byType(OverviewPage)),
        );
        final rail = find.byKey(const ValueKey('navigation-rail-extent'));
        final bar = find.byKey(const ValueKey('navigation-bar-extent'));
        final fullRail = tester.getSize(rail).width;
        final oldDestination = tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .onDestinationSelected!;
        final initialPage = tester.getRect(find.byType(OverviewPage));
        expect(fullRail, greaterThan(0));
        tester.view.physicalSize = const Size(599, 900);
        await tester.pump();
        expect(tester.getSize(rail).width, fullRail);
        await tester.pump(const Duration(milliseconds: 80));
        final reversingRail = tester.getSize(rail).width;
        expect(reversingRail, inExclusiveRange(0, fullRail));
        final enteringBar = tester.getSize(bar).height;
        expect(enteringBar, inExclusiveRange(0, 80));
        expect(
          find.byType(NavigationRail),
          findsOneWidget,
          reason: 'a retiring extent must still contain its painted rail',
        );
        expect(find.byType(NavigationBar), findsOneWidget);
        final middlePage = tester.getRect(find.byType(OverviewPage));
        expect(middlePage.left, closeTo(reversingRail, .001));
        expect(middlePage.left, lessThan(initialPage.left));
        expect(middlePage.bottom, closeTo(900 - enteringBar, .001));
        for (final gate in [
          tester
              .widget<IgnorePointer>(
                find
                    .ancestor(
                      of: find.byType(NavigationRail),
                      matching: find.byType(IgnorePointer),
                    )
                    .first,
              )
              .ignoring,
          tester
              .widget<ExcludeFocus>(
                find
                    .ancestor(
                      of: find.byType(NavigationRail),
                      matching: find.byType(ExcludeFocus),
                    )
                    .first,
              )
              .excluding,
          tester
              .widget<ExcludeSemantics>(
                find
                    .ancestor(
                      of: find.byType(NavigationRail),
                      matching: find.byType(ExcludeSemantics),
                    )
                    .first,
              )
              .excluding,
        ]) {
          expect(gate, isTrue);
        }
        oldDestination(4);
        await tester.idle();
        expect(
          tester.widget<AppTaskScope>(find.byType(AppTaskScope)).task,
          AppTask.overview,
        );
        tester.view.physicalSize = const Size(1000, 900);
        await tester.pump();
        expect(tester.getSize(rail).width, closeTo(reversingRail, .001));
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getSize(rail).width, greaterThan(reversingRail));
        expect(tester.state(find.byType(OverviewPage)), same(state));
        expect(
          Navigator.of(tester.element(find.byType(OverviewPage))),
          same(navigator),
        );
        await tester.pumpAndSettle();
        expect(tester.getSize(rail).width, fullRail);
        expect(bar, findsNothing);
        final shell = find
            .descendant(
              of: find.byType(AppShell),
              matching: find.byType(Scaffold),
            )
            .first;
        expect(tester.widget<Scaffold>(shell).bottomNavigationBar, isNull);
        expect(tester.getRect(find.byType(OverviewPage)), initialPage);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('enabling reduced motion settles an in-flight retained task', (
      tester,
    ) async {
      final motion = ValueNotifier(false);
      addTearDown(motion.dispose);
      await mount(tester, motionUpdates: motion);
      final overview = tester.state(find.byType(OverviewPage));
      final settings = tester.state(
        find.byType(SettingsPage, skipOffstage: false),
      );
      await choose(tester, AppTask.settings);
      tester.view.physicalSize = const Size(599, 900);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(opacity(tester, AppTask.settings), inExclusiveRange(0, 1));
      motion.value = true;
      await tester.pump();
      expect(opacity(tester, AppTask.settings), 1);
      expect(opacity(tester, AppTask.overview), 0);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('navigation-rail-extent')))
            .width,
        0,
      );
      expect(tester.state(find.byType(SettingsPage)), same(settings));
      expect(
        tester.state(find.byType(OverviewPage, skipOffstage: false)),
        same(overview),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'navigation capacity measures the label style actually rendered',
      (tester) async {
        final base = AppTheme.light;
        final theme = base.copyWith(
          navigationRailTheme: base.navigationRailTheme.copyWith(
            selectedLabelTextStyle: const TextStyle(fontSize: 20, height: 1.4),
            unselectedLabelTextStyle: const TextStyle(
              fontSize: 17,
              height: 1.4,
            ),
          ),
          navigationBarTheme: base.navigationBarTheme.copyWith(
            labelTextStyle: WidgetStateProperty.resolveWith(
              (states) => TextStyle(
                fontSize: states.contains(WidgetState.selected) ? 18 : 16,
                height: 1.3,
              ),
            ),
          ),
        );
        await mount(tester, theme: theme, scale: 2);
        final rail = find.byType(NavigationRail);
        expect(rail, findsOneWidget);
        final label = find.descendant(
          of: rail,
          matching: find.text('Overview'),
        );
        final context = tester.element(label);
        final style = DefaultTextStyle.of(context).style;
        expect(style.fontSize, 20);
        final painter = TextPainter(
          text: TextSpan(text: 'Overview', style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        expect(
          tester.widget<NavigationRail>(rail).minWidth!,
          greaterThanOrEqualTo(painter.width + 32),
        );
        painter.dispose();
        tester.view.physicalSize = const Size(599, 900);
        await tester.pumpAndSettle();
        final bar = find.byType(NavigationBar);
        final barLabel = find.descendant(
          of: bar,
          matching: find.text('Overview'),
        );
        final barText = tester.widget<Text>(barLabel);
        final barStyle = DefaultTextStyle.of(tester.element(barLabel)).style
            .merge(barText.style);
        expect(barStyle.fontSize, 18);
        expect(
          tester.getSize(find.byType(OverviewPage)).height,
          greaterThanOrEqualTo(160),
        );
        expect(tester.takeException(), isNull);
      },
    );

    for (final language in ['en', 'zh']) {
      for (final theme in [AppTheme.light, AppTheme.dark]) {
        testWidgets(
          '700x479 2x navigation and reversing resize $language/${theme.brightness}',
          (tester) async {
            await mount(
              tester,
              language: language,
              theme: theme,
              scale: 2,
              size: const Size(700, 479),
            );
            await choose(tester, AppTask.settings);
            await tester.pumpAndSettle();
            final state = tester.state(find.byType(SettingsPage));
            final navigator = Navigator.of(
              tester.element(find.byType(SettingsPage)),
            );
            for (final size in [
              const Size(700, 479),
              const Size(599, 479),
              const Size(601, 481),
              const Size(320, 600),
              const Size(1000, 900),
              const Size(600, 480),
              const Size(700, 479),
            ]) {
              tester.view.physicalSize = size;
              await tester.pump();
              for (final milliseconds in [16, 40, 80]) {
                await tester.pump(Duration(milliseconds: milliseconds));
                expect(tester.state(find.byType(SettingsPage)), same(state));
                expect(
                  Navigator.of(tester.element(find.byType(SettingsPage))),
                  same(navigator),
                );
                expect(
                  tester.getSize(find.byType(SettingsPage)).width,
                  greaterThanOrEqualTo(280),
                );
                expect(
                  tester.getSize(find.byType(SettingsPage)).height,
                  greaterThanOrEqualTo(160),
                );
                expect(
                  tester.takeException(),
                  isNull,
                  reason: '$size at $milliseconds ms',
                );
              }
            }
            await tester.pumpAndSettle();
            expect(app.commands, isEmpty);
          },
        );
      }
    }

    testWidgets(
      'reduced motion settles task and navigation extents immediately',
      (tester) async {
        await mount(tester, reducedMotion: true);
        final state = tester.state(find.byType(OverviewPage));
        await choose(tester, AppTask.settings);
        expect(opacity(tester, AppTask.settings), 1);
        expect(opacity(tester, AppTask.overview), 0);
        await choose(tester, AppTask.overview);
        expect(opacity(tester, AppTask.overview), 1);
        expect(tester.state(find.byType(OverviewPage)), same(state));
        tester.view.physicalSize = const Size(320, 600);
        await tester.pump();
        expect(
          tester
              .getSize(find.byKey(const ValueKey('navigation-rail-extent')))
              .width,
          0,
        );
        expect(
          tester
              .getSize(find.byKey(const ValueKey('navigation-bar-extent')))
              .height,
          greaterThan(0),
        );
        app.setInteractive(false);
        await tester.pump();
        expect(
          tester.widget<OverviewPage>(find.byType(OverviewPage)).active,
          isFalse,
        );
        expect(
          AppTaskActivity.isActive(tester.element(find.byType(OverviewPage))),
          isFalse,
        );
        app.setInteractive(true);
        await tester.pump();
        expect(
          tester.widget<OverviewPage>(find.byType(OverviewPage)).active,
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  });
}
