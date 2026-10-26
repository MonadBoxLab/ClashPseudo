import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/overview/overview_page.dart';
import 'package:clash_pseudo/src/features/overview/widgets/power_ripples.dart';
import 'package:clash_pseudo/src/features/overview/widgets/status_hero.dart';
import 'package:clash_pseudo/src/features/overview/widgets/traffic_panel.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'overview_page_test.dart' show ViewController, config;

void main() {
  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'overview reflows the same control and network task $language/$scale',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(320, 900);
          addTearDown(tester.view.reset);
          final app = ViewController()
            ..collection = ConfigCollection(
              entries: [config('one')],
              selectedId: 'one',
            );
          try {
            await tester.pumpWidget(
              MaterialApp(
                theme: AppTheme.light,
                locale: Locale(language),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: true,
                  ),
                  child: child!,
                ),
                home: OverviewPage(controller: app),
              ),
            );
            await tester.pump();
            final page = tester.state(find.byType(OverviewPage));
            final ripples = tester.state(find.byType(PowerRipples));
            final traffic = tester
                .widget<TrafficPanel>(find.byType(TrafficPanel))
                .traffic;
            final scroll = tester
                .state<ScrollableState>(find.byType(Scrollable).first)
                .position;
            for (final size in [
              const Size(700, 479),
              const Size(839, 480),
              const Size(840, 481),
              const Size(1000, 899),
              const Size(1200, 900),
              const Size(1600, 901),
              const Size(1704, 320),
              const Size(1704, 280),
              const Size(280, 1704),
              const Size(1600, 280),
              const Size(600, 1600),
              const Size(280, 280),
              const Size(1000, 900),
              const Size(320, 900),
            ]) {
              tester.view.physicalSize = size;
              for (final ms in [0, 16, 320]) {
                await tester.pump(Duration(milliseconds: ms));
                final workspace = tester.widget<Flex>(
                  find.byKey(const ValueKey('overview-workspace')),
                );
                final wide = size.width >= (scale == 1 ? 840 : 1040);
                expect(
                  workspace.direction,
                  wide ? Axis.horizontal : Axis.vertical,
                );
                expect(tester.state(find.byType(OverviewPage)), same(page));
                expect(tester.state(find.byType(PowerRipples)), same(ripples));
                expect(
                  tester
                      .widget<TrafficPanel>(find.byType(TrafficPanel))
                      .traffic,
                  same(traffic),
                );
                expect(
                  tester
                      .state<ScrollableState>(find.byType(Scrollable).first)
                      .position,
                  same(scroll),
                );
                final hero = tester.getRect(find.byType(StatusHero));
                final network = tester.getRect(
                  find.byKey(const ValueKey('network-surface')),
                );
                if (wide) {
                  expect(hero.width, inInclusiveRange(320, 480));
                  final panel = tester.getRect(find.byType(TrafficPanel));
                  final readingArea = tester.getRect(
                    find
                        .ancestor(
                          of: find.byType(TrafficPanel),
                          matching: find.byType(Align),
                        )
                        .first,
                  );
                  expect(panel.width, lessThanOrEqualTo(840 * scale));
                  expect(panel.center.dx, closeTo(readingArea.center.dx, .01));
                  expect(panel.center.dy, closeTo(readingArea.center.dy, .01));
                  expect(network.left, closeTo(hero.right, .01));
                  expect(network.top, closeTo(hero.top, .01));
                  expect(hero.width + network.width, closeTo(size.width, .01));
                } else {
                  expect(network.top, closeTo(hero.bottom, .01));
                  expect(network.width, closeTo(hero.width, .01));
                }
                expect(app.commands, isEmpty);
                expect(
                  tester.takeException(),
                  isNull,
                  reason: '$size/$scale/$ms',
                );
              }
            }
          } finally {
            await tester.pumpWidget(const SizedBox());
            app.dispose();
          }
        },
      );
    }
  }

  testWidgets('network groups use spare height and width independently', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = ViewController();
    try {
      tester.view.physicalSize = const Size(1400, 500);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: OverviewPage(controller: app),
        ),
      );
      await tester.pump();
      final strings = AppLocalizations.of(
        tester.element(find.byType(OverviewPage)),
      );
      ({double section, double reading, double columns, double total})
      spacing() {
        Rect anchor(String name) => tester.getRect(find.byKey(ValueKey(name)));
        final down = anchor('traffic-download-direction');
        final up = anchor('traffic-upload-direction');
        final charts = find.byType(TrafficChart);
        return (
          section:
              down.top -
              tester.getRect(find.text(strings.networkActivity)).bottom,
          reading: anchor('traffic-download-reading').top - down.bottom,
          columns: up.left - tester.getRect(charts.first).right,
          total:
              anchor('traffic-download-total').top -
              tester.getRect(charts.first).bottom,
        );
      }

      final short = spacing();
      tester.view.physicalSize = const Size(1400, 1100);
      await tester.pump();
      final tall = spacing();
      expect(tall.section, greaterThan(short.section));
      expect(tall.reading, closeTo(short.reading, .01));
      expect(tall.total, closeTo(short.total, .01));
      expect(tall.columns, closeTo(short.columns, .01));
      tester.view.physicalSize = const Size(1000, 1100);
      await tester.pump();
      final narrow = spacing();
      expect(narrow.columns, lessThan(tall.columns));
      expect(narrow.reading, closeTo(tall.reading, .01));
      expect(narrow.total, greaterThanOrEqualTo(12));
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    }
  });

  for (final brand in BrandColor.values) {
    for (final dark in [false, true]) {
      testWidgets(
        'power state keeps its brand fill even without a configuration $brand/$dark',
        (tester) async {
          final app = ViewController();
          final palette = HomePalette(dark, brand: brand);
          try {
            await tester.pumpWidget(
              MaterialApp(
                theme: AppTheme.forBrightness(
                  dark ? Brightness.dark : Brightness.light,
                  brand,
                ),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(disableAnimations: true),
                  child: child!,
                ),
                home: OverviewPage(controller: app),
              ),
            );
            await tester.pump();
            final power = find.byKey(const ValueKey('power-button'));
            var button = tester.widget<FilledButton>(power);
            expect(button.onPressed, isNull);
            Color checkButton(FilledButton value) {
              final face = value.style!.backgroundColor!.resolve({})!;
              final glyph = value.style!.foregroundColor!.resolve({})!;
              expect(face.a, 1);
              expect(glyph.a, 1);
              expect(
                value.style!.backgroundColor!.resolve({WidgetState.disabled}),
                face,
              );
              expect(
                value.style!.foregroundColor!.resolve({WidgetState.disabled}),
                glyph,
              );
              final luminances = [
                face.computeLuminance(),
                glyph.computeLuminance(),
              ]..sort();
              expect(
                (luminances.last + .05) / (luminances.first + .05),
                greaterThanOrEqualTo(4.5),
              );
              return face;
            }

            final stoppedFace = checkButton(button);
            app.state = const AppSnapshot(phase: 'RUNNING');
            app.changed();
            await tester.pump();
            button = tester.widget<FilledButton>(power);
            expect(checkButton(button), isNot(stoppedFace));
            final field = tester.widget<DecoratedBox>(
              find.byKey(const ValueKey('overview-brand-field')),
            );
            expect((field.decoration as BoxDecoration).color, palette.hero);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            app.dispose();
          }
        },
      );
    }
  }
}
