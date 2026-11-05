import '../locale/model_text.dart';
import '../locale/message_text.dart';

import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../navigation/task_activity.dart';
import '../theme/app_theme.dart';

import 'delay_test_controller.dart';
import '../../model/app_message.dart';
import '../../model/delay_result.dart';
import 'strategy_controller.dart';
import '../../model/strategy_snapshot.dart';
import '../components/feedback/operation_feedback.dart';
import '../components/feedback/operation_notice.dart';
import '../components/reading/provenance_details.dart';
import '../../l10n/app_localizations.dart';
import 'strategy_icon.dart';
import 'strategy_card_status.dart';

part 'strategy_popup_content.dart';

Future<void> showStrategyPopup({
  required BuildContext context,
  BuildContext? ownerContext,
  required StrategyController controller,
  required String name,
}) async {
  final owner = ownerContext ?? context;
  if (!context.mounted || !owner.mounted) return;
  final sourceRoute = ModalRoute.of(context);
  if (!identical(sourceRoute, ModalRoute.of(owner)) ||
      !identical(
        context.getElementForInheritedWidgetOfExactType<AppTaskActivity>(),
        owner.getElementForInheritedWidgetOfExactType<AppTaskActivity>(),
      )) {
    return;
  }
  final taskCurrent = AppTaskActivity.capture(owner);
  if (!controller.active ||
      !taskCurrent() ||
      !AppTaskActivity.routeIsActive(sourceRoute)) {
    return;
  }
  final navigator = Navigator.of(context, rootNavigator: true);
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  final box = context.findRenderObject()! as RenderBox;
  final focus = FocusManager.instance.primaryFocus;
  final route = _StrategyPopupRoute(
    sourceRoute: sourceRoute,
    taskCurrent: taskCurrent,
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
      controller.active &&
      controller.app.storageEpoch == route.storageEpoch &&
      controller.app.state.core.matchesIdentity(route.sourceCore) &&
      taskCurrent() &&
      AppTaskActivity.routeIsActive(sourceRoute) &&
      focus?.context?.mounted == true &&
      focus!.canRequestFocus) {
    focus.requestFocus();
  }
}

class _StrategyPopupRoute extends PopupRoute<void> {
  _StrategyPopupRoute({
    required this.sourceRoute,
    required this.taskCurrent,
    required this.anchorBox,
    required this.anchor,
    required this.strategies,
    required this.name,
    required this.generation,
    required this.storageEpoch,
    required this.reducedMotion,
    required this.barrierLabel,
  }) : sourceCore = strategies.app.state.core;

  final ModalRoute<dynamic>? sourceRoute;
  final bool Function({Route<dynamic>? ownedPopup}) taskCurrent;
  final CoreSnapshot sourceCore;
  final _interactive = ValueNotifier(true);

  bool ownerCurrent({ModalRoute<dynamic>? feedback}) =>
      _interactive.value &&
      isActive &&
      (isCurrent || feedback != null) &&
      animation?.status != AnimationStatus.reverse &&
      strategies.active &&
      taskCurrent(ownedPopup: feedback ?? this) &&
      AppTaskActivity.routeIsActive(
        sourceRoute,
        ownedPopup: feedback ?? this,
      ) &&
      AppTaskActivity.routeIsActive(this, ownedPopup: feedback);

  @override
  bool didPop(void result) {
    _interactive.value = false;
    return super.didPop(result);
  }

  @override
  void dispose() {
    _interactive.dispose();
    super.dispose();
  }

  bool _canReturnToSource = true;
  double? _fallbackReverseStart;
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
    return OperationNoticeHost(
      shrinkWrap: true,
      child: AnimatedBuilder(
        animation: Listenable.merge([animation, strategies, _interactive]),
        builder: (context, _) {
          final media = MediaQuery.of(context);
          final interactive = ownerCurrent();
          return LayoutBuilder(
            builder: (context, constraints) {
              final geometry = (
                constraints.biggest,
                media.textScaler.scale(14),
              );
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
              // Never collapse into a moved or retired card. The same popup still
              // leaves continuously on its own surface, without adding a second
              // animation to the valid card morph or waiting to revoke actions.
              final fallback =
                  !animate &&
                  !media.disableAnimations &&
                  animation.status == AnimationStatus.reverse;
              if (fallback) _fallbackReverseStart ??= animation.value;
              final opacity = fallback
                  ? (animation.value / math.max(_fallbackReverseStart!, .0001))
                        .clamp(0.0, 1.0)
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
                    math.max(media.padding.bottom, media.viewInsets.bottom) +
                        12,
                  ),
                ),
                child: Opacity(
                  key: ValueKey('strategy-fallback-opacity-$name'),
                  opacity: opacity,
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
                      child: ExcludeSemantics(
                        excluding: !interactive,
                        child: ExcludeFocus(
                          excluding: !interactive,
                          child: IgnorePointer(
                            ignoring: !interactive,
                            child: StrategyPopup(
                              controller: strategies,
                              name: name,
                              generation: generation,
                              storageEpoch: storageEpoch,
                              anchored: _height != null,
                              progress: progress,
                              sourceWidth: (source ?? anchor).width,
                              active: _interactive,
                              isCurrent: (feedback) =>
                                  ownerCurrent(feedback: feedback),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
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
