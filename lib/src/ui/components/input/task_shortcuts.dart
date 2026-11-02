import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../navigation/task_activity.dart';

class TaskShortcuts extends StatefulWidget {
  const TaskShortcuts({
    super.key,
    required this.child,
    this.enabled = true,
    this.shortcutsEnabled = true,
    this.onSearch,
    this.onSave,
    this.onEscape,
  });

  final Widget child;
  final bool enabled;

  /// 只暂停快捷键，当前任务中的控件仍可获得焦点。
  final bool shortcutsEnabled;

  final VoidCallback? onSearch;
  final VoidCallback? onSave;
  final VoidCallback? onEscape;

  @override
  State<TaskShortcuts> createState() => _TaskShortcutsState();
}

class _TaskShortcutsState extends State<TaskShortcuts> {
  bool _inTree = true;
  late bool Function({Route<dynamic>? ownedPopup}) _taskCurrent;
  InheritedElement? _ownerElement;
  ModalRoute<dynamic>? _route;

  Object? get _owner {
    final element = _ownerElement;
    return element != null && element.mounted
        ? (element.widget as AppTaskScope).owner
        : null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _taskCurrent = AppTaskActivity.capture(context);
    AppTaskScope.maybeOf(context);
    _ownerElement = context
        .getElementForInheritedWidgetOfExactType<AppTaskScope>();
    _route = ModalRoute.of(context);
  }

  @override
  void activate() {
    super.activate();
    _inTree = true;
  }

  @override
  void deactivate() {
    _inTree = false;
    super.deactivate();
  }

  bool get _active {
    if (!mounted || !_inTree || !widget.enabled) return false;
    if (_ownerElement != null && !_ownerElement!.mounted) return false;
    final owner = _owner;
    return _taskCurrent() &&
        (owner is! AppController || owner.interactive) &&
        AppTaskActivity.routeIsActive(_route);
  }

  bool get _shortcutsActive => _active && widget.shortcutsEnabled;

  void _search() {
    if (_shortcutsActive) widget.onSearch?.call();
  }

  void _save() {
    if (_shortcutsActive) widget.onSave?.call();
  }

  void _escape() {
    if (_shortcutsActive) widget.onEscape?.call();
  }

  @override
  Widget build(BuildContext context) {
    final owner = _owner;
    Widget shortcuts() {
      final active = _active;
      return CallbackShortcuts(
        bindings: active && widget.shortcutsEnabled
            ? {
                if (widget.onSearch != null) ...{
                  const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                      _search,
                  const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
                      _search,
                },
                if (widget.onSave != null) ...{
                  const SingleActivator(LogicalKeyboardKey.keyS, control: true):
                      _save,
                  const SingleActivator(LogicalKeyboardKey.keyS, meta: true):
                      _save,
                },
                if (widget.onEscape != null)
                  const SingleActivator(LogicalKeyboardKey.escape): _escape,
              }
            : const {},
        child: FocusScope(
          autofocus: active,
          canRequestFocus: active,
          descendantsAreFocusable: active,
          descendantsAreTraversable: active,
          child: widget.child,
        ),
      );
    }

    return owner is AppController
        ? ListenableBuilder(listenable: owner, builder: (_, _) => shortcuts())
        : shortcuts();
  }
}
