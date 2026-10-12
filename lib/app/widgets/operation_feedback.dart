import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../../features/configs/widgets/confirm_action.dart';

class OperationFeedback extends StatelessWidget {
  const OperationFeedback({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final message =
        controller.error ??
        state.operation ??
        state.resultMessage ??
        state.error;
    if (message == null) return const SizedBox.shrink();
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (controller.busy)
              if (MediaQuery.disableAnimationsOf(context))
                const Icon(Icons.hourglass_top)
              else
                const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Text(message, style: Theme.of(context).textTheme.bodyMedium),
            if (!controller.busy &&
                state.needsHttpConfirmation &&
                controller.lastCommand?['action'] == 'import')
              TextButton(
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
