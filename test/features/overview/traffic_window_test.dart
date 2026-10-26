import 'package:clash_pseudo/src/app/format_bytes.dart';
import 'package:clash_pseudo/src/features/overview/traffic_window.dart';
import 'package:clash_pseudo/src/features/overview/widgets/traffic_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

  test('byte formatting keeps binary units, unknown separate from zero', () {
    expect(formatBytes(null), '—');
    expect(formatBytes(-1), '—');
    expect(formatBytes(0), '0 B');
    expect(formatBytes(1023), '1023 B');
    expect(formatBytes(1024), '1.00 KiB');
    expect(formatBytes(1048576), '1.00 MiB');
    expect(formatBytes(8348509), '7.96 MiB');
    expect(formatBytes(2328878), '2.22 MiB');
    expect(formatBytes(9566363), '9.12 MiB');
    expect(formatBytes(1073741824), '1.00 GiB');
    expect(formatBytes(1099511627776), '1.00 TiB');
    expect(formatBytes(0x7fffffffffffffff), '8.00 EiB');
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

  test(
    'format uses binary units and stable switching without capping data',
    () {
      final format = TrafficRateFormatter();
      expect(format.format(0), (value: '0', unit: 'B/s'));
      expect(format.format(1024), (value: '1.00', unit: 'KiB/s'));
      expect(format.format(0.98 * 1024).unit, 'KiB/s');
      expect(format.format(0.89 * 1024).unit, 'B/s');
      expect(format.format(1024 * 1024).unit, 'MiB/s');
      expect(format.format(0.98 * 1024 * 1024).unit, 'MiB/s');
      expect(format.format(0.89 * 1024 * 1024).unit, 'KiB/s');
      expect(format.format(1099511627776), (value: '1024', unit: 'GiB/s'));
      expect(format.format(0.2), (value: '0.200', unit: 'B/s'));
      expect(format.format(null).value, '—');
      expect(format.format(double.nan).value, '—');
      format.reset();
      expect(format.format(1000).unit, 'B/s');
    },
  );

  test('plot respects time, gaps, independent scales and a zero baseline', () {
    final points = [
      const TrafficPoint(1000, 0, 0),
      const TrafficPoint(2000, 10, 1000),
      const TrafficPoint(3000, null, 500),
      const TrafficPoint(5000, 5, 0),
    ];
    const size = Size(320, 64);
    final up = TrafficPlot(points, 5000, true).positions(size);
    final down = TrafficPlot(points, 5000, false).positions(size);
    expect(up[1]!.dy, down[1]!.dy);
    expect(up[2], isNull);
    expect(down[2], isNotNull);
    expect(up[3]!.dx - up[1]!.dx, closeTo(30, 0.001));
    expect(down.last!.dy, 54);
    expect(
      TrafficPlot([const TrafficPoint(0, 0, 0)], 0, false).endpoint(size),
      const Offset(310, 54),
    );
    expect(TrafficPlot([], 0, false).endpoint(size), isNull);
  });
}
