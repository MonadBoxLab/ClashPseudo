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

/// [isCurrent] checks whether the result popup may open, both before and after waiting
/// for UI interaction to resume.
/// Read the current page and selection state in the callback rather than returning a
/// cached boolean.
/// After opening, [isCurrentWithPopup] receives the actual popup Route and checks the
/// source page,
/// pane, and selection. Its own popup may cover the source, but task exit, source
/// closure, or another page invalidates it.
/// [onRoute] receives the owned result popup Route before push. Opening copy-error
/// details passes
/// the details Route; closing details restores the result Route, and closing all popups
/// passes null.
/// [eligibilityChanges] supplies source-page state notifications for hosts without an
/// inherited controller.
/// Each notification synchronously checks eligibility; once invalidated, the result
/// stays disabled even if state recovers in the same frame.
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
          // Keep invalidated results disabled; close only the owned popup, not a page
          // or popup covering it.
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
      // Synchronous push observers can invalidate the result; keep it disabled from the
      // first frame.
      retired = true;
    }
  }

  eligibilityChanges?.addListener(eligibilityChanged);
  var listeningToOwner = false;
  try {
    onRoute?.call(dialog);
    final presentation = navigator.push<void>(dialog);
    // Listen to inherited controllers after push returns so synchronous observers first
    // receive the bound Route.
    // Listen to caller-supplied eligibilityChanges before push.
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

/// Expands technical text in the result popup; copying checks both popup and
/// source-page eligibility.
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
      final showSubmissionFailure =
          submissionFailed &&
          !controller.feedbackHandledLocally(command, submissionFailed: true);
      if (submissionFailed && !showSubmissionFailure) _failedCommand = command;
      if (!showSubmissionFailure) {
        if (!completed) return;
        if (controller.feedbackHandledLocally(
          command,
          submissionFailed: false,
          resultId: state.resultId,
        )) {
          _result = state.resultId;
          return;
        }
      }
      void consume() {
        if (showSubmissionFailure) {
          _failedCommand = command;
        } else {
          _result = state.resultId;
        }
      }

      final message = showSubmissionFailure
          ? controller.commandErrorMessage
          : state.resultMessageDescription;
      if (message == null) {
        consume();
        return;
      }
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
        consume();
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
      var presented = false;
      _presenting = true;
      try {
        presented = await showAppNotice(
          context,
          message,
          error: !success,
          title: success ? (strings) => strings.operationFinished : null,
          isCurrent: current,
          isCurrentWithPopup: (_) => current(),
          eligibilityChanges: controller,
          identity: (command, showSubmissionFailure, state.resultId),
          onPresented: consume,
        );
      } finally {
        _presenting = false;
        if (mounted && (presented || !current())) _changed();
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
