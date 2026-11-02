import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/overview/overview_page.dart';
import 'package:clash_pseudo/src/ui/overview/widgets/power_ripples.dart';
import 'package:clash_pseudo/src/ui/overview/widgets/session_uptime.dart';
import 'package:clash_pseudo/src/ui/overview/widgets/status_hero.dart';
import 'package:clash_pseudo/src/ui/overview/widgets/traffic_panel.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'overview_page_test.dart' show ViewController, config;

import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';

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
            final workspace = tester.element(
              find.byKey(const ValueKey('overview-workspace')),
            );
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
                final wide = size.width >= (scale == 1 ? 840 : 1040);
                expect(
                  tester.element(
                    find.byKey(const ValueKey('overview-workspace')),
                  ),
                  same(workspace),
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

  for (final immediateMode in ['ticker', 'reduced']) {
    testWidgets(
      'hero same-target $immediateMode snap keeps geometry and focus',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(800, 1000);
        addTearDown(tester.view.reset);
        final app = ViewController()
          ..state = const AppSnapshot(phase: 'RUNNING');
        final bounds = ValueNotifier(const Size(320, 600));
        final immediate = ValueNotifier(false);
        var live = true;
        try {
          await tester.pumpWidget(
            MaterialApp(
              navigatorObservers: [AppTaskNavigatorObserver()],
              theme: AppTheme.light,
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => ValueListenableBuilder<bool>(
                valueListenable: immediate,
                child: child,
                builder: (context, snap, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    disableAnimations: immediateMode == 'reduced' && snap,
                  ),
                  child: TickerMode(
                    enabled: immediateMode != 'ticker' || !snap,
                    child: AppTaskActivity(
                      active: true,
                      isActiveNow: () => live,
                      child: child!,
                    ),
                  ),
                ),
              ),
              home: Scaffold(
                body: ValueListenableBuilder<Size>(
                  valueListenable: bounds,
                  builder: (context, size, _) => Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: size.width,
                      height: size.height,
                      child: StatusHero(
                        controller: app,
                        runningProgress: 1,
                        visible: true,
                        isCurrent: () => live,
                        onManage: () {},
                        onImport: () {},
                        onMode: () {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          final power = find.byKey(const ValueKey('power-button'));
          final ripples = find.byType(PowerRipples);
          final uptime = find.byType(SessionUptime);
          final mode = find.byKey(const ValueKey('mode-trigger'));
          final powerElement = tester.element(power);
          final rippleState = tester.state(ripples);
          final uptimeState = tester.state(uptime);
          final focusFinder = find
              .descendant(of: power, matching: find.byType(Focus))
              .first;
          final focus = tester.state(focusFinder);
          final focusNode = Focus.of(
            tester.element(
              find
                  .descendant(of: focusFinder, matching: find.byType(Semantics))
                  .first,
            ),
          );
          focusNode.requestFocus();
          await tester.pump();
          final retiredStop = tester.widget<FilledButton>(power).onPressed!;

          Positioned position(Finder child) => tester.widget<Positioned>(
            find.ancestor(of: child, matching: find.byType(Positioned)),
          );
          AnimatedPositioned motion(Finder child) =>
              tester.widget<AnimatedPositioned>(
                find.ancestor(
                  of: child,
                  matching: find.byType(AnimatedPositioned),
                ),
              );
          Offset powerOffset() =>
              Offset(position(ripples).left!, position(ripples).top!);
          void identity() {
            expect(tester.element(power), same(powerElement));
            expect(tester.state(ripples), same(rippleState));
            expect(tester.state(uptime), same(uptimeState));
            expect(tester.state(focusFinder), same(focus));
            expect(focusNode.hasPrimaryFocus, isTrue);
            expect(find.byType(StatusHero), findsOneWidget);
            expect(ripples, findsOneWidget);
            expect(uptime, findsOneWidget);
            expect(tester.takeException(), isNull);
          }

          final initial = powerOffset();
          bounds.value = const Size(560, 900);
          await tester.pump();
          final powerTarget = Offset(
            motion(ripples).left!,
            motion(ripples).top!,
          );
          final detailsTarget = motion(uptime).top!;
          expect(motion(ripples).duration, const Duration(milliseconds: 180));
          expect(motion(uptime).curve, Curves.easeOutCubic);
          expect(powerOffset(), initial);
          await tester.pump(const Duration(milliseconds: 60));
          expect(
            powerOffset().dx,
            inExclusiveRange(initial.dx, powerTarget.dx),
          );
          expect(
            powerOffset().dy,
            inExclusiveRange(initial.dy, powerTarget.dy),
          );
          expect(position(uptime).top, lessThan(detailsTarget));
          identity();

          // Only the motion policy changes; both geometry targets stay fixed.
          immediate.value = true;
          await tester.pump();
          expect(powerOffset(), powerTarget);
          expect(position(uptime).top, detailsTarget);
          expect(
            tester.getRect(uptime).bottom,
            lessThanOrEqualTo(tester.getRect(mode).top),
          );
          identity();
          immediate.value = false;
          await tester.pump();
          expect(powerOffset(), powerTarget);
          expect(position(uptime).top, detailsTarget);
          identity();
          await tester.pump(const Duration(milliseconds: 16));
          expect(powerOffset(), powerTarget);
          expect(position(uptime).top, detailsTarget);
          identity();

          bounds.value = const Size(320, 600);
          await tester.pump();
          expect(powerOffset(), powerTarget);
          await tester.pump(const Duration(milliseconds: 60));
          final returning = powerOffset();
          final returningDetails = position(uptime).top!;
          expect(returning.dx, inExclusiveRange(initial.dx, powerTarget.dx));
          expect(returning.dy, inExclusiveRange(initial.dy, powerTarget.dy));
          bounds.value = const Size(560, 900);
          await tester.pump();
          expect(powerOffset(), returning);
          expect(position(uptime).top, returningDetails);
          await tester.pump(const Duration(milliseconds: 16));
          expect(powerOffset().dx, greaterThan(returning.dx));
          expect(powerOffset().dy, greaterThan(returning.dy));
          identity();

          live = false;
          retiredStop();
          expect(app.commands, isEmpty);
          live = true;
          await tester.tap(power);
          expect(app.commands.single, {'action': 'stop'});
          expect(powerOffset().dy, lessThan(powerTarget.dy));
          await tester.pump(const Duration(milliseconds: 180));
          expect(powerOffset(), powerTarget);
          expect(position(uptime).top, detailsTarget);
          identity();
        } finally {
          await tester.pumpWidget(const SizedBox());
          bounds.dispose();
          immediate.dispose();
          app.dispose();
        }
      },
    );
  }

  testWidgets('hidden overview resizes with the same import IME reader', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 900);
    addTearDown(tester.view.reset);
    final app = ViewController()..state = const AppSnapshot();
    final active = ValueNotifier(true);
    try {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [AppTaskNavigatorObserver()],
          theme: AppTheme.light,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => ValueListenableBuilder<bool>(
            valueListenable: active,
            child: child,
            builder: (context, live, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(1.3)),
              child: TickerMode(
                enabled: live,
                child: Offstage(
                  offstage: !live,
                  child: AppTaskActivity(
                    active: live,
                    isActiveNow: () => active.value,
                    child: child!,
                  ),
                ),
              ),
            ),
          ),
          home: OverviewPage(controller: app),
        ),
      );
      await tester.pump();
      final page = find.byType(OverviewPage, skipOffstage: false);
      final power = find.byKey(
        const ValueKey('power-button'),
        skipOffstage: false,
      );
      final ripples = find.byType(PowerRipples, skipOffstage: false);
      final uptime = find.byType(SessionUptime, skipOffstage: false);
      final pageState = tester.state(page);
      final rippleState = tester.state(ripples);
      final uptimeState = tester.state(uptime);
      final powerElement = tester.element(power);
      final scroll = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: page,
                  matching: find.byType(Scrollable, skipOffstage: false),
                  skipOffstage: false,
                )
                .first,
          )
          .position;
      final retiredStop = tester.widget<FilledButton>(power).onPressed!;
      void identity() {
        expect(tester.state(page), same(pageState));
        expect(tester.state(ripples), same(rippleState));
        expect(tester.state(uptime), same(uptimeState));
        expect(tester.element(power), same(powerElement));
        expect(
          tester
              .state<ScrollableState>(
                find
                    .descendant(
                      of: page,
                      matching: find.byType(Scrollable, skipOffstage: false),
                      skipOffstage: false,
                    )
                    .first,
              )
              .position,
          same(scroll),
        );
        expect(page, findsOneWidget);
        expect(ripples, findsOneWidget);
        expect(uptime, findsOneWidget);
        expect(tester.takeException(), isNull);
      }

      active.value = false;
      retiredStop();
      expect(app.commands, isEmpty);
      await tester.pump();
      for (final size in const [
        Size(320, 900),
        Size(700, 900),
        Size(320, 1000),
      ]) {
        tester.view.physicalSize = size;
        await tester.pump();
        expect(TickerMode.valuesOf(tester.element(page)).enabled, isFalse);
        expect(AppTaskActivity.isActive(tester.element(page)), isFalse);
        expect(
          find.ancestor(
            of: uptime,
            matching: find.byType(AnimatedPositioned, skipOffstage: false),
          ),
          findsNothing,
        );
        final powerPosition = tester.widget<Positioned>(
          find.ancestor(
            of: ripples,
            matching: find.byType(Positioned, skipOffstage: false),
          ),
        );
        final detailsPosition = tester.widget<Positioned>(
          find.ancestor(
            of: uptime,
            matching: find.byType(Positioned, skipOffstage: false),
          ),
        );
        expect(
          detailsPosition.top,
          powerPosition.top! + PowerRipples.buttonDiameter,
        );
        expect(
          tester.getRect(uptime).bottom,
          lessThanOrEqualTo(
            tester
                .getRect(
                  find.byKey(
                    const ValueKey('mode-trigger'),
                    skipOffstage: false,
                  ),
                )
                .top,
          ),
        );
        expect(
          tester.getRect(power).center.dx,
          closeTo(
            tester
                .getRect(
                  find.byKey(
                    const ValueKey('mode-trigger'),
                    skipOffstage: false,
                  ),
                )
                .center
                .dx,
            .01,
          ),
        );
        identity();
        retiredStop();
        expect(app.commands, isEmpty);
      }
      active.value = true;
      await tester.pump();
      identity();
      await tester.tap(find.text('Import configuration'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final field = find.byKey(const ValueKey('import-source'));
      const source = 'http://example.test/ime?token=synthetic';
      await tester.enterText(field, source);
      final input = tester.widget<TextField>(field).controller!;
      final editable = tester.state<EditableTextState>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      );
      expect(editable.widget.focusNode.hasFocus, isTrue);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      tester.view.physicalSize = const Size(600, 900);
      await tester.pump();
      expect(tester.widget<TextField>(field).controller, same(input));
      expect(input.text, source);
      expect(
        tester.state<EditableTextState>(
          find.descendant(of: field, matching: find.byType(EditableText)),
        ),
        same(editable),
      );
      expect(editable.widget.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      identity();
      retiredStop();
      expect(app.commands, isEmpty);
      expect(find.byType(AlertDialog), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox());
      active.dispose();
      app.dispose();
    }
  });

  testWidgets(
    'capacity reflow has real intermediate rectangles, continuous reversal and one reading identity',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(830, 300);
      addTearDown(tester.view.reset);
      final app = ViewController();
      Widget host({bool reduced = false}) => MaterialApp(
        theme: AppTheme.light,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: child!,
        ),
        home: OverviewPage(controller: app),
      );
      try {
        await tester.pumpWidget(host());
        await tester.pump();
        final page = tester.state(find.byType(OverviewPage));
        final panel = tester.state(find.byType(TrafficPanel));
        final ripples = tester.state(find.byType(PowerRipples));
        final traffic = tester
            .widget<TrafficPanel>(find.byType(TrafficPanel))
            .traffic;
        final scroll = tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position;
        scroll.jumpTo(48);
        await tester.pump();
        Rect network() => tester
            .getRect(find.byKey(const ValueKey('network-surface')))
            .shift(
              -tester.getTopLeft(
                find.byKey(const ValueKey('overview-workspace')),
              ),
            );
        void identity() {
          expect(tester.state(find.byType(OverviewPage)), same(page));
          expect(tester.state(find.byType(TrafficPanel)), same(panel));
          expect(tester.state(find.byType(PowerRipples)), same(ripples));
          expect(
            tester.widget<TrafficPanel>(find.byType(TrafficPanel)).traffic,
            same(traffic),
          );
          expect(
            tester
                .state<ScrollableState>(find.byType(Scrollable).first)
                .position,
            same(scroll),
          );
          expect(scroll.pixels, 48);
          expect(find.byType(OverviewPage), findsOneWidget);
          expect(find.byType(TrafficPanel), findsOneWidget);
          expect(tester.takeException(), isNull);
        }

        expect(network().left, 0);
        tester.view.physicalSize = const Size(860, 300);
        await tester.pump();
        final first = network();
        await tester.pump(const Duration(milliseconds: 60));
        final middle = network();
        expect(middle.left, greaterThan(first.left));
        expect(middle.left, lessThan(320));
        expect(middle.top, greaterThan(0));
        expect(middle.top, lessThan(first.top));
        expect(middle.width, greaterThan(540));
        identity();
        tester.view.physicalSize = const Size(830, 300);
        await tester.pump();
        expect(network().left, closeTo(middle.left, .01));
        await tester.pump(const Duration(milliseconds: 16));
        expect(network().left, lessThan(middle.left));
        for (final width in [850.0, 820.0, 855.0, 815.0, 860.0]) {
          final before = network().left;
          tester.view.physicalSize = Size(width, 300);
          await tester.pump();
          expect(network().left, closeTo(before, .01));
          await tester.pump(const Duration(milliseconds: 16));
          expect(network().right, closeTo(width, .01));
          identity();
        }
        await tester.pump(const Duration(milliseconds: 220));
        expect(network().left, closeTo(320, .01));
        expect(network().top, closeTo(0, .01));
        identity();
        tester.view.physicalSize = const Size(830, 300);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        expect(network().left, inExclusiveRange(0, 320));
        await tester.pumpWidget(host(reduced: true));
        expect(network().left, 0);
        expect(network().width, 830);
        identity();
        tester.view.physicalSize = const Size(860, 300);
        await tester.pump();
        expect(network().left, closeTo(320, .01));
        expect(network().top, 0);
        identity();
      } finally {
        await tester.pumpWidget(const SizedBox());
        app.dispose();
      }
    },
  );

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
