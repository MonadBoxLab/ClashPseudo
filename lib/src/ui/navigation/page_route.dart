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
    // Keep the declarative ModalRoute subscription while callbacks read the Route
    // instance directly.
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
