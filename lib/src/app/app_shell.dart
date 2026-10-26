import 'dart:async';

import 'package:flutter/material.dart';

import '../features/configs/configs_page.dart';
import '../features/connections/connections_page.dart';
import '../features/settings/settings_page.dart';
import '../l10n/app_localizations.dart';
import '../features/overview/overview_page.dart';
import '../features/strategies/strategies_page.dart';
import '../features/strategies/strategy_controller.dart';
import 'app_controller.dart';
import 'app_task.dart';
import 'workspace_window.dart';
import 'widgets/operation_feedback.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});
  final AppController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late StrategyController strategies;
  final _navigator = GlobalKey<NavigatorState>();
  late final _routes = _WorkspaceRoutes(_routesChanged);
  void _open(AppTask task) => unawaited(_openTask(widget.controller, task));
  final _history = [AppTask.overview];
  AppTask get _task => _history.last;
  bool _overviewScheduled = false;
  bool _openingOverview = false;
  bool _supported = true;
  bool _focused = false;
  Size _lastBodySize = const Size(320, 480);

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_handleKey);
    strategies = StrategyController(widget.controller);
    widget.controller.addListener(_readOverviewRequest);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        if (WorkspaceScope.maybeOf(context) == null) {
          widget.controller.setWindowSupported(_supported);
        }
        _readOverviewRequest();
      }
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
      if (mounted) {
        if (WorkspaceScope.maybeOf(context) == null) {
          widget.controller.setWindowSupported(_supported);
        }
        _readOverviewRequest();
      }
    });
  }

  KeyEventResult _handleKey(KeyEvent event) =>
      _supported ? KeyEventResult.ignored : KeyEventResult.handled;

  void _routesChanged() {
    final focused = _routes.stack.any((route) => route is FocusedPageRoute);
    if (mounted && focused != _focused) setState(() => _focused = focused);
  }

  void _readOverviewRequest() {
    if (!_supported || !widget.controller.interactive) return;
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
    if (_openingOverview || !mounted || !_supported) return;
    _openingOverview = true;
    try {
      final outer = Navigator.of(context);
      final outerRoot = ModalRoute.of(context);
      if (outerRoot == null || !await _unwind(app, outer, outerRoot)) return;
      final navigator = _navigator.currentState;
      if (navigator == null || _routes.stack.isEmpty) return;
      if (!await _unwind(app, navigator, _routes.stack.first)) return;
      if (!mounted || !identical(widget.controller, app)) return;
      if (!_supported) {
        if (system) app.requestOverview();
        return;
      }
      setState(() {
        if (system) _history.clear();
        if (_history.isEmpty || _task != task) _history.add(task);
      });
    } finally {
      _openingOverview = false;
    }
  }

  Widget _pages() => PopScope<void>(
    canPop: _history.length == 1,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop &&
          _routes.stack.firstOrNull?.willHandlePopInternally == true) {
        _navigator.currentState!.pop();
      } else if (!didPop && _history.length > 1) {
        setState(() => _history.removeLast());
      }
    },
    child: IndexedStack(
      index: _task.index,
      children: [
        for (final task in AppTask.values)
          ExcludeFocus(
            excluding: _task != task,
            child: TickerMode(
              enabled: _task == task,
              child: switch (task) {
                AppTask.overview => OverviewPage(
                  controller: widget.controller,
                  active: _supported && _task == task,
                  onOpenTask: _open,
                ),
                AppTask.strategies => StrategiesPage(
                  controller: strategies,
                  active: _supported && _task == task,
                ),
                AppTask.connections => ConnectionsPage(
                  app: widget.controller,
                  active: _supported && _task == task,
                  embedded: true,
                ),
                AppTask.configurations => ConfigsPage(
                  controller: widget.controller,
                  active: _supported && _task == task,
                ),
                AppTask.settings => SettingsPage(
                  app: widget.controller,
                  active: _supported && _task == task,
                  onOpenTask: _open,
                ),
              },
            ),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final strings = AppLocalizations.of(context);
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
        final workspace = WorkspaceScope.maybeOf(context);
        final wasSupported = _supported;
        _supported = layout.supported && (workspace?.supported ?? true);
        if (wasSupported != _supported) {
          final supported = _supported;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _supported != supported) return;
            if (workspace == null) {
              widget.controller.setWindowSupported(supported);
            }
            if (supported) _readOverviewRequest();
          });
        }
        final selected = layout.tasks.contains(_task)
            ? layout.tasks.indexOf(_task)
            : layout.tasks.length - 1;
        final showNavigation = _supported && !_focused;
        return AppTaskScope(
          open: _open,
          supported: _supported,
          task: _task,
          owner: widget.controller,
          child: OperationFeedback(
            controller: widget.controller,
            child: Scaffold(
              body: Row(
                children: [
                  if (showNavigation && layout.rail)
                    SafeArea(
                      child: SizedBox(
                        width: layout.navigationWidth,
                        child: NavigationRail(
                          groupAlignment: 0,
                          minWidth: layout.navigationWidth,
                          selectedIndex: selected,
                          onDestinationSelected: (index) =>
                              _open(layout.tasks[index]),
                          labelType: NavigationRailLabelType.all,
                          destinations: [
                            for (final task in layout.tasks)
                              NavigationRailDestination(
                                padding: EdgeInsets.symmetric(
                                  vertical: layout.destinationPadding,
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
                  Expanded(
                    key: const ValueKey('app-pages'),
                    child: LayoutBuilder(
                      builder: (context, body) {
                        if (_supported) _lastBodySize = body.biggest;
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            Offstage(
                              offstage: !_supported,
                              child: OverflowBox(
                                minWidth: _lastBodySize.width,
                                maxWidth: _lastBodySize.width,
                                minHeight: _lastBodySize.height,
                                maxHeight: _lastBodySize.height,
                                child: NavigatorPopHandler<Object?>(
                                  enabled: _supported,
                                  onPopWithResult: (result) =>
                                      _navigator.currentState?.maybePop(result),
                                  child: Semantics(
                                    container: true,
                                    explicitChildNodes: true,
                                    child: Navigator(
                                      key: _navigator,
                                      observers: [_routes],
                                      onGenerateRoute: (_) =>
                                          MaterialPageRoute<void>(
                                            builder: (context) {
                                              AppTaskScope.maybeOf(context);
                                              return _pages();
                                            },
                                          ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (!_supported)
                              SafeArea(
                                child: SingleChildScrollView(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(strings.enlargeWindow),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
              bottomNavigationBar: showNavigation && !layout.rail
                  ? NavigationBar(
                      height: layout.navigationHeight,
                      selectedIndex: selected,
                      onDestinationSelected: (index) =>
                          _open(layout.tasks[index]),
                      destinations: [
                        for (final task in layout.tasks)
                          NavigationDestination(
                            icon: Icon(icons[task]!.$1, color: icons[task]!.$3),
                            selectedIcon: Icon(
                              icons[task]!.$2,
                              color: icons[task]!.$3,
                            ),
                            label: labels[task]!,
                          ),
                      ],
                    )
                  : null,
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_handleKey);
    widget.controller.removeListener(_readOverviewRequest);
    strategies.dispose();
    super.dispose();
  }
}

class _WorkspaceRoutes extends NavigatorObserver {
  _WorkspaceRoutes(this.changed);
  final VoidCallback changed;
  final stack = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    stack.add(route);
    changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    stack.remove(route);
    changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    stack.remove(route);
    changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = stack.indexOf(oldRoute!);
    if (index >= 0) {
      if (newRoute == null) {
        stack.removeAt(index);
      } else {
        stack[index] = newRoute;
      }
    }
    changed();
  }
}
