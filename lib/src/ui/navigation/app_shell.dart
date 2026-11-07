import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../components/feedback/operation_feedback.dart';
import '../components/feedback/operation_notice.dart';
import '../configs/configs_page.dart';
import '../connections/connections_page.dart';
import '../overview/overview_page.dart';
import '../settings/settings_page.dart';
import '../settings/core_cleanup_action.dart';
import '../locale/message_text.dart';
import '../../model/messages.dart';
import '../../l10n/app_localizations.dart';
import '../strategies/strategies_page.dart';
import '../strategies/strategy_controller.dart';
import 'page_route.dart';
import 'route_observer.dart';
import 'task_activity.dart';
import 'task_pane.dart';
import 'workspace_layout.dart';
import 'workspace_routes.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});
  final AppController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late StrategyController strategies;
  final _navigator = GlobalKey<NavigatorState>();
  late final _routes = WorkspaceRoutes(_routesChanged);
  void _open(AppTask task) {
    if (!mounted ||
        !widget.controller.interactive ||
        !AppTaskActivity.routeIsActive(ModalRoute.of(context))) {
      return;
    }
    unawaited(_openTask(widget.controller, task));
  }

  void _openFrom(
    AppTask source,
    AppTask task,
    Route<dynamic>? root,
    Route<dynamic>? outer,
  ) {
    if (!_taskActive(source, root: root, outer: outer)) return;
    _open(task);
  }

  final _history = [AppTask.overview];
  AppTask get _task => _history.last;
  bool _overviewScheduled = false;
  bool _openingOverview = false;
  bool _focused = false;
  WorkspaceLayout? _railLayout;
  WorkspaceLayout? _barLayout;
  bool _rail = false;
  Object? _recoverySource;
  Object? _recoveryTicket;
  bool _recoveryDismissed = false;
  ModalRoute<dynamic>? _recoveryDialog;

  Object get _currentRecoverySource => (
    widget.controller,
    widget.controller.storageEpoch,
    widget.controller.state.generation,
    widget.controller.state.core.identity,
  );

  void _scheduleRecovery(BuildContext noticeContext) {
    final app = widget.controller;
    if (!app.state.recoveryRequired) {
      _recoverySource = null;
      _recoveryTicket = null;
      _recoveryDismissed = false;
      return;
    }
    final source = _currentRecoverySource;
    if (_recoverySource != source) {
      _recoverySource = source;
      _recoveryTicket = null;
      _recoveryDismissed = false;
    }
    bool canPresent() =>
        mounted &&
        noticeContext.mounted &&
        app.interactive &&
        identical(widget.controller, app) &&
        AppTaskActivity.isActive(noticeContext) &&
        AppTaskActivity.routeIsActive(ModalRoute.of(noticeContext)) &&
        _routes.stack.lastOrNull is! PopupRoute<dynamic>;
    if (!canPresent()) return;
    if (_recoveryDismissed || _recoveryTicket != null) return;
    final ticket = _recoveryTicket = Object();
    bool current() =>
        mounted &&
        noticeContext.mounted &&
        _recoveryTicket == ticket &&
        source == _currentRecoverySource &&
        app.state.recoveryRequired;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!current()) {
        if (_recoveryTicket == ticket) _recoveryTicket = null;
        return;
      }
      unawaited(
        showLocalizedOperationNotice(
          noticeContext,
          (strings) => strings.coreInterruptedTitle,
          identity: ticket,
          eligibilityChanges: Listenable.merge([app, _routes]),
          isCurrent: current,
          canPresent: canPresent,
          isCurrentWithPopup: (popup) =>
              mounted &&
              source == _currentRecoverySource &&
              app.state.recoveryRequired &&
              app.interactive &&
              AppTaskActivity.isActive(noticeContext, ownedPopup: popup) &&
              AppTaskActivity.routeIsActive(
                ModalRoute.of(noticeContext),
                ownedPopup: popup,
              ),
          onDetails: () async {
            if (!current()) return;
            _recoveryDismissed = true;
            await _showRecovery(noticeContext, source);
          },
          onClosed: (reason) {
            if (_recoveryTicket != ticket) return;
            _recoveryTicket = null;
            if (reason == SnackBarClosedReason.action ||
                reason == SnackBarClosedReason.dismiss ||
                reason == SnackBarClosedReason.swipe) {
              _recoveryDismissed = true;
            }
          },
        ).then((presented) {
          if (!presented && _recoveryTicket == ticket) _recoveryTicket = null;
        }),
      );
    });
  }

  Future<void> _showRecovery(BuildContext noticeContext, Object source) async {
    final app = widget.controller;
    if (!noticeContext.mounted ||
        source != _currentRecoverySource ||
        !app.state.recoveryRequired) {
      return;
    }
    final origin = ModalRoute.of(noticeContext);
    final navigator = Navigator.of(noticeContext, rootNavigator: true);
    late DialogRoute<String> dialog;
    var retired = false;
    var closing = false;
    var dismissalScheduled = false;
    bool current(ModalRoute<dynamic> popup) =>
        !retired &&
        mounted &&
        noticeContext.mounted &&
        source == _currentRecoverySource &&
        app.state.recoveryRequired &&
        app.interactive &&
        AppTaskActivity.isActive(noticeContext, ownedPopup: popup) &&
        AppTaskActivity.routeIsActive(origin, ownedPopup: popup);
    void check() {
      if (closing) {
        if (source != _currentRecoverySource || !app.state.recoveryRequired) {
          retired = true;
        }
        return;
      }
      if (dialog.animation?.status == AnimationStatus.reverse) return;
      final popup = AppTaskNavigatorObserver.coveringPopup(dialog) ?? dialog;
      if (current(popup)) return;
      retired = true;
      if (dismissalScheduled) return;
      dismissalScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!navigator.mounted || !dialog.isActive) return;
        if (dialog.isCurrent) {
          navigator.pop();
        } else {
          navigator.removeRoute(dialog);
        }
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    }

    final changes = Listenable.merge([
      app,
      _routes,
      AppTaskNavigatorObserver.changesFor(origin),
    ]);
    dialog = DialogRoute<String>(
      context: noticeContext,
      themes: InheritedTheme.capture(
        from: noticeContext,
        to: navigator.context,
      ),
      animationStyle: MediaQuery.disableAnimationsOf(noticeContext)
          ? AnimationStyle.noAnimation
          : null,
      builder: (context) {
        ModalRoute.isCurrentOf(context);
        return ListenableBuilder(
          listenable: changes,
          builder: (context, _) {
            check();
            final active = current(dialog);
            final strings = AppLocalizations.of(context);
            void close([String? action]) {
              if (!current(dialog)) return;
              closing = true;
              navigator.pop(action);
            }

            return IgnorePointer(
              ignoring: !active,
              child: ExcludeFocus(
                excluding: !active,
                child: ExcludeSemantics(
                  excluding: !active,
                  child: AlertDialog(
                    key: const ValueKey('overview-core-recovery'),
                    scrollable: true,
                    title: Text(strings.coreInterruptedTitle),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SelectableText(strings.coreInterruptedMessage),
                        for (final text in {
                          for (final error in [
                            app.errorMessage,
                            app.state.errorMessage,
                            app.state.modeErrorMessage,
                            if (!app.state.resultSuccess)
                              app.state.resultMessageDescription,
                          ].whereType<AppMessage>())
                            error.resolve(strings),
                        }) ...[
                          const SizedBox(height: 12),
                          SelectableText(text),
                        ],
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed: active && app.canEdit && !app.busy
                                  ? () => close('restart')
                                  : null,
                              icon: const Icon(Icons.restart_alt),
                              label: Text(strings.coreRecoveryRestart),
                            ),
                            TextButton(
                              onPressed: active ? () => close('select') : null,
                              child: Text(strings.coreRecoverySelect),
                            ),
                          ],
                        ),
                        CoreCleanupAction(
                          app: app,
                          request: const {},
                          enabled: active,
                          isCurrent: () => current(dialog),
                          isCurrentWithPopup: current,
                          title: (strings) => strings.coreCleanupSelect,
                          description: (strings) =>
                              strings.coreCleanupSelectionNotice,
                          icon: Icons.delete_sweep_outlined,
                        ),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: active ? close : null,
                        child: Text(strings.close),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    _recoveryDialog = dialog;
    changes.addListener(check);
    final String? action;
    try {
      action = await navigator.push(dialog);
      await dialog.completed;
    } finally {
      changes.removeListener(check);
      if (identical(_recoveryDialog, dialog)) _recoveryDialog = null;
    }
    if (retired ||
        !mounted ||
        !noticeContext.mounted ||
        source != _currentRecoverySource ||
        !app.state.recoveryRequired ||
        !app.interactive) {
      return;
    }
    if (action == 'restart' && app.canEdit && !app.busy) {
      await app.submit({
        'action': 'start',
        'vpnIntent': app.state.vpnIntent || !app.state.lanIntent,
      });
    } else if (action == 'select') {
      await _openTask(app, AppTask.configurations);
    }
  }

  void _openNavigation(AppTask task, {required bool rail}) {
    if (_focused ||
        _rail != rail ||
        _routes.stack.isEmpty ||
        !AppTaskActivity.routeIsActive(_routes.stack.first)) {
      return;
    }
    _open(task);
  }

  @override
  void initState() {
    super.initState();
    strategies = StrategyController(widget.controller);
    widget.controller.addListener(_readOverviewRequest);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _readOverviewRequest();
    });
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    oldWidget.controller.removeListener(_readOverviewRequest);
    strategies.dispose();
    strategies = StrategyController(widget.controller);
    _overviewScheduled = false;
    widget.controller.addListener(_readOverviewRequest);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _readOverviewRequest();
    });
  }

  void _routesChanged() {
    final focused = _routes.stack.any((route) => route is FocusedPageRoute);
    if (mounted && focused != _focused) setState(() => _focused = focused);
    if (mounted && widget.controller.state.recoveryRequired) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  void _readOverviewRequest() {
    if (!widget.controller.interactive) return;
    final app = widget.controller;
    if (!app.takeOverviewRequest()) return;
    if (_openingOverview || _overviewScheduled) return;
    _overviewScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(widget.controller, app)) return;
      _overviewScheduled = false;
      unawaited(_openTask(app, AppTask.overview, system: true));
    });
  }

  Route<dynamic>? _topRoute(NavigatorState navigator) {
    Route<dynamic>? top;
    navigator.popUntil((route) {
      top = route;
      return true;
    });
    return top;
  }

  Future<bool> _unwind(
    AppController app,
    NavigatorState navigator,
    Route<dynamic> root,
  ) async {
    while (mounted && root.isActive && identical(widget.controller, app)) {
      final top = _topRoute(navigator);
      if (top == null) return false;
      if (identical(top, root)) return true;
      final leave = app.overviewLeaveFor(top);
      if (leave != null) {
        if (!await leave()) return false;
      } else {
        final hadLocalHistory = top.willHandlePopInternally;
        await navigator.maybePop<void>();
        if (mounted &&
            hadLocalHistory &&
            top.isActive &&
            !top.willHandlePopInternally &&
            identical(_topRoute(navigator), top)) {
          await WidgetsBinding.instance.endOfFrame;
          if (!mounted ||
              !top.isActive ||
              !identical(_topRoute(navigator), top)) {
            return false;
          }
          continue;
        }
      }
      if (!mounted || top.isActive) return false;
    }
    return false;
  }

  Future<void> _openTask(
    AppController app,
    AppTask task, {
    bool system = false,
  }) async {
    if (_openingOverview || !mounted) return;
    _openingOverview = true;
    try {
      final outer = Navigator.of(context);
      final outerRoot = ModalRoute.of(context);
      final navigator = _navigator.currentState;
      final root = _routes.stack.firstOrNull;
      if (outerRoot == null || navigator == null || root == null) return;
      bool select() {
        if (!mounted ||
            !identical(widget.controller, app) ||
            !app.interactive ||
            !identical(outerRoot.navigator, outer) ||
            !identical(_navigator.currentState, navigator) ||
            !identical(root.navigator, navigator) ||
            !identical(_routes.stack.firstOrNull, root) ||
            !AppTaskActivity.routeIsActive(outerRoot) ||
            !AppTaskActivity.routeIsActive(root)) {
          return false;
        }
        setState(() {
          if (system) _history.clear();
          if (_history.isEmpty || _task != task) _history.add(task);
        });
        return true;
      }

      // Switch tasks synchronously when both Navigators are at their roots; disable
      // old-task actions and start the transition in the first frame.
      if (select()) return;
      if (!await _unwind(app, outer, outerRoot)) return;
      if (!await _unwind(app, navigator, root)) return;
      select();
    } finally {
      _openingOverview = false;
    }
  }

  bool _taskActive(
    AppTask task, {
    required Route<dynamic>? outer,
    Route<dynamic>? root,
    Route<dynamic>? ownedPopup,
    bool requireInteraction = true,
  }) =>
      mounted &&
      _task == task &&
      widget.controller.foreground &&
      (!requireInteraction || widget.controller.interactive) &&
      AppTaskActivity.routeIsActive(outer, ownedPopup: ownedPopup) &&
      _routes.stack.isNotEmpty &&
      identical(root, _routes.stack.first) &&
      AppTaskActivity.routeIsActive(root, ownedPopup: ownedPopup);

  bool _taskSourceCurrent(
    AppController app,
    AppTask task, {
    required Route<dynamic>? outer,
    required NavigatorState? outerNavigator,
    required Route<dynamic>? root,
    required NavigatorState? innerNavigator,
  }) =>
      mounted &&
      identical(widget.controller, app) &&
      _task == task &&
      outer != null &&
      outerNavigator != null &&
      outerNavigator.mounted &&
      identical(outer.navigator, outerNavigator) &&
      root != null &&
      innerNavigator != null &&
      innerNavigator.mounted &&
      identical(_navigator.currentState, innerNavigator) &&
      identical(root.navigator, innerNavigator) &&
      identical(_routes.stack.firstOrNull, root) &&
      AppTaskNavigatorObserver.isCurrentPage(outer) &&
      AppTaskNavigatorObserver.isCurrentPage(root);

  bool _pagePresent(Route<dynamic>? root) =>
      mounted &&
      widget.controller.foreground &&
      identical(root, _routes.stack.firstOrNull) &&
      root != null &&
      AppTaskNavigatorObserver.isCurrentPage(root) &&
      AppTaskNavigatorObserver.isCurrentPage(ModalRoute.of(context));

  Widget _pages(bool active, Route<dynamic>? root) {
    // A page covered by its own popup can still receive results; check underlying page
    // interaction separately.
    final outer = ModalRoute.of(context);
    final outerNavigator = outer?.navigator;
    final innerNavigator = _navigator.currentState;
    final app = widget.controller;
    final present = _pagePresent(root);
    return PopScope<void>(
      canPop: _history.length == 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!mounted ||
            !identical(root, _routes.stack.firstOrNull) ||
            !AppTaskActivity.routeIsActive(root)) {
          return;
        }
        if (!didPop &&
            _routes.stack.firstOrNull?.willHandlePopInternally == true) {
          _navigator.currentState!.pop();
        } else if (!didPop && _history.length > 1) {
          setState(() => _history.removeLast());
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          for (final task in AppTask.values)
            TaskPane(
              key: ValueKey(task),
              selected: _task == task,
              active: active && _task == task,
              isActiveNow: () => _taskActive(task, root: root, outer: outer),
              isVisibleNow: () => _taskActive(
                task,
                root: root,
                outer: outer,
                requireInteraction: false,
              ),
              isActiveWithPopup: (popup) => _taskActive(
                task,
                root: root,
                outer: outer,
                ownedPopup: popup,
              ),
              isSourceCurrent: () => _taskSourceCurrent(
                app,
                task,
                outer: outer,
                outerNavigator: outerNavigator,
                root: root,
                innerNavigator: innerNavigator,
              ),
              child: switch (task) {
                AppTask.overview => OverviewPage(
                  controller: widget.controller,
                  active: present && _task == task,
                  onOpenTask: (target) => _openFrom(task, target, root, outer),
                ),
                AppTask.strategies => StrategiesPage(
                  controller: strategies,
                  active: present && _task == task,
                ),
                AppTask.connections => ConnectionsPage(
                  app: widget.controller,
                  active: present && _task == task,
                  embedded: true,
                ),
                AppTask.configurations => ConfigsPage(
                  controller: widget.controller,
                  active: present && _task == task,
                ),
                AppTask.settings => SettingsPage(
                  app: widget.controller,
                  active: present && _task == task,
                  onOpenTask: (target) => _openFrom(task, target, root, outer),
                ),
              },
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final outer = ModalRoute.of(context);
    final outerNavigator = outer?.navigator;
    final app = widget.controller;
    bool sourceCurrent() =>
        mounted &&
        identical(widget.controller, app) &&
        outer != null &&
        outerNavigator != null &&
        outerNavigator.mounted &&
        identical(outer.navigator, outerNavigator) &&
        AppTaskNavigatorObserver.isCurrentPage(outer);
    bool current({Route<dynamic>? ownedPopup}) =>
        mounted &&
        identical(widget.controller, app) &&
        app.interactive &&
        AppTaskActivity.isActive(context, ownedPopup: ownedPopup) &&
        AppTaskActivity.routeIsActive(outer, ownedPopup: ownedPopup);
    bool activeNow() => current();
    bool activeWithPopup(Route<dynamic> popup) => current(ownedPopup: popup);
    return RouteStatusBuilder(
      animation: outer?.animation ?? const AlwaysStoppedAnimation<double>(1),
      builder: (context) => ListenableBuilder(
        listenable: app,
        builder: (context, child) => AppTaskActivity(
          active: current(),
          isActiveNow: activeNow,
          isActiveWithPopup: activeWithPopup,
          isSourceCurrent: sourceCurrent,
          isVisibleNow: () =>
              mounted &&
              identical(widget.controller, app) &&
              app.foreground &&
              AppTaskActivity.isVisible(context) &&
              AppTaskActivity.routeIsActive(outer),
          child: child!,
        ),
        child: Builder(builder: _workspace),
      ),
    );
  }

  Widget _workspace(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final labels = WorkspaceLayout.navigationLabels(context);
    final icons = {
      AppTask.overview: (
        Icons.home_outlined,
        Icons.home_rounded,
        colors.primary,
      ),
      AppTask.strategies: (
        Icons.alt_route_outlined,
        Icons.alt_route_rounded,
        colors.secondary,
      ),
      AppTask.connections: (
        Icons.swap_vert_outlined,
        Icons.swap_vert_rounded,
        colors.secondary,
      ),
      AppTask.configurations: (
        Icons.description_outlined,
        Icons.description_rounded,
        colors.tertiary,
      ),
      AppTask.settings: (
        Icons.settings_outlined,
        Icons.settings_rounded,
        colors.tertiary,
      ),
    };
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = WorkspaceLayout.of(context, constraints.biggest);
        _rail = layout.rail;
        if (layout.rail) {
          _railLayout = layout;
        } else {
          _barLayout = layout;
        }
        // Retain only navigation controls for the exit animation; business pages and
        // the inner Navigator keep the same subtree.
        final railLayout = _railLayout ?? layout;
        final barLayout = _barLayout ?? layout;
        int selected(WorkspaceLayout layout) => layout.tasks.contains(_task)
            ? layout.tasks.indexOf(_task)
            : layout.tasks.length - 1;
        final showNavigation = !_focused;
        final showRail = showNavigation && layout.rail;
        final showBar = showNavigation && !layout.rail;
        final padding = MediaQuery.paddingOf(context);
        final reducedMotion = MediaQuery.disableAnimationsOf(context);
        final duration = reducedMotion
            ? Duration.zero
            : const Duration(milliseconds: 200);
        final navigationWidth = railLayout.navigationWidth;
        final barWidth = layout.rail
            ? constraints.maxWidth
            : layout.navigationWidth + padding.horizontal;
        final barHeight = barLayout.navigationHeight + padding.bottom;
        return TweenAnimationBuilder<double>(
          tween: Tween(end: showBar ? barHeight : 0),
          duration: duration,
          curve: Curves.easeInOutCubic,
          builder: (context, value, child) {
            final extent = (reducedMotion ? (showBar ? barHeight : 0.0) : value)
                .clamp(
                  0.0,
                  (constraints.maxHeight -
                          (layout.compact
                              ? 1
                              : WorkspaceLayout.minimumBodyHeight))
                      .clamp(0.0, constraints.maxHeight),
                );
            return Scaffold(
              body: SafeArea(
                top: false,
                child: Row(
                  children: [
                    TweenAnimationBuilder<double>(
                      key: const ValueKey('navigation-rail-extent'),
                      tween: Tween(end: showRail ? navigationWidth : 0),
                      duration: duration,
                      curve: Curves.easeInOutCubic,
                      builder: (context, value, child) => SizedBox(
                        width:
                            (reducedMotion
                                    ? (showRail ? navigationWidth : 0.0)
                                    : value)
                                .clamp(
                                  0.0,
                                  (constraints.maxWidth -
                                          padding.horizontal -
                                          WorkspaceLayout.minimumContentWidth)
                                      .clamp(0.0, constraints.maxWidth),
                                ),
                        child: ClipRect(
                          child: OverflowBox(
                            alignment: AlignmentDirectional.centerStart,
                            minWidth: navigationWidth,
                            maxWidth: navigationWidth,
                            child: (!reducedMotion && value > 0) || showRail
                                ? child
                                : null,
                          ),
                        ),
                      ),
                      child: NavigationActivity(
                        active: showRail,
                        child: SafeArea(
                          child: SizedBox(
                            width: railLayout.navigationWidth,
                            child: LayoutBuilder(
                              builder: (context, railConstraints) =>
                                  NavigationRail(
                                    groupAlignment: 0,
                                    minWidth: railLayout.navigationWidth,
                                    scrollable: true,
                                    selectedLabelTextStyle:
                                        WorkspaceLayout.navigationLabelStyle(
                                          context,
                                          rail: true,
                                          selected: true,
                                        ),
                                    unselectedLabelTextStyle:
                                        WorkspaceLayout.navigationLabelStyle(
                                          context,
                                          rail: true,
                                          selected: false,
                                        ),
                                    selectedIndex: selected(railLayout),
                                    onDestinationSelected: (index) =>
                                        _openNavigation(
                                          railLayout.tasks[index],
                                          rail: true,
                                        ),
                                    labelType: NavigationRailLabelType.all,
                                    destinations: [
                                      for (final task in railLayout.tasks)
                                        NavigationRailDestination(
                                          padding: EdgeInsets.symmetric(
                                            vertical:
                                                railLayout.destinationPadding,
                                          ),
                                          icon: Icon(
                                            icons[task]!.$1,
                                            color: icons[task]!.$3,
                                          ),
                                          selectedIcon: Icon(
                                            icons[task]!.$2,
                                            color: icons[task]!.$3,
                                          ),
                                          label: Text(labels[task]!),
                                        ),
                                    ],
                                  ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      key: const ValueKey('app-pages'),
                      child: OperationNoticeHost(
                        child: ListenableBuilder(
                          listenable: Listenable.merge([
                            widget.controller,
                            AppTaskNavigatorObserver.changesFor(
                              ModalRoute.of(this.context),
                            ),
                          ]),
                          builder: (noticeContext, _) {
                            _scheduleRecovery(noticeContext);
                            return AppTaskScope(
                              open: _open,
                              task: _task,
                              owner: widget.controller,
                              child: OperationFeedback(
                                controller: widget.controller,
                                child: NavigatorPopHandler<Object?>(
                                  onPopWithResult: (result) =>
                                      _navigator.currentState?.maybePop(result),
                                  child: Semantics(
                                    container: true,
                                    explicitChildNodes: true,
                                    child: Navigator(
                                      key: _navigator,
                                      observers: [_routes],
                                      onGenerateRoute: (_) => MaterialPageRoute<void>(
                                        builder: (context) {
                                          AppTaskScope.maybeOf(context);
                                          final root = ModalRoute.of(context)!;
                                          return ListenableBuilder(
                                            listenable: Listenable.merge([
                                              widget.controller,
                                              _routes,
                                              AppTaskNavigatorObserver.changesFor(
                                                ModalRoute.of(this.context),
                                              ),
                                            ]),
                                            builder: (context, _) =>
                                                RouteStatusBuilder(
                                                  animation: root.animation!,
                                                  builder: (context) => _pages(
                                                    AppTaskActivity.isActive(
                                                          context,
                                                        ) &&
                                                        AppTaskActivity.routeIsActive(
                                                          root,
                                                        ),
                                                    root,
                                                  ),
                                                ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Scaffold checks only for non-null when consuming the body's bottom
              // padding.
              bottomNavigationBar: extent == 0 && !showBar
                  ? null
                  : SizedBox(
                      key: const ValueKey('navigation-bar-extent'),
                      height: extent,
                      child: ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.bottomCenter,
                          minHeight: barHeight,
                          maxHeight: barHeight,
                          child: (!reducedMotion && value > 0) || showBar
                              ? child
                              : null,
                        ),
                      ),
                    ),
            );
          },
          child: NavigationActivity(
            active: showBar,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: barWidth,
                child: NavigationBar(
                  height: barLayout.navigationHeight,
                  labelTextStyle: WidgetStateProperty.resolveWith(
                    (states) => WorkspaceLayout.navigationLabelStyle(
                      context,
                      rail: false,
                      selected: states.contains(WidgetState.selected),
                    ),
                  ),
                  labelBehavior: barLayout.compact
                      ? NavigationDestinationLabelBehavior.alwaysHide
                      : NavigationDestinationLabelBehavior.alwaysShow,
                  selectedIndex: selected(barLayout),
                  onDestinationSelected: (index) =>
                      _openNavigation(barLayout.tasks[index], rail: false),
                  destinations: [
                    for (final task in barLayout.tasks)
                      NavigationDestination(
                        icon: Icon(icons[task]!.$1, color: icons[task]!.$3),
                        selectedIcon: Icon(
                          icons[task]!.$2,
                          color: icons[task]!.$3,
                        ),
                        label: labels[task]!,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_readOverviewRequest);
    strategies.dispose();
    super.dispose();
  }
}
