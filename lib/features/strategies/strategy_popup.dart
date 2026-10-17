import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'strategy_controller.dart';
import 'strategy_snapshot.dart';
import '../../app/widgets/operation_feedback.dart';
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
                source == anchor &&
                core.generation == sourceCore.generation &&
                core.configId == sourceCore.configId &&
                core.revision == sourceCore.revision &&
                strategies.groups.any((group) => group.name == name);
            // Never collapse toward an old position or a replacement card.
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

class StrategyPopup extends StatefulWidget {
  const StrategyPopup({
    super.key,
    required this.controller,
    required this.name,
    required this.generation,
    this.progress = 1,
    this.sourceWidth = 180,
    this.anchored = false,
  });
  final StrategyController controller;
  final String name;
  final int generation;
  final double progress;
  final double sourceWidth;
  final bool anchored;

  @override
  State<StrategyPopup> createState() => _StrategyPopupState();
}

class _StrategyPopupState extends State<StrategyPopup> {
  StrategyController get controller => widget.controller;
  String get name => widget.name;
  int get generation => widget.generation;
  double get progress => widget.progress;
  double get sourceWidth => widget.sourceWidth;
  StrategySnapshot? _lastData;
  StrategyGroup? _lastGroup;
  bool _expired = false;

  final _scroll = ScrollController();
  final _viewport = GlobalKey();
  final _center = GlobalKey();
  final _rowKeys = <Object, GlobalKey>{};
  final _indices = <Key, int>{};
  List<Object> _ids = [];
  int _centerIndex = 0;

