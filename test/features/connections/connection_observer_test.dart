import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import 'package:clash_pseudo/src/features/connections/connection_observer.dart';
import 'package:clash_pseudo/src/features/connections/connection_snapshot.dart';
import 'package:clash_pseudo/src/features/connections/connection_window.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import 'connection_window_fixtures.dart' as fixtures;

class ObservationBridge extends AppBridge {
  int now = 0;
  int session = 1;
  int reads = 0;
  bool running = true;
  bool fail = false;
  bool trackerActive = true;
  int? sessionUploadBytes = 5000;
  int? sessionDownloadBytes = 9000;
  String composition = 'one';
  String trackerId = 'a';
  Map<String, dynamic>? ruleSuggestions;
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
      'composition': composition,
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
            [
              if (trackerActive)
                {
                  ...fixtures.row(trackerId, upload: now, download: now * 2),
                  'ruleSuggestions': ruleSuggestions,
                },
            ],
            now,
            presence: {
              for (final id in query['previousActiveIds'] as List<String>)
                id: id == trackerId ? trackerActive : true,
              if (query['detailId'] case final String id)
                id: id == trackerId ? trackerActive : true,
            },
          ),
          'uploadTotal': now * 10,
          'downloadTotal': now * 20,
          'activeCount': 2000,
          'sessionUploadBytes': sessionUploadBytes,
          'sessionDownloadBytes': sessionDownloadBytes,
          'composition': composition,
          'purpose': 'VPN',
        };
  }
}

