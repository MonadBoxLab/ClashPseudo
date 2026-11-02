import 'package:flutter/material.dart';

import '../../../navigation/task_activity.dart';
import 'form_body.dart';

/// Interaction is revoked at the start of a section's exit, not when its last
/// frame disappears. Validation/save still visit mounted, inactive drafts.
class DefinitionFormInteraction extends StatelessWidget {
  const DefinitionFormInteraction({
    super.key,
    required this.active,
    required this.child,
    this.isActiveNow,
    this.isActiveWithPopup,
  });

  final bool active;
  final bool Function()? isActiveNow;
  final bool Function(Route<dynamic> popup)? isActiveWithPopup;
  final Widget child;

  static bool canAct(BuildContext context, {Route<dynamic>? ownedPopup}) {
    if (!context.mounted ||
        !AppTaskActivity.isActive(context, ownedPopup: ownedPopup) ||
        !AppTaskActivity.routeIsActive(
          ModalRoute.of(context),
          ownedPopup: ownedPopup,
        )) {
      return false;
    }
    var active = true;
    context.visitAncestorElements((element) {
      if (element.widget case _DefinitionInteractionScope scope) {
        final current = ownedPopup != null && scope.isActiveWithPopup != null
            ? scope.isActiveWithPopup!(ownedPopup)
            : scope.isActiveNow?.call() ?? scope.active;
        active = active && current;
      }
      return active;
    });
    return active;
  }

  @override
  Widget build(BuildContext context) => _DefinitionInteractionScope(
    active: active,
    isActiveNow: isActiveNow,
    isActiveWithPopup: isActiveWithPopup,
    child: IgnorePointer(
      ignoring: !active,
      child: ExcludeFocus(
        excluding: !active,
        child: ExcludeSemantics(excluding: !active, child: child),
      ),
    ),
  );
}

class _DefinitionInteractionScope extends InheritedWidget {
  const _DefinitionInteractionScope({
    required this.active,
    this.isActiveNow,
    this.isActiveWithPopup,
    required super.child,
  });
  final bool active;
  final bool Function()? isActiveNow;
  final bool Function(Route<dynamic> popup)? isActiveWithPopup;

  @override
  bool updateShouldNotify(_DefinitionInteractionScope oldWidget) =>
      active != oldWidget.active;
}

/// One mounted draft tree, including while hidden. The controller reverses from
/// its current value; no outgoing copy can retain actions, focus or semantics.
class DefinitionFormVisibility extends StatefulWidget {
  const DefinitionFormVisibility({
    super.key,
    required this.visible,
    required this.child,
    this.maintainState = true,
  });

  final bool visible;
  final Widget child;
  final bool maintainState;

  @override
  State<DefinitionFormVisibility> createState() =>
      _DefinitionFormVisibilityState();
}

