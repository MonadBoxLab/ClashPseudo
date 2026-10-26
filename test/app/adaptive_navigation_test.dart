import 'dart:math' as math;

import 'package:clash_pseudo/src/app/app_shell.dart';
import 'package:clash_pseudo/src/app/widgets/choice_menu_button.dart';
import 'package:clash_pseudo/src/features/overview/overview_page.dart';
import 'package:clash_pseudo/src/features/overview/widgets/status_hero.dart';
import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/features/settings/settings_page.dart';
import 'package:clash_pseudo/src/features/overview/widgets/session_uptime.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/strategies/strategy_fakes.dart';

void main() {
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
                    widget is IndexedSemantics && widget.index == readingIndex,
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
                  matching: find.byType(CustomScrollView, skipOffstage: false),
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
              expect((left + right) / 2, closeTo(overviewRect.center.dx, .01));
              if (hero.right <= network.left + .01) {
                expect(hero.width, inInclusiveRange(320, 480));
                expect(network.top, closeTo(hero.top, .01));
              } else {
                expect(network.top, closeTo(hero.bottom, .01));
                expect(network.width, hero.width);
              }
              if (width >= 600) {
                expect(find.byType(NavigationBar), findsNothing);
                expect(
                  tester
                      .widget<NavigationRail>(find.byType(NavigationRail))
                      .selectedIndex,
                  tester
                          .widget<NavigationRail>(find.byType(NavigationRail))
                          .destinations
                          .length -
                      1,
                );
              } else {
                expect(find.byType(NavigationRail), findsNothing);
                expect(
                  tester
                      .widget<NavigationBar>(find.byType(NavigationBar))
                      .selectedIndex,
                  tester
                          .widget<NavigationBar>(find.byType(NavigationBar))
                          .destinations
                          .length -
                      1,
                );
              }
              final power = tester.getRect(
                find.byKey(const ValueKey('power-button'), skipOffstage: false),
              );
              final uptime = tester.getRect(
                find.byType(SessionUptime, skipOffstage: false),
              );
              final mode = tester.getRect(
                find.byKey(const ValueKey('mode-trigger'), skipOffstage: false),
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
}
