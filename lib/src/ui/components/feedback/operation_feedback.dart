import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../../../model/messages.dart';
import '../../app/app_controller.dart';
import '../../locale/message_text.dart';
import '../../navigation/task_activity.dart';
import '../../navigation/workspace_window.dart';
import 'operation_notice.dart';

/// Retains the description so an open result also follows a locale change.
Future<void> showAppMessage(
  BuildContext context,
  AppMessage message, {
  String Function(AppLocalizations)? title,
  String? subject,
  bool error = true,
  bool Function()? isCurrent,
  bool Function(ModalRoute<dynamic> ownedPopup)? isCurrentWithPopup,
  Listenable? eligibilityChanges,
  ValueChanged<ModalRoute<dynamic>?>? onRoute,
  Future<void> Function()? onRetry,
}) => showLocalizedOperationMessage(
  context,
  message.summary,
  technicalDetail: message.technicalDetail,
  title: title,
  subject: subject,
  error: error,
  isCurrent: isCurrent,
  isCurrentWithPopup: isCurrentWithPopup,
  eligibilityChanges: eligibilityChanges,
  onRoute: onRoute,
  onRetry: onRetry,
);

/// [isCurrent] 检查是否允许打开结果弹窗，在等待界面恢复交互前后各检查一次。
/// 回调应读取当前页面和选中对象的状态，不能返回事先保存的布尔值。
/// 弹窗打开后，[isCurrentWithPopup] 接收该弹窗的实际 Route，检查来源页面、
/// 分栏及选中对象；允许自己的弹窗覆盖来源页，但不允许任务退出、来源页关闭或被其他页面覆盖。
/// [onRoute] 在 push 前传入当前所属结果弹窗的实际 Route；主动打开复制错误详情时
/// 传入详情 Route，详情关闭后恢复原结果 Route，全部关闭后传入 null。
/// [eligibilityChanges] 提供来源页面的状态变更通知，供未继承控制器的宿主使用。
/// 每次通知都同步检查是否仍允许操作；结果一旦失效，即使状态在同一帧内恢复也不再启用。
Future<void> showLocalizedOperationMessage(
  BuildContext context,
  String Function(AppLocalizations) summary, {
  String? Function(AppLocalizations)? technicalDetail,
  String Function(AppLocalizations)? title,
  String? subject,
  bool error = true,
  bool Function()? isCurrent,
  bool Function(ModalRoute<dynamic> ownedPopup)? isCurrentWithPopup,
  Listenable? eligibilityChanges,
  ValueChanged<ModalRoute<dynamic>?>? onRoute,
  Future<void> Function()? onRetry,
}) async {
  if (!context.mounted) return;
  final owner =
      AppTaskScope.maybeOf(context)?.owner ??
      WorkspaceScope.maybeOf(context)?.controller;
  final route = ModalRoute.of(context);
  final taskActive = AppTaskActivity.capture(context);
  bool eligible({ModalRoute<dynamic>? ownedPopup}) =>
      context.mounted &&
      AppTaskActivity.routeIsActive(route, ownedPopup: ownedPopup) &&
      taskActive(ownedPopup: ownedPopup) &&
      (ownedPopup == null || owner is! AppController || owner.interactive) &&
      (ownedPopup == null
          ? (isCurrent?.call() ?? true)
          : (isCurrentWithPopup?.call(ownedPopup) ?? true));
  if (!AppTaskActivity.routeIsActive(route) || isCurrent?.call() == false) {
    return;
  }
  if (owner is AppController && !await owner.waitUntilInteractive()) return;
  if (!context.mounted || !eligible()) return;
  assert(debugCheckHasMaterialLocalizations(context));
  final navigator = Navigator.of(context, rootNavigator: true);
  if (!navigator.mounted) return;
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  var retired = false;
  var retirementScheduled = false;
  var retryRequested = false;
  ModalRoute<dynamic>? detailsPopup;
  VoidCallback? checkCurrent;
  final eligibility = Listenable.merge([
    if (owner is AppController) owner,
    if (eligibilityChanges != null && !identical(eligibilityChanges, owner))
      eligibilityChanges,
  ]);
  final dialog = DialogRoute<void>(
    context: context,
    themes: themes,
    barrierColor:
        DialogTheme.of(context).barrierColor ??
        Theme.of(context).dialogTheme.barrierColor ??
        Colors.black54,
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
    animationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (context) {
      final route = ModalRoute.of(context)!;
      final animation = route.animation!;
      final strings = AppLocalizations.of(context);
      final detail = technicalDetail?.call(strings);
      void retire() {
        if (!retired ||
            retirementScheduled ||
            !route.isActive ||
            animation.status == AnimationStatus.reverse) {
          return;
        }
        final navigator = route.navigator;
        if (navigator == null) return;
        retirementScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!retired ||
              !navigator.mounted ||
              !identical(route.navigator, navigator) ||
              !route.isActive ||
              animation.status == AnimationStatus.reverse) {
            return;
          }
          // 失效的结果保持不可操作；仅关闭所属弹窗，不关闭覆盖它的页面或其他弹窗。
          if (route.isCurrent) {
            navigator.pop();
          } else {
            navigator.removeRoute(route);
          }
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      }

      // The SDK keeps the dialog painting during reverse. Reading state stays
      // mounted, but closing content must no longer own actions or accessibility.
      bool current({ModalRoute<dynamic>? ownedPopup}) {
        if (retired) {
          retire();
          return false;
        }
        final nested = detailsPopup;
        final popup =
            ownedPopup ??
            (nested != null &&
                    nested.isActive &&
                    nested.animation?.status != AnimationStatus.reverse
                ? nested
                : null);
        final active =
            route.isActive &&
            animation.status != AnimationStatus.reverse &&
            AppTaskActivity.routeIsActive(route, ownedPopup: popup) &&
            eligible(ownedPopup: popup ?? route);
        if (!active) {
          retired = true;
          retire();
        }
        return active && (ownedPopup != null || route.isCurrent);
      }

      checkCurrent = () => current();
      ModalRoute.isCurrentOf(context);
      return OperationNoticeHost(
        onDismiss: () {
          if (current()) {
            retired = true;
            Navigator.pop(context);
          }
        },
        child: Builder(
          builder: (feedbackContext) => AnimatedBuilder(
            animation: Listenable.merge([animation, eligibility]),
            builder: (context, child) {
              final active = current();
              if (!active) retire();
              return IgnorePointer(
                ignoring: !active,
                child: ExcludeFocus(
                  excluding: !active,
                  child: ExcludeSemantics(excluding: !active, child: child!),
                ),
              );
            },
            child: AlertDialog(
              scrollable: true,
              titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
              contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              title: Text(
                title?.call(AppLocalizations.of(context)) ??
                    (error
                        ? AppLocalizations.of(context).operationNotCompleted
                        : AppLocalizations.of(context).operationFinished),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (subject != null) ...[
                    SelectableText(
                      subject,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                  ],
                  SelectableText(
                    summary(AppLocalizations.of(context)),
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(height: 1.5),
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: 12),
                    _OperationTechnicalDetails(
                      text: detail,
                      isCurrent: current,
                      onCopyFailure: (message) async {
                        bool copyCurrent({ModalRoute<dynamic>? ownedPopup}) =>
                            current(ownedPopup: ownedPopup) &&
                            technicalDetail?.call(
                                  AppLocalizations.of(context),
                                ) ==
                                detail;
                        await showAppNotice(
                          feedbackContext,
                          message,
                          isCurrent: copyCurrent,
                          eligibilityChanges: eligibility,
                          onDetails: () => showAppMessage(
                            feedbackContext,
                            message,
                            isCurrent: copyCurrent,
                            isCurrentWithPopup: (popup) =>
                                copyCurrent(ownedPopup: popup),
                            eligibilityChanges: eligibility,
                            onRoute: (popup) {
                              detailsPopup = popup;
                              onRoute?.call(popup ?? route);
                            },
                          ),
                        );
                      },
                    ),
                  ],
                ],
              ),
              actions: [
                if (onRetry != null)
                  TextButton(
                    onPressed: () {
                      if (!current()) return;
                      retryRequested = true;
                      retired = true;
                      Navigator.pop(context);
                    },
                    child: Text(AppLocalizations.of(context).retry),
                  ),
                TextButton(
                  onPressed: () {
                    if (current()) {
                      retired = true;
                      Navigator.pop(context);
                    } else {
                      retire();
                    }
                  },
                  child: Text(AppLocalizations.of(context).close),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
  void eligibilityChanged() {
    final check = checkCurrent;
    if (check != null) {
      check();
    } else if (!eligible(ownedPopup: dialog.isActive ? dialog : null)) {
      // push 的同步 observer 回调也可能使结果失效；首帧仍须保持不可操作。
      retired = true;
    }
  }

  eligibilityChanges?.addListener(eligibilityChanged);
  var listeningToOwner = false;
  try {
    onRoute?.call(dialog);
    final presentation = navigator.push<void>(dialog);
    // 继承的控制器在 push 返回后开始监听，使同步 observer 先收到已绑定的实际 Route。
    // 调用者传入的 eligibilityChanges 则在 push 前开始监听。
    if (owner is AppController && !identical(eligibilityChanges, owner)) {
      owner.addListener(eligibilityChanged);
      listeningToOwner = true;
    }
    await presentation;
  } finally {
    eligibilityChanges?.removeListener(eligibilityChanged);
    if (listeningToOwner && owner is AppController) {
      owner.removeListener(eligibilityChanged);
    }
    onRoute?.call(null);
  }
  await dialog.completed;
  if (retryRequested && context.mounted && eligible()) await onRetry!();
}

/// 在结果弹窗中展开技术原文；复制时检查该弹窗及来源页面是否仍允许操作。
class _OperationTechnicalDetails extends StatefulWidget {
  const _OperationTechnicalDetails({
    required this.text,
    required this.isCurrent,
    required this.onCopyFailure,
  });

  final String text;
  final bool Function() isCurrent;
  final Future<void> Function(AppMessage) onCopyFailure;

  @override
  State<_OperationTechnicalDetails> createState() =>
      _OperationTechnicalDetailsState();
}

class _OperationTechnicalDetailsState
    extends State<_OperationTechnicalDetails> {
  bool _expanded = false;

  Future<void> _copy(String text) async {
    if (!mounted || !_expanded || widget.text != text || !widget.isCurrent()) {
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (failure) {
      if (mounted && _expanded && widget.isCurrent() && widget.text == text) {
        await widget.onCopyFailure(
          messages.operationFailed.withDetail(failure),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final text = widget.text;
    return ExpansionTile(
      key: const ValueKey('operation-technical-details'),
      onExpansionChanged: (value) => _expanded = value,
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      expansionAnimationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      title: Text(strings.technicalDetails),
      children: [
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton.icon(
            key: const ValueKey('operation-technical-copy'),
            onPressed: () => _copy(text),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.copy_rounded),
            label: Text(strings.copyTechnicalDetails),
          ),
        ),
        SelectableText(
          widget.text,
          key: const ValueKey('operation-technical-text'),
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(fontFamily: 'monospace', height: 1.5),
        ),
      ],
    );
  }
}

// Observe each command once and display feedback on its own overlay surface.
class OperationFeedback extends StatefulWidget {
  const OperationFeedback({
    super.key,
    required this.controller,
    required this.child,
  });
  final AppController controller;
  final Widget child;

  @override
  State<OperationFeedback> createState() => _OperationFeedbackState();
}

class _OperationFeedbackState extends State<OperationFeedback> {
  String? _result;
  Object? _failedCommand;
  bool _scheduled = false;
  bool _presenting = false;

  @override
  void initState() {
    super.initState();
    _result = widget.controller.state.resultId;
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(OperationFeedback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_changed);
    _result = widget.controller.state.resultId;
    _failedCommand = null;
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (_scheduled || _presenting) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _scheduled = false;
      if (!mounted) return;
      final controller = widget.controller;
      if (!controller.interactive || controller.busy) return;
      final state = controller.state;
      final command = controller.lastCommand;
      final submissionFailed =
          controller.commandErrorMessage != null &&
          command != null &&
          !identical(command, _failedCommand);
      final completed = state.resultId != null && state.resultId != _result;
      if (!submissionFailed && !completed) return;
      // Retain the result while a local reader owns presentation; acknowledgment
      // consumes that reader's actual result.
      if (controller.hasLocalFeedbackOwner) return;
      // Automatic preparation and connection details own their existing UI.
      if (command == null ||
          controller.lastCommandAutomatic ||
          command['action'] == 'closeConnection') {
        if (completed) _result = state.resultId;
        if (submissionFailed) _failedCommand = command;
        return;
      }
      var showSubmissionFailure = submissionFailed;
      if (submissionFailed) {
        _failedCommand = command;
        showSubmissionFailure = !controller.feedbackHandledLocally(
          command,
          submissionFailed: true,
        );
      }
      if (!showSubmissionFailure) {
        if (!completed) return;
        _result = state.resultId;
        if (controller.feedbackHandledLocally(
          command,
          submissionFailed: false,
          resultId: state.resultId,
        )) {
          return;
        }
      }
      final message = showSubmissionFailure
          ? controller.commandErrorMessage
          : state.resultMessageDescription;
      if (message == null) return;
      final success = !showSubmissionFailure && state.resultSuccess;
      if (success &&
          const [
            'start',
            'stop',
            'setMode',
            'select',
            'delete',
            'setStrategy',
            'changeOverride',
            'reorderOverrides',
            'deleteOverride',
          ].contains(command['action'])) {
        return;
      }
      bool current() =>
          mounted &&
          identical(widget.controller, controller) &&
          identical(controller.lastCommand, command) &&
          !controller.hasLocalFeedbackOwner &&
          (showSubmissionFailure
              ? identical(controller.commandErrorMessage, message)
              : controller.state.resultId == state.resultId);
      _presenting = true;
      try {
        await showAppNotice(
          context,
          message,
          error: !success,
          title: success ? (strings) => strings.operationFinished : null,
          isCurrent: current,
          isCurrentWithPopup: (_) => current(),
          eligibilityChanges: controller,
          identity: (command, showSubmissionFailure, state.resultId),
        );
      } finally {
        _presenting = false;
        if (mounted) _changed();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) => widget.child;

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }
}
