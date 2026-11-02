import 'package:clash_pseudo/src/model/traffic_snapshot.dart';
import 'package:clash_pseudo/src/ui/components/reading/format_bytes.dart';
import 'package:clash_pseudo/src/ui/overview/widgets/traffic_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
