part of 'form_body.dart';

double _definitionColumnsCapacity(
  double width,
  double primaryMinimum,
  double secondaryMinimum,
  double gap,
) {
  assert(width.isFinite);
  final primaryTarget = math.min(
    math.max(primaryMinimum, width * .36),
    width * .48,
  );
  final secondaryTarget = math.max(0.0, width - primaryTarget - gap);
  double capacity(double target, double minimum) {
    if (width == 0) return 0.0;
    if (width <= target) return 1.0;
    return ((width - math.min(minimum, width)) / (width - target))
        .clamp(0.0, 1.0)
        .toDouble();
  }

  return math.min(
    capacity(primaryTarget, primaryMinimum),
    capacity(secondaryTarget, secondaryMinimum),
  );
}

class _DefinitionColumnsMotion extends ImplicitlyAnimatedWidget {
  const _DefinitionColumnsMotion({
    required this.target,
    required this.capacity,
    required this.reduced,
    required this.builder,
    required super.onEnd,
  }) : super(
         duration: reduced ? Duration.zero : const Duration(milliseconds: 180),
         curve: Curves.easeInOutCubic,
       );

  final double target;
  final double capacity;
  final bool reduced;
  final ValueWidgetBuilder<double> builder;

  @override
  AnimatedWidgetBaseState<_DefinitionColumnsMotion> createState() =>
      _DefinitionColumnsMotionState();
}

class _DefinitionColumnsMotionState
    extends AnimatedWidgetBaseState<_DefinitionColumnsMotion> {
  Tween<double>? _progress;

  @override
  void forEachTween(TweenVisitor<dynamic> visitor) {
    _progress = visitor(
      _progress,
      widget.target,
      (dynamic value) => Tween<double>(begin: value as double),
    ) as Tween<double>?;
  }

  @override
  void didUpdateWidget(_DefinitionColumnsMotion oldWidget) {
    final tween = _progress;
    if (tween != null && tween.evaluate(animation) > widget.capacity) {
      // Rebase the same tween before SDK retargeting, not only at render time.
      tween
        ..begin = widget.capacity
        ..end = widget.capacity;
    }
    super.didUpdateWidget(oldWidget);
    if (widget.reduced && !oldWidget.reduced) {
      // Changing duration alone leaves the running simulation untouched.
      // Setting value stops it and finishes the existing tween in this frame.
      controller.value = 1.0;
    }
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _progress!.evaluate(animation), null);
}

/// Each chapter retains one parent. Its original-order vertical position and
/// two-column position interpolate within this frame's actual width constraints.
class _DefinitionColumns extends MultiChildRenderObjectWidget {
  const _DefinitionColumns({
    required this.progress,
    required this.primaryMinimum,
    required this.capacity,
    required this.gap,
    required this.direction,
    required this.secondary,
    required super.children,
  });

  final double progress;
  final double primaryMinimum;
  final double capacity;
  final double gap;
  final TextDirection direction;
  final List<bool> secondary;

  @override
  _DefinitionColumnsRenderBox createRenderObject(BuildContext context) =>
      _DefinitionColumnsRenderBox(
        progress,
        primaryMinimum,
        capacity,
        gap,
        direction,
        secondary,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _DefinitionColumnsRenderBox renderObject,
  ) => renderObject.update(
    progress,
    primaryMinimum,
    capacity,
    gap,
    direction,
    secondary,
  );
}

class _DefinitionColumnsParentData extends ContainerBoxParentData<RenderBox> {}

class _DefinitionColumnsRenderBox extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _DefinitionColumnsParentData>,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          _DefinitionColumnsParentData
        > {
  _DefinitionColumnsRenderBox(
    this._progress,
    this._primaryMinimum,
    this._capacity,
    this._gap,
    this._direction,
    this._secondary,
  );

  double _progress;
  double _primaryMinimum;
  double _capacity;
  double _gap;
  TextDirection _direction;
  List<bool> _secondary;

  void update(
    double progress,
    double primaryMinimum,
    double capacity,
    double gap,
    TextDirection direction,
    List<bool> secondary,
  ) {
    if (_progress == progress &&
        _primaryMinimum == primaryMinimum &&
        _capacity == capacity &&
        _gap == gap &&
        _direction == direction &&
        _secondary.length == secondary.length &&
        _secondary.indexed.every((entry) => entry.$2 == secondary[entry.$1])) {
      return;
    }
    _progress = progress;
    _primaryMinimum = primaryMinimum;
    _capacity = capacity;
    _gap = gap;
    _direction = direction;
    _secondary = secondary;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _DefinitionColumnsParentData) {
      child.parentData = _DefinitionColumnsParentData();
    }
  }

  @override
  void performLayout() {
    assert(constraints.hasBoundedWidth);
    final width = constraints.maxWidth;
    final primaryTarget = math.min(
      math.max(_primaryMinimum, width * .36),
      width * .48,
    );
    final secondaryTarget = math.max(0.0, width - primaryTarget - _gap);
    final effectiveProgress = math.min(_progress, _capacity);
    var narrowY = 0.0;
    var primaryY = 0.0;
    var secondaryY = 0.0;
    var bottom = 0.0;
    var index = 0;
    var child = firstChild;
    while (child != null) {
      final secondary = _secondary[index++];
      final targetWidth = secondary ? secondaryTarget : primaryTarget;
      final childWidth = width + (targetWidth - width) * effectiveProgress;
      child.layout(
        BoxConstraints.tightFor(width: childWidth),
        parentUsesSize: true,
      );
      final x = secondary ? (primaryTarget + _gap) * effectiveProgress : 0.0;
      final columnY = secondary ? secondaryY : primaryY;
      final y = narrowY + (columnY - narrowY) * effectiveProgress;
      final data = child.parentData! as _DefinitionColumnsParentData;
      data.offset = Offset(
        _direction == TextDirection.ltr ? x : width - x - childWidth,
        y,
      );
      bottom = math.max(bottom, y + child.size.height);
      narrowY += child.size.height;
      if (secondary) {
        secondaryY += child.size.height;
      } else {
        primaryY += child.size.height;
      }
      child = data.nextSibling;
    }
    size = constraints.constrain(Size(width, bottom));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

class _DefinitionFormViewport extends InheritedWidget {
  const _DefinitionFormViewport({required this.height, required super.child});

  final double height;

  @override
  bool updateShouldNotify(_DefinitionFormViewport oldWidget) =>
      height != oldWidget.height;
}
