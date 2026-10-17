import 'package:flutter/material.dart';

class StatusText extends StatefulWidget {
  const StatusText(
    this.text, {
    super.key,
    this.style,
    this.textAlign = TextAlign.center,
  });
  final String text;
  final TextStyle? style;
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
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _animation.value = 1;
    } else {
      _animation.forward(from: 0);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _animation.value = 1;
    }
  }

  @override
  Widget build(BuildContext context) => Semantics(
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
          final alignment = switch (widget.textAlign) {
            TextAlign.start => AlignmentDirectional.centerStart,
            TextAlign.end => AlignmentDirectional.centerEnd,
            TextAlign.left => Alignment.centerLeft,
            TextAlign.right => Alignment.centerRight,
            _ => Alignment.center,
          };
          final strut = StrutStyle.fromTextStyle(
            DefaultTextStyle.of(context).style.merge(widget.style),
            forceStrutHeight: true,
          );
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Stack(
              alignment: alignment,
              children: [
                Opacity(
                  opacity: 0,
                  child: Text(
                    widget.text.isEmpty ? ' ' : widget.text,
                    style: widget.style,
                    strutStyle: strut,
                    textAlign: widget.textAlign,
                    softWrap: false,
                  ),
                ),
                Positioned.fill(
                  child: Align(
                    alignment: alignment,
                    child: Opacity(
                      opacity: exiting ? 1 - eased : eased,
                      child: Transform.translate(
                        offset: Offset(
                          0,
                          exiting ? -3 * eased : 3 * (1 - eased),
                        ),
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
              ],
            ),
          );
        },
      ),
    ),
  );

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }
}
