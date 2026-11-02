import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// The configuration cards' SDK size transition with exact stationary bounds.
class ExactSizeTransition extends AnimatedSize {
  const ExactSizeTransition({super.key, required Widget child})
    : super(
        child: child,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeInOutCubic,
        alignment: Alignment.topCenter,
        clipBehavior: Clip.hardEdge,
      );

  @override
  State<AnimatedSize> createState() => _ExactSizeTransitionState();
}

class _ExactSizeTransitionState extends State<AnimatedSize>
    with SingleTickerProviderStateMixin {
  @override
  Widget build(BuildContext context) =>
      _ExactSizeRenderWidget(vsync: this, child: widget.child);
}

class _ExactSizeRenderWidget extends SingleChildRenderObjectWidget {
  const _ExactSizeRenderWidget({required this.vsync, required super.child});
  final TickerProvider vsync;

  @override
  RenderAnimatedSize createRenderObject(BuildContext context) =>
      _ExactRenderAnimatedSize(vsync, Directionality.maybeOf(context));

  @override
  void updateRenderObject(
    BuildContext context,
    RenderAnimatedSize renderObject,
  ) {
    renderObject
      ..vsync = vsync
      ..textDirection = Directionality.maybeOf(context);
  }
}

class _ExactRenderAnimatedSize extends RenderAnimatedSize {
  _ExactRenderAnimatedSize(TickerProvider vsync, TextDirection? textDirection)
    : super(
        vsync: vsync,
        textDirection: textDirection,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeInOutCubic,
        alignment: Alignment.topCenter,
        clipBehavior: Clip.hardEdge,
      );

  Size? _lastTarget;
  bool _followingRealResize = false;

  @override
  void performLayout() {
    super.performLayout();
    final target = constraints.constrain(child?.size ?? constraints.smallest);
    if (_lastTarget != null && target != _lastTarget) {
      _followingRealResize = true;
    }
    if (!isAnimating) _followingRealResize = false;
    _lastTarget = Size(target.width, target.height);
    // A stable SDK relayout may run a SizeTween with equal endpoints. Keep
    // its floating-point interpolation out of the box, clip and hit bounds.
    // Once a target really changes, the SDK owns the whole transition.
    if (!_followingRealResize) {
      size = target;
      if (child != null) alignChild();
    }
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final sdkSize = super.computeDryLayout(constraints);
    if (_followingRealResize || child == null || constraints.isTight) {
      return sdkSize;
    }
    final target = constraints.constrain(child!.getDryLayout(constraints));
    return _lastTarget == null || target == _lastTarget ? target : sdkSize;
  }
}
