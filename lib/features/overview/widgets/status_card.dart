import 'package:flutter/material.dart';

import '../../../app/app_controller.dart';

class StatusCard extends StatelessWidget {
  const StatusCard({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final theme = Theme.of(context);
    final title = controller.loading
        ? '正在核实'
        : switch (state.phase) {
            'RUNNING' => '接管运行中',
            'STOPPED' => '接管已关闭',
            'STARTING' => '正在启动',
            'STOPPING' => '正在停止',
            _ => '状态未确认',
          };
    final selected = controller.collection.selected;
    final actual = controller.collection.find(state.configId);
    final subtitle = state.running
        ? '实际使用：${actual?.name ?? '配置身份未确认'}'
        : !state.confirmed
        ? '核实实际状态后才能继续操作。'
        : selected == null
        ? '导入完整配置后，即可启动网络接管。'
        : selected.body == null
        ? '当前配置需要重新导入更新。'
        : '关闭接管不会删除已保存的配置。';
    final enabled =
        !controller.busy &&
        state.confirmed &&
        (state.running || (controller.error == null && selected?.body != null));
    return Card(
      color: state.running
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  state.running
                      ? Icons.verified_user_outlined
                      : Icons.shield_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Text('接管状态', style: theme.textTheme.labelLarge),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Text(subtitle),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: enabled
                    ? () => controller.submit({
                        'action': state.running ? 'stop' : 'start',
                      })
                    : null,
                icon: Icon(
                  state.running ? Icons.stop_rounded : Icons.power_settings_new,
                ),
                label: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(state.running ? '停止接管' : '启动接管'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
