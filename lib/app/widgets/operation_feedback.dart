import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../../features/configs/widgets/confirm_action.dart';

Future<void> showOperationMessage(
  BuildContext context,
  String message, {
  String title = '操作未完成',
  String? subject,
  bool error = true,
}) => showDialog<void>(
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
            title,
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
          Text(subject, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
        ],
        SelectableText(
          message,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  ),
);

// Observe each command once, independently of the page or popup that is open.
// Feedback never participates in the underlying page's layout.
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
      if (!controller.foreground || controller.busy) return;
      final state = controller.state;
      final command = controller.lastCommand;
      final submissionFailed =
          controller.commandError != null &&
          command != null &&
          !identical(command, _failedCommand);
      final completed = state.resultId != null && state.resultId != _result;
      if (!submissionFailed && !completed) return;
      if (completed) _result = state.resultId;
      if (submissionFailed) _failedCommand = command;
      // Automatic strategy preparation reports its state on the strategy page.
      // Disconnect results are owned by the connection detail controller.
      if (command == null ||
          controller.lastCommandAutomatic ||
          command['action'] == 'closeConnection' ||
          command['action'] == 'saveLocal') {
        return;
      }
      final message = submissionFailed
          ? controller.commandError
          : state.resultMessage;
      if (message == null || message.trim().isEmpty) return;
      if (!submissionFailed && state.resultSuccess) {
        if (const [
          'start',
          'stop',
          'setMode',
          'select',
          'delete',
          'setStrategy',
        ].contains(command['action'])) {
          return;
        }
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
        return;
      }
      _presenting = true;
      try {
        if (state.needsHttpConfirmation &&
            const ['import', 'updateConfig'].contains(command['action'])) {
          final retry = Map<String, Object?>.of(command);
          final allowed = await confirmAction(
            context,
            title: '允许此次明文重定向？',
            message: '此来源将重定向到 HTTP，配置和凭据可能被读取或篡改。仅本次重试允许明文传输。',
            confirmLabel: '确认并重试',
          );
          if (allowed &&
              mounted &&
              !controller.busy &&
              identical(controller.lastCommand, command)) {
            await controller.submit({...retry, 'allowHttp': true});
          }
        } else {
          await showOperationMessage(context, message);
        }
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