void main() {
  testWidgets(
    'observed rule metadata survives missing candidates, failure and inactivity with its original source',
    (tester) async {
      const id = '00000000-0000-4000-8000-000000000001';
      final bridge = ObservationBridge()
        ..trackerId = id
        ..ruleSuggestions = {
          'connectionId': id,
          'host': 'a.private.github.io',
          'suffixBoundary': 'private.github.io',
          'ipCidr': '192.0.2.1/32',
        };
      final observer = ConnectionObserver(bridge);
      observer.snapshot(bridge.state, null);
      await tester.pump(Duration.zero);
      final trusted = observer.window.records.single.ruleMetadata!;
      expect(trusted.suffixes, ['a.private.github.io', 'private.github.io']);
      expect(trusted.source.composition, 'one');
      bridge.ruleSuggestions = null;
      bridge.now = 1000;
      await tester.pump(const Duration(seconds: 1));
      expect(observer.window.records.single.ruleMetadata, same(trusted));
      bridge.ruleSuggestions = {
        'connectionId': id,
        'host': null,
        'suffixBoundary': null,
        'ipCidr': null,
      };
      bridge.now = 2000;
      await tester.pump(const Duration(seconds: 1));
      expect(observer.window.records.single.ruleMetadata, same(trusted));
      bridge.fail = true;
      bridge.now = 3000;
      await tester.pump(const Duration(seconds: 1));
      expect(observer.snapshot(bridge.state, null)['failed'], isTrue);
      expect(observer.window.records.single.ruleMetadata, same(trusted));
      bridge.fail = false;
      bridge.trackerActive = false;
      bridge.now = 4000;
      await tester.pump(const Duration(seconds: 1));
      expect(observer.window.records.single.active, isFalse);
      final detail = {
        'generation': 7,
        'configId': 'one',
        'revision': 1,
        'composition': 'one',
        'purpose': 'VPN',
        'id': id,
      };
      final value = ConnectionSnapshot.fromMap(
        Map<String, dynamic>.from(observer.snapshot(bridge.state, detail)),
      );
      expect(value.detail!.active, isFalse);
      expect(value.detail!.ruleMetadata!.toMap(), trusted.toMap());
      bridge.composition = 'changed';
      observer.updateState(bridge.state);
      await tester.pump();
      final historical = ConnectionSnapshot.fromMap(
        Map<String, dynamic>.from(observer.snapshot(bridge.state, null)),
      ).records.single.ruleMetadata!;
      expect(historical.source.composition, 'one');
      expect(
        historical.matches(CoreSnapshot.fromMap(bridge.state['core'])),
        isFalse,
      );
      bridge.running = false;
      observer.updateState(bridge.state);
      expect(observer.window.records.single.ruleMetadata, same(trusted));
      bridge.running = true;
      bridge.session++;
      observer.updateState(bridge.state);
      expect(observer.window.records, isEmpty);
      observer.dispose();
    },
  );

  testWidgets(
    'rule helper cannot be attached to a different requested detail or native identity',
    (tester) async {
      const id = '00000000-0000-4000-8000-000000000001';
      const otherId = '00000000-0000-4000-8000-000000000002';
      final bridge = ObservationBridge()
        ..trackerId = id
        ..ruleSuggestions = {
          'connectionId': otherId,
          'host': 'wrong.example',
          'suffixBoundary': 'wrong.example',
          'ipCidr': null,
        };
      final observer = ConnectionObserver(bridge);
      final detail = {
        'generation': 7,
        'configId': 'one',
        'revision': 1,
        'composition': 'one',
        'purpose': 'VPN',
        'id': id,
      };
      observer.snapshot(bridge.state, detail);
      await tester.pump(Duration.zero);
      final result = observer.snapshot(bridge.state, detail);
      expect(result['failed'], isTrue);
      expect(result.containsKey('ruleSuggestions'), isFalse);
      expect(observer.window.records, isEmpty);
      observer.dispose();
    },
  );

  testWidgets(
    'native lease totals survive sampling loss and close, not a new lease or composition',
    (tester) async {
      final bridge = ObservationBridge();
      final observer = ConnectionObserver(bridge)..updateState(bridge.state);
      await tester.pump(Duration.zero);
      var value = observer.trafficSnapshot(bridge.state);
      expect(value['sessionUploadBytes'], 5000);
      expect(value['sessionDownloadBytes'], 9000);
      expect(value['upload'], isNull);
      expect(value['composition'], 'one');
      // Preserve session totals after a visible record closes.
      observer.closed(fixtures.core, 'a');
      expect(
        observer.trafficSnapshot(bridge.state)['sessionUploadBytes'],
        5000,
      );
      bridge.fail = true;
      bridge.now = 1000;
      await tester.pump(const Duration(seconds: 1));
      expect(
        observer.trafficSnapshot(bridge.state)['sessionUploadBytes'],
        isNull,
      );
      bridge.fail = false;
      bridge.sessionUploadBytes = 8000;
      bridge.now = 2000;
      await tester.pump(const Duration(seconds: 1));
      expect(
        observer.trafficSnapshot(bridge.state)['sessionUploadBytes'],
        8000,
      );
      bridge.running = false;
      observer.updateState(bridge.state);
      expect(
        observer.trafficSnapshot(bridge.state)['sessionUploadBytes'],
        isNull,
      );
      bridge.running = true;
      bridge.session++;
      bridge.sessionUploadBytes = 11;
      bridge.sessionDownloadBytes = 12;
      bridge.now = 3000;
      observer.updateState(bridge.state);
      expect(
        observer.trafficSnapshot(bridge.state)['sessionUploadBytes'],
        isNull,
      );
      await tester.pump(Duration.zero);
      expect(observer.trafficSnapshot(bridge.state)['sessionUploadBytes'], 11);
      bridge.composition = 'replacement';
      bridge.now = 4000;
      observer.updateState(bridge.state);
      expect(
        observer.trafficSnapshot(bridge.state)['sessionUploadBytes'],
        isNull,
      );
      await tester.pump(Duration.zero);
      value = observer.trafficSnapshot(bridge.state);
      expect(value['composition'], 'replacement');
      expect(value['sessionUploadBytes'], 11);
      expect(bridge.reads, 5);
      observer.dispose();
    },
  );

  testWidgets('snapshot carries existing sample age without renewing it', (
    tester,
  ) async {
    final bridge = ObservationBridge();
    final observer = ConnectionObserver(bridge);
    expect(observer.snapshot(bridge.state, null)['sampleAgeMs'], isNull);
    await tester.pump(Duration.zero);
    expect(observer.snapshot(bridge.state, null)['sampleAgeMs'], 0);
    bridge.now = 3500;
    final fresh = observer.snapshot(bridge.state, null);
    expect(fresh['sampleAgeMs'], 3500);
    expect(fresh['fresh'], isTrue);
    bridge.now = 5001;
    final stale = observer.snapshot(bridge.state, null);
    expect(stale['sampleAgeMs'], 5001);
    expect(stale['fresh'], isFalse);
    expect(observer.snapshot(bridge.state, null)['sampleAgeMs'], 5001);
    expect(bridge.reads, 1);
    bridge.running = false;
    expect(observer.snapshot(bridge.state, null)['sampleAgeMs'], isNull);
    observer.dispose();
  });

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
