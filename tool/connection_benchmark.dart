import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/features/connections/connection_snapshot.dart';
import 'package:clash_pseudo/features/connections/connection_window.dart';
import 'package:clash_pseudo/features/strategies/strategy_snapshot.dart';

// Local algorithm benchmark, not a substitute for device CPU/heap profiling.
void main() {
  const core = CoreSnapshot(
    generation: 1,
    phase: 'READY',
    purpose: 'VPN',
    configId: 'benchmark',
    revision: 1,
  );
  for (final longFields in [false, true]) {
    Map<String, dynamic> row(int id) => {
      'id': '$id',
      'start': '2026-10-16T10:00:00.123456Z',
      'upload': 100,
      'download': 200,
      'chains': longFields ? List.filled(16, '节点🌐' * 16) : ['DIRECT'],
      'rule': 'Domain',
      'rulePayload': longFields ? '目标🌐' * 50 : 'fixture.test',
      'metadata': {
        'host': longFields ? '目标🌐' * 50 : 'fixture.test',
        'destinationIP': '192.0.2.1',
        'destinationPort': 443,
        'network': 'TCP',
        'type': 'Tun',
      },
    };
    final rows = List.generate(1000, row);
    final window = ConnectionWindow();
    Map<String, dynamic> sample(
      List<Map<String, dynamic>> values,
      int time,
    ) => {
      'generation': 1,
      'configId': 'benchmark',
      'revision': 1,
      'complete': true,
      'elapsedMs': time,
      'observedAt': 1792144800000 + time,
      'connections': values,
      'presence': {
        for (final id in window.parameters['previousActiveIds'] as List<String>)
          id: int.parse(id) < 1000,
      },
    };
    window.accept(sample(List.generate(500, (i) => row(1000 + i)), 0), core, {
      'previousActiveIds': <String>[],
    });
    window.accept(sample(rows, 1000), core, window.parameters);
    final record = window.records.firstWhere((row) => row.active);
    final raw = jsonEncode(sample(rows, 1000));
    var elapsed = 1000;
    var checksum = 0;
    void measure(String name, void Function(int) run) {
      for (var i = 0; i < 20; i++) {
        run(i);
      }
      final times = <int>[];
      for (var trial = 0; trial < 5; trial++) {
        final watch = Stopwatch()..start();
        for (var i = 0; i < 100; i++) {
          run(i);
        }
        times.add(watch.elapsedMicroseconds);
      }
      times.sort();
      stdout.writeln(
        jsonEncode({
          'case': longFields ? 'long-fields' : 'normal',
          'stage': name,
          'iterations': 100,
          'medianUs': times[2],
          'minUs': times.first,
          'maxUs': times.last,
        }),
      );
    }

    measure('observed-1000', (i) {
      for (var n = 0; n < 1000; n++) {
        final copy = record.observed(active: true, downloadSpeed: i.toDouble());
        checksum += copy.chains.length;
      }
    });
    measure('decode', (_) {
      checksum += (jsonDecode(raw) as Map).length;
    });
    measure('merge-1000-active-500-inactive', (i) {
      elapsed += 1000;
      for (final row in rows) {
        row['download'] = elapsed;
      }
      window.accept(sample(rows, elapsed), core, window.parameters);
      checksum += window.records.length;
    });
    measure('prune-500-inactive', (_) => window.prune(elapsed));
    measure('snapshot-roundtrip', (_) {
      final snapshot = ConnectionSnapshot.fromMap({
        'generation': 1,
        'configId': 'benchmark',
        'revision': 1,
        'connections': [for (final row in window.records) row.toMap()],
      });
      checksum += snapshot.records.length;
    });
    if (window.records.length != 1500 || checksum == 0) {
      throw StateError('Benchmark fixture changed');
    }
  }
}
