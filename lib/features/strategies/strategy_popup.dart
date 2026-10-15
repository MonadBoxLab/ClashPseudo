import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'strategy_controller.dart';
import 'strategy_icon.dart';

Future<void> showStrategyPopup({
  required BuildContext context,
  required StrategyController controller,
  required String name,
}) async {
  final navigator = Navigator.of(context);
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  final box = context.findRenderObject()! as RenderBox;
  final focus = FocusManager.instance.primaryFocus;
  final route = _StrategyPopupRoute(
    anchorBox: box,
    anchor: box.localToGlobal(Offset.zero, ancestor: overlay) & box.size,
    strategies: controller,
    name: name,
    generation: controller.app.state.core.generation,
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
    required this.reducedMotion,
    required this.barrierLabel,
  });

  final RenderBox anchorBox;
  final Rect anchor;
  final StrategyController strategies;
  final String name;
  final int generation;
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
            final valid =
                source != null &&
                strategies.app.state.core.generation == generation &&
                strategies.groups.any((group) => group.name == name);
            final animate =
                valid && strategies.app.foreground && !media.disableAnimations;
            final progress = animate
                ? Curves.easeOutCubic.transform(animation.value)
                : 1.0;
            final colors = Theme.of(context).colorScheme;
            return CustomSingleChildLayout(
              delegate: _PopupPosition(
                anchor: source ?? anchor,
                progress: progress,
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
  });
  final Rect anchor;
  final EdgeInsets padding;
  final double progress;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width = math.min(
      420.0,
      math.max(0.0, constraints.maxWidth - padding.horizontal),
    );
    return BoxConstraints(
      minWidth: width,
      maxWidth: width,
      maxHeight: math.min(
        600.0,
        math.max(0.0, constraints.maxHeight - padding.vertical),
      ),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
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

class StrategyPopup extends StatelessWidget {
  const StrategyPopup({
    super.key,
    required this.controller,
    required this.name,
    required this.generation,
    this.progress = 1,
    this.sourceWidth = 180,
  });
  final StrategyController controller;
  final String name;
  final int generation;
  final double progress;
  final double sourceWidth;

  Widget _heading(
    BuildContext context,
    String type,
    String label,
    double details,
  ) => LayoutBuilder(
    builder: (context, constraints) {
      final scaler = MediaQuery.textScalerOf(context);
      final colors = Theme.of(context).colorScheme;
      final style = DefaultTextStyle.of(context).style.merge(
        TextStyle(
          fontSize: 18,
          height: 1.2,
          fontWeight: FontWeight.w600,
          color: colors.onSurface,
        ),
      );
      final width = math.max(1.0, constraints.maxWidth - 76);
      final painter = TextPainter(
        text: TextSpan(text: name, style: style),
        textDirection: Directionality.of(context),
        textScaler: scaler,
      )..layout(maxWidth: width);
      final titleHeight = painter.height;
      painter.dispose();
      final initial = TextPainter(
        text: TextSpan(text: name, style: style.copyWith(fontSize: 16)),
        maxLines: 2,
        textDirection: Directionality.of(context),
        textScaler: scaler,
      )..layout(maxWidth: math.max(1.0, sourceWidth - 28));
      final initialTop =
          40 + math.max(0.0, (24 * scaler.scale(14) / 14 - initial.height) / 2);
      initial.dispose();
      return SizedBox(
        height: math.max(30, titleHeight + 4 + scaler.scale(12) * 1.4),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(left: 0, top: 0, child: StrategyIcon(type: type)),
            Positioned(
              left: 42 * progress,
              top: initialTop * (1 - progress),
              width: (sourceWidth - 28) * (1 - progress) + width * progress,
              child: Text(
                name,
                style: style.copyWith(fontSize: 16 + 2 * progress),
              ),
            ),
            Positioned(
              left: 42,
              top: titleHeight + 4,
              right: 34,
              child: Opacity(
                opacity: details,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final data = controller.data;
      final sameContext =
          data?.generation == generation &&
          controller.app.state.core.generation == generation;
      final group = sameContext
          ? controller.groups.where((group) => group.name == name).firstOrNull
          : null;
      final colors = Theme.of(context).colorScheme;
      final saved = sameContext && data != null
          ? controller.app.collection.find(data.configId)?.choices[name]
          : null;
      final savedDiffers =
          saved != null &&
          group != null &&
          (group.automatic
              ? (saved.member ?? '') != group.fixed
              : saved.member != group.now);
      final waiting = controller.changingGroup == name;
      final error = controller.operationError ?? controller.readError;
      final showSelection =
          sameContext &&
          data?.matches(controller.app.state.core) == true &&
          controller.readError == null;
      final details = ((progress - .35) / .65).clamp(0.0, 1.0);
      final muted = TextStyle(
        fontSize: 12,
        height: 1.4,
        color: colors.onSurfaceVariant,
      );
      return Semantics(
        scopesRoute: true,
        explicitChildNodes: true,
        namesRoute: true,
        label: name,
        child: Material(
          key: ValueKey('strategy-popup-$name'),
          type: MaterialType.transparency,
          child: Stack(
            children: [
              CustomScrollView(
                shrinkWrap: true,
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _heading(
                            context,
                            group?.rawType ?? '',
                            group == null
                                ? ''
                                : '${group.typeLabel} · ${group.members.length}',
                            details,
                          ),
                          Opacity(
                            opacity: details,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (group == null)
                                  const Padding(
                                    padding: EdgeInsets.only(top: 8),
                                    child: Text('策略已更新，请重新打开。'),
                                  )
                                else ...[
                                  if (!controller.current)
                                    Text('状态未更新', style: muted),
                                  if (group.automatic)
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            group.fixed.isEmpty
                                                ? '自动'
                                                : '固定：${group.fixed}',
                                            style: muted,
                                          ),
                                        ),
                                        TextButton(
                                          key: const ValueKey(
                                            'strategy-automatic',
                                          ),
                                          onPressed: controller.canChoose
                                              ? () => controller.choose(
                                                  name,
                                                  null,
                                                )
                                              : null,
                                          child: const Text(
                                            '恢复自动',
                                            style: TextStyle(fontSize: 12),
                                          ),
                                        ),
                                      ],
                                    ),
                                  if (savedDiffers)
                                    Text(
                                      '已保存：${saved.member ?? '自动'}',
                                      style: muted,
                                    ),
                                  if (data?.unrestored.containsKey(name) ==
                                      true)
                                    Text('原选择未恢复', style: muted),
                                  if (waiting)
                                    Semantics(
                                      liveRegion: true,
                                      child: const Text('正在切换…'),
                                    ),
                                  if (error != null)
                                    Semantics(
                                      liveRegion: true,
                                      child: Text(
                                        error,
                                        style: TextStyle(color: colors.error),
                                      ),
                                    ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (group != null)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(8, 2, 8, 10),
                      sliver: SliverList.builder(
                        itemCount: group.members.length,
                        itemBuilder: (context, index) {
                          final member = group.members[index];
                          final first =
                              group.members.indexWhere(
                                (value) => value.name == member.name,
                              ) ==
                              index;
                          final selected =
                              showSelection &&
                              first &&
                              group.selectable &&
                              group.now == member.name;
                          final fixed =
                              showSelection &&
                              first &&
                              group.automatic &&
                              group.fixed == member.name;
                          final isGroup = const [
                            'select',
                            'url-test',
                            'fallback',
                            'load-balance',
                          ].contains(member.type);
                          final child = isGroup
                              ? data?.find(member.name)
                              : null;
                          final subtitle = !first
                              ? '同名成员'
                              : child != null
                              ? (child.now.isEmpty
                                    ? child.typeLabel
                                    : child.now)
                              : member.type;
                          return Opacity(
                            opacity: details,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Semantics(
                                selected: selected,
                                child: Material(
                                  color: selected
                                      ? colors.surfaceContainerHighest
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                  clipBehavior: Clip.antiAlias,
                                  child: InkWell(
                                    key: ValueKey('strategy-member-$index'),
                                    onTap:
                                        controller.canChoose &&
                                            group.selectable &&
                                            first
                                        ? () => controller.choose(
                                            name,
                                            member.name,
                                          )
                                        : null,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 10,
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  member.name,
                                                  style: TextStyle(
                                                    fontSize: 15,
                                                    height: 1.3,
                                                    fontWeight: selected
                                                        ? FontWeight.w600
                                                        : FontWeight.w500,
                                                  ),
                                                ),
                                                const SizedBox(height: 3),
                                                Text(subtitle, style: muted),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          SizedBox(
                                            width: 40,
                                            child: Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.end,
                                              children: [
                                                if (fixed)
                                                  Tooltip(
                                                    message: '已固定',
                                                    child: Icon(
                                                      Icons.push_pin_rounded,
                                                      size: 14,
                                                      color: colors.primary,
                                                    ),
                                                  ),
                                                if (selected)
                                                  Icon(
                                                    Icons.check_rounded,
                                                    size: 21,
                                                    color: colors.primary,
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
              Positioned(
                top: 2,
                right: 2,
                child: Opacity(
                  opacity: details,
                  child: IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: '关闭策略浮窗',
                    icon: Icon(
                      Icons.close_rounded,
                      size: 20,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
