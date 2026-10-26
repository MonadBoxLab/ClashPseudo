import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../app_task.dart';

class TaskShortcuts extends StatelessWidget {
  const TaskShortcuts({
    super.key,
    required this.child,
    this.enabled = true,
    this.onSearch,
    this.onSave,
    this.onEscape,
  });

  final Widget child;
  final bool enabled;
  final VoidCallback? onSearch;
  final VoidCallback? onSave;
  final VoidCallback? onEscape;

  @override
  Widget build(BuildContext context) {
    final scope = AppTaskScope.maybeOf(context);
    final owner = scope?.owner;
    Widget shortcuts() {
      final active =
          enabled &&
          (scope?.supported ?? true) &&
          (owner is! AppController || owner.interactive) &&
          (ModalRoute.of(context)?.isCurrent ?? true);
      return CallbackShortcuts(
        bindings: active
            ? {
                if (onSearch != null) ...{
                  const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                      onSearch!,
                  const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
                      onSearch!,
                },
                if (onSave != null) ...{
                  const SingleActivator(LogicalKeyboardKey.keyS, control: true):
                      onSave!,
                  const SingleActivator(LogicalKeyboardKey.keyS, meta: true):
                      onSave!,
                },
                const SingleActivator(LogicalKeyboardKey.escape): ?onEscape,
              }
            : const {},
        child: FocusScope(autofocus: active, child: child),
      );
    }

    return owner is AppController
        ? ListenableBuilder(listenable: owner, builder: (_, _) => shortcuts())
        : shortcuts();
  }
}
