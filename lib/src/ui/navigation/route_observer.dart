import 'package:flutter/material.dart';

/// 分别观察两层 Navigator 的实际路由栈，区分页面被自己的弹窗覆盖和页面退出。
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

  /// 订阅路由栈变化，包括原页面已被弹窗覆盖后的页面打开和关闭。
  static Listenable? changesFor(Route<dynamic>? route) =>
      route == null ? null : _owners[route];

  /// 判断业务页面是否仍为当前页面，被弹窗覆盖不视为退出。
  /// 底层页面和弹窗中的操作仍须通过 AppTaskActivity 检查。
  static bool isCurrentPage(Route<dynamic>? route) {
    if (route is! PageRoute<dynamic> ||
        !route.isActive ||
        route.animation?.status == AnimationStatus.reverse) {
      return false;
    }
    return route.isCurrent || _owners[route]?._onlyPopupsAbove(route) == true;
  }

  /// 仅有 PopupRoute 覆盖时返回最上层弹窗，用于暂停原弹窗的交互。
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
