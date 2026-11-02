import 'package:flutter/widgets.dart';

import '../app/app_controller.dart';

class WorkspaceScope extends InheritedWidget {
  const WorkspaceScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final AppController controller;

  static WorkspaceScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WorkspaceScope>();

  @override
  bool updateShouldNotify(WorkspaceScope oldWidget) =>
      !identical(controller, oldWidget.controller);
}

class WorkspaceWindow extends StatelessWidget {
  const WorkspaceWindow({
    super.key,
    required this.controller,
    required this.child,
  });

  final AppController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      WorkspaceScope(controller: controller, child: child);
}
