import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:clash_pseudo/src/logic/connections/connection_window.dart';
import 'package:clash_pseudo/src/model/application_contract.dart';

import '../support/core_runtime_fixture.dart';

import '../../benchmark/connections.dart' as benchmark;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final count in [50, 500, 1000]) {
    test(
      'CoreRuntime projects $count connections with 20 warmups, 30 measurements, and one confirmation for 51 actual reads',
      () async {
        final fixture = await CoreRuntimeFixture.create();
        addTearDown(fixture.dispose);
        await fixture.warmUp();
        final window = ConnectionWindow();
        final ids = [
          for (var i = 1; i <= count; i++)
            '${i.toRadixString(16).padLeft(8, '0')}-0000-4000-8000-000000000000',
        ];
        final rows = [
          for (final id in ids)
            {
              'id': id,
              'start': '2026-10-16T10:00:00Z',
              'upload': 100,
              'download': 200,
              'chains': ['节点🌐', 'DIRECT'],
              'metadata': {
                'host': 'fixture.test',
                'network': 'TCP',
                'type': 'Tun',
              },
              'strategy': {
                'type': 'select',
                'icon': 'https://fixture.test/icon.svg',
              },
            },
        ];
        final times = <int>[];
        for (var index = 0; index < 51; index++) {
          fixture.script(ApplicationContract.coreOperationConnections, (
            request,
          ) {
            final previous = (request.arguments['previousActiveIds'] as List)
                .cast<String>();
            expect(request.arguments['limit'], count);
            expect(previous, ids);
            request.complete({
              'complete': true,
              'connections': rows,
              'presence': {for (final id in previous) id: true},
              'limited': false,
              'activeCount': count,
              'uploadTotal': 9000000,
              'downloadTotal': 0,
              'sessionUploadBytes': 100,
              'sessionDownloadBytes': 200,
            });
          });
          fixture.now = 100 + index * 1000;
          final query = {
            ...window.parameters,
            'limit': count,
            'previousActiveIds': ids,
          };
          final timing = Stopwatch()..start();
          final result = await fixture.operation.sampleConnections(
            fixture.core,
            query,
          );
          timing.stop();
          if (index >= 20 && index < 50) times.add(timing.elapsedMicroseconds);
          expect(result['complete'], isTrue);
          expect(result['processId'], fixture.core.processId);
          expect(result['inputId'], fixture.core.inputId);
          expect(result['generation'], fixture.core.generation);
          expect(result['configId'], 'one');
          expect(result['revision'], 1);
          expect(result['composition'], fixture.core.composition);
          expect(result['purpose'], 'RUNNING');
          expect(result['elapsedMs'], fixture.now);
          expect(result['observedAt'], greaterThan(0));
          expect(result['presence'], hasLength(count));
          expect(result['sessionUploadBytes'], 100);
          expect(result['sessionDownloadBytes'], 200);
          window.accept(result, fixture.core, query);
          expect(window.records, hasLength(count));
          expect(window.records.every((record) => record.active), isTrue);
          expect(window.records.first.chains, ['节点🌐', 'DIRECT']);
          expect(window.records.first.strategyType, 'select');
          expect(
            window.records.first.strategyIcon,
            'https://fixture.test/icon.svg',
          );
        }
        expect(
          fixture.calls(ApplicationContract.coreOperationConnections),
          hasLength(51),
        );
        expect(window.records, hasLength(count));
        expect(fixture.exits, isEmpty);
        times.sort();
        expect(times, hasLength(30));
        stdout.writeln(
          'ConnectionBenchmark scope=CoreRuntime-FD-fixture rows=$count '
          'bytes=${utf8.encode(jsonEncode(rows)).length} medianUs=${times[15]} p90Us=${times[27]}',
        );
      },
    );
  }

  test(
    'connection benchmark exercises production window operations',
    () => benchmark.runConnectionBenchmark(timing: false),
  );
}
