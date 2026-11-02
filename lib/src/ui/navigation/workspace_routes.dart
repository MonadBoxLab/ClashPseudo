import 'package:flutter/material.dart';

import 'route_observer.dart';

class RouteStatusBuilder extends StatusTransitionWidget {
  const RouteStatusBuilder({
    super.key,
    required super.animation,
    required this.builder,
  });

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => builder(context);
}

class WorkspaceRoutes extends AppTaskNavigatorObserver {
  WorkspaceRoutes(this.changed);
  final VoidCallback changed;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    changed();
  }
}
