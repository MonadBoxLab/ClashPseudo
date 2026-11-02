import 'package:flutter/material.dart';

class StatusText extends StatefulWidget {
  const StatusText(
    this.text, {
    super.key,
    this.style,
    this.emptyText = '',
    this.animate = true,
    this.textAlign = TextAlign.center,
    this.maxLines = 1,
  });
  final String text;

  /// Related text used for empty-slot geometry only.
  final String emptyText;
  final TextStyle? style;
  final bool animate;
  final TextAlign textAlign;

  /// Single-line readings scroll horizontally; status prose can wrap with null.
  final int? maxLines;

  @override
  State<StatusText> createState() => _StatusTextState();
}

class _StatusTextState extends State<StatusText>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
    value: 1,
  );
  late String _source = widget.text;
  late String _target = widget.text;
  double _fromOpacity = 1;
  double _fromOffset = 0;
  bool _enterOnly = false;
  static const _handoff = 100 / 280;

  bool get _immediate =>
      !widget.animate ||
      MediaQuery.disableAnimationsOf(context) ||
      !TickerMode.valuesOf(context).enabled;

  ({String text, double opacity, double offset}) get _frame {
    final value = _animation.value;
    if (!_enterOnly && value < _handoff) {
      final eased = Curves.easeOut.transform(value / _handoff);
      return (
        text: _source,
        opacity: _fromOpacity * (1 - eased),
        offset: _fromOffset + (-3 - _fromOffset) * eased,
      );
    }
    final progress = _enterOnly ? value : (value - _handoff) / (1 - _handoff);
    final eased = Curves.easeOut.transform(progress.clamp(0, 1));
    return (
      text: _target,
      opacity: _enterOnly ? _fromOpacity + (1 - _fromOpacity) * eased : eased,
      offset: (_enterOnly ? _fromOffset : 3) * (1 - eased),
    );
  }

  void _snap() {
    _source = _target = widget.text;
    _fromOpacity = 1;
    _fromOffset = 0;
    _enterOnly = true;
    _animation.value = 1;
  }

  @override
  void didUpdateWidget(StatusText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_immediate) {
      _snap();
      return;
    }
    if (widget.text == oldWidget.text) return;
    // Re-time the transition, not its visible endpoints. This also covers a
    // replacement after the handoff, while the previous target is still entering.
    final current = _frame;
    _source = current.text;
    _target = widget.text;
    _fromOpacity = current.opacity;
    _fromOffset = current.offset;
    _enterOnly = _source == _target;
    _animation.duration = Duration(milliseconds: _enterOnly ? 180 : 280);
    _animation.reset();
    _animation.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_immediate) _snap();
  }

  @override
  Widget build(BuildContext context) {
    final alignment = switch (widget.textAlign) {
      TextAlign.start => AlignmentDirectional.centerStart,
      TextAlign.end => AlignmentDirectional.centerEnd,
      TextAlign.left => Alignment.centerLeft,
      TextAlign.right => Alignment.centerRight,
      _ => Alignment.center,
    };
    final style = DefaultTextStyle.of(context).style.merge(widget.style);
    final strut = StrutStyle.fromTextStyle(style, forceStrutHeight: true);
    final geometryText = widget.text.isEmpty ? widget.emptyText : widget.text;
    final painter = TextPainter(
      text: TextSpan(text: geometryText, style: style),
      textAlign: widget.textAlign,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
      strutStyle: strut,
    )..layout();
    final size = painter.size;
    painter.dispose();
    return Semantics(
      label: widget.text,
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: _animation,
          builder: (context, _) {
            final frame = _frame;
            final visible = Opacity(
              opacity: frame.opacity,
              child: Transform.translate(
                offset: Offset(0, frame.offset),
                child: Text(
                  frame.text,
                  style: widget.style,
                  strutStyle: strut,
                  textAlign: widget.textAlign,
                  maxLines: widget.maxLines,
                  softWrap: widget.maxLines != 1,
                ),
              ),
            );
            if (widget.maxLines != 1) {
              return Align(
                alignment: alignment,
                heightFactor: 1,
                child: visible,
              );
            }
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: Align(alignment: alignment, child: visible),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }
}
