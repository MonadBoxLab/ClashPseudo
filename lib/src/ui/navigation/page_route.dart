import 'package:flutter/material.dart';

import 'task_activity.dart';

class FocusedPageRoute<T> extends MaterialPageRoute<T> {
  FocusedPageRoute({required super.builder, super.settings});

  @override
  Widget buildContent(BuildContext context) {
    final parentCurrent = AppTaskActivity.capture(context);
    final parentSource = AppTaskActivity.captureSource(context);
    final ownerNavigator = navigator;
    bool sourceCurrent() =>
        context.mounted &&
        parentSource() &&
        ownerNavigator != null &&
        ownerNavigator.mounted &&
        identical(navigator, ownerNavigator) &&
        AppTaskActivity.routeIsActive(this);
    // 保留 ModalRoute 的声明式订阅，同时让回调直接读取 Route 实例。
    ModalRoute.of(context);
    bool current({Route<dynamic>? ownedPopup}) =>
        context.mounted &&
        parentCurrent(ownedPopup: ownedPopup) &&
        AppTaskActivity.routeIsActive(this, ownedPopup: ownedPopup);
    final content = super.buildContent(context);
    bool activeNow() => current();
    bool activeWithPopup(Route<dynamic> popup) => current(ownedPopup: popup);
    Widget activity() {
      final active = current();
      return AppTaskActivity(
        active: active,
        isActiveNow: activeNow,
        isActiveWithPopup: activeWithPopup,
        isSourceCurrent: sourceCurrent,
        child: IgnorePointer(
          ignoring: !active,
          child: ExcludeFocus(
            excluding: !active,
            child: ExcludeSemantics(excluding: !active, child: content),
          ),
        ),
      );
    }

    return ListenableBuilder(
      listenable: animation!,
      builder: (_, _) => activity(),
    );
  }
}
