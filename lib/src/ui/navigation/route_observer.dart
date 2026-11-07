import 'package:flutter/material.dart';

/// Observes both Navigator stacks to distinguish a page covered by its own popup from
/// an exited page.
class AppTaskNavigatorObserver extends NavigatorObserver with ChangeNotifier {
  static bool routeIsActive(
    Route<dynamic>? route, {
    Route<dynamic>? ownedPopup,
  }) {
    if (ownedPopup != null &&
        (ownedPopup is! PopupRoute<dynamic> ||
            !ownedPopup.isActive ||
            !ownedPopup.isCurrent ||
            ownedPopup.animation?.status == AnimationStatus.reverse)) {
      return false;
    }
    if (route == null) return true;
    if (!route.isActive ||
        (route is TransitionRoute<dynamic> &&
            route.animation?.status == AnimationStatus.reverse)) {
      return false;
    }
    return route.isCurrent ||
        (ownedPopup != null &&
            AppTaskNavigatorObserver._owners[route]?._coveredOnlyByPopups(
                  route,
                  ownedPopup,
                ) ==
                true);
  }

  static final _owners = Expando<AppTaskNavigatorObserver>();
  final stack = <Route<dynamic>>[];

  /// Subscribes to stack changes, including pages opening and closing after a popup
  /// covers the source page.
  static Listenable? changesFor(Route<dynamic>? route) =>
      route == null ? null : _owners[route];

  /// Checks whether the business page is current; popup coverage does not count as
  /// exit.
  /// Actions in the underlying page and popups still require AppTaskActivity checks.
  static bool isCurrentPage(Route<dynamic>? route) {
    if (route is! PageRoute<dynamic> ||
        !route.isActive ||
        route.animation?.status == AnimationStatus.reverse) {
      return false;
    }
    return route.isCurrent || _owners[route]?._onlyPopupsAbove(route) == true;
  }

  /// Returns the top popup when only PopupRoutes cover the page, allowing interaction
  /// in the original popup to pause.
  static PopupRoute<dynamic>? coveringPopup(Route<dynamic> route) {
    final observer = _owners[route];
    final top = observer?.stack.lastOrNull;
    return !route.isCurrent &&
            route.isActive &&
            observer?._onlyPopupsAbove(route) == true &&
            top is PopupRoute<dynamic> &&
            top.isActive
        ? top
        : null;
  }

  bool _onlyPopupsAbove(Route<dynamic> origin) {
    final index = stack.indexOf(origin);
    return index >= 0 &&
        stack.skip(index + 1).every((route) => route is PopupRoute<dynamic>);
  }

  bool _coveredOnlyByPopups(Route<dynamic> origin, Route<dynamic> popup) =>
      identical(origin.navigator, popup.navigator) &&
      identical(stack.lastOrNull, popup) &&
      _onlyPopupsAbove(origin);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    stack.add(route);
    _owners[route] = this;
    notifyListeners();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    stack.remove(route);
    _owners[route] = null;
    notifyListeners();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    stack.remove(route);
    _owners[route] = null;
    notifyListeners();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = stack.indexOf(oldRoute!);
    _owners[oldRoute] = null;
    if (index < 0) return;
    if (newRoute == null) {
      stack.removeAt(index);
    } else {
      stack[index] = newRoute;
      _owners[newRoute] = this;
    }
    notifyListeners();
  }
}
