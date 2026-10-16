import 'dart:async';

import 'package:clash_pseudo/app/app_controller.dart';
import 'package:clash_pseudo/app/app_theme.dart';
import 'package:clash_pseudo/features/overview/traffic_controller.dart';
import 'package:clash_pseudo/features/overview/traffic_window.dart';
import 'package:clash_pseudo/features/overview/widgets/traffic_panel.dart';
import 'package:clash_pseudo/features/strategies/strategy_snapshot.dart';
import 'package:clash_pseudo/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const core = CoreSnapshot(
  generation: 7,
  phase: 'READY',
  purpose: 'VPN',
  configId: 'one',
  revision: 1,
);
TrafficSnapshot data({int now = 1000, int generation = 7}) =>
    TrafficSnapshot.fromMap({
      'generation': generation,
      'configId': 'one',
      'revision': 1,
      'sessionGeneration': 1,
      'phase': 'RUNNING',
      'fresh': true,
      'failed': false,
      'elapsedMs': now,
      'sampledAt': now,
      'upload': 0,
      'download': 2048,
      'activeCount': 2000,
      'points': [
        {'elapsedMs': now - 1000, 'upload': 0, 'download': 1024},
        {'elapsedMs': now, 'upload': 0, 'download': 2048},
      ],
    });

class TrafficBridge extends AppBridge {
  int reads = 0;
  Completer<TrafficSnapshot>? pending;
  TrafficSnapshot value = data();
  bool fail = false;
  @override
  Future<TrafficSnapshot> traffic() {
    reads++;
    if (fail) return Future.error(StateError('failed'));
    return pending?.future ?? Future.value(value);
  }
}

class TrafficApp extends AppController {
  TrafficApp(super.platform) {
    loading = false;
    configsLoaded = true;
    state = const AppSnapshot(phase: 'RUNNING', generation: 1, core: core);
  }
  @override
  Future<void> refresh() async {}
  void changed() => notifyListeners();
}

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

void main() {
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

  for (final dark in [false, true]) {
    testWidgets(
      'panel real data, wide touch targets and reduced motion ($dark)',
      (tester) async {
        final bridge = TrafficBridge();
        final app = TrafficApp(bridge);
        var opens = 0;
        Widget show({
          bool visible = true,
          bool reduced = false,
          double scale = 1,
        }) => MaterialApp(
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
                    app: app,
                    visible: visible,
                    width: 320,
                    onOpen: () => opens++,
                  ),
                ),
              ),
            ),
          ),
        );
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(show());
        await tester.pump();
        expect(
          tester.getSemantics(find.bySemanticsLabel('下载 2.00 KiB/s，查看连接')),
          matchesSemantics(
            label: '下载 2.00 KiB/s，查看连接',
            isButton: true,
            hasTapAction: true,
          ),
        );
        semantics.dispose();
        expect(find.text('2000 个活跃连接'), findsOneWidget);
        expect(find.text('2.00'), findsOneWidget);
        expect(find.text('KiB/s'), findsOneWidget);
        expect(find.text('0'), findsOneWidget);
        expect(tester.hasRunningAnimations, isTrue);
        for (final label in ['下载', '上传', '查看连接']) {
          await tester.tap(find.text(label));
          await tester.pump();
        }
        expect(opens, 3);
        expect(
          tester.getSize(find.widgetWithText(TextButton, '查看连接')).height,
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
        app.dispose();
      },
    );
  }
}
