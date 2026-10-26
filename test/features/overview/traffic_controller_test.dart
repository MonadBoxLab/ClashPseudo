import 'package:clash_pseudo/src/model/app_snapshot.dart';

import 'dart:async';

import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/features/overview/traffic_controller.dart';
import 'package:clash_pseudo/src/features/overview/traffic_window.dart';
import 'package:clash_pseudo/src/features/overview/widgets/traffic_panel.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fakes.dart';

class TestClock implements Stopwatch {
  @override
  int elapsedMilliseconds = 0;
  @override
  void start() {}
  @override
  void stop() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MemoryBridge extends TrafficBridge {
  int memoryReads = 0;
  bool memoryFails = false;
  Completer<Map<String, dynamic>>? memoryPending;
  int? rss = 123456789;
  bool memoryValid = true;
  int? sampledAt;

  @override
  Future<Map<String, dynamic>> processMemory() {
    memoryReads++;
    if (memoryFails) return Future.error(StateError('unavailable'));
    return memoryPending?.future ??
        Future.value({
          'processRssBytes': rss,
          'sampledAt': sampledAt ?? DateTime.now().millisecondsSinceEpoch,
          'valid': memoryValid,
          if (!memoryValid) 'error': 'unavailable',
        });
  }
}

void main() {
  testWidgets(
    'RSS reads only while overview foreground visible, including VPN stopped',
    (tester) async {
      final bridge = MemoryBridge();
      final app = TrafficApp(bridge)
        ..state = const AppSnapshot(phase: 'STOPPED');
      final view = TrafficController(app);
      await tester.pump(const Duration(seconds: 2));
      expect(bridge.memoryReads, 0);
      view.setVisible(true);
      await tester.pump();
      expect(view.processRssBytes, 123456789);
      expect(bridge.reads, 0);
      expect(bridge.memoryReads, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.memoryReads, 2);
      app.setForeground(false);
      await tester.pump(const Duration(seconds: 10));
      expect(bridge.memoryReads, 2);
      expect(view.processRssBytes, isNull);
      app.setForeground(true);
      await tester.pump();
      expect(bridge.memoryReads, 3);
      view.setVisible(false);
      await tester.pump(const Duration(seconds: 10));
      expect(bridge.memoryReads, 3);
      expect(bridge.reads, 0);
      view.dispose();
      app.dispose();
    },
  );

  testWidgets(
    'RSS single flight survives visibility changes and discards a late hidden sample',
    (tester) async {
      final bridge = MemoryBridge()
        ..memoryPending = Completer<Map<String, dynamic>>();
      final app = TrafficApp(bridge);
      final view = TrafficController(app)..setVisible(true);
      view.setVisible(false);
      view.setVisible(true);
      await tester.pump(const Duration(seconds: 20));
      expect(bridge.memoryReads, 1);
      expect(view.processRssBytes, isNull);
      final old = bridge.memoryPending!;
      bridge.memoryPending = Completer<Map<String, dynamic>>();
      old.complete({
        'processRssBytes': 999,
        'sampledAt': DateTime.now().millisecondsSinceEpoch,
        'valid': true,
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(view.processRssBytes, isNull);
      expect(bridge.memoryReads, 2);
      view.dispose();
      bridge.memoryPending!.complete({
        'processRssBytes': 888,
        'sampledAt': DateTime.now().millisecondsSinceEpoch,
        'valid': true,
      });
      await tester.pump();
      app.dispose();
    },
  );

  testWidgets(
    'RSS failure is unknown not zero and traffic remains independently valid',
    (tester) async {
      final bridge = MemoryBridge();
      final app = TrafficApp(bridge);
      final view = TrafficController(app)..setVisible(true);
      await tester.pump();
      expect(view.processRssBytes, 123456789);
      bridge.memoryFails = true;
      await tester.pump(const Duration(seconds: 1));
      expect(view.processRssBytes, isNull);
      expect(view.memoryUnavailable, isTrue);
      expect(view.data!.download, 2048);
      bridge.memoryFails = false;
      bridge.fail = true;
      bridge.rss = 0;
      await tester.pump(const Duration(seconds: 1));
      expect(view.processRssBytes, 0);
      expect(view.memoryUnavailable, isFalse);
      expect(view.error, isNotNull);
      view.dispose();
      app.dispose();
    },
  );

  testWidgets('RSS validity, timestamp and bytes are all required', (
    tester,
  ) async {
    for (final invalid in ['null', 'negative', 'invalid', 'old', 'future']) {
      final bridge = MemoryBridge();
      switch (invalid) {
        case 'null':
          bridge.rss = null;
        case 'negative':
          bridge.rss = -1;
        case 'invalid':
          bridge.memoryValid = false;
        case 'old':
          bridge.sampledAt = DateTime.now().millisecondsSinceEpoch - 6000;
        case 'future':
          bridge.sampledAt = DateTime.now().millisecondsSinceEpoch + 6000;
      }
      final app = TrafficApp(bridge);
      final view = TrafficController(app)..setVisible(true);
      await tester.pump();
      expect(view.processRssBytes, isNull, reason: invalid);
      expect(view.memoryUnavailable, isTrue, reason: invalid);
      view.dispose();
      app.dispose();
    }
  });

  testWidgets(
    'RSS ages to unknown while the next native read remains pending',
    (tester) async {
      final bridge = MemoryBridge();
      final app = TrafficApp(bridge);
      final view = TrafficController(app)..setVisible(true);
      await tester.pump();
      bridge.memoryPending = Completer<Map<String, dynamic>>();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 4001));
      expect(view.processRssBytes, isNull);
      expect(view.memoryUnavailable, isTrue);
      expect(bridge.memoryReads, 2);
      view.dispose();
      bridge.memoryPending!.complete({
        'processRssBytes': 1,
        'sampledAt': DateTime.now().millisecondsSinceEpoch,
        'valid': true,
      });
      await tester.pump();
      app.dispose();
    },
  );

  testWidgets('visible UI queries only, returning reads existing window', (
    tester,
  ) async {
    final bridge = TrafficBridge();
    final app = TrafficApp(bridge);
    final view = TrafficController(app);
    await tester.pump(const Duration(seconds: 10));
    expect(bridge.reads, 0);
    view.setVisible(true);
    await tester.pump();
    expect(view.data?.points.length, 2);
    expect(view.data?.activeCount, 2000);
    expect(bridge.reads, 1);
    app.changed();
    await tester.pump();
    expect(bridge.reads, 1);
    app.setForeground(false);
    await tester.pump(const Duration(seconds: 31));
    expect(bridge.reads, 1);
    bridge.value = data(now: 32000);
    app.setForeground(true);
    await tester.pump();
    expect(bridge.reads, 2);
    expect(view.data?.points.last.elapsedMs, 32000);
    view.setVisible(false);
    await tester.pump(const Duration(seconds: 31));
    expect(bridge.reads, 2);
    app.state = const AppSnapshot(phase: 'STOPPED');
    app.changed();
    view.setVisible(true);
    await tester.pump();
    expect(view.data, isNull);
    expect(bridge.reads, 2);
    view.dispose();
    app.dispose();
  });

  testWidgets(
    'local expiry invalidates while read is pending, then prunes history',
    (tester) async {
      final bridge = TrafficBridge();
      final app = TrafficApp(bridge);
      final clock = TestClock();
      final view = TrafficController(app, clock: clock)..setVisible(true);
      await tester.pump();
      var notifications = 0;
      view.addListener(() => notifications++);
      bridge.pending = Completer<TrafficSnapshot>();
      clock.elapsedMilliseconds = 1000;
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.reads, 2);
      clock.elapsedMilliseconds = 5001;
      await tester.pump(const Duration(milliseconds: 4001));
      expect(view.data?.fresh, isFalse);
      expect(view.data?.activeCount, isNull);
      expect(notifications, greaterThan(0));
      bridge.fail = true;
      clock.elapsedMilliseconds = 31001;
      await tester.pump(const Duration(seconds: 26));
      expect(view.data?.points, isEmpty);
      view.dispose();
      bridge.pending!.complete(data());
      await tester.pump();
      app.dispose();
    },
  );

