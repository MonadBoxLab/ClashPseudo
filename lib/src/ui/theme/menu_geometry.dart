import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// Material menu view / screen padding (`_kMenuViewPadding` / `_kMenuScreenPadding`).
const double kAppMenuViewPadding = 8;

/// Menu item minimum size: wide enough for short labels, tall enough to tap.
const Size kAppMenuItemMinimumSize = Size(168, 56);

/// Insets inside each [MenuItemButton]; vertical padding keeps text off the edges.
const EdgeInsets kAppMenuItemPadding = EdgeInsets.symmetric(
  horizontal: 16,
  vertical: 12,
);

/// Rounded menu panel that paints [kAppMenuViewPadding] inside its layout box.
///
/// [MenuAnchor] clamps to the safe area but ignores [MenuAnchor.reservedPadding]
/// when positioning (https://github.com/flutter/flutter/issues/194952), so short
/// panels can sit flush on the screen edge. Pair with [MenuStyle.padding] of the
/// same inset so hit targets and the painted surface stay aligned.
class AppMenuPanelShape extends RoundedRectangleBorder {
  const AppMenuPanelShape({
    this.viewPadding = kAppMenuViewPadding,
    super.side,
    super.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  final double viewPadding;

  EdgeInsets get _inset => EdgeInsets.all(viewPadding);

  Rect _content(Rect rect) => _inset.deflateRect(rect);

  @override
  EdgeInsetsGeometry get dimensions => _inset
      .add(super.dimensions)
      .clamp(EdgeInsets.zero, EdgeInsetsGeometry.infinity);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      super.getOuterPath(_content(rect), textDirection: textDirection);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      super.getInnerPath(_content(rect), textDirection: textDirection);

  @override
  void paintInterior(
    Canvas canvas,
    Rect rect,
    Paint paint, {
    TextDirection? textDirection,
  }) => super.paintInterior(
    canvas,
    _content(rect),
    paint,
    textDirection: textDirection,
  );

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) =>
      super.paint(canvas, _content(rect), textDirection: textDirection);

  @override
  AppMenuPanelShape scale(double t) => AppMenuPanelShape(
    viewPadding: viewPadding * t,
    side: side.scale(t),
    borderRadius: borderRadius * t,
  );

  @override
  AppMenuPanelShape copyWith({
    BorderSide? side,
    BorderRadiusGeometry? borderRadius,
    double? viewPadding,
  }) => AppMenuPanelShape(
    viewPadding: viewPadding ?? this.viewPadding,
    side: side ?? this.side,
    borderRadius: borderRadius ?? this.borderRadius,
  );

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is AppMenuPanelShape) {
      return AppMenuPanelShape(
        viewPadding: lerpDouble(a.viewPadding, viewPadding, t)!,
        side: BorderSide.lerp(a.side, side, t),
        borderRadius: BorderRadiusGeometry.lerp(
          a.borderRadius,
          borderRadius,
          t,
        )!,
      );
    }
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is AppMenuPanelShape) {
      return AppMenuPanelShape(
        viewPadding: lerpDouble(viewPadding, b.viewPadding, t)!,
        side: BorderSide.lerp(side, b.side, t),
        borderRadius: BorderRadiusGeometry.lerp(
          borderRadius,
          b.borderRadius,
          t,
        )!,
      );
    }
    return super.lerpTo(b, t);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppMenuPanelShape &&
          viewPadding == other.viewPadding &&
          side == other.side &&
          borderRadius == other.borderRadius;

  @override
  int get hashCode => Object.hash(viewPadding, side, borderRadius);
}
