import 'package:flutter/material.dart';

import 'route_observer.dart';

enum AppTask { overview, strategies, connections, configurations, settings }

class AppTaskScope extends InheritedWidget {
  const AppTaskScope({
    super.key,
    required this.open,
    required this.task,
    required this.owner,
    required super.child,
  });

  final ValueChanged<AppTask> open;
  final AppTask task;
  final Object owner;

  static AppTaskScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppTaskScope>();

  @override
  bool updateShouldNotify(AppTaskScope oldWidget) =>
      open != oldWidget.open ||
      task != oldWidget.task ||
      !identical(owner, oldWidget.owner);
}

/// Disables page actions on exit even while the exit animation still paints the page.
class AppTaskActivity extends InheritedWidget {
  const AppTaskActivity({
    super.key,
    required this.active,
    this.isActiveNow,
    this.isActiveWithPopup,
    this.isSourceCurrent,
    this.isVisibleNow,
    required super.child,
  });

  /// Interaction state for widget subscriptions; cached and asynchronous callbacks must
  /// recheck current state.
  final bool active;

  /// Reads current task and route interaction state without depending on a widget
  /// rebuild.
  final bool Function()? isActiveNow;

  /// The caller must provide its actual popup Route to allow that popup to cover the
  /// source page.
  final bool Function(Route<dynamic> ownedPopup)? isActiveWithPopup;

  /// Checks whether the source page awaiting a result is still valid, not whether the
  /// page or popup allows interaction.
  /// Without this callback, use current interaction state; do not treat disabled
  /// interaction as a temporary pause.
  final bool Function()? isSourceCurrent;

  /// Allows visible foreground reads while input focus is temporarily elsewhere.
  final bool Function()? isVisibleNow;

  static bool isVisible(BuildContext context) {
    if (!context.mounted) return false;
    final activity = context
        .dependOnInheritedWidgetOfExactType<AppTaskActivity>();
    return activity?.isVisibleNow?.call() ?? activity?._current() ?? true;
  }

  bool _current({Route<dynamic>? ownedPopup}) =>
      ownedPopup != null && isActiveWithPopup != null
      ? isActiveWithPopup!(ownedPopup)
      : isActiveNow?.call() ?? active;

  /// Requires the source page to be current by default; owned confirmations or forms
  /// may pass a foreground PopupRoute.
  /// Still checks task selection, interaction, source-route closure or exit, and
  /// coverage by another PageRoute.
  static bool isActive(BuildContext context, {Route<dynamic>? ownedPopup}) {
    if (!context.mounted) return false;
    return context
            .dependOnInheritedWidgetOfExactType<AppTaskActivity>()
            ?._current(ownedPopup: ownedPopup) ??
        true;
  }

  /// Captures the AppTaskActivity element while the source is mounted, avoiding
  /// ancestor lookups in later checks.
  /// Reads the element's current widget each time so interaction changes take effect
  /// immediately.
  static bool Function({Route<dynamic>? ownedPopup}) capture(
    BuildContext context,
  ) {
    if (!context.mounted) return ({Route<dynamic>? ownedPopup}) => false;
    final owner = context
        .getElementForInheritedWidgetOfExactType<AppTaskActivity>();
    if (owner != null) context.dependOnInheritedElement(owner);
    return ({Route<dynamic>? ownedPopup}) =>
        context.mounted &&
        (owner == null ||
            (owner.mounted &&
                (owner.widget as AppTaskActivity)._current(
                  ownedPopup: ownedPopup,
                )));
  }

  /// Captures the task and source page awaiting a result; later checks read only the
  /// original inherited element.
  /// Uses isSourceCurrent when provided; otherwise checks current interaction state.
  static bool Function() captureSource(BuildContext context) {
    if (!context.mounted) return () => false;
    final scopeElement = context
        .getElementForInheritedWidgetOfExactType<AppTaskScope>();
    if (scopeElement != null) context.dependOnInheritedElement(scopeElement);
    final scope = scopeElement?.widget as AppTaskScope?;
    final owner = context
        .getElementForInheritedWidgetOfExactType<AppTaskActivity>();
    if (owner != null) context.dependOnInheritedElement(owner);
    return () {
      if (!context.mounted) return false;
      if (scopeElement != null) {
        if (!scopeElement.mounted) return false;
        final currentScope = scopeElement.widget as AppTaskScope;
        if (!identical(currentScope.owner, scope!.owner) ||
            currentScope.task != scope.task) {
          return false;
        }
      }
      if (owner == null) return true;
      if (!owner.mounted) return false;
      final activity = owner.widget as AppTaskActivity;
      return activity.isSourceCurrent?.call() ?? activity._current();
    };
  }

  static bool routeIsActive(
    Route<dynamic>? route, {
    Route<dynamic>? ownedPopup,
  }) => AppTaskNavigatorObserver.routeIsActive(route, ownedPopup: ownedPopup);

  @override
  bool updateShouldNotify(AppTaskActivity oldWidget) =>
      active != oldWidget.active ||
      isActiveNow != oldWidget.isActiveNow ||
      isActiveWithPopup != oldWidget.isActiveWithPopup ||
      isVisibleNow != oldWidget.isVisibleNow ||
      isSourceCurrent != oldWidget.isSourceCurrent;
}
