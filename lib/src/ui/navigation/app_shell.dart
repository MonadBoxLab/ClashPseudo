import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../components/feedback/operation_feedback.dart';
import '../components/feedback/operation_notice.dart';
import '../configs/configs_page.dart';
import '../connections/connections_page.dart';
import '../overview/overview_page.dart';
import '../settings/settings_page.dart';
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

      // 两层 Navigator 都位于根页面时同步切换任务，首帧即停用旧任务的操作并开始切换动画。
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
  }) =>
      mounted &&
      _task == task &&
      widget.controller.interactive &&
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
      AppTaskActivity.routeIsActive(outer) &&
      AppTaskActivity.routeIsActive(root);

  bool _pagePresent(Route<dynamic>? root) =>
      mounted &&
      widget.controller.interactive &&
      identical(root, _routes.stack.firstOrNull) &&
      root != null &&
      AppTaskNavigatorObserver.isCurrentPage(root) &&
      AppTaskNavigatorObserver.isCurrentPage(ModalRoute.of(context));

  Widget _pages(bool active, Route<dynamic>? root) {
    // 页面被自己的弹窗覆盖时仍可接收操作结果；底层页面是否允许交互需要另行检查。
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
        AppTaskActivity.routeIsActive(outer);
    bool current({Route<dynamic>? ownedPopup}) =>
        mounted &&
        identical(widget.controller, app) &&
        app.interactive &&
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
        // 仅保留导航控件用于退出动画，业务页面和内部 Navigator 始终使用同一棵组件树。
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
        return AppTaskScope(
          open: _open,
          task: _task,
          owner: widget.controller,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: showBar ? barHeight : 0),
            duration: duration,
            curve: Curves.easeInOutCubic,
            builder: (context, value, child) {
              final extent =
                  (reducedMotion ? (showBar ? barHeight : 0.0) : value).clamp(
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
                        ),
                      ),
                    ],
                  ),
                ),
                // Scaffold 仅按非 null 判断是否消费 body 的底部 padding。
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