  testWidgets(
    'one query in flight and old identity never overwrites new state',
    (tester) async {
      final bridge = TrafficBridge()..pending = Completer<TrafficSnapshot>();
      final app = TrafficApp(bridge);
      final view = TrafficController(app)..setVisible(true);
      view.setVisible(false);
      view.setVisible(true);
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.reads, 1);
      app.state = const AppSnapshot(
        phase: 'RUNNING',
        generation: 2,
        core: core,
      );
      app.changed();
      final old = bridge.pending!;
      bridge.pending = null;
      old.complete(data());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(view.data, isNull);
      expect(view.error, isNotNull);
      view.dispose();
      app.dispose();
    },
  );

  for (final locale in ['zh', 'en']) {
    for (final width in [280.0, 360.0, 700.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('footer stays readable and stable $locale $width $scale', (
          tester,
        ) async {
          final bridge = TrafficBridge();
          final app = TrafficApp(bridge);
          final traffic = TrafficController(app)..setVisible(true);
          final semantics = tester.ensureSemantics();
          await tester.pumpWidget(
            MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: Locale(locale),
              home: MediaQuery(
                data: MediaQueryData(
                  disableAnimations: true,
                  textScaler: TextScaler.linear(scale),
                ),
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: SizedBox(
                      width: width,
                      child: TrafficPanel(
                        traffic: traffic,
                        visible: true,
                        width: width,
                        onOpen: () {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          final context = tester.element(find.byType(TrafficPanel));
          final strings = AppLocalizations.of(context);
          final panel = tester.getRect(find.byType(TrafficPanel));
          expect(find.byKey(const ValueKey('traffic-caption')), findsNothing);
          final status = find.byKey(const ValueKey('traffic-status'));
          expect(status, findsNothing);
          for (final chart in tester.widgetList<TrafficChart>(
            find.byType(TrafficChart),
          )) {
            expect(chart.size.height, greaterThanOrEqualTo(80));
          }
          expect(
            find.bySemanticsLabel(
              '${strings.download} 2.00 KiB/s · ${strings.trafficDownloaded} — · ${strings.recentConnections}',
            ),
            findsOneWidget,
          );
          bridge.fail = true;
          await tester.pump(const Duration(seconds: 1));
          await tester.pump();
          expect(traffic.error, isNotNull);
          expect(status, findsNothing);
          expect(find.byType(AlertDialog), findsNothing);
          expect(tester.getRect(find.byType(TrafficPanel)), panel);
          bridge.fail = false;
          await tester.pump(const Duration(seconds: 1));
          await tester.pump();
          expect(tester.getRect(find.byType(TrafficPanel)), panel);
          app.state = const AppSnapshot(phase: 'STOPPED');
          app.changed();
          for (final milliseconds in [0, 16, 100, 200]) {
            await tester.pump(Duration(milliseconds: milliseconds));
            expect(find.byTooltip(strings.waitingTakeover), findsNothing);
            expect(status, findsNothing);
            expect(tester.getRect(find.byType(TrafficPanel)), panel);
            expect(tester.takeException(), isNull);
          }
          semantics.dispose();
          await tester.pumpWidget(const SizedBox());
          traffic.dispose();
          app.dispose();
        });
      }
    }
  }

  for (final dark in [false, true]) {
    testWidgets(
      'panel real data, wide touch targets and reduced motion ($dark)',
      (tester) async {
        final bridge = TrafficBridge();
        final app = TrafficApp(bridge);
        final traffic = TrafficController(app)..setVisible(true);
        var opens = 0;
        Widget show({
          bool visible = true,
          bool reduced = false,
          double scale = 1,
        }) {
          traffic.setVisible(visible);
          return MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
            theme: dark ? AppTheme.dark : AppTheme.light,
            home: MediaQuery(
              data: MediaQueryData(
                disableAnimations: reduced,
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: SizedBox(
                    width: 320,
                    child: TrafficPanel(
                      traffic: traffic,
                      visible: visible,
                      width: 320,
                      onOpen: () => opens++,
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(show());
        await tester.pump();
        expect(
          tester.getSemantics(
            find.bySemanticsLabel('下载 2.00 KiB/s · 累计下载 — · 最近连接'),
          ),
          matchesSemantics(
            label: '下载 2.00 KiB/s · 累计下载 — · 最近连接',
            hint: AppLocalizations.of(tester.element(find.byType(TrafficPanel)))
                .trafficSessionScope,
            isButton: true,
            hasTapAction: true,
          ),
        );
        semantics.dispose();
        expect(find.text('连接 2000'), findsOneWidget);
        expect(find.text('2.00'), findsOneWidget);
        expect(find.text('KiB/s'), findsOneWidget);
        expect(find.text('0'), findsOneWidget);
        expect(tester.hasRunningAnimations, isTrue);
        for (final label in ['下载', '上传', '最近连接']) {
          await tester.tap(find.text(label));
          await tester.pump();
        }
        expect(opens, 3);
        expect(
          tester.getSize(find.widgetWithText(TextButton, '最近连接')).height,
          greaterThanOrEqualTo(48),
        );
        await tester.pumpWidget(show(reduced: true, scale: 2));
        // Let the earlier Material tap feedback finish independently of the endpoint.
        await tester.pumpAndSettle();
        expect(tester.hasRunningAnimations, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(show(visible: false));
        await tester.pump();
        final reads = bridge.reads;
        await tester.pump(const Duration(seconds: 10));
        await tester.pumpAndSettle();
        expect(bridge.reads, reads);
        expect(tester.hasRunningAnimations, isFalse);
        await tester.pumpWidget(const SizedBox());
        traffic.dispose();
        app.dispose();
      },
    );
  }
}