  void _anchorRows(List<Object> ids) {
    if (ids.length == _ids.length &&
        ids.indexed.every((e) => e.$2 == _ids[e.$1])) {
      return;
    }
    Object? anchor;
    double offset = 0;
    final viewport = _viewport.currentContext?.findRenderObject() as RenderBox?;
    final top = viewport?.localToGlobal(Offset.zero).dy;
    final remaining = ids.toSet();
    if (widget.anchored && _scroll.hasClients && top != null) {
      for (final id in _ids) {
        final box =
            _rowKeys[id]?.currentContext?.findRenderObject() as RenderBox?;
        if (remaining.contains(id) &&
            box != null &&
            box.hasSize &&
            box.localToGlobal(Offset.zero).dy + box.size.height > top) {
          anchor = id;
          offset = top - box.localToGlobal(Offset.zero).dy;
          break;
        }
      }
    }
    _ids = ids;
    _centerIndex = anchor == null ? 0 : ids.indexOf(anchor);
    _rowKeys.removeWhere((id, _) => !remaining.contains(id));
    _indices.clear();
    for (var i = 0; i < ids.length; i++) {
      final key = _rowKeys[ids[i]];
      if (key != null) _indices[key] = i;
    }
    if (_scroll.hasClients) _scroll.position.correctBy(offset - _scroll.offset);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _choose(String? member) {
    if (_expired ||
        _lastData?.matches(controller.app.state.core) != true ||
        controller.data?.generation != generation) {
      return;
    }
    controller.choose(name, member);
  }

  Widget _heading(
    BuildContext context,
    String type,
    String icon,
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
            Positioned(
              left: 0,
              top: 0,
              child: StrategyIcon(type: type, source: icon),
            ),
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
      final incoming = controller.data;
      final core = controller.app.state.core;
      final candidate = controller.groups
          .where((group) => group.name == name)
          .firstOrNull;
      final previous = _lastData;
      final identityChanged =
          core.generation != generation ||
          core.phase == 'EMPTY' ||
          (core.ready && previous != null && !previous.matches(core));
      if ((controller.app.platformError == null && identityChanged) ||
          (incoming?.matches(core) == true && candidate == null)) {
        _expired = true;
      }
      if (!_expired &&
          incoming?.generation == generation &&
          candidate != null) {
        _lastData = incoming;
        _lastGroup = candidate;
      }
      final data = _lastData;
      final group = _lastGroup;
      final sameContext = !_expired && data?.matches(core) == true;
      final canChoose = sameContext && controller.canChoose;
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
      final seen = <String, int>{};
      final ids = <Object>[
        'heading',
        for (final member in group?.members ?? <StrategyMember>[])
          (
            member.name,
            seen.update(member.name, (n) => n + 1, ifAbsent: () => 0),
          ),
      ];
      _anchorRows(ids);
      final header = Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => showOperationMessage(
                context,
                [
                  if (_expired) '策略已失效，请关闭后重新打开。当前内容仅供查看。',
                  ?error,
                  if (savedDiffers) '已保存：${saved.member ?? '自动'}；实际选择仍以当前标记为准。',
                  if (data?.unrestored[name] != null)
                    '原选择未恢复：${data!.unrestored[name]}',
                  if (!_expired &&
                      error == null &&
                      !savedDiffers &&
                      data?.unrestored[name] == null)
                    '当前选择以实际读取结果为准。',
                ].join('\n\n'),
                title: name,
                error: error != null || savedDiffers,
              ),
              child: _heading(
                context,
                group?.rawType ?? '',
                group?.icon ?? '',
                _expired
                    ? '已失效 · 请重新打开'
                    : waiting
                    ? '正在切换…'
                    : error != null
                    ? '更新失败 · 查看原因'
                    : savedDiffers
                    ? '保存与实际不一致 · 查看详情'
                    : data?.unrestored.containsKey(name) == true
                    ? '原选择未恢复 · 查看详情'
                    : !controller.current
                    ? '状态未更新'
                    : group == null
                    ? '正在读取策略'
                    : '${group.typeLabel} · ${group.members.length}',
                details,
              ),
            ),
            if (group?.automatic == true)
              Opacity(
                opacity: details,
                child: Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Text(
                          group!.fixed.isEmpty ? '自动' : '固定：${group.fixed}',
                          softWrap: false,
                          style: muted,
                        ),
                      ),
                    ),
                    TextButton(
                      key: const ValueKey('strategy-automatic'),
                      onPressed: canChoose ? () => _choose(null) : null,
                      child: const Text('恢复自动', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
      Widget memberRow(int index) {
        final member = group!.members[index];
        final first =
            group.members.indexWhere((value) => value.name == member.name) ==
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
        final child = isGroup ? data?.find(member.name) : null;
        final subtitle = !first
            ? '同名成员'
            : child != null
            ? (child.now.isEmpty ? child.typeLabel : child.now)
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
                  onTap: canChoose && group.selectable && first
                      ? () => _choose(member.name)
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
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                member.name,
                                style: TextStyle(
                                  fontSize: 15,
                                  height: 1.3,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 3),
                              SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Text(
                                  subtitle,
                                  softWrap: false,
                                  style: muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 40,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
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
      }

      SliverChildBuilderDelegate rows({required bool before}) {
        final count = before ? _centerIndex : ids.length - _centerIndex;
        return SliverChildBuilderDelegate(
          (context, local) {
            final index = before
                ? _centerIndex - local - 1
                : _centerIndex + local;
            final key = _rowKeys.putIfAbsent(ids[index], GlobalKey.new);
            _indices[key] = index;
            return KeyedSubtree(
              key: key,
              child: index == 0
                  ? header
                  : Padding(
                      padding: EdgeInsets.fromLTRB(
                        8,
                        0,
                        8,
                        index == ids.length - 1 ? 10 : 0,
                      ),
                      child: memberRow(index - 1),
                    ),
            );
          },
          childCount: count,
          semanticIndexCallback: (_, local) {
            final index = before
                ? _centerIndex - local - 1
                : _centerIndex + local;
            return index == 0 ? null : index - 1;
          },
          findChildIndexCallback: (key) {
            final index = _indices[key];
            if (index == null) return null;
            final local = before
                ? _centerIndex - index - 1
                : index - _centerIndex;
            return local < 0 || local >= count ? null : local;
          },
        );
      }

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
                key: _viewport,
                controller: _scroll,
                shrinkWrap: !widget.anchored,
                center: widget.anchored ? _center : null,
                semanticChildCount: ids.length - 1,
                slivers: [
                  if (widget.anchored) SliverList(delegate: rows(before: true)),
                  SliverList(key: _center, delegate: rows(before: false)),
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
