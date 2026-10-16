import 'package:clash_pseudo/features/connections/connection_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
        'fieldsTruncated': true,
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
      expect(observed.toMap().containsKey('start'), isFalse);
      expect(transferred.toMap(), observed.toMap());
      expect(observed.toMap(), {
        ...source.toMap(),
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
