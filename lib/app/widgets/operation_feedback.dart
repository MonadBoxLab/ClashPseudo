import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../../features/configs/widgets/confirm_action.dart';

class OperationFeedback extends StatelessWidget {
  const OperationFeedback({
    super.key,
    required this.controller,
    this.showOperation = true,
    this.hideToggleSuccess = false,
    this.hideModeSuccess = false,
    this.foregroundColor,
  });
  final AppController controller;
  final bool showOperation;
  final bool hideToggleSuccess;
  final bool hideModeSuccess;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final redundantSuccess =
        !state.needsHttpConfirmation &&
        ((hideToggleSuccess &&
                state.resultSuccess &&
                const ['接管已启动。', '接管已停止。'].contains(state.resultMessage)) ||
            (hideModeSuccess &&
                state.resultSuccess &&
                const [
                  '运行模式已切换。',
                  '运行模式已确认。',
                  '模式已保存，下次启动生效。',
                ].contains(state.resultMessage)));
    final result = redundantSuccess || state.resultMessage?.isEmpty == true
        ? null
        : state.resultMessage;
    final message =
        controller.error ??
        (state.operation != null
            ? showOperation
                  ? state.operation
                  : null
            : result ?? state.error);
    if (message == null || message.isEmpty) return const SizedBox.shrink();
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (controller.busy)
              if (MediaQuery.disableAnimationsOf(context))
                Icon(Icons.hourglass_top, color: foregroundColor)
              else
                LinearProgressIndicator(color: foregroundColor),
            const SizedBox(height: 8),
            Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: foregroundColor),
            ),
            if (!controller.busy &&
                state.needsHttpConfirmation &&
                controller.lastCommand?['action'] == 'import')
              TextButton(
                style: TextButton.styleFrom(foregroundColor: foregroundColor),
                onPressed: () async {
                  final allowed = await confirmAction(
                    context,
                    title: '允许此次明文重定向？',
                    message: '此来源将重定向到 HTTP，配置和凭据可能被读取或篡改。仅本次重试允许明文传输。',
                    confirmLabel: '确认并重试',
                  );
                  if (allowed && context.mounted) {
                    await controller.submit({
                      ...controller.lastCommand!,
                      'allowHttp': true,
                    });
                  }
                },
                child: const Text('确认 HTTP 风险并重试'),
              ),
          ],
        ),
      ),
    );
  }
}
