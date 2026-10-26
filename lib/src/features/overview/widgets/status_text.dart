import 'package:flutter/material.dart';

class StatusText extends StatefulWidget {
  const StatusText(
    this.text, {
    super.key,
    this.style,
    this.emptyText = '',
    this.animate = true,
    this.textAlign = TextAlign.center,
  });
  final String text;

  /// Related text used for empty-slot geometry only.
  final String emptyText;
  final TextStyle? style;
  final bool animate;
  final TextAlign textAlign;

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
  late String _previous = widget.text;
  late String _target = widget.text;
  static const _handoff = 100 / 280;

  @override
  void didUpdateWidget(StatusText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text == oldWidget.text) return;
    _previous = _animation.value < _handoff ? _previous : _target;
    _target = widget.text;
    if (!widget.animate ||
        MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _animation.value = 1;
    } else {
      _animation.forward(from: 0);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.animate ||
        MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _animation.value = 1;
    }
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
    final painter = TextPainter(
      text: TextSpan(
        text: widget.text.isEmpty ? widget.emptyText : widget.text,
        style: style,
      ),
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
            final exiting = _animation.value < _handoff;
            final progress = exiting
                ? _animation.value / _handoff
                : (_animation.value - _handoff) / (1 - _handoff);
            final eased = Curves.easeOut.transform(progress.clamp(0, 1));
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: Align(
                  alignment: alignment,
                  child: Opacity(
                    opacity: exiting ? 1 - eased : eased,
                    child: Transform.translate(
                      offset: Offset(0, exiting ? -3 * eased : 3 * (1 - eased)),
                      child: Text(
                        exiting ? _previous : _target,
                        style: widget.style,
                        strutStyle: strut,
                        textAlign: widget.textAlign,
                        softWrap: false,
                      ),
                    ),
                  ),
                ),
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
