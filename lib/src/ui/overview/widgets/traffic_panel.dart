import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../l10n/app_localizations.dart';

import '../../theme/app_theme.dart';
import '../../components/reading/format_bytes.dart';
import '../traffic_controller.dart';
import '../../../model/traffic_snapshot.dart';
import '../../locale/message_text.dart';

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
    required this.traffic,
    required this.visible,
    required this.width,
    required this.onOpen,
    this.fillHeight = false,
  });
  final double width;
  final bool fillHeight;
  final TrafficController traffic;
  final bool visible;
  final VoidCallback onOpen;

  @override
  State<TrafficPanel> createState() => _TrafficPanelState();
}

class _TrafficPanelState extends State<TrafficPanel>
    with SingleTickerProviderStateMixin {
  TrafficController get _traffic => widget.traffic;
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
    _traffic.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion();
  }

  @override
  void didUpdateWidget(TrafficPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.traffic != widget.traffic) {
      oldWidget.traffic.removeListener(_changed);
      _traffic.addListener(_changed);
    }
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
    final strings = AppLocalizations.of(context);
    final core = _traffic.app.state.core;
    final identity = (
      _traffic.app.state.generation,
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
    final count = data?.activeCount;
    final countText = '${strings.trafficConnections} ${count ?? '—'}';
    final stacked =
        widget.width < 260 || MediaQuery.textScalerOf(context).scale(32) > 48;
    final columnGap = (widget.width * .06).clamp(16.0, 48.0);
    final download = _download.format(data?.download);
    final upload = _upload.format(data?.upload);
    final reduced =
        MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled;
    return Column(
      mainAxisSize: widget.fillHeight ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                strings.networkActivity,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            Flexible(
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: widget.onOpen,
                  child: Text(strings.recentConnections),
                ),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 24),
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: stacked ? 1.0 : 0.0),
            duration: reduced
                ? Duration.zero
                : const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) {
              final progress = reduced ? (stacked ? 1.0 : 0.0) : value;
              final half = (widget.width - columnGap) / 2;
              final metricWidth = half + (widget.width - half) * progress;
              return _TrafficPair(
                key: const ValueKey('traffic-metrics-layout'),
                progress: progress,
                horizontalGap: columnGap,
                verticalGap: 24,
                children: [
                  _metric(
                    strings.download,
                    false,
                    colors.downloadPlot,
                    download,
                    data,
                    width: metricWidth,
                    readingGap: 24,
                  ),
                  _metric(
                    strings.upload,
                    true,
                    colors.uploadPlot,
                    upload,
                    data,
                    width: metricWidth,
                    readingGap: 24,
                  ),
                ],
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Builder(
            builder: (context) {
              final style = Theme.of(context).textTheme.bodySmall!;
              final scaler = MediaQuery.textScalerOf(context);
              final direction = Directionality.of(context);
              final strut = StrutStyle.fromTextStyle(
                style,
                height: 1.5,
                forceStrutHeight: true,
              );
              Size measure(String text, {double width = double.infinity}) {
                final painter = TextPainter(
                  text: TextSpan(text: text, style: style),
                  textDirection: direction,
                  textScaler: scaler,
                  strutStyle: strut,
                )..layout(maxWidth: width);
                final size = painter.size;
                painter.dispose();
                return size;
              }

              final countWidth = [
                '${strings.trafficConnections} —',
                '${strings.trafficConnections} 999999',
              ].map((text) => measure(text).width).reduce(math.max);
              String megabytes(int? bytes) =>
                  bytes == null ? '—' : (bytes / 1000000).toStringAsFixed(1);
              final appMemory = strings.memoryApplication(
                megabytes(_traffic.appRssBytes),
              );
              final coreMemory = strings.memoryCore(
                megabytes(_traffic.coreRssBytes),
              );
              final appMemorySize = measure(
                strings.memoryApplication('99999.9'),
              );
              final coreMemorySize = measure(strings.memoryCore('99999.9'));
              final memoryWidth = math.max(
                appMemorySize.width,
                coreMemorySize.width,
              );
              final stackedFooter =
                  stacked ||
                  (widget.width - columnGap) / 2 <
                      math.max(countWidth, memoryWidth);
              Widget summaryText(String text, Key key) => SingleChildScrollView(
                key: key,
                scrollDirection: Axis.horizontal,
                child: Text(
                  text,
                  softWrap: false,
                  maxLines: 1,
                  strutStyle: strut,
                  style: style,
                ),
              );
              final countLabel = summaryText(
                countText,
                const ValueKey('traffic-active-count'),
              );
              final memoryLabel = Tooltip(
                message: _traffic.memoryUnavailable
                    ? _traffic.memoryErrorMessage?.resolve(strings) ??
                          strings.processMemoryUnavailable
                    : '',
                child: ColoredBox(
                  color: Colors.transparent,
                  key: const ValueKey('traffic-memory'),
                  child: SizedBox(
                    height: appMemorySize.height + coreMemorySize.height,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        summaryText(
                          appMemory,
                          const ValueKey('traffic-memory-app'),
                        ),
                        if (_traffic.coreMemoryRunning)
                          summaryText(
                            coreMemory,
                            const ValueKey('traffic-memory-core'),
                          ),
                      ],
                    ),
                  ),
                ),
              );
              return TweenAnimationBuilder<double>(
                tween: Tween(end: stackedFooter ? 1.0 : 0.0),
                duration: reduced
                    ? Duration.zero
                    : const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => _TrafficPair(
                  key: const ValueKey('traffic-summary-layout'),
                  progress: reduced ? (stackedFooter ? 1.0 : 0.0) : value,
                  horizontalGap: columnGap,
                  verticalGap: 4,
                  children: [countLabel, memoryLabel],
                ),
              );
            },
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
    TrafficSnapshot? data, {
    required double width,
    required double readingGap,
  }) {
    final strings = AppLocalizations.of(context);
    final totalLabel = upload
        ? strings.trafficUploaded
        : strings.trafficDownloaded;
    final total =
        '$totalLabel ${formatBytes(upload ? data?.sessionUploadBytes : data?.sessionDownloadBytes)}';
    final current = upload ? data?.upload : data?.download;
    final directionStyle = DefaultTextStyle.of(context).style;
    final directionWidth = math.max(1.0, width - 21);
    var directionHeight = 16.0;
    for (final direction in [strings.download, strings.upload]) {
      final painter = TextPainter(
        text: TextSpan(text: direction, style: directionStyle),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
      )..layout(maxWidth: directionWidth);
      directionHeight = math.max(directionHeight, painter.height);
      painter.dispose();
    }
    final height = (width * 0.3).clamp(80.0, 112.0).toDouble();
    final plot = TrafficPlot(
      data?.points ?? const [],
      data?.elapsedMs ?? 0,
      upload,
    );
    return Semantics(
      button: true,
      onTap: widget.onOpen,
      label:
          '$label ${rate.value} ${rate.unit} · $total · ${strings.recentConnections}',
      excludeSemantics: true,
      child: InkWell(
        onTap: widget.onOpen,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                key: ValueKey(
                  upload
                      ? 'traffic-upload-direction'
                      : 'traffic-download-direction',
                ),
                height: directionHeight,
                child: Row(
                  children: [
                    Icon(
                      upload ? Icons.arrow_upward : Icons.arrow_downward,
                      size: 16,
                      color: color,
                    ),
                    const SizedBox(width: 5),
                    Flexible(child: Text(label)),
                  ],
                ),
              ),
              SizedBox(height: readingGap),
              Row(
                key: ValueKey(
                  upload
                      ? 'traffic-upload-reading'
                      : 'traffic-download-reading',
                ),
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Flexible(
                    child: SizedBox(
                      width: MediaQuery.textScalerOf(context).scale(32) * 2.6,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        reverse: true,
                        child: Text(
                          rate.value,
                          textAlign: TextAlign.end,
                          softWrap: false,
                          style: Theme.of(context).textTheme.headlineLarge
                              ?.copyWith(
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: SizedBox(
                      width: MediaQuery.textScalerOf(context).scale(12) * 3.5,
                      child: Text(
                        rate.unit,
                        softWrap: false,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: height,
                child: TrafficChart(
                  key: ValueKey((_identity, upload)),
                  plot: plot,
                  size: Size(width, height),
                  color: color,
                  wave: _wave,
                  animate: _wave.isAnimating && current != null,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: SingleChildScrollView(
                  key: ValueKey(
                    upload ? 'traffic-upload-total' : 'traffic-download-total',
                  ),
                  scrollDirection: Axis.horizontal,
                  child: Text(
                    total,
                    softWrap: false,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
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
    _wave.dispose();
    super.dispose();
  }
}

// A single pair of retained children; only their actual layout rectangles move.
class _TrafficPair extends MultiChildRenderObjectWidget {
  const _TrafficPair({
    super.key,
    required this.progress,
    required this.horizontalGap,
    required this.verticalGap,
    required super.children,
  });
  final double progress;
  final double horizontalGap;
  final double verticalGap;

  @override
  _RenderTrafficPair createRenderObject(BuildContext context) =>
      _RenderTrafficPair(progress, horizontalGap, verticalGap);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderTrafficPair renderObject,
  ) => renderObject.update(progress, horizontalGap, verticalGap);
}

class _TrafficPairData extends ContainerBoxParentData<RenderBox> {}

typedef _TrafficPairGeometry = ({Size size, Rect first, Rect second});

class _RenderTrafficPair extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _TrafficPairData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _TrafficPairData> {
  _RenderTrafficPair(this._progress, this._horizontalGap, this._verticalGap);
  double _progress;
  double _horizontalGap;
  double _verticalGap;

  void update(double progress, double horizontalGap, double verticalGap) {
    if ((_progress, _horizontalGap, _verticalGap) ==
        (progress, horizontalGap, verticalGap)) {
      return;
    }
    _progress = progress;
    _horizontalGap = horizontalGap;
    _verticalGap = verticalGap;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _TrafficPairData) {
      child.parentData = _TrafficPairData();
    }
  }

  _TrafficPairGeometry _geometry(double width) {
    final first = firstChild!;
    final second = childAfter(first)!;
    final half = math.max(0.0, (width - _horizontalGap) / 2);
    final childWidth = half + (width - half) * _progress;
    final firstHeight = first.getMaxIntrinsicHeight(childWidth);
    final secondHeight = second.getMaxIntrinsicHeight(childWidth);
    final rowHeight = math.max(firstHeight, secondHeight);
    final columnHeight = firstHeight + _verticalGap + secondHeight;
    return (
      size: Size(width, rowHeight + (columnHeight - rowHeight) * _progress),
      first: Rect.fromLTWH(0, 0, childWidth, firstHeight),
      second: Rect.fromLTWH(
        (half + _horizontalGap) * (1 - _progress),
        (firstHeight + _verticalGap) * _progress,
        childWidth,
        secondHeight,
      ),
    );
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _geometry(width).size.height;
  @override
  double computeMaxIntrinsicHeight(double width) =>
      _geometry(width).size.height;
  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(_geometry(constraints.maxWidth).size);

  @override
  void performLayout() {
    final geometry = _geometry(constraints.maxWidth);
    size = constraints.constrain(geometry.size);
    void place(RenderBox child, Rect rect) {
      child.layout(BoxConstraints.tight(rect.size), parentUsesSize: true);
      (child.parentData! as _TrafficPairData).offset = rect.topLeft;
    }

    final first = firstChild!;
    place(first, geometry.first);
    place(childAfter(first)!, geometry.second);
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
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
                    surface: HomePalette.of(context).surface,
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
                    ((point.elapsedMs - anchor + TrafficSnapshot.durationMs) /
                                TrafficSnapshot.durationMs)
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
                          (vertex.time - anchor + TrafficSnapshot.durationMs) /
                              TrafficSnapshot.durationMs *
                              math.max(0, size.width - 20),
                      vertex.position!.dy,
                    ),
              phase: vertex.phase,
            ),
      for (var i = 0; i < plot.points.length; i++)
        (time: plot.points[i].elapsedMs, position: positions[i], phase: 0),
    ];
    if (vertices.length > TrafficSnapshot.maxPoints * 2) {
      vertices.removeRange(0, vertices.length - TrafficSnapshot.maxPoints * 2);
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
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
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
  _EndpointPainter(
    this.color,
    this.phase, {
    required this.surface,
    required this.animate,
  }) : super(repaint: animate ? phase : null);
  final Color color;
  final Color surface;
  final Animation<double> phase;
  final bool animate;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    if (animate) {
      canvas.drawCircle(
        center,
        4 + phase.value * 5.5,
        Paint()
          ..color = color.withValues(alpha: 0.4 * (1 - phase.value))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    canvas.drawCircle(center, 6, Paint()..color = surface);
    canvas.drawCircle(center, 4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_EndpointPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.surface != surface ||
      oldDelegate.animate != animate;
}
