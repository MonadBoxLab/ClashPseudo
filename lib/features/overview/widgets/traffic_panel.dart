import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/app_controller.dart';
import '../../../app/app_theme.dart';
import '../traffic_controller.dart';
import '../traffic_window.dart';

class TrafficRateFormatter {
  int _unit = 0;
  static const units = ['B/s', 'KiB/s', 'MiB/s', 'GiB/s'];

  void reset() => _unit = 0;

  ({String value, String unit}) format(double? rate) {
    if (rate == null || !rate.isFinite || rate < 0) {
      return (value: '—', unit: '');
    }
    if (rate == 0) {
      reset();
      return (value: '0', unit: units[0]);
    }
    while (_unit < units.length - 1 && rate / math.pow(1024, _unit) >= 1024) {
      _unit++;
    }
    while (_unit > 0 && rate / math.pow(1024, _unit) < 0.9) {
      _unit--;
    }
    final scaled = rate / math.pow(1024, _unit);
    final String value;
    if (scaled >= 1000000 || scaled < 0.000001) {
      value = scaled.toStringAsPrecision(3);
    } else {
      final decimals = (2 - (math.log(scaled) / math.ln10).floor()).clamp(0, 8);
      final rounded = scaled.toStringAsFixed(decimals);
      value =
          _unit < units.length - 1 &&
              scaled < 1024 &&
              double.parse(rounded) >= 1024
          ? '1023'
          : rounded;
    }
    return (value: value, unit: units[_unit]);
  }
}

class TrafficPanel extends StatefulWidget {
  const TrafficPanel({
    super.key,
    required this.app,
    required this.visible,
    required this.width,
    required this.onOpen,
  });
  final double width;
  final AppController app;
  final bool visible;
  final VoidCallback onOpen;

  @override
  State<TrafficPanel> createState() => _TrafficPanelState();
}

