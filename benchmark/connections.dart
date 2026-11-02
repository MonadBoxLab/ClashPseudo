import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/model/connection_snapshot.dart';
import 'package:clash_pseudo/src/logic/connections/connection_window.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

// Host algorithm benchmark for local timing and allocation metrics.
void main() => runConnectionBenchmark();

void runConnectionBenchmark({bool timing = true}) {
  const core = CoreSnapshot(
    generation: 1,
    phase: 'READY',
    purpose: 'RUNNING',
    configId: 'benchmark',
    revision: 1,
    composition: 'benchmark-composition',
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
      int time, {
      ConnectionWindow? target,
    }) => {
      'generation': 1,
      'configId': 'benchmark',
      'revision': 1,
      'composition': core.composition,
      'purpose': core.purpose,
      'complete': true,
      'elapsedMs': time,
      'observedAt': 1792144800000 + time,
      'connections': values,
      'presence': {
        for (final id
            in (target ?? window).parameters['previousActiveIds']
                as List<String>)
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
    void measure(
      String name,
      void Function(int) run, {
      void Function()? prepare,
      void Function()? verify,
    }) {
      if (!timing) {
        prepare?.call();
        run(0);
        verify?.call();
        return;
      }
      for (var i = 0; i < 20; i++) {
        prepare?.call();
        run(i);
        verify?.call();
      }
      final times = <int>[];
      for (var trial = 0; trial < 5; trial++) {
        final watch = Stopwatch();
        for (var i = 0; i < 100; i++) {
          prepare?.call();
          watch.start();
          run(i);
          watch.stop();
          verify?.call();
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
    late ConnectionWindow pruning;
    measure(
      'prune-500-expired',
      (_) => pruning.prune(1000 + ConnectionWindow.retentionMs),
      prepare: () {
        pruning = ConnectionWindow();
        pruning.accept(
          sample(List.generate(500, (i) => row(1000 + i)), 0, target: pruning),
          core,
          {'previousActiveIds': <String>[]},
        );
        pruning.accept(
          sample(rows, 1000, target: pruning),
          core,
          pruning.parameters,
        );
        final before = pruning.records;
        if (before.length != 1500 ||
            before.where((row) => !row.active).length != 500) {
          throw StateError(
            'Prune benchmark must begin with 500 inactive records',
          );
        }
      },
      verify: () {
        final after = pruning.records;
        if (after.length != 1000 || after.any((row) => !row.active)) {
          throw StateError(
            'Prune benchmark did not expire exactly 500 records',
          );
        }
        checksum += after.length;
      },
    );
    measure('snapshot-roundtrip', (_) {
      final snapshot = ConnectionSnapshot.fromMap({
        'generation': 1,
        'configId': 'benchmark',
        'revision': 1,
        'composition': core.composition,
        'purpose': core.purpose,
        'connections': [for (final row in window.records) row.toMap()],
      });
      checksum += snapshot.records.length;
    });
    if (window.records.length != 1500 || checksum == 0) {
      throw StateError('Benchmark fixture changed');
    }
  }
}
