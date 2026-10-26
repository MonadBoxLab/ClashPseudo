import 'dart:ui' show SemanticsAction;

import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/features/overview/widgets/session_uptime.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class UptimeClock implements Stopwatch {
  @override
  int elapsedMilliseconds = 0;
  @override
  void reset() => elapsedMilliseconds = 0;
  @override
  void start() {}
  @override
  void stop() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AppSnapshot sample(int milliseconds, {int generation = 1}) => AppSnapshot(
  phase: 'RUNNING',
  generation: generation,
  runningSinceElapsedMs: 100,
  elapsedRealtimeMs: milliseconds + 100,
);

void main() {
  test('uptime units retain elapsed days instead of wrapping years', () {
    expect(uptimeText(0), (clock: '00:00:00', days: '0'));
    expect(uptimeText(59999), (clock: '00:00:59', days: '0'));
    expect(uptimeText(60000), (clock: '00:01:00', days: '0'));
    expect(uptimeText(3599999), (clock: '00:59:59', days: '0'));
    expect(uptimeText(3600000), (clock: '01:00:00', days: '0'));
    expect(uptimeText(86400000), (clock: '00:00:00', days: '1'));
    expect(uptimeText(12345 * 86400000 + 45296000), (
      clock: '12:34:56',
      days: '12345',
    ));
    expect(uptimeText(9223372036854775807).days, '106751991167');
  });

  test('only a valid running monotonic sample supplies uptime', () {
    expect(sample(123).uptimeMilliseconds, 123);
    expect(const AppSnapshot(phase: 'RUNNING').uptimeMilliseconds, isNull);
    expect(
      const AppSnapshot(
        phase: 'RUNNING',
        runningSinceElapsedMs: 200,
        elapsedRealtimeMs: 100,
      ).uptimeMilliseconds,
      isNull,
    );
    expect(
      const AppSnapshot(
        phase: 'STOPPED',
        runningSinceElapsedMs: 100,
        elapsedRealtimeMs: 200,
      ).uptimeMilliseconds,
      isNull,
    );
    expect(
      AppSnapshot.fromMap({
        'phase': 'RUNNING',
        'mode': 'rule',
        'runningSinceElapsedMs': 'invalid',
        'elapsedRealtimeMs': 200,
      }).uptimeMilliseconds,
      isNull,
    );
  });

  testWidgets(
    'uptime includes time spent reading files after the platform reply',
    (tester) async {
      final observation = UptimeClock()..elapsedMilliseconds = 5000;
      final interpolation = UptimeClock();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SessionUptime(
              snapshot: AppSnapshot(
                phase: 'RUNNING',
                generation: 1,
                runningSinceElapsedMs: 100,
                elapsedRealtimeMs: 10100,
                observationClock: observation,
              ),
              active: true,
              showUptime: true,
              title: 'Running',
              subtitle: '',
              color: Colors.black,
              refresh: () {},
              clock: interpolation,
            ),
          ),
        ),
      );
      expect(find.text('00h 00m 15s'), findsWidgets);
      interpolation.elapsedMilliseconds = 1000;
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('00h 00m 16s'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final language in ['en', 'zh']) {
    for (final width in [280.0, 700.0]) {
      for (final scale in [1.0, 1.3, 2.0]) {
        testWidgets(
          'status details target stays stable $language/$width/$scale',
          (tester) async {
            var opened = 0;
            Widget host(bool issue) => MaterialApp(
              locale: Locale(language),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: width,
                      child: Builder(
                        builder: (context) {
                          final strings = AppLocalizations.of(context);
                          return SessionUptime(
                            snapshot: const AppSnapshot(phase: 'STOPPED'),
                            active: true,
                            showUptime: false,
                            title: strings.stateStopped,
                            subtitle: issue
                                ? strings.statusIssue
                                : strings.statusReady,
                            color: Colors.black,
                            refresh: () {},
                            onIssue: issue ? () => opened++ : null,
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpWidget(host(false));
            final status = find.byType(SessionUptime);
            final target = find.descendant(
              of: status,
              matching: find.byType(InkWell),
            );
            final bounds = tester.getRect(status);
            final title = tester.getRect(
              find.byKey(const ValueKey('uptime-title')),
            );
            for (final issue in [true, false, true, false]) {
              await tester.pumpWidget(host(issue));
              for (final ms in [0, 16, 80, 100, 180]) {
                await tester.pump(Duration(milliseconds: ms));
                final hit = tester.getRect(target);
                expect(hit.width, greaterThanOrEqualTo(48));
                expect(hit.height, greaterThanOrEqualTo(48));
                expect(tester.getRect(status), bounds);
                expect(
                  tester.getRect(find.byKey(const ValueKey('uptime-title'))),
                  title,
                );
                expect(tester.widget<InkWell>(target).onTap != null, issue);
                final strings = AppLocalizations.of(tester.element(status));
                expect(
                  find.semantics.byLabel(strings.stateStopped),
                  findsOneWidget,
                );
                if (issue) {
                  final node = tester.getSemantics(
                    find.byKey(const ValueKey('status-details')),
                  );
                  expect(node.rect.height, greaterThanOrEqualTo(48));
                  expect(node.getSemanticsData().label, strings.statusIssue);
                  expect(
                    node.getSemanticsData().hasAction(SemanticsAction.tap),
                    isTrue,
                  );
                  expect(
                    find.semantics.byLabel(strings.statusIssue),
                    findsOneWidget,
                  );
                }
                expect(tester.takeException(), isNull);
              }
              final before = opened;
              if (issue) {
                await tester.tapAt(
                  tester.getRect(target).topLeft + const Offset(4, 4),
                );
                expect(
                  opened,
                  before + 1,
                  reason: 'The full target, not only its text, must work.',
                );
              }
            }
            await tester.pumpWidget(host(true));
            await tester.pump(const Duration(milliseconds: 320));
            final beforeRetirement = opened;
            final gesture = await tester.startGesture(tester.getCenter(target));
            await tester.pumpWidget(host(false));
            await tester.pump(const Duration(milliseconds: 16));
            await gesture.up();
            expect(opened, beforeRetirement);
            expect(
              tester
                  .getSemantics(find.byKey(const ValueKey('status-details')))
                  .getSemanticsData()
                  .hasAction(SemanticsAction.tap),
              isFalse,
            );
            expect(tester.getRect(status), bounds);
            await tester.pumpWidget(const SizedBox());
          },
          semanticsEnabled: true,
        );
      }
    }
  }

  for (final language in ['zh', 'en']) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('uptime stays stable $language $dark $scale', (
          tester,
        ) async {
          final clock = UptimeClock();
          var refreshes = 0;
          Widget host(AppSnapshot snapshot, {bool active = true}) =>
              MaterialApp(
                locale: Locale(language),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                theme: ThemeData(
                  brightness: dark ? Brightness.dark : Brightness.light,
                ),
                home: MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                  child: Scaffold(
                    body: Center(
                      child: SizedBox(
                        width: 272,
                        child: SessionUptime(
                          snapshot: snapshot,
                          active: active,
                          showUptime: snapshot.running,
                          title: 'Stopped',
                          subtitle: 'Ready',
                          color: dark ? Colors.white : Colors.black,
                          clock: clock,
                          refresh: () => refreshes++,
                        ),
                      ),
                    ),
                  ),
                ),
              );
          final start = sample(86399000);
          await tester.pumpWidget(host(start));
          final strings = AppLocalizations.of(
            tester.element(find.byType(SessionUptime)),
          );
          final bounds = tester.getRect(find.byType(SessionUptime));
          expect(
            find.text(strings.uptimeClock('23', '59', '59')),
            findsWidgets,
          );
          clock.elapsedMilliseconds = 1000;
          await tester.pump(const Duration(seconds: 1));
          expect(
            find.text(strings.uptimeClock('00', '00', '00')),
            findsWidgets,
          );
          expect(find.text(strings.uptimeDays('1')), findsWidgets);
          expect(tester.getRect(find.byType(SessionUptime)), bounds);
          expect(tester.hasRunningAnimations, isFalse);
          await tester.pumpWidget(host(start, active: false));
          clock.elapsedMilliseconds = 3600000;
          await tester.pump(const Duration(hours: 1));
          expect(
            find.text(strings.uptimeClock('00', '00', '00')),
            findsWidgets,
          );
          await tester.pumpWidget(host(start));
          await tester.pump();
          expect(refreshes, 1);
          for (final ms in [0, 16, 80, 200]) {
            await tester.pump(Duration(milliseconds: ms));
            expect(
              find.semantics.byLabel(strings.statusPending),
              findsOneWidget,
            );
            expect(tester.getRect(find.byType(SessionUptime)), bounds);
          }
          expect(find.text(strings.statusPending), findsOneWidget);
          await tester.pumpWidget(host(sample(86400000 + 3600000)));
          expect(
            find.text(strings.uptimeClock('01', '00', '00')),
            findsWidgets,
          );
          await tester.pumpWidget(host(sample(9223372036854775000)));
          expect(find.text(strings.uptimeDays('106751991167')), findsWidgets);
          expect(tester.getRect(find.byType(SessionUptime)), bounds);
          await tester.pumpWidget(host(sample(0, generation: 2)));
          expect(
            find.text(strings.uptimeClock('00', '00', '00')),
            findsWidgets,
          );
          expect(find.text(strings.uptimeRunning), findsWidgets);
          expect(tester.getRect(find.byType(SessionUptime)), bounds);
          await tester.pumpWidget(host(const AppSnapshot(phase: 'STOPPED')));
          for (final ms in [16, 100, 200]) {
            await tester.pump(Duration(milliseconds: ms));
            expect(tester.getRect(find.byType(SessionUptime)), bounds);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        }, semanticsEnabled: true);
      }
    }
  }
}
