import 'dart:ui' as ui;

import 'package:clash_pseudo/src/features/overview/traffic_window.dart';
import 'package:clash_pseudo/src/features/overview/widgets/traffic_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const size = Size(200, 64);
TrafficPlot plot(
  List<TrafficPoint> points, {
  bool upload = false,
  int now = 0,
}) => TrafficPlot(points, now, upload);

Future<List<int>> pixels(TrafficFrame frame, bool upload) async {
  final recorder = ui.PictureRecorder();
  TrafficPainter(frame, Colors.blue, upload).paint(Canvas(recorder), size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(200, 64);
  final bytes = (await image.toByteData())!.buffer.asUint8List().toList();
  image.dispose();
  picture.dispose();
  return bytes;
}

void main() {
  const points = [TrafficPoint(1000, 100, 100), TrafficPoint(2000, 50, 50)];
  test('latest sample stays at right edge regardless of query age', () {
    for (final now in [2000, 2100, 2900, 7001]) {
      final value = plot(points, now: now);
      expect(value.endpoint(size)!.dx, 190);
      expect(value.positions(size).first!.dx, closeTo(184, 0.001));
    }
  });

  test('history, scale and new tail share continuous geometry', () {
    final old = TrafficFrame.fromPlot(plot(points), size);
    final next = TrafficFrame.fromPlot(
      plot([...points, const TrafficPoint(3000, 200, 200)]),
      size,
      previous: old,
      keepDeparting: true,
    );
    final start = TrafficFrame.lerp(old, next, 0);
    for (var i = 0; i < old.vertices.length; i++) {
      expect(start.vertices[i], old.vertices[i]);
    }
    expect(start.endpoint, old.endpoint);
    final middle = TrafficFrame.lerp(old, next, 0.5);
    for (var i = 0; i < old.vertices.length; i++) {
      expect(
        middle.vertices[i].position,
        Offset.lerp(old.vertices[i].position, next.vertices[i].position, 0.5),
      );
    }
    expect(middle.endpoint!.dx, 190);
    expect(middle.endpoint!.dy, inExclusiveRange(10, 32));
    expect(
      middle.vertices.first.position!.dx,
      closeTo(old.vertices.first.position!.dx - 3, 0.001),
    );
  });

  test(
    'dash phase survives repeated left clipping and bounded frame eviction',
    () {
      var frame = TrafficFrame.fromPlot(
        plot(const [TrafficPoint(0, 0, 0)]),
        size,
      );
      for (var end = 1; end <= 120; end++) {
        final times = [for (var i = (end - 30).clamp(0, end); i <= end; i++) i];
        final next = TrafficFrame.fromPlot(
          plot([for (final i in times) TrafficPoint(i * 1000, 0, 0)]),
          size,
          previous: frame,
          keepDeparting: true,
        );
        final overlap = {for (final v in frame.vertices) v.time: v};
        for (final vertex in next.vertices) {
          if (overlap.containsKey(vertex.time)) {
            expect(vertex.phase, closeTo(overlap[vertex.time]!.phase, 0.00001));
          }
        }
        final mid = TrafficFrame.lerp(frame, next, 0.5);
        expect(mid.endpoint!.dx, 190);
        expect(next.vertices.length, lessThanOrEqualTo(62));
        frame = next;
      }
      final cropped = TrafficFrame.fromPlot(
        plot([for (var i = 100; i <= 120; i++) TrafficPoint(i * 1000, 0, 0)]),
        size,
        previous: frame,
      );
      for (final v in cropped.vertices) {
        expect(
          v.phase,
          frame.vertices.singleWhere((old) => old.time == v.time).phase,
        );
      }
    },
  );

  test('departing maximum rescales surviving history without a jump', () {
    final old = TrafficFrame.fromPlot(
      plot(const [TrafficPoint(0, 1000, 1000), TrafficPoint(30000, 100, 100)]),
      size,
    );
    final next = TrafficFrame.fromPlot(
      plot(const [TrafficPoint(30000, 100, 100), TrafficPoint(31000, 50, 50)]),
      size,
      previous: old,
      keepDeparting: true,
    );
    final start = TrafficFrame.lerp(old, next, 0);
    expect(start.vertices[1].position, old.vertices[1].position);
    final middle = TrafficFrame.lerp(old, next, 0.5);
    expect(middle.vertices[1].position!.dx, closeTo(187, 0.001));
    expect(middle.vertices[1].position!.dy, closeTo(29.8, 0.001));
    expect(next.vertices.first.position!.dx, lessThan(10));
    expect(next.vertices[1].position!.dy, 10);
  });

  test('dashes never bridge a missing sample', () {
    final frame = TrafficFrame.fromPlot(
      plot(const [
        TrafficPoint(0, 0, 0),
        TrafficPoint(1000, 100, 100),
        TrafficPoint(2000, null, null),
        TrafficPoint(3000, 50, 50),
        TrafficPoint(4000, 0, 0),
      ]),
      size,
    );
    final gapLeft = frame.vertices[1].position!.dx;
    final gapRight = frame.vertices[3].position!.dx;
    for (final (a, b) in frame.dashes()) {
      expect(b.dx <= gapLeft || a.dx >= gapRight, isTrue);
    }
  });

  for (final upload in [false, true]) {
    test(
      'incoming sample and cropping do not flash pixels ($upload)',
      () async {
        final values = [
          for (var i = 0; i <= 30; i++)
            TrafficPoint(i * 1000, (i % 4) * 100.0, (i % 4) * 100.0),
        ];
        final old = TrafficFrame.fromPlot(plot(values, upload: upload), size);
        final next = TrafficFrame.fromPlot(
          plot([
            ...values.skip(1),
            const TrafficPoint(31000, 500, 500),
          ], upload: upload),
          size,
          previous: old,
          keepDeparting: true,
        );
        expect(
          await pixels(TrafficFrame.lerp(old, next, 0), upload),
          await pixels(old, upload),
        );
        final halfway = TrafficFrame.lerp(old, next, 0.5);
        final retarget = TrafficFrame.fromPlot(
          plot([
            ...values.skip(2),
            const TrafficPoint(31000, 500, 500),
            const TrafficPoint(32000, 0, 0),
          ], upload: upload),
          size,
          previous: halfway,
          keepDeparting: true,
        );
        expect(
          await pixels(TrafficFrame.lerp(halfway, retarget, 0), upload),
          await pixels(halfway, upload),
        );
      },
    );

    testWidgets('continuous updates, interruption and lifecycle ($upload)', (
      tester,
    ) async {
      Widget chart(
        List<TrafficPoint> values, {
        bool animate = true,
        int id = 1,
      }) => MaterialApp(
        home: Center(
          child: SizedBox.fromSize(
            size: size,
            child: TrafficChart(
              key: ValueKey(id),
              plot: plot(values, upload: upload),
              size: size,
              color: Colors.blue,
              wave: const AlwaysStoppedAnimation(0.5),
              animate: animate,
            ),
          ),
        ),
      );
      TrafficFrame frame() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<TrafficPainter>()
          .single
          .frame;
      Offset dot() {
        final positioned = tester
            .widgetList<Positioned>(find.byType(Positioned))
            .singleWhere((p) => p.width == 20 && p.height == 20);
        return Offset(positioned.left! + 10, positioned.top! + 10);
      }

      const high = [TrafficPoint(1000, 100, 100), TrafficPoint(2000, 100, 100)];
      const low = [...high, TrafficPoint(3000, 0, 0)];
      await tester.pumpWidget(chart(high));
      expect(tester.hasRunningAnimations, isFalse);
      final initial = frame();
      await tester.pumpWidget(chart(low));
      expect(dot(), const Offset(190, 10));
      for (var i = 1; i <= 3; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          frame().vertices.first.position!.dx,
          closeTo(initial.vertices.first.position!.dx - i * 1.5, 0.001),
        );
        expect(dot().dy, closeTo(10 + i * 11, 0.001));
        expect(dot(), frame().endpoint);
      }
      final interrupted = frame();
      const next = [...low, TrafficPoint(4000, 200, 200)];
      await tester.pumpWidget(chart(next));
      for (var i = 0; i < interrupted.vertices.length; i++) {
        expect(frame().vertices[i], interrupted.vertices[i]);
      }
      expect(dot(), interrupted.endpoint);
      await tester.pump(const Duration(milliseconds: 500));
      final pending = frame();
      // Retain the current transition when the same sample is read again.
      await tester.pumpWidget(chart(next));
      expect(frame().endpoint, pending.endpoint);
      await tester.pump(const Duration(milliseconds: 500));
      expect(dot(), const Offset(190, 10));
      await tester.pump(const Duration(milliseconds: 1));
      expect(tester.hasRunningAnimations, isFalse);

      await tester.pumpWidget(chart([...next, const TrafficPoint(5000, 0, 0)]));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(
        chart([...next, const TrafficPoint(5000, 0, 0)], animate: false),
      );
      expect(dot(), const Offset(190, 54));
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpWidget(chart(high, id: 2));
      expect(dot(), const Offset(190, 10));
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpWidget(
        chart([
          ...high,
          const TrafficPoint(3000, null, null),
          const TrafficPoint(4000, 0, 0),
        ], id: 2),
      );
      expect(dot(), const Offset(190, 54));
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpWidget(chart(const [], id: 2));
      expect(frame().endpoint, isNull);
      await tester.pumpWidget(const SizedBox());
      expect(tester.hasRunningAnimations, isFalse);
    });
  }
}