class _DefinitionFormVisibilityState extends State<DefinitionFormVisibility>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: widget.visible ? 1 : 0,
  );
  bool _reduced = false;

  void _target() {
    final target = widget.visible ? 1.0 : 0.0;
    if (_reduced) {
      _controller.value = target;
    } else {
      _controller.animateTo(target, curve: Curves.easeInOutCubic);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    if (_reduced != reduced) {
      _reduced = reduced;
      _target();
    }
  }

  @override
  void didUpdateWidget(DefinitionFormVisibility oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible == widget.visible) return;
    if (!widget.visible) DefinitionFormBody.unfocusWithin(context);
    _target();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: DefinitionFormInteraction(
      active: widget.visible,
      isActiveNow: () => mounted && widget.visible,
      child: widget.child,
    ),
    builder: (context, child) => Offstage(
      offstage: !widget.visible && _controller.value == 0,
      child: ClipRect(
        child: Align(
          alignment: AlignmentDirectional.topStart,
          heightFactor: _controller.value,
          child: FadeTransition(opacity: _controller, child: child),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

/// Keep the SDK expansion controller and one mounted draft body, anchored at
/// the top of its animated local clip. Collapse revokes the body immediately.
class DefinitionFormExpansion extends StatefulWidget {
  const DefinitionFormExpansion({
    super.key,
    required this.title,
    required this.children,
    this.leading,
    this.initiallyExpanded = false,
    this.onExpansionChanged,
    this.tilePadding,
    this.childrenPadding,
    this.shape,
    this.collapsedShape,
    this.maintainState = true,
  });

  final Widget title;
  final List<Widget> children;
  final Widget? leading;
  final bool initiallyExpanded;
  final ValueChanged<bool>? onExpansionChanged;
  final EdgeInsetsGeometry? tilePadding;
  final EdgeInsetsGeometry? childrenPadding;
  final ShapeBorder? shape;
  final ShapeBorder? collapsedShape;
  final bool maintainState;

  @override
  State<DefinitionFormExpansion> createState() =>
      _DefinitionFormExpansionState();
}

class _DefinitionFormExpansionState extends State<DefinitionFormExpansion> {
  late final ExpansibleController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ExpansibleController();
    if (widget.initiallyExpanded) _controller.expand();
    _controller.addListener(_changed);
  }

  void _changed() {
    if (!_controller.isExpanded) DefinitionFormBody.unfocusWithin(context);
    widget.onExpansionChanged?.call(_controller.isExpanded);
  }

  void _toggle() {
    if (!mounted || !DefinitionFormInteraction.canAct(context)) return;
    if (_controller.isExpanded) {
      _controller.collapse();
    } else {
      _controller.expand();
    }
  }

  Widget _header(BuildContext context, Animation<double> animation) {
    final theme = Theme.of(context);
    final tileTheme = ExpansionTileTheme.of(context);
    final localizations = MaterialLocalizations.of(context);
    final expanded = _controller.isExpanded;
    return Semantics(
      expanded: expanded,
      liveRegion: true,
      onTapHint: expanded
          ? localizations.expansionTileExpandedTapHint
          : localizations.expansionTileCollapsedTapHint,
      hint: expanded ? localizations.collapsedHint : localizations.expandedHint,
      child: ListTileTheme.merge(
        textColor: Color.lerp(
          tileTheme.collapsedTextColor ?? theme.colorScheme.onSurface,
          tileTheme.textColor ??
              (theme.useMaterial3
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.primary),
          Curves.easeIn.transform(animation.value),
        ),
        iconColor: Color.lerp(
          tileTheme.collapsedIconColor ?? theme.colorScheme.onSurfaceVariant,
          tileTheme.iconColor ?? theme.colorScheme.primary,
          Curves.easeIn.transform(animation.value),
        ),
        child: ListTile(
          onTap: _toggle,
          contentPadding: widget.tilePadding ?? tileTheme.tilePadding,
          leading: widget.leading,
          title: widget.title,
          trailing: RotationTransition(
            turns: AlwaysStoppedAnimation(
              Curves.easeIn.transform(animation.value) / 2,
            ),
            child: const Icon(Icons.expand_more),
          ),
        ),
      ),
    );
  }

  Widget _contents(
    BuildContext context,
    Widget header,
    Widget _,
    Animation<double> animation,
  ) {
    final theme = Theme.of(context);
    final tileTheme = ExpansionTileTheme.of(context);
    final progress = Curves.easeInOutCubic.transform(animation.value);
    final closed = !_controller.isExpanded && animation.isDismissed;
    final shape = ShapeBorder.lerp(
      widget.collapsedShape ??
          tileTheme.collapsedShape ??
          const Border(
            top: BorderSide(color: Colors.transparent),
            bottom: BorderSide(color: Colors.transparent),
          ),
      widget.shape ??
          tileTheme.shape ??
          Border(
            top: BorderSide(color: theme.dividerColor),
            bottom: BorderSide(color: theme.dividerColor),
          ),
      progress,
    )!;
    final background = Color.lerp(
      tileTheme.collapsedBackgroundColor ?? Colors.transparent,
      tileTheme.backgroundColor ?? Colors.transparent,
      progress,
    );
    return Material(
      color: background,
      shape: shape,
      clipBehavior: tileTheme.clipBehavior ?? Clip.antiAlias,
      child: Padding(
        padding: shape.dimensions,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            header,
            // Expansible's default body wrapper centers the full-height child
            // inside its shrinking clip. Keep the first field's own label
            // paint space at the top instead of translating it above that clip.
            ClipRect(
              child: Align(
                alignment: AlignmentDirectional.topStart,
                heightFactor: progress,
                child: Offstage(
                  offstage: closed,
                  child: TickerMode(
                    enabled: !closed,
                    child: DefinitionFormInteraction(
                      active: _controller.isExpanded,
                      isActiveNow: () => mounted && _controller.isExpanded,
                      child: Padding(
                        padding:
                            widget.childrenPadding ??
                            tileTheme.childrenPadding ??
                            EdgeInsets.zero,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: widget.children,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Expansible(
    controller: _controller,
    maintainState: true,
    animationStyle: AnimationStyle(
      duration:
          MediaQuery.disableAnimationsOf(context) ||
              MediaQuery.accessibleNavigationOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      curve: Curves.easeInOutCubic,
    ),
    headerBuilder: _header,
    // _contents owns the single body tree and its top-anchored local clip.
    bodyBuilder: (_, _) => const SizedBox.shrink(),
    expansibleBuilder: _contents,
  );

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.dispose();
    super.dispose();
  }
}