class _TrafficPanelState extends State<TrafficPanel>
    with SingleTickerProviderStateMixin {
  late TrafficController _traffic;
  late final AnimationController _wave;
  final _upload = TrafficRateFormatter();
  final _download = TrafficRateFormatter();
  Object? _identity;

  @override
  void initState() {
    super.initState();
    _wave = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    _traffic = TrafficController(widget.app)..addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _traffic.setVisible(widget.visible);
    _motion();
  }

  @override
  void didUpdateWidget(TrafficPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app != widget.app) {
      _traffic.removeListener(_changed);
      _traffic.dispose();
      _traffic = TrafficController(widget.app)..addListener(_changed);
    }
    _traffic.setVisible(widget.visible);
    _motion();
  }

  void _changed() {
    if (!mounted) return;
    _motion();
    setState(() {});
  }

  void _motion() {
    final data = _traffic.data;
    final animate =
        widget.visible &&
        _traffic.active &&
        data?.fresh == true &&
        (data?.upload != null || data?.download != null) &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (animate) {
      if (!_wave.isAnimating) _wave.repeat();
    } else {
      _wave.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _traffic.data;
    final core = widget.app.state.core;
    final identity = (
      widget.app.state.generation,
      core.generation,
      core.configId,
      core.revision,
      _traffic.available,
    );
    if (_identity != identity) {
      _identity = identity;
      _upload.reset();
      _download.reset();
    }
    final colors = ConnectionPalette(
      Theme.of(context).brightness == Brightness.dark,
    );
    final failed = _traffic.error != null || data?.failed == true;
    final String note;
    if (widget.app.state.phase == 'STOPPED') {
      note = '等待实际接管';
    } else if (!_traffic.available) {
      note = '等待状态同步';
    } else if (failed) {
      note = '更新失败';
    } else if (data?.fresh != true) {
      note = '等待更新';
    } else if (data?.upload == null && data?.download == null) {
      note = '等待采样';
    } else {
      note = '近 30 秒 · 各图独立尺度';
    }
    final count = data?.activeCount;
    final countText = widget.app.state.phase == 'STOPPED'
        ? '暂无实时连接数据'
        : count == null
        ? '活跃连接 —'
        : '$count 个活跃连接';
    final down = _metric(
      '下载',
      false,
      colors.download,
      _download.format(data?.download),
      data,
    );
    final up = _metric(
      '上传',
      true,
      colors.upload,
      _upload.format(data?.upload),
      data,
    );
    final stacked =
        widget.width < 260 || MediaQuery.textScalerOf(context).scale(32) > 48;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '网络活动',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: widget.onOpen,
              child: const Text('查看连接'),
            ),
          ],
        ),
        if (stacked)
          Column(children: [down, const SizedBox(height: 8), up])
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: down),
              const SizedBox(width: 12),
              Expanded(child: up),
            ],
          ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: Wrap(
            spacing: 16,
            runSpacing: 6,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Text(countText, style: Theme.of(context).textTheme.bodySmall),
              Text(note, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }

  Widget _metric(
    String label,
    bool upload,
    Color color,
    ({String value, String unit}) rate,
    TrafficSnapshot? data,
  ) {
    final current = upload ? data?.upload : data?.download;
    return Semantics(
      button: true,
      onTap: widget.onOpen,
      label: '$label ${rate.value} ${rate.unit}，查看连接',
      excludeSemantics: true,
      child: InkWell(
        onTap: widget.onOpen,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    upload ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 16,
                    color: color,
                  ),
                  const SizedBox(width: 5),
                  Text(label),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: 5,
                children: [
                  Text(
                    rate.value,
                    style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text(
                      rate.unit,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 64,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final plot = TrafficPlot(
                      data?.points ?? const [],
                      data?.elapsedMs ?? 0,
                      upload,
                    );
                    final size = Size(constraints.maxWidth, 64);
                    return TrafficChart(
                      key: ValueKey((_identity, upload)),
                      plot: plot,
                      size: size,
                      color: color,
                      wave: _wave,
                      animate: _wave.isAnimating && current != null,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _traffic.removeListener(_changed);
    _traffic.dispose();
    _wave.dispose();
    super.dispose();
  }
}

class TrafficChart extends StatefulWidget {
  const TrafficChart({
    super.key,
    required this.plot,
    required this.size,
    required this.color,
    required this.wave,
    required this.animate,
  });

  final TrafficPlot plot;
  final Size size;
  final Color color;
  final Animation<double> wave;
  final bool animate;

  @override
  State<TrafficChart> createState() => _TrafficChartState();
}

class _TrafficChartState extends State<TrafficChart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _movement;
  late TrafficFrame _from;
  late TrafficFrame _to;

  TrafficFrame get _frame => TrafficFrame.lerp(_from, _to, _movement.value);

  @override
  void initState() {
    super.initState();
    _movement = AnimationController(vsync: this, value: 1);
    _from = _to = TrafficFrame.fromPlot(widget.plot, widget.size);
  }

  @override
  void didUpdateWidget(TrafficChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.plot.points.lastOrNull?.elapsedMs;
    final latest = widget.plot.points.lastOrNull?.elapsedMs;
    final continuous =
        widget.animate &&
        oldWidget.animate &&
        widget.size == oldWidget.size &&
        previous != null &&
        latest != null &&
        latest >= previous &&
        _frame.endpoint != null &&
        !widget.plot.points.any(
          (point) =>
              point.elapsedMs >= previous && widget.plot.value(point) == null,
        );
    if (continuous && latest == previous) return;
    final current = _frame;
    _movement.stop();
    _to = TrafficFrame.fromPlot(
      widget.plot,
      widget.size,
      previous: current,
      keepDeparting: continuous,
    );
    if (continuous) {
      _from = current;
      _movement.duration = Duration(
        milliseconds: (latest - previous).clamp(1, 1000),
      );
      _movement.forward(from: 0);
    } else {
      _from = _to;
      _movement.value = 1;
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _movement,
    builder: (context, child) {
      final frame = _frame;
      final endpoint = frame.endpoint;
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: TrafficPainter(
                  frame,
                  widget.color,
                  widget.plot.upload,
                ),
              ),
            ),
          ),
          if (endpoint != null)
            Positioned(
              left: endpoint.dx - 10,
              top: endpoint.dy - 10,
              width: 20,
              height: 20,
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _EndpointPainter(
                    widget.color,
                    widget.wave,
                    animate: widget.animate,
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );

  @override
  void dispose() {
    _movement.dispose();
    super.dispose();
  }
}

class TrafficPlot {
  TrafficPlot(this.points, this.now, this.upload);
  final List<TrafficPoint> points;
  final int now;
  final bool upload;
  double? value(TrafficPoint point) => upload ? point.upload : point.download;

  List<Offset?> positions(Size size) {
    final maximum = points.fold<double>(
      0,
      (m, p) => math.max(m, value(p) ?? 0),
    );
    final anchor = points.isEmpty ? now : points.last.elapsedMs;
    final width = math.max(0.0, size.width - 20);
    final height = math.max(0.0, size.height - 20);
    return [
      for (final point in points)
        value(point) == null
            ? null
            : Offset(
                10 +
                    ((point.elapsedMs - anchor + TrafficWindow.durationMs) /
                                TrafficWindow.durationMs)
                            .clamp(0, 1) *
                        width,
                10 + height * (maximum == 0 ? 1 : 1 - value(point)! / maximum),
              ),
    ];
  }

  Offset? endpoint(Size size) => points.isEmpty ? null : positions(size).last;
}

typedef TrafficVertex = ({int time, Offset? position, double phase});

class TrafficFrame {
  const TrafficFrame(this.vertices, this.anchor);
  final List<TrafficVertex> vertices;
  final double anchor;

  Offset? get endpoint => vertices.lastOrNull?.position;

  factory TrafficFrame.fromPlot(
    TrafficPlot plot,
    Size size, {
    TrafficFrame? previous,
    bool keepDeparting = false,
  }) {
    if (plot.points.isEmpty) return const TrafficFrame([], 0);
    final positions = plot.positions(size);
    final anchor = plot.points.last.elapsedMs.toDouble();
    final old = {
      for (final vertex in previous?.vertices ?? <TrafficVertex>[])
        vertex.time: vertex,
    };
    final vertices = <TrafficVertex>[
      if (keepDeparting)
        for (final vertex in old.values)
          if (vertex.time < plot.points.first.elapsedMs)
            (
              time: vertex.time,
              position: vertex.position == null
                  ? null
                  : Offset(
                      10 +
                          (vertex.time - anchor + TrafficWindow.durationMs) /
                              TrafficWindow.durationMs *
                              math.max(0, size.width - 20),
                      vertex.position!.dy,
                    ),
              phase: vertex.phase,
            ),
      for (var i = 0; i < plot.points.length; i++)
        (time: plot.points[i].elapsedMs, position: positions[i], phase: 0),
    ];
    if (vertices.length > TrafficWindow.maxPoints * 2) {
      vertices.removeRange(0, vertices.length - TrafficWindow.maxPoints * 2);
    }
    // Preserve a surviving sample's dash phase, including when the left edge
    // is cropped. Each disconnected segment has its own continuous phase.
    var start = 0;
    while (start < vertices.length) {
      if (vertices[start].position == null) {
        start++;
        continue;
      }
      var end = start + 1;
      while (end < vertices.length && vertices[end].position != null) {
        final vertex = vertices[end];
        vertices[end] = (
          time: vertex.time,
          position: vertex.position,
          phase:
              vertices[end - 1].phase +
              (vertex.position! - vertices[end - 1].position!).distance,
        );
        end++;
      }
      double shift = 0;
      for (var i = start; i < end; i++) {
        final match = old[vertices[i].time];
        if (match?.position != null) {
          shift = match!.phase - vertices[i].phase;
          break;
        }
      }
      for (var i = start; i < end; i++) {
        final vertex = vertices[i];
        vertices[i] = (
          time: vertex.time,
          position: vertex.position,
          phase: vertex.phase + shift,
        );
      }
      start = end;
    }
    return TrafficFrame(vertices, anchor);
  }

  static TrafficFrame lerp(TrafficFrame from, TrafficFrame to, double t) {
    if (t >= 1 || identical(from, to)) return to;
    final old = {for (final vertex in from.vertices) vertex.time: vertex};
    final last = from.vertices.lastOrNull;
    return TrafficFrame([
      for (final vertex in to.vertices)
        if (vertex.position == null)
          vertex
        else
          (
            time: vertex.time,
            position: Offset.lerp(
              old[vertex.time]?.position ?? last?.position ?? vertex.position,
              vertex.position,
              t,
            ),
            phase:
                (old[vertex.time]?.phase ?? last?.phase ?? vertex.phase) *
                    (1 - t) +
                vertex.phase * t,
          ),
    ], from.anchor * (1 - t) + to.anchor * t);
  }

  Iterable<(Offset, Offset)> dashes() sync* {
    for (var i = 1; i < vertices.length; i++) {
      final a = vertices[i - 1];
      final b = vertices[i];
      if (a.position == null || b.position == null || b.phase <= a.phase) {
        continue;
      }
      for (
        double start = (a.phase / 7).floor() * 7;
        start < b.phase;
        start += 7
      ) {
        final left = math.max(a.phase, start);
        final right = math.min(b.phase, start + 4);
        if (right <= left) continue;
        yield (
          Offset.lerp(
            a.position,
            b.position,
            (left - a.phase) / (b.phase - a.phase),
          )!,
          Offset.lerp(
            a.position,
            b.position,
            (right - a.phase) / (b.phase - a.phase),
          )!,
        );
      }
    }
  }
}

class TrafficPainter extends CustomPainter {
  TrafficPainter(this.frame, this.color, this.upload);
  final TrafficFrame frame;
  final Color color;
  final bool upload;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.18)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(10, size.height - 10),
      Offset(size.width - 10, size.height - 10),
      paint,
    );
    paint
      ..color = color
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke;
    canvas.save();
    canvas.clipRect(
      Rect.fromLTRB(10, 0, math.max(10, size.width - 10), size.height),
    );
    if (upload) {
      for (final (start, end) in frame.dashes()) {
        canvas.drawLine(start, end, paint);
      }
    } else {
      final path = Path();
      var connected = false;
      for (final vertex in frame.vertices) {
        final point = vertex.position;
        if (point == null) {
          connected = false;
        } else if (!connected) {
          path.moveTo(point.dx, point.dy);
          connected = true;
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      canvas.drawPath(path, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(TrafficPainter oldDelegate) =>
      oldDelegate.frame != frame ||
      oldDelegate.color != color ||
      oldDelegate.upload != upload;
}

class _EndpointPainter extends CustomPainter {
  _EndpointPainter(this.color, this.phase, {required this.animate})
    : super(repaint: animate ? phase : null);
  final Color color;
  final Animation<double> phase;
  final bool animate;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    if (animate) {
      canvas.drawCircle(
        center,
        3 + phase.value * 6.5,
        Paint()
          ..color = color.withValues(alpha: 0.4 * (1 - phase.value))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    canvas.drawCircle(center, 3, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_EndpointPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.animate != animate;
}
