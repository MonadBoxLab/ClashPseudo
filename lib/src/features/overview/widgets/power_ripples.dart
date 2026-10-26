import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Stopping fades expanding circles out within 1.5 seconds.
class PowerRipples extends StatefulWidget {
  const PowerRipples({
    super.key,
    required this.emitting,
    required this.visible,
    required this.color,
    required this.child,
  });

  static const buttonDiameter = 88.0;

  final bool emitting;
  final bool visible;
  final Color color;
  final Widget child;

  @override
  State<PowerRipples> createState() => _PowerRipplesState();
}

class _PowerRipplesState extends State<PowerRipples>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker = createTicker(_tick);
  final _time = ValueNotifier<double>(0);
  final _waves = <RippleWave>[];
  bool _foreground = true;
  bool _emitting = false;
  double _next = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(PowerRipples oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    final visible =
        widget.visible &&
        _foreground &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context);
    if (!visible) {
      _emitting = false;
      _waves.clear();
      _ticker.stop();
      _time.value = 0;
      return;
    }
    if (widget.emitting && !_emitting) {
      if (!_ticker.isActive) _time.value = 0;
      _waves.add(RippleWave(_time.value));
      _next = _time.value + 2;
      if (!_ticker.isActive) _ticker.start();
    } else if (!widget.emitting && _emitting) {
      for (final wave in _waves) {
        wave.stoppedAt ??= _time.value;
      }
    }
    _emitting = widget.emitting;
  }

  void _tick(Duration elapsed) {
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    _waves.removeWhere((wave) => wave.finished(seconds));
    if (_emitting && seconds >= _next) {
      // Resume animation from the current phase after missed frames.
      _waves.add(RippleWave(seconds));
      _next = seconds + 2;
    }
    _time.value = seconds;
    if (!_emitting && _waves.isEmpty) _ticker.stop();
  }

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      Positioned(
        left: -PowerRipples.buttonDiameter * 2,
        top: -PowerRipples.buttonDiameter * 2,
        width: PowerRipples.buttonDiameter * 5,
        height: PowerRipples.buttonDiameter * 5,
        child: IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: RipplePainter(_time, _waves, widget.color),
            ),
          ),
        ),
      ),
      widget.child,
    ],
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }
}

class RippleWave {
  RippleWave(this.birth);

  final double birth;
  double? stoppedAt;

  double age(double time) => (time - birth) / 6;

  double opacity(double time) => stoppedAt == null
      ? 1
      : 1 - Curves.easeOut.transform(((time - stoppedAt!) / 1.5).clamp(0, 1));

  bool finished(double time) =>
      time - birth >= 6 || (stoppedAt != null && time - stoppedAt! >= 1.5);
}

class RipplePainter extends CustomPainter {
  RipplePainter(this.time, this.waves, this.color) : super(repaint: time);
  final ValueNotifier<double> time;
  final List<RippleWave> waves;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    const radii = [34.0, 48.0, 77.0, 117.0, 165.0];
    const opacity = [.55, .43, .29, .14, 0.0];
    for (final wave in waves) {
      final age = wave.age(time.value);
      if (age < 0 || age >= 1) continue;
      final segment = (age * 4).floor();
      final fraction = age * 4 - segment;
      final radius =
          radii[segment] + (radii[segment + 1] - radii[segment]) * fraction;
      final alpha = age < .035
          ? .53 * age / .035
          : opacity[segment] +
                (opacity[segment + 1] - opacity[segment]) * fraction;
      paint.color = color.withValues(alpha: alpha * wave.opacity(time.value));
      canvas.drawCircle(
        center,
        radius / 34 * PowerRipples.buttonDiameter / 2,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(RipplePainter oldDelegate) => color != oldDelegate.color;
}
