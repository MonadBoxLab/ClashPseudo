import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';

import 'delay_test_controller.dart';
import 'delay_result.dart';
import 'strategy_controller.dart';
import 'strategy_choice.dart';
import 'strategy_snapshot.dart';
import '../../app/widgets/operation_feedback.dart';
import '../../app/widgets/provenance_details.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/messages.dart';
import 'strategy_icon.dart';

part 'strategy_popup_content.dart';

Future<void> showStrategyPopup({
  required BuildContext context,
  required StrategyController controller,
  required String name,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  final box = context.findRenderObject()! as RenderBox;
  final focus = FocusManager.instance.primaryFocus;
  final route = _StrategyPopupRoute(
    anchorBox: box,
    anchor: box.localToGlobal(Offset.zero, ancestor: overlay) & box.size,
    strategies: controller,
    name: name,
    generation: controller.app.state.core.generation,
    storageEpoch: controller.app.storageEpoch,
    reducedMotion: MediaQuery.disableAnimationsOf(context),
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
  );
  await navigator.push<void>(route);
  // Keep the source hidden until the reverse transition has finished.
  await route.completed;
  if (context.mounted &&
      focus?.context?.mounted == true &&
      focus!.canRequestFocus) {
    focus.requestFocus();
  }
}

class _StrategyPopupRoute extends PopupRoute<void> {
  _StrategyPopupRoute({
    required this.anchorBox,
    required this.anchor,
    required this.strategies,
    required this.name,
    required this.generation,
    required this.storageEpoch,
    required this.reducedMotion,
    required this.barrierLabel,
  }) : sourceCore = strategies.app.state.core;

  final CoreSnapshot sourceCore;
  bool _canReturnToSource = true;
  double? _height;
  (Size, double)? _geometry;
  final RenderBox anchorBox;
  final Rect anchor;
  final StrategyController strategies;
  final String name;
  final int generation;
  final int storageEpoch;
  final bool reducedMotion;
  @override
  final String barrierLabel;
  @override
  bool get barrierDismissible => true;
  @override
  Color get barrierColor => const Color(0x520e1419);
  @override
  Duration get transitionDuration =>
      reducedMotion ? Duration.zero : const Duration(milliseconds: 260);
  @override
  Duration get reverseTransitionDuration =>
      reducedMotion ? Duration.zero : const Duration(milliseconds: 200);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return AnimatedBuilder(
      animation: Listenable.merge([animation, strategies]),
      builder: (context, _) {
        final media = MediaQuery.of(context);
        return LayoutBuilder(
          builder: (context, constraints) {
            final geometry = (constraints.biggest, media.textScaler.scale(14));
            if (_geometry != geometry) {
              _geometry = geometry;
              _height = null;
            }
            Rect? source;
            if (anchorBox.attached) {
              final box = anchorBox;
              final overlay = navigator!.overlay!.context.findRenderObject();
              if (box.attached && box.hasSize && overlay is RenderBox) {
                final rect =
                    box.localToGlobal(Offset.zero, ancestor: overlay) &
                    box.size;
                if (rect.overlaps(Offset.zero & constraints.biggest)) {
                  source = rect;
                }
              }
            }
            final core = strategies.app.state.core;
            _canReturnToSource =
                _canReturnToSource &&
                strategies.app.storageEpoch == storageEpoch &&
                source == anchor &&
                core.generation == sourceCore.generation &&
                core.configId == sourceCore.configId &&
                core.revision == sourceCore.revision &&
                core.composition == sourceCore.composition &&
                strategies.groups.any((group) => group.name == name);
            // Collapse toward the current captured card geometry only.
            final animate =
                _canReturnToSource &&
                strategies.app.foreground &&
                !media.disableAnimations;
            final progress = animate
                ? Curves.easeOutCubic.transform(animation.value)
                : 1.0;
            final colors = Theme.of(context).colorScheme;
            return CustomSingleChildLayout(
              delegate: _PopupPosition(
                anchor: anchor,
                progress: progress,
                height: _height,
                onMeasured: (value) {
                  if (_height != null) return;
                  _height = value;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (isActive) changedExternalState();
                  });
                },
                padding: EdgeInsets.fromLTRB(
                  media.padding.left + 12,
                  media.padding.top + 12,
                  media.padding.right + 12,
                  math.max(media.padding.bottom, media.viewInsets.bottom) + 12,
                ),
              ),
              child: CustomPaint(
                painter: _PopupSurface(
                  (source ?? anchor).size,
                  progress,
                  colors.surface,
                  colors.outlineVariant,
                ),
                child: ClipRRect(
                  key: ValueKey('strategy-reveal-$name'),
                  clipper: _PopupClip((source ?? anchor).size, progress),
                  child: StrategyPopup(
                    controller: strategies,
                    name: name,
                    generation: generation,
                    storageEpoch: storageEpoch,
                    anchored: _height != null,
                    progress: progress,
                    sourceWidth: (source ?? anchor).width,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _PopupPosition extends SingleChildLayoutDelegate {
  _PopupPosition({
    required this.anchor,
    required this.padding,
    required this.progress,
    required this.height,
    required this.onMeasured,
  });
  final double? height;
  final ValueChanged<double> onMeasured;
  final Rect anchor;
  final EdgeInsets padding;
  final double progress;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width = math.min(
      420.0,
      math.max(0.0, constraints.maxWidth - padding.horizontal),
    );
    final maximum = math.min(
      600.0,
      math.max(0.0, constraints.maxHeight - padding.vertical),
    );
    return BoxConstraints(
      minWidth: width,
      maxWidth: width,
      minHeight: height == null ? 0 : math.min(height!, maximum),
      maxHeight: height == null ? maximum : math.min(height!, maximum),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    onMeasured(childSize.height);
    final target = Offset(
      anchor.left.clamp(
        padding.left,
        math.max(padding.left, size.width - padding.right - childSize.width),
      ),
      anchor.top.clamp(
        padding.top,
        math.max(padding.top, size.height - padding.bottom - childSize.height),
      ),
    );
    return Offset.lerp(anchor.topLeft, target, progress)!;
  }

  @override
  bool shouldRelayout(_PopupPosition oldDelegate) =>
      height != oldDelegate.height ||
      anchor != oldDelegate.anchor ||
      padding != oldDelegate.padding ||
      progress != oldDelegate.progress;
}

class _PopupClip extends CustomClipper<RRect> {
  const _PopupClip(this.source, this.progress);
  final Size source;
  final double progress;
  @override
  RRect getClip(Size size) => RRect.fromRectAndRadius(
    Offset.zero & Size.lerp(source, size, progress)!,
    Radius.circular(13 + 3 * progress),
  );
  @override
  bool shouldReclip(_PopupClip oldClipper) =>
      source != oldClipper.source || progress != oldClipper.progress;
}

class _PopupSurface extends CustomPainter {
  const _PopupSurface(this.source, this.progress, this.surface, this.outline);
  final Size source;
  final double progress;
  final Color surface;
  final Color outline;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = _PopupClip(source, progress).getClip(size);
    canvas.drawShadow(
      Path()..addRRect(rect),
      Colors.black.withValues(alpha: .24 * progress),
      12 * progress,
      true,
    );
    canvas.drawRRect(rect, Paint()..color = surface);
    canvas.drawRRect(
      rect,
      Paint()
        ..color = outline.withValues(alpha: .7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = .7,
    );
  }

  @override
  bool shouldRepaint(_PopupSurface oldDelegate) =>
      source != oldDelegate.source ||
      progress != oldDelegate.progress ||
      surface != oldDelegate.surface ||
      outline != oldDelegate.outline;
}
