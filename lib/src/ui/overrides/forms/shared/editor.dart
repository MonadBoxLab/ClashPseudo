import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/app_controller.dart';
import '../../../navigation/task_activity.dart';
import '../../../navigation/workspace_layout.dart';
import '../../../components/input/task_shortcuts.dart';
import '../../../../l10n/app_localizations.dart';
import 'form_interaction.dart';
import 'save_bar.dart';

class DefinitionEditor extends StatefulWidget {
  const DefinitionEditor({
    super.key,
    required this.dirty,
    required this.saving,
    required this.onSave,
    required this.child,
    this.completedResult,
    this.isCompletedSourceCurrent,
  });

  final bool dirty;
  final bool saving;
  final Object? completedResult;
  final bool Function()? isCompletedSourceCurrent;
  final VoidCallback onSave;
  final Widget child;

  @override
  State<DefinitionEditor> createState() => _DefinitionEditorState();
}

class _DefinitionEditorState extends State<DefinitionEditor> {
  AppController? _app;
  ModalRoute<dynamic>? _route;
  NavigatorState? _navigator;
  Future<bool>? _leaving;
  Future<bool> Function()? _overviewLeave;
  Future<bool> Function()? _escapeLeave;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = AppTaskScope.maybeOf(context);
    final owner = scope?.owner;
    final app = owner is AppController ? owner : null;
    final route = ModalRoute.of(context);
    final navigator = Navigator.maybeOf(context);
    if (identical(app, _app) &&
        identical(route, _route) &&
        identical(navigator, _navigator)) {
      return;
    }
    final previous = _route;
    final previousLeave = _overviewLeave;
    if (previous != null && previousLeave != null) {
      _app?.unregisterOverviewLeave(previous, previousLeave);
    }
    _app = app;
    _route = route;
    _navigator = navigator;
    _overviewLeave = null;
    if (route == null || navigator == null) return;
    final scopeElement = context
        .getElementForInheritedWidgetOfExactType<AppTaskScope>();
    final taskActive = AppTaskActivity.capture(context);
    bool current() =>
        mounted &&
        identical(_app, app) &&
        identical(_route, route) &&
        identical(_navigator, navigator) &&
        navigator.mounted &&
        identical(route.navigator, navigator) &&
        (scopeElement == null ||
            (scopeElement.mounted &&
                identical(
                  (scopeElement.widget as AppTaskScope).owner,
                  owner,
                ))) &&
        app?.interactive != false &&
        AppTaskActivity.routeIsActive(route) &&
        taskActive();
    Future<bool> leave({bool oneLayer = false}) =>
        _leave(route, navigator, current, oneLayer: oneLayer);
    _overviewLeave = () => leave();
    _escapeLeave = () => leave(oneLayer: true);
    app?.registerOverviewLeave(route, _overviewLeave!);
  }

  Future<bool> _leave(
    ModalRoute<dynamic> route,
    NavigatorState navigator,
    bool Function() current, {
    bool oneLayer = false,
  }) {
    if (!current()) return Future.value(false);
    if (oneLayer &&
        widget.completedResult == null &&
        route.willHandlePopInternally) {
      // Escape 先关闭菜单等由 LocalHistory 管理的界面；
      // 同一次按键不再退出表单或显示丢弃修改确认框。
      return _popOneLocalHistory(route, navigator, current);
    }
    return _leaving ??= _performLeave(
      route,
      navigator,
      current,
    ).whenComplete(() => _leaving = null);
  }

  Future<bool> _popOneLocalHistory(
    ModalRoute<dynamic> route,
    NavigatorState navigator,
    bool Function() current,
  ) async {
    await navigator.maybePop<void>();
    if (!current()) return false;
    await WidgetsBinding.instance.endOfFrame;
    return false;
  }

  Future<bool> _performLeave(
    ModalRoute<dynamic> route,
    NavigatorState navigator,
    bool Function() current,
  ) async {
    bool canLeave() =>
        current() &&
        (!widget.saving || widget.completedResult != null) &&
        (widget.completedResult == null ||
            widget.isCompletedSourceCurrent?.call() != false);
    if (!canLeave()) return false;
    if (route.willHandlePopInternally) {
      await navigator.maybePop<void>();
      if (!canLeave()) return false;
      await WidgetsBinding.instance.endOfFrame;
      if (!canLeave() || route.willHandlePopInternally) return false;
    }
    if (!mounted || !canLeave()) return false;
    if (widget.dirty && widget.completedResult == null) {
      FocusManager.instance.primaryFocus?.unfocus();
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) {
          final strings = AppLocalizations.of(context);
          return AlertDialog(
            scrollable: true,
            title: Text(strings.discardEditsTitle),
            content: Text(strings.discardEditsMessage),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(strings.continueEditing),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(strings.discard),
              ),
            ],
          );
        },
      );
      if (discard != true || !canLeave()) return false;
    }
    if (!canLeave() || !navigator.canPop()) return false;
    navigator.pop(widget.completedResult);
    return !route.isActive;
  }

  @override
  Widget build(BuildContext context) {
    final leave = _overviewLeave;
    final escape = _escapeLeave;
    return TaskShortcuts(
      onSave: () {
        if (!widget.saving &&
            widget.completedResult == null &&
            DefinitionFormInteraction.canAct(context)) {
          widget.onSave();
        }
      },
      onEscape:
          (widget.saving && widget.completedResult == null) || escape == null
          ? null
          : () {
              unawaited(escape());
            },
      child: PopScope<void>(
        canPop:
            widget.completedResult == null && !widget.dirty && !widget.saving,
        onPopInvokedWithResult: (didPop, _) {
          // 路由或菜单已处理返回时，不再继续退出表单。
          if (didPop ||
              _route?.willHandlePopInternally == true ||
              leave == null) {
            return;
          }
          unawaited(leave());
        },
        child: ListenableBuilder(
          listenable:
              _route?.animation ?? const AlwaysStoppedAnimation<double>(1),
          child: widget.child,
          builder: (context, child) => DefinitionFormInteraction(
            active: DefinitionFormInteraction.canAct(context),
            isActiveNow: () =>
                mounted &&
                !widget.saving &&
                AppTaskActivity.routeIsActive(_route) &&
                AppTaskActivity.isActive(this.context),
            isActiveWithPopup: (popup) =>
                mounted &&
                !widget.saving &&
                AppTaskActivity.routeIsActive(_route, ownedPopup: popup) &&
                AppTaskActivity.isActive(this.context, ownedPopup: popup),
            child: child!,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    final route = _route;
    final leave = _overviewLeave;
    if (route != null && leave != null) {
      _app?.unregisterOverviewLeave(route, leave);
    }
    super.dispose();
  }
}

// AppBar otherwise clamps title scaling and defaults to a single ellipsized line.
Widget definitionToolbarTitle(
  BuildContext context,
  String title, {
  bool compact = false,
}) => MediaQuery(
  data: MediaQuery.of(context),
  child: Tooltip(
    message: title,
    excludeFromSemantics: true,
    child: Text(
      title,
      softWrap: !compact,
      maxLines: compact ? 1 : null,
      overflow: compact ? TextOverflow.ellipsis : TextOverflow.visible,
    ),
  ),
);

/// Reserve title space according to actual width and text scale.
double definitionToolbarHeight(
  BuildContext context,
  String title,
  double width,
) {
  final theme = Theme.of(context);
  final painter = TextPainter(
    text: TextSpan(
      text: title,
      style: theme.appBarTheme.titleTextStyle ?? theme.textTheme.titleLarge,
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout(maxWidth: math.max(1, width - 88));
  final height = math.max(kToolbarHeight, painter.height + 16);
  painter.dispose();
  return height;
}

({double toolbarHeight, bool compact}) definitionEditorLayout(
  BuildContext context,
  String title,
  Size bounds, {
  double? footerHeight,
}) {
  final toolbar = definitionToolbarHeight(context, title, bounds.width);
  final available =
      bounds.height -
      MediaQuery.paddingOf(context).vertical -
      MediaQuery.viewInsetsOf(context).vertical;
  final compact =
      available -
          toolbar -
          (footerHeight ?? DefinitionSaveBar.heightOf(context)) <
      WorkspaceLayout.minimumBodyHeight;
  return (toolbarHeight: compact ? kToolbarHeight : toolbar, compact: compact);
}

/// 保存前记录发起保存的任务和路由，供保存完成后核对。
/// 交互暂停时，是否仍认定为同一保存来源，由任务的来源检查函数决定。
bool Function() captureDefinitionSaveSource(BuildContext context) {
  if (!context.mounted) return () => false;
  final route = ModalRoute.of(context);
  final navigator = Navigator.maybeOf(context);
  final sourceCurrent = AppTaskActivity.captureSource(context);
  return () =>
      context.mounted &&
      route != null &&
      navigator != null &&
      navigator.mounted &&
      identical(route.navigator, navigator) &&
      AppTaskActivity.routeIsActive(route) &&
      sourceCurrent();
}

/// 保存完成后，只有原任务、原路由仍有效且允许交互时，才关闭原表单。
Future<void> definitionSaved(
  BuildContext context,
  Object result, {
  bool Function()? isSourceCurrent,
}) async {
  if (!context.mounted) return;
  final route = ModalRoute.of(context);
  if (route == null) return;
  final navigator = Navigator.of(context);
  final taskActive = AppTaskActivity.capture(context);
  final sourceCurrent = AppTaskActivity.captureSource(context);
  final owner = AppTaskScope.maybeOf(context)?.owner;
  final scopeElement = context
      .getElementForInheritedWidgetOfExactType<AppTaskScope>();
  bool source() =>
      context.mounted &&
      navigator.mounted &&
      identical(route.navigator, navigator) &&
      (scopeElement == null ||
          (scopeElement.mounted &&
              identical((scopeElement.widget as AppTaskScope).owner, owner))) &&
      AppTaskActivity.routeIsActive(route) &&
      sourceCurrent() &&
      (isSourceCurrent?.call() ?? true);
  if (!source()) return;
  if (owner is AppController && !await owner.waitUntilInteractive()) return;
  if (!source() || !taskActive()) return;
  navigator.pop(result);
}
