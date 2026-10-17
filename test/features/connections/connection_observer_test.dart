import 'dart:async';

import 'package:clash_pseudo/features/connections/connection_observer.dart';
import 'package:clash_pseudo/features/connections/connection_window.dart';
import 'package:clash_pseudo/features/strategies/strategy_snapshot.dart';
import 'package:clash_pseudo/platform/app_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import 'connection_window_test.dart' as fixtures;

class ObservationBridge extends AppBridge {
  int now = 0;
  int session = 1;
  int reads = 0;
  bool running = true;
  bool fail = false;
  final retained = <bool>[];
  final requests = <Map<String, Object?>>[];
  Completer<Map<String, dynamic>>? pending;

  Map<String, dynamic> get state => {
    'phase': running ? 'RUNNING' : 'STOPPED',
    'generation': session,
    'elapsedMs': now,
    'mode': 'rule',
    'core': {
      'generation': 7,
      'phase': running ? 'READY' : 'EMPTY',
      'purpose': running ? 'VPN' : null,
      'configId': 'one',
      'revision': 1,
    },
  };

  @override
  Future<Map<String, dynamic>> runtimeState() async => state;

  @override
  Future<void> retainObservation(bool value) async {
    retained.add(value);
  }

  @override
  Future<Map<String, dynamic>> sampleConnections(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) async {
    reads++;
    requests.add(query);
    if (fail) throw StateError('unavailable');
    return pending?.future ??
        {
          ...fixtures.sample(
            [fixtures.row('a', upload: now, download: now * 2)],
            now,
            presence: {
              for (final id in query['previousActiveIds'] as List<String>)
                id: true,
            },
          ),
          'uploadTotal': now * 10,
          'downloadTotal': now * 20,
          'activeCount': 2000,
        };
  }
}

