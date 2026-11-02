import 'package:clash_pseudo/src/model/connection_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('raw records retain unknown explicit values through observation and transfer', () {
    final raw = <String, dynamic>{
      'id': 'explicit-values',
      'upload': 0,
      'download': 0,
      'ruleSuggestions': null,
      'future': {
        'false': false,
        'zero': 0,
        'null': null,
        'list': <Object?>[],
        'map': <String, Object?>{},
        'nested': [false, 0, null, <String, Object?>{}],
      },
    };
    final record = ConnectionRecord.fromMap(raw);
    final transferred = ConnectionRecord.fromMap(
      record.observed(active: false).toMap(),
    );
    expect(transferred.raw, raw);
    expect(transferred.upload, 0);
    expect(transferred.download, 0);
    expect(transferred.rawBytes, record.rawBytes);
    expect(
      () => (transferred.raw['future'] as Map)['zero'] = 1,
      throwsUnsupportedError,
    );
    expect(
      () =>
          ((transferred.raw['future'] as Map)['nested'] as List).add('changed'),
      throwsUnsupportedError,
    );
  });

  test(
    'observation copies reuse immutable fields without mutating frozen rows',
    () {
      final source = ConnectionRecord.fromMap({
        'id': 'one',
        'start': '2026-10-16T10:00:00.123456+05:30',
        'upload': 100,
        'download': 200,
        'chains': ['节点🌐', '出口'],
        'rule': 'Domain',
        'rulePayload': 'fixture.test',
        'futureField': {'original': '完整反馈🌐'},
        'metadata': {
          'host': 'fixture.test',
          'destinationIP': '192.0.2.1',
          'destinationPort': 443,
          'sourceIP': '192.0.2.2',
          'sourcePort': 1234,
          'network': 'TCP',
          'type': 'Tun',
        },
      });
      final at = DateTime.fromMillisecondsSinceEpoch(1000);
      final observed = source.observed(
        active: true,
        at: at,
        uploadSpeed: 0,
        downloadSpeed: 20,
      );
      expect(identical(source.start, observed.start), isTrue);
      expect(identical(source.chains, observed.chains), isTrue);
      expect(() => observed.chains.add('changed'), throwsUnsupportedError);
      expect(source.uploadSpeed, isNull);
      expect(source.observedAt, isNull);
      final transferred = ConnectionRecord.fromMap(observed.toMap());
      expect(transferred.start, source.start);
      expect(transferred.start!.microsecond, 456);
      expect(transferred.start!.isUtc, isFalse);
      expect(observed.raw['start'], '2026-10-16T10:00:00.123456+05:30');
      expect(transferred.raw, source.raw);
      expect(transferred.toMap(), observed.toMap());
      expect(observed.toMap()['observation'], {
        'active': true,
        'observedAt': 1000,
        'uploadSpeed': 0.0,
        'downloadSpeed': 20.0,
      });
      final ended = observed.observed(active: false);
      expect(ended.active, isFalse);
      expect(ended.observedAt, at);
      expect(ended.uploadSpeed, isNull);
      expect(ended.downloadSpeed, isNull);
      expect(observed.active, isTrue);
      expect(observed.downloadSpeed, 20);
    },
  );

  for (final suggestions in <Object>[
    'original unknown helper value',
    {'connectionId': 'not-a-uuid'},
    {
      'connectionId': '11111111-1111-4111-8111-111111111111',
      'host': 'fixture.test',
    },
  ]) {
    test(
      'invalid rule diagnostics do not discard original data: $suggestions',
      () {
        final raw = {
          'id': 'one',
          'ruleSuggestions': suggestions,
          'futureField': {
            'original': 'https://user:pass@fixture.test/?token=原文',
          },
          'chains': List.generate(100, (index) => '节点$index'),
        };
        final record = ConnectionRecord.fromMap(raw);
        expect(record.raw, raw);
        expect(record.ruleMetadata, isNull);
        expect(record.ruleError, isNotEmpty);
        final observed = record.observed(active: false);
        expect(observed.raw, same(record.raw));
        expect(observed.ruleError, record.ruleError);
        final transferred = ConnectionRecord.fromMap(observed.toMap());
        expect(transferred.raw, raw);
        expect(transferred.ruleError, record.ruleError);
        expect(transferred.active, isFalse);
        final snapshot = ConnectionSnapshot.fromMap({
          'generation': 1,
          'configId': 'fixture',
          'revision': 1,
          'connections': [
            raw,
            {'id': 'two'},
          ],
        });
        expect(snapshot.records.map((row) => row.id), ['one', 'two']);
        expect(snapshot.records.first.raw, raw);
      },
    );
  }

  test('rule diagnostics retain distinct original blocks across repeated transfers', () {
    const original =
        'native rule failure\nCaused by: original cause\n'
        'Suppressed: original cleanup\nSuppressed: original cleanup';
    final raw = <String, dynamic>{
      'id': 'one',
      'ruleError': original,
      'ruleSuggestions': 'invalid helper',
    };
    final record = ConnectionRecord.fromMap(raw);
    final diagnostic = record.ruleError!;
    expect(
      diagnostic,
      '$original\nFormatException: Invalid connection rule source',
    );
    var transferred = record;
    for (var index = 0; index < 3; index++) {
      transferred = ConnectionRecord.fromMap(transferred.toMap());
      expect(transferred.raw, raw);
      expect(transferred.ruleError, diagnostic);
      expect(transferred.ruleMetadata, isNull);
    }
  });

  test('direct observation copies keep rate validation and missing fields', () {
    final source = ConnectionRecord.fromMap({'id': 'empty'});
    final copy = source.observed(
      active: true,
      uploadSpeed: double.infinity,
      downloadSpeed: -1,
    );
    expect(copy.toMap(), source.toMap());
    expect(
      source.observed(active: false, uploadSpeed: double.nan).uploadSpeed,
      isNull,
    );
  });
}
