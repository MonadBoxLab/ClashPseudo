import 'dart:math' as math;

import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/ui/components/input/choice_menu_button.dart';
import 'package:clash_pseudo/src/ui/navigation/app_shell.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/navigation/workspace_layout.dart';
import 'package:clash_pseudo/src/ui/navigation/workspace_window.dart';
import 'package:clash_pseudo/src/ui/overview/overview_page.dart';
import 'package:clash_pseudo/src/ui/overview/widgets/session_uptime.dart';
import 'package:clash_pseudo/src/ui/overview/widgets/status_hero.dart';
import 'package:clash_pseudo/src/ui/settings/settings_page.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/strategy_fakes.dart';
import '../../support/text_scalers.dart';

void main() {
  for (final language in ['en', 'zh']) {
    for (final dark in [false, true]) {
      testWidgets(
        'navigation computes form and capacity separately from logical width and height $language/$dark',
        (tester) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? AppTheme.dark : AppTheme.light,
              locale: Locale(language),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const Scaffold(body: SizedBox()),
            ),
          );
          final context = tester.element(find.byType(Scaffold));
          WorkspaceLayout resolve(
            Size size, {
            EdgeInsets padding = EdgeInsets.zero,
            EdgeInsets insets = EdgeInsets.zero,
          }) => WorkspaceLayout.resolve(
            size: size,
            padding: padding,
            viewInsets: insets,
            textScaler: TextScaler.noScaling,
            textDirection: TextDirection.ltr,
            labelStyle: WorkspaceLayout.navigationLabelStyle(
              context,
              rail: false,
              selected: false,
            ),
            railLabelStyles: [
              for (final selected in [false, true])
                WorkspaceLayout.navigationLabelStyle(
                  context,
                  rail: true,
                  selected: selected,
                ),
            ],
            barLabelStyles: [
              for (final selected in [false, true])
                WorkspaceLayout.navigationLabelStyle(
                  context,
                  rail: false,
                  selected: selected,
                ),
            ],
            labels: WorkspaceLayout.navigationLabels(context),
          );
          for (final (size, count, rail) in [
            (const Size(411, 914), 3, false),
            (const Size(914, 411), 5, false),
            (const Size(479, 900), 3, false),
            (const Size(480, 900), language == 'en' ? 3 : 4, false),
            (const Size(481, 900), language == 'en' ? 3 : 4, false),
            (const Size(599, 900), language == 'en' ? 3 : 4, false),
            (const Size(600, 900), 5, true),
            (const Size(601, 900), 5, true),
            (const Size(840, 479), 5, false),
            (const Size(840, 480), 5, true),
            (const Size(840, 481), 5, true),
          ]) {
            final layout = resolve(size);
            expect(layout.compact, isFalse, reason: '$size');
            expect(layout.rail, rail, reason: '$size');
            expect(
              layout.tasks,
              WorkspaceLayout.destinations(count),
              reason: '$size',
            );
          }
          expect(
            resolve(
              const Size(500, 900),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ).tasks.length,
            3,
          );
          expect(
            resolve(
              const Size(620, 900),
              insets: const EdgeInsets.only(right: 30),
            ).tasks.length,
            language == 'en' ? 3 : 4,
          );
          final keyboard = resolve(
            const Size(840, 900),
            insets: const EdgeInsets.only(bottom: 500),
          );
          expect(keyboard.rail, isFalse);
          expect(keyboard.tasks.length, 5);
        },
      );
    }
  }
  group('adaptive_navigation', () {
    for (final language in ['zh', 'en']) {
      for (final scale in [1.0, 1.3, 2.0]) {
        testWidgets(
          'navigation adapts without replacing page state $language $scale',
          (tester) async {
            tester.view.physicalSize = const Size(599, 1000);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final app = StrategyAppFake(StrategyBridgeFake())
              ..preferencesLoaded = true
              ..overridesLoaded = true;
            addTearDown(app.dispose);
            await tester.pumpWidget(
              MaterialApp(
                locale: Locale(language),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                theme: AppTheme.light,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: AppShell(controller: app),
              ),
            );
            await tester.pumpAndSettle();
            final strings = AppLocalizations.of(
              tester.element(find.byType(AppShell)),
            );
            await tester.tap(
              find.descendant(
                of: find.byType(NavigationBar),
                matching: find.text(strings.settings),
              ),
            );
            await tester.pumpAndSettle();
            final settings = tester.state(find.byType(SettingsPage));
            final list = find
                .descendant(
                  of: find.byType(SettingsPage),
                  matching: find.byType(Scrollable),
                )
                .first;
            final scroll = tester.state<ScrollableState>(list).position;
            scroll.jumpTo(100);
            await tester.pump();
            final readingList = find.descendant(
              of: find.byType(SettingsPage),
              matching: find.byType(CustomScrollView),
            );
            (int, double) reader() {
              final viewport = tester.getRect(readingList);
              final visible =
                  find
                      .descendant(
                        of: find.byType(SettingsPage),
                        matching: find.byType(IndexedSemantics),
                      )
                      .evaluate()
                      .map(
                        (element) => (
                          (element.widget as IndexedSemantics).index,
                          tester.getRect(find.byWidget(element.widget)),
                        ),
                      )
                      .where(
                        (row) =>
                            row.$2.top >= viewport.top &&
                            row.$2.top < viewport.bottom,
                      )
                      .toList()
                    ..sort((a, b) => a.$2.top.compareTo(b.$2.top));
              expect(visible, isNotEmpty);
              return (visible.first.$1, visible.first.$2.top);
            }

            for (final width in [
              600.0,
              601.0,
              839.0,
              840.0,
              841.0,
              1199.0,
              1200.0,
              1201.0,
              1599.0,
              1600.0,
              1601.0,
              1704.0,
              320.0,
              700.0,
              599.0,
            ]) {
              final (readingIndex, readingTop) = reader();
              final anchor = find.descendant(
                of: find.byType(SettingsPage),
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is IndexedSemantics &&
                      widget.index == readingIndex,
                ),
              );
              tester.view.physicalSize = Size(width, 1000);
              double? layoutPixels;
              for (final milliseconds in [0, 16, 100, 300]) {
                await tester.pump(Duration(milliseconds: milliseconds));
                expect(tester.state(find.byType(SettingsPage)), same(settings));
                expect(
                  tester.state<ScrollableState>(list).position,
                  same(scroll),
                );
                layoutPixels ??= scroll.pixels;
                expect(scroll.pixels, closeTo(layoutPixels, .01));
                expect(tester.getTopLeft(anchor).dy, closeTo(readingTop, .01));
                final pageRect = tester.getRect(find.byType(SettingsPage));
                final reading = tester.getRect(
                  find.descendant(
                    of: find.byType(SettingsPage),
                    matching: find.byType(CustomScrollView),
                  ),
                );
                expect(reading.width, math.min(1200, pageRect.width));
                expect(reading.center.dx, closeTo(pageRect.center.dx, .01));
                final overview = find.byType(OverviewPage, skipOffstage: false);
                final overviewRect = tester.getRect(overview);
                final overviewViewport = tester.getRect(
                  find.descendant(
                    of: overview,
                    matching: find.byType(
                      CustomScrollView,
                      skipOffstage: false,
                    ),
                    skipOffstage: false,
                  ),
                );
                expect(overviewViewport.width, overviewRect.width);
                expect(
                  overviewViewport.center.dx,
                  closeTo(overviewRect.center.dx, .01),
                );
                final hero = tester.getRect(
                  find.byType(StatusHero, skipOffstage: false),
                );
                final network = tester.getRect(
                  find.byKey(
                    const ValueKey('network-surface'),
                    skipOffstage: false,
                  ),
                );
                final left = math.min(hero.left, network.left);
                final right = math.max(hero.right, network.right);
                expect(right - left, overviewRect.width);
                expect(
                  (left + right) / 2,
                  closeTo(overviewRect.center.dx, .01),
                );
                if (hero.right <= network.left + .01) {
                  expect(hero.width, inInclusiveRange(320, 480));
                  expect(network.top, closeTo(hero.top, .01));
                } else {
                  expect(network.top, closeTo(hero.bottom, .01));
                  expect(network.width, hero.width);
                }
                final layout = WorkspaceLayout.of(
                  tester.element(find.byType(AppShell)),
                  Size(width, 1000),
                );
                final rail = find.byType(NavigationRail);
                final bar = find.byType(NavigationBar);
                final target = layout.rail ? rail : bar;
                final retiring = layout.rail ? bar : rail;
                expect(target, findsOneWidget);
                if (layout.rail) {
                  final navigation = tester.widget<NavigationRail>(target);
                  expect(
                    navigation.selectedIndex,
                    navigation.destinations.length - 1,
                  );
                } else {
                  final navigation = tester.widget<NavigationBar>(target);
                  expect(
                    navigation.selectedIndex,
                    navigation.destinations.length - 1,
                  );
                }
                final railExtent = find.byKey(
                  const ValueKey('navigation-rail-extent'),
                );
                final barExtent = find.byKey(
                  const ValueKey('navigation-bar-extent'),
                );
                final railWidth = tester.getSize(railExtent).width;
                final double barHeight;
                if (barExtent.evaluate().isEmpty) {
                  expect(bar, findsNothing);
                  final shell = find
                      .descendant(
                        of: find.byType(AppShell),
                        matching: find.byType(Scaffold),
                      )
                      .first;
                  expect(
                    tester.widget<Scaffold>(shell).bottomNavigationBar,
                    isNull,
                  );
                  barHeight = 0;
                } else {
                  barHeight = tester.getSize(barExtent).height;
                }
                expect(pageRect.left, closeTo(railWidth, .01));
                expect(pageRect.width, closeTo(width - railWidth, .01));
                expect(pageRect.bottom, closeTo(1000 - barHeight, .01));
                final retiringExtent = layout.rail ? barExtent : railExtent;
                final retiringSize = layout.rail ? barHeight : railWidth;
                if (retiringSize == 0) {
                  expect(retiring, findsNothing);
                } else {
                  expect(retiring, findsOneWidget);
                  final pointerGate = find.descendant(
                    of: retiringExtent,
                    matching: find.ancestor(
                      of: retiring,
                      matching: find.byWidgetPredicate(
                        (widget) =>
                            widget is IgnorePointer &&
                            widget.child is ExcludeFocus &&
                            (widget.child as ExcludeFocus).child
                                is ExcludeSemantics,
                      ),
                    ),
                  );
                  expect(pointerGate, findsOneWidget);
                  final pointer = tester.widget<IgnorePointer>(pointerGate);
                  final focus = pointer.child as ExcludeFocus;
                  final semantics = focus.child as ExcludeSemantics;
                  final gates = <Type, Widget>{
                    IgnorePointer: pointer,
                    ExcludeFocus: focus,
                    ExcludeSemantics: semantics,
                  };
                  Finder gate(Type type) {
                    final result = find.descendant(
                      of: retiringExtent,
                      matching: find.ancestor(
                        of: retiring,
                        matching: find.byWidget(gates[type]!),
                      ),
                    );
                    expect(result, findsOneWidget);
                    return result;
                  }

                  expect(
                    tester.widget<IgnorePointer>(gate(IgnorePointer)).ignoring,
                    isTrue,
                  );
                  expect(
                    tester.widget<ExcludeFocus>(gate(ExcludeFocus)).excluding,
                    isTrue,
                  );
                  expect(
                    tester
                        .widget<ExcludeSemantics>(gate(ExcludeSemantics))
                        .excluding,
                    isTrue,
                  );
                  if (layout.rail) {
                    tester
                        .widget<NavigationBar>(retiring)
                        .onDestinationSelected!(0);
                  } else {
                    tester
                        .widget<NavigationRail>(retiring)
                        .onDestinationSelected!(0);
                  }
                  expect(
                    AppTaskActivity.isActive(
                      tester.element(find.byType(SettingsPage)),
                    ),
                    isTrue,
                    reason: 'retiring navigation cannot switch the live task',
                  );
                }
                final power = tester.getRect(
                  find.byKey(
                    const ValueKey('power-button'),
                    skipOffstage: false,
                  ),
                );
                final uptime = tester.getRect(
                  find.byType(SessionUptime, skipOffstage: false),
                );
                final mode = tester.getRect(
                  find.byKey(
                    const ValueKey('mode-trigger'),
                    skipOffstage: false,
                  ),
                );
                expect(power.bottom, lessThanOrEqualTo(uptime.top));
                expect(uptime.bottom, lessThanOrEqualTo(mode.top));
                expect(app.commands, isEmpty);
                expect(tester.takeException(), isNull);
              }
            }
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }

    testWidgets('system overview retires the hidden settings menu and focus', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1704, 1136);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = StrategyAppFake(StrategyBridgeFake())
        ..preferencesLoaded = true
        ..overridesLoaded = true;
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.light,
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();
      final rail = find.byType(NavigationRail);
      await tester.tap(
        find.descendant(of: rail, matching: find.text('Settings')),
      );
      await tester.pumpAndSettle();
      final choice = find.byType(ChoiceMenuButton<String>).first;
      final trigger = tester
          .widget<InkWell>(
            find
                .descendant(
                  of: choice,
                  matching: find.byWidgetPredicate(
                    (widget) => widget is InkWell && widget.focusNode != null,
                  ),
                )
                .first,
          )
          .focusNode!;
      await tester.tap(choice);
      await tester.pumpAndSettle();
      final retired = tester.widget<MenuItemButton>(
        find.widgetWithText(MenuItemButton, 'Dark'),
      );
      app.requestOverview();
      for (final ms in [0, 16, 80, 300]) {
        await tester.pump(Duration(milliseconds: ms));
        if (tester.widget<NavigationRail>(rail).selectedIndex ==
            tester.widget<NavigationRail>(rail).destinations.length - 1) {
          // Settings remains visible until the overview request's post-frame
          // consumption.
          expect(ms, 0);
          continue;
        }
        expect(trigger.hasFocus, isFalse);
        expect(trigger.canRequestFocus, isFalse);
      }
      expect(find.byType(MenuItemButton), findsNothing);
      retired.onPressed!();
      trigger.requestFocus();
      await tester.pump();
      expect(trigger.hasFocus, isFalse);
      expect(app.commands, isEmpty);
      expect(tester.widget<NavigationRail>(rail).selectedIndex, 0);
      expect(
        ModalRoute.of(tester.element(find.byType(AppShell)))!
            .willHandlePopInternally,
        isFalse,
      );
      await tester.tap(
        find.descendant(of: rail, matching: find.text('Settings')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
      expect(trigger.hasFocus, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
  group('workspace_layout', () {
    for (final language in ['en', 'zh']) {
      for (final scaler in [
        TextScaler.noScaling,
        const TextScaler.linear(1.3),
        const TextScaler.linear(2),
        const NonlinearTextScaler(),
      ]) {
        testWidgets(
          'workspace capacity and compact fallback $language/$scaler',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = const Size(320, 900);
            addTearDown(tester.view.reset);
            final app = StrategyAppFake(StrategyBridgeFake())
              ..preferencesLoaded = true
              ..overridesLoaded = true;
            await tester.pumpWidget(
              MaterialApp(
                navigatorObservers: [AppTaskNavigatorObserver()],
                theme: AppTheme.light,
                locale: Locale(language),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: scaler),
                  child: WorkspaceWindow(controller: app, child: child!),
                ),
                home: AppShell(controller: app),
              ),
            );
            await tester.pumpAndSettle();
            final context = tester.element(find.byType(AppShell));
            final strings = AppLocalizations.of(context);
            final labels = {
              AppTask.overview: strings.overview,
              AppTask.strategies: strings.strategies,
              AppTask.connections: strings.connectionsNavigation,
              AppTask.configurations: strings.configurationsNavigation,
              AppTask.settings: strings.settings,
            };
            WorkspaceLayout resolve(
              Size size, [
              EdgeInsets padding = EdgeInsets.zero,
              EdgeInsets viewInsets = EdgeInsets.zero,
            ]) => WorkspaceLayout.resolve(
              size: size,
              padding: padding,
              viewInsets: viewInsets,
              textScaler: scaler,
              textDirection: TextDirection.ltr,
              labelStyle: Theme.of(context).textTheme.labelMedium!,
              labels: labels,
            );
            for (final width in [
              160.0,
              200.0,
              279.0,
              280.0,
              281.0,
              320.0,
              599.0,
              600.0,
              601.0,
              700.0,
              839.0,
              840.0,
              841.0,
              1000.0,
              1199.0,
              1200.0,
              1201.0,
              1400.0,
              1599.0,
              1600.0,
              1601.0,
              1704.0,
            ]) {
              for (final height in [
                200.0,
                279.0,
                280.0,
                281.0,
                479.0,
                480.0,
                481.0,
                899.0,
                900.0,
                901.0,
              ]) {
                for (final padding in [
                  EdgeInsets.zero,
                  const EdgeInsets.fromLTRB(8, 24, 8, 24),
                ]) {
                  final layout = resolve(Size(width, height), padding);
                  expect(layout.tasks.length, inInclusiveRange(3, 5));
                  expect(layout.tasks, [
                    AppTask.overview,
                    AppTask.strategies,
                    if (layout.tasks.length >= 4) AppTask.connections,
                    if (layout.tasks.length == 5) AppTask.configurations,
                    AppTask.settings,
                  ]);
                  if (layout.compact) {
                    expect(layout.rail, isFalse);
                    expect(layout.navigationHeight, 64);
                    expect(layout.navigationWidth, greaterThanOrEqualTo(192));
                    expect(
                      layout.navigationWidth,
                      greaterThanOrEqualTo(width - padding.horizontal),
                    );
                  } else {
                    expect(
                      width - padding.horizontal,
                      greaterThanOrEqualTo(280),
                    );
                    expect(
                      height - padding.vertical,
                      greaterThanOrEqualTo(280),
                    );
                    if (layout.rail) {
                      expect(
                        width - padding.horizontal - layout.navigationWidth,
                        greaterThanOrEqualTo(280),
                      );
                    } else {
                      expect(
                        height - padding.vertical - layout.navigationHeight,
                        greaterThanOrEqualTo(160),
                      );
                      expect(
                        (width - padding.horizontal) / layout.tasks.length,
                        greaterThanOrEqualTo(64),
                      );
                    }
                  }
                }
              }
            }
            expect(
              resolve(
                const Size(1704, 901),
                EdgeInsets.zero,
                const EdgeInsets.only(bottom: 622),
              ).compact,
              isTrue,
            );
            expect(
              resolve(
                const Size(1704, 901),
                EdgeInsets.zero,
                const EdgeInsets.only(bottom: 621),
              ).compact,
              isFalse,
            );
            expect(
              resolve(
                const Size(1704, 901),
                const EdgeInsets.only(left: 24),
                const EdgeInsets.only(right: 1401),
              ).compact,
              isTrue,
            );
            expect(resolve(const Size(279, 900)).compact, isTrue);
            expect(resolve(const Size(1704, 279)).compact, isTrue);
            expect(resolve(const Size(280, 900)).compact, isFalse);
            expect(resolve(const Size(280, 900)).tasks.length, 3);
            expect(resolve(const Size(1704, 901)).tasks, const [
              AppTask.overview,
              AppTask.strategies,
              AppTask.connections,
              AppTask.configurations,
              AppTask.settings,
            ]);
            await tester.tap(
              find.descendant(
                of: find.byType(NavigationBar),
                matching: find.text(strings.settings),
              ),
            );
            await tester.pumpAndSettle();
            final settings = tester.state(find.byType(SettingsPage));
            for (final size in [
              const Size(280, 280),
              const Size(281, 281),
              const Size(320, 280),
              const Size(599, 479),
              const Size(600, 480),
              const Size(601, 481),
              const Size(1000, 320),
              const Size(1400, 899),
              const Size(1704, 901),
              const Size(279, 900),
              const Size(1704, 279),
              const Size(200, 200),
              const Size(160, 280),
              const Size(320, 900),
            ]) {
              tester.view.physicalSize = size;
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 16));
              expect(tester.state(find.byType(SettingsPage)), same(settings));
              expect(app.interactive, isTrue);
              expect(await app.waitUntilInteractive(), isTrue);
              // The retiring carrier keeps clipped pixels until its extent is zero;
              // only the current carrier owns focus, semantics and destinations.
              final rail = find.byType(NavigationRail);
              final bar = find.byType(NavigationBar);
              expect(
                rail.evaluate().length + bar.evaluate().length,
                inInclusiveRange(1, 2),
              );
              final currentRail = WorkspaceLayout.of(context, size).rail;
              final retiring = currentRail ? bar : rail;
              if (retiring.evaluate().isNotEmpty) {
                final extent = find.byKey(
                  ValueKey(
                    currentRail
                        ? 'navigation-bar-extent'
                        : 'navigation-rail-extent',
                  ),
                );
                final pointerGate = find.descendant(
                  of: extent,
                  matching: find.ancestor(
                    of: retiring,
                    matching: find.byWidgetPredicate(
                      (widget) =>
                          widget is IgnorePointer &&
                          widget.child is ExcludeFocus &&
                          (widget.child as ExcludeFocus).child
                              is ExcludeSemantics,
                    ),
                  ),
                );
                expect(pointerGate, findsOneWidget);
                final pointer = tester.widget<IgnorePointer>(pointerGate);
                final focus = pointer.child as ExcludeFocus;
                final semantics = focus.child as ExcludeSemantics;
                final gates = <Type, Widget>{
                  IgnorePointer: pointer,
                  ExcludeFocus: focus,
                  ExcludeSemantics: semantics,
                };
                Finder gate(Type type) {
                  final result = find.descendant(
                    of: extent,
                    matching: find.ancestor(
                      of: retiring,
                      matching: find.byWidget(gates[type]!),
                    ),
                  );
                  expect(result, findsOneWidget);
                  return result;
                }

                expect(
                  tester.widget<IgnorePointer>(gate(IgnorePointer)).ignoring,
                  isTrue,
                );
                expect(
                  tester.widget<ExcludeFocus>(gate(ExcludeFocus)).excluding,
                  isTrue,
                );
                expect(
                  tester
                      .widget<ExcludeSemantics>(gate(ExcludeSemantics))
                      .excluding,
                  isTrue,
                );
              }
              final carrier = currentRail
                  ? rail
                  : find
                        .ancestor(
                          of: bar,
                          matching: find.byType(SingleChildScrollView),
                        )
                        .first;
              final rect = tester.getRect(carrier);
              expect(rect.left, greaterThanOrEqualTo(0));
              expect(rect.top, greaterThanOrEqualTo(0));
              expect(rect.right, lessThanOrEqualTo(size.width + .01));
              expect(rect.bottom, lessThanOrEqualTo(size.height + .01));
              final page = tester.getRect(find.byType(SettingsPage));
              if (resolve(size).compact) {
                expect(page.width, greaterThan(0));
                expect(page.height, greaterThan(0));
              } else {
                expect(page.width, greaterThanOrEqualTo(280));
                expect(page.height, greaterThanOrEqualTo(160));
              }
              expect(app.commands, isEmpty);
              expect(tester.takeException(), isNull, reason: '$size/$scaler');
            }
            tester.view.physicalSize = const Size(200, 200);
            await tester.pumpAndSettle();
            await tester.tap(find.byIcon(Icons.home_outlined));
            await tester.pumpAndSettle();
            expect(
              tester.widget<AppTaskScope>(find.byType(AppTaskScope)).task,
              AppTask.overview,
            );
            await tester.tap(find.byIcon(Icons.settings_outlined));
            await tester.pumpAndSettle();
            expect(tester.state(find.byType(SettingsPage)), same(settings));
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
            app.dispose();
          },
        );
      }
    }
  });
}
