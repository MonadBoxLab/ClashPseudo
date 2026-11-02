import 'package:clash_pseudo/src/logic/connections/traffic_window.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clash_pseudo/src/model/traffic_snapshot.dart';

Map<String, dynamic> sample(
  int time,
  Object? up,
  Object? down, {
  Object? count = 12,
}) => {
  'elapsedMs': time,
  'uploadTotal': up,
  'downloadTotal': down,
  'activeCount': count,
};

TrafficSnapshot snapshot(TrafficWindow window, int now, {bool fresh = true}) =>
    TrafficSnapshot.fromMap({
      'phase': 'RUNNING',
      'generation': 1,
      'sessionGeneration': 2,
      'configId': 'test',
      'revision': 1,
      'failed': false,
      ...window.snapshot(now, fresh: fresh),
    }).at(now);

void main() {
  test('native session totals include first-sample bytes and never use visible rows', () {
    final window = TrafficWindow()
      ..accept({
        ...sample(1000, 9000000, 17000000),
        'sessionUploadBytes': 4500,
        'sessionDownloadBytes': 8800,
        'connections': const [],
      });
    var value = snapshot(window, 1000);
    expect(value.sessionUploadBytes, 4500);
    expect(value.sessionDownloadBytes, 8800);
    expect(value.upload, isNull);
    window.accept({
      ...sample(2000, 9000100, 17000200, count: 0),
      'sessionUploadBytes': 4600,
      'sessionDownloadBytes': 9000,
    });
    value = snapshot(window, 2000);
    expect(value.activeCount, 0);
    expect(value.sessionUploadBytes, 4600);
    expect(value.sessionDownloadBytes, 9000);
    expect(value.upload, 100);
    expect(value.at(7001).sessionUploadBytes, isNull);
    expect(value.at(2000, unavailable: true).sessionDownloadBytes, isNull);
    window.invalidate();
    expect(snapshot(window, 2000).sessionUploadBytes, isNull);
    window.accept({
      ...sample(3000, 9000200, 17000300),
      'sessionUploadBytes': 4700,
      'sessionDownloadBytes': 9100,
    });
    expect(snapshot(window, 3000).sessionUploadBytes, 4700);
    window.clear();
    window.accept({
      ...sample(4000, 99999999, 99999999),
      'sessionUploadBytes': 11,
      'sessionDownloadBytes': 12,
    });
    expect(snapshot(window, 4000).sessionUploadBytes, 11);
  });

  test('session totals remain unknown independently for missing or invalid native values', () {
    final window = TrafficWindow();
    for (final invalid in [null, -1, '0', 1.0, double.nan]) {
      window.clear();
      window.accept({
        ...sample(1000, 100, 200),
        'sessionUploadBytes': invalid,
        'sessionDownloadBytes': 0,
      });
      final value = snapshot(window, 1000);
      expect(value.sessionUploadBytes, isNull);
      expect(value.sessionDownloadBytes, 0);
    }
    window.clear();
    window.accept(sample(1000, 99999, 99999));
    expect(snapshot(window, 1000).sessionUploadBytes, isNull);
  });

  test('first global sample has a count but no invented speed', () {
    final window = TrafficWindow()..accept(sample(1000, 9000000, 17000000));
    final value = snapshot(window, 1000);
    expect(value.upload, isNull);
    expect(value.download, isNull);
    expect(value.activeCount, 12);
    expect(value.fresh, isTrue);
  });

  test('actual intervals, zero and independent direction validity', () {
    final window = TrafficWindow()..accept(sample(1000, 100, 200));
    window.accept(sample(2500, 400, 200));
    expect(snapshot(window, 2500).upload, 200);
    expect(snapshot(window, 2500).download, 0);
    window.accept(sample(3500, 1, 800, count: -1));
    final value = snapshot(window, 3500);
    expect(value.upload, isNull);
    expect(value.download, 600);
    expect(value.activeCount, isNull);
    window.accept(sample(4500, 11, null));
    expect(snapshot(window, 4500).upload, 10);
    expect(snapshot(window, 4500).download, isNull);
    window.accept(sample(5500, -1, 900));
    expect(snapshot(window, 5500).upload, isNull);
    expect(snapshot(window, 5500).download, isNull);
  });

  test(
    'failed reads and long gaps restart the baseline and break the plot',
    () {
      final window = TrafficWindow()
        ..accept(sample(0, 0, 0))
        ..accept(sample(1000, 100, 200))
        ..invalidate();
      expect(snapshot(window, 1001).upload, isNull);
      window.accept(sample(2000, 1000, 2000));
      expect(snapshot(window, 2000).points.last.upload, isNull);
      window.accept(sample(3000, 1100, 2100));
      expect(snapshot(window, 3000).upload, 100);
      window.accept(sample(9000, 5000, 5000));
      expect(snapshot(window, 9000).upload, isNull);
    },
  );

  test('repeated or reversed monotonic time is not accepted', () {
    final window = TrafficWindow()
      ..accept(sample(1000, 0, 0))
      ..accept(sample(2000, 100, 200));
    for (final time in [2000, 1500]) {
      window.accept(sample(time, 900, 900));
      expect(snapshot(window, 2000).fresh, isFalse);
      expect(snapshot(window, 2000).points.length, 2);
    }
    window.accept(sample(3000, 1000, 1000));
    expect(snapshot(window, 3000).upload, isNull);
  });

  test('freshness ages without another successful native read', () {
    final window = TrafficWindow()
      ..accept(sample(0, 0, 0))
      ..accept(sample(1000, 100, 200));
    final value = snapshot(window, 1000);
    expect(value.at(6000).fresh, isTrue);
    final expired = value.at(6001);
    expect(expired.fresh, isFalse);
    expect(expired.upload, isNull);
    expect(expired.activeCount, isNull);
    expect(expired.points.length, 2);
    expect(value.at(31001).points, isEmpty);
  });

  test('30-second inclusive boundary and 31-point cap are independent of real active count', () {
    final window = TrafficWindow();
    for (var i = 0; i <= 30; i++) {
      window.accept(sample(i * 1000, i * 100, i * 200, count: 2000));
    }
    final boundary = snapshot(window, 30000);
    expect(boundary.points, hasLength(31));
    expect(boundary.points.first.elapsedMs, 0);
    expect(boundary.activeCount, 2000);
    expect(boundary.at(30001).points, hasLength(30));
    expect(boundary.at(30001).points.first.elapsedMs, 1000);
    expect(boundary.at(60001).points, isEmpty);
    expect(boundary.at(35001).activeCount, isNull);
    window.clear();
    for (var i = 0; i < 100; i++) {
      window.accept(sample(i * 100, i, i * 2, count: 2000));
    }
    final dense = snapshot(window, 9900);
    expect(dense.points, hasLength(31));
    expect(dense.points.first.elapsedMs, 6900);
    expect(dense.activeCount, 2000);
  });

  test('thirty-second window and point limit remain bounded', () {
    final window = TrafficWindow();
    for (var i = 0; i <= 100; i++) {
      window.accept(sample(i * 1000, i * 100, i * 200));
    }
    final value = snapshot(window, 100000);
    expect(value.points.length, 31);
    expect(value.points.first.elapsedMs, 70000);
    expect(snapshot(window, 130001).points, isEmpty);
    window.clear();
    window.accept(sample(140000, 100000, 200000));
    expect(snapshot(window, 140000).upload, isNull);
    expect(snapshot(window, 140000).points.length, 1);
  });

  test(
    'invalid summary fields are independent and legitimate zeros survive',
    () {
      final window = TrafficWindow()
        ..accept(sample(0, '0', 0, count: 0))
        ..accept(sample(1000, 1.0, 0, count: 2000));
      final value = snapshot(window, 1000);
      expect(value.upload, isNull);
      expect(value.download, 0);
      expect(value.activeCount, 2000);
      expect(snapshot(window, 1000, fresh: false).activeCount, isNull);
    },
  );
}