void main() {
  testWidgets(
    'traffic shares sampling, preserves detail and resets at new session',
    (tester) async {
      final bridge = ObservationBridge();
      final observer = ConnectionObserver(bridge);
      observer.updateState(bridge.state);
      await tester.pump(Duration.zero);
      observer.window.pinDetail('a');
      for (var i = 1; i <= 35; i++) {
        bridge.now = i * 1000;
        await tester.pump(const Duration(seconds: 1));
      }
      final value = observer.trafficSnapshot(bridge.state);
      expect(value['upload'], 10000);
      expect(value['download'], 20000);
      expect(value['activeCount'], 2000);
      expect((value['points'] as List).length, 31);
      expect(value.containsKey('connections'), isFalse);
      expect(observer.window.parameters['detailId'], 'a');
      expect(bridge.reads, 36);
      observer.trafficSnapshot(bridge.state);
      expect(bridge.reads, 36);
      bridge.running = false;
      observer.updateState(bridge.state);
      expect(observer.trafficSnapshot(bridge.state)['points'], isEmpty);
      expect(observer.retained, isTrue);
      bridge.running = true;
      bridge.session++;
      bridge.now += 1000;
      observer.updateState(bridge.state);
      await tester.pump();
      expect(observer.trafficSnapshot(bridge.state)['upload'], isNull);
      observer.dispose();
    },
  );

  testWidgets(
    'observation continues without a UI and stops native reads at stop',
    (tester) async {
      final bridge = ObservationBridge();
      final observer = ConnectionObserver(bridge);
      observer.updateState(bridge.state);
      await tester.pump(Duration.zero);
      expect(bridge.reads, 1);
      expect(bridge.retained, [true]);
      bridge.now = 1000;
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.reads, 2);
      expect(observer.window.records.single.downloadSpeed, 2000);
      bridge.running = false;
      observer.updateState(bridge.state);
      expect(observer.window.records.single.active, isFalse);
      bridge.now += ConnectionWindow.retentionMs;
      await tester.pump(const Duration(minutes: 15));
      expect(bridge.reads, 2);
      expect(observer.retained, isFalse);
      expect(bridge.retained, [true, false]);
      observer.dispose();
    },
  );

  testWidgets('stopped icon history is cleared when session identity changes', (
    tester,
  ) async {
    final bridge = ObservationBridge()
      ..pending = Completer<Map<String, dynamic>>();
    final observer = ConnectionObserver(bridge);
    observer.updateState(bridge.state);
    await tester.pump(Duration.zero);
    bridge.pending!.complete(
      fixtures.sample([
        {
          ...fixtures.row('a'),
          'strategy': {
            'type': 'fallback',
            'icon': 'https://fixture.test/old.svg',
          },
        },
      ], 0),
    );
    bridge.pending = null;
    await tester.pump();
    observer.window.pinDetail('a');
    bridge.running = false;
    observer.updateState(bridge.state);
    expect(
      observer.window.records.single.strategyIcon,
      'https://fixture.test/old.svg',
    );
    expect(observer.window.detail!.strategyType, 'fallback');
    bridge.running = true;
    bridge.session++;
    observer.updateState(bridge.state);
    await tester.pump(Duration.zero);
    expect(observer.window.records.single.id, 'a');
    expect(observer.window.records.single.strategyIcon, isEmpty);
    expect(observer.window.detail, isNull);
    observer.dispose();
  });

  testWidgets('one sample in flight and no catch-up queue', (tester) async {
    final bridge = ObservationBridge()
      ..pending = Completer<Map<String, dynamic>>();
    final observer = ConnectionObserver(bridge);
    observer.updateState(bridge.state);
    await tester.pump(Duration.zero);
    bridge.now = 3000;
    await tester.pump(const Duration(seconds: 3));
    expect(bridge.reads, 1);
    bridge.pending!.complete(fixtures.sample([fixtures.row('a')], 3000));
    bridge.pending = null;
    await tester.pump(Duration.zero);
    expect(bridge.reads, 1);
    bridge.now = 4000;
    await tester.pump(const Duration(seconds: 1));
    expect(bridge.reads, 2);
    observer.dispose();
  });

  testWidgets('late old-session sample cannot repopulate cleared records', (
    tester,
  ) async {
    final bridge = ObservationBridge()
      ..pending = Completer<Map<String, dynamic>>();
    final observer = ConnectionObserver(bridge);
    observer.updateState(bridge.state);
    await tester.pump(Duration.zero);
    bridge.running = false;
    observer.updateState(bridge.state);
    bridge.pending!.complete(fixtures.sample([fixtures.row('old')], 1000));
    bridge.pending = null;
    await tester.pump(Duration.zero);
    expect(observer.window.records, isEmpty);
    bridge.running = true;
    bridge.session++;
    bridge.now = 2000;
    observer.updateState(bridge.state);
    await tester.pump(Duration.zero);
    expect(observer.window.records.single.id, 'a');
    expect(observer.window.records.single.downloadSpeed, isNull);
    observer.dispose();
  });

  testWidgets(
    'failure preserves presence but invalidates speed and freshness',
    (tester) async {
      final bridge = ObservationBridge();
      final observer = ConnectionObserver(bridge);
      observer.updateState(bridge.state);
      await tester.pump(Duration.zero);
      bridge.fail = true;
      bridge.now = 1000;
      await tester.pump(const Duration(seconds: 1));
      final snapshot = observer.snapshot(bridge.state, null);
      expect(snapshot['fresh'], isFalse);
      expect(snapshot['failed'], isTrue);
      expect(observer.window.records.single.active, isTrue);
      expect(observer.window.records.single.downloadSpeed, isNull);
      bridge.fail = false;
      bridge.now = 2000;
      await tester.pump(const Duration(seconds: 1));
      expect(observer.window.records.single.downloadSpeed, isNull);
      bridge.now = 3000;
      await tester.pump(const Duration(seconds: 1));
      expect(observer.window.records.single.downloadSpeed, 2000);
      observer.dispose();
    },
  );

  testWidgets(
    'acknowledged close invalidates earlier sample and clears speed',
    (tester) async {
      final bridge = ObservationBridge();
      final observer = ConnectionObserver(bridge);
      observer.updateState(bridge.state);
      await tester.pump(Duration.zero);
      bridge.pending = Completer<Map<String, dynamic>>();
      bridge.now = 1000;
      await tester.pump(const Duration(seconds: 1));
      observer.closed(fixtures.core, 'a');
      expect(observer.window.records.single.active, isFalse);
      bridge.running = false;
      observer.updateState(bridge.state);
      bridge.pending!.complete(
        fixtures.sample([fixtures.row('a')], 1000, presence: {'a': true}),
      );
      bridge.pending = null;
      await tester.pump(Duration.zero);
      expect(observer.window.records.single.active, isFalse);
      observer.dispose();
    },
  );
}
