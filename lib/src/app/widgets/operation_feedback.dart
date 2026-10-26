import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../app_task.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/messages.dart';
import '../workspace_window.dart';

/// Retains the description so an open result also follows a locale change.
Future<void> showAppMessage(
  BuildContext context,
  AppMessage message, {
  String Function(AppLocalizations)? title,
  String? subject,
  bool error = true,
}) => showLocalizedOperationMessage(
  context,
  message.resolve,
  title: title,
  subject: subject,
  error: error,
);

Future<void> showLocalizedOperationMessage(
  BuildContext context,
  String Function(AppLocalizations) message, {
  String Function(AppLocalizations)? title,
  String? subject,
  bool error = true,
}) async {
  final owner =
      AppTaskScope.maybeOf(context)?.owner ??
      WorkspaceScope.maybeOf(context)?.controller;
  final route = ModalRoute.of(context);
  if (owner is AppController && !await owner.waitUntilInteractive()) return;
  if (!context.mounted || route?.isActive == false) return;
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            error ? Icons.error_outline : Icons.info_outline,
            size: 22,
            color: error ? Theme.of(context).colorScheme.error : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title?.call(AppLocalizations.of(context)) ??
                  AppLocalizations.of(context).operationNotCompleted,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
          ),
        ],
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
            message(AppLocalizations.of(context)),
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(height: 1.5),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(AppLocalizations.of(context).close),
        ),
      ],
    ),
  );
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
      if (!showSubmissionFailure && state.resultSuccess) {
        if (const [
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Builder(
              builder: (context) =>
                  Text(message.resolve(AppLocalizations.of(context))),
            ),
          ),
        );
        return;
      }
      _presenting = true;
      try {
        await showAppMessage(context, message);
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
