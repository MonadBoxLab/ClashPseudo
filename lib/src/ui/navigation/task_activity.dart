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

/// 页面退出后即停用界面操作，即使退出动画仍在绘制该页面。
class AppTaskActivity extends InheritedWidget {
  const AppTaskActivity({
    super.key,
    required this.active,
    this.isActiveNow,
    this.isActiveWithPopup,
    this.isSourceCurrent,
    required super.child,
  });

  /// 供组件订阅的交互状态；缓存回调和异步回调须重新检查当前状态。
  final bool active;

  /// 读取任务和路由的当前交互状态，不依赖组件是否已经重建。
  final bool Function()? isActiveNow;

  /// 调用方须提供自己打开的弹窗的实际 Route，才能允许该弹窗覆盖来源页面。
  final bool Function(Route<dynamic> ownedPopup)? isActiveWithPopup;

  /// 检查等待显示结果的来源页面是否仍有效，不代表页面或弹窗允许交互。
  /// 未提供此回调时按当前交互状态判断，不将无法操作的状态视为暂时暂停。
  final bool Function()? isSourceCurrent;

  bool _current({Route<dynamic>? ownedPopup}) =>
      ownedPopup != null && isActiveWithPopup != null
      ? isActiveWithPopup!(ownedPopup)
      : isActiveNow?.call() ?? active;

  /// 默认要求来源页为当前路由；自己的确认弹窗或表单可传入仍在前台的 PopupRoute。
  /// 仍须检查任务选择、交互状态、来源路由是否已关闭或正在退出，以及是否被其他 PageRoute 覆盖。
  static bool isActive(BuildContext context, {Route<dynamic>? ownedPopup}) {
    if (!context.mounted) return false;
    return context
            .dependOnInheritedWidgetOfExactType<AppTaskActivity>()
            ?._current(ownedPopup: ownedPopup) ??
        true;
  }

  /// 在来源组件仍位于树中时保存其 AppTaskActivity 元素，后续检查不再查询祖先。
  /// 每次读取该元素的当前 widget，使交互状态变化立即生效。
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

  /// 保存等待显示结果的任务和来源页面，后续只读取原来的继承组件元素。
  /// 提供 isSourceCurrent 时按该回调检查；未提供时仍检查当前交互状态。
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
      isSourceCurrent != oldWidget.isSourceCurrent;
}
