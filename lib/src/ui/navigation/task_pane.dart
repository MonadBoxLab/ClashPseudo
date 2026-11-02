import 'package:flutter/material.dart';

import 'task_activity.dart';

class TaskPane extends StatelessWidget {
  const TaskPane({
    super.key,
    required this.selected,
    required this.active,
    required this.isActiveNow,
    required this.isActiveWithPopup,
    required this.isSourceCurrent,
    required this.child,
  });

  final bool selected;
  final bool active;
  final bool Function() isActiveNow;
  final bool Function(Route<dynamic>) isActiveWithPopup;
  final bool Function() isSourceCurrent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final parentCurrent = AppTaskActivity.capture(context);
    final parentSource = AppTaskActivity.captureSource(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: selected ? 1 : 0),
      duration: reducedMotion
          ? Duration.zero
          : const Duration(milliseconds: 200),
      curve: Curves.easeInOutCubic,
      builder: (context, value, child) {
        final opacity = reducedMotion ? (selected ? 1.0 : 0.0) : value;
        return Offstage(
          offstage: !selected && opacity == 0,
          child: TickerMode(
            enabled: selected || opacity > 0,
            child: Opacity(opacity: opacity, child: child),
          ),
        );
      },
      child: AppTaskActivity(
        active: active,
        isActiveNow: () => parentCurrent() && isActiveNow(),
        isActiveWithPopup: (popup) =>
            parentCurrent(ownedPopup: popup) && isActiveWithPopup(popup),
        isSourceCurrent: () => parentSource() && isSourceCurrent(),
        child: IgnorePointer(
          ignoring: !active,
          child: ExcludeFocus(
            excluding: !active,
            child: ExcludeSemantics(excluding: !active, child: child),
          ),
        ),
      ),
    );
  }
}

class NavigationActivity extends StatelessWidget {
  const NavigationActivity({
    super.key,
    required this.active,
    required this.child,
  });

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final eligible = active && AppTaskActivity.isActive(context);
    return IgnorePointer(
      ignoring: !eligible,
      child: ExcludeFocus(
        excluding: !eligible,
        child: ExcludeSemantics(excluding: !eligible, child: child),
      ),
    );
  }
}
