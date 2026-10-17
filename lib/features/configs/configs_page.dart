import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import 'config_entry.dart';
import 'widgets/confirm_action.dart';
import 'widgets/import_dialog.dart';

class ConfigsPage extends StatelessWidget {
  const ConfigsPage({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('配置'),
        actions: [
          IconButton(
            tooltip: '导入完整配置',
            onPressed: controller.canEdit
                ? () => openImport(context, controller)
                : null,
            icon: const Icon(Icons.add_link),
          ),
        ],
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (!controller.configsCurrent)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      controller.configError == null
                          ? '正在读取已保存配置'
                          : controller.configsLoaded
                          ? '以下为上次已读取的配置记录，当前内容未确认。'
                          : '配置读取失败，不能据此判断是否保存过配置。',
                    ),
                  ),
                if (controller.configsCurrent &&
                    controller.collection.entries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    child: Column(
                      children: [
                        Icon(
                          Icons.description_outlined,
                          size: 48,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(height: 16),
                        const Text('尚未保存配置'),
                        const SizedBox(height: 8),
                        const Text('导入完整配置 URL，再选择是否启动。'),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: controller.canEdit
                              ? () => openImport(context, controller)
                              : null,
                          icon: const Icon(Icons.add_link),
                          label: const Text('导入配置'),
                        ),
                      ],
                    ),
                  ),
                for (final entry in controller.collection.entries)
                  _tile(context, entry),
                const SizedBox(height: 24),
                Text(
                  '配置数据可通过受支持的 Android 系统备份或换机迁移恢复。缓存、任务与接管状态不备份，恢复后不会自动启动。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _tile(BuildContext context, ConfigEntry entry) {
    final selected = entry.id == controller.collection.selectedId;
    final running =
        controller.configsCurrent &&
        controller.state.running &&
        entry.id == controller.state.configId;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 12, top: 4),
                  child: Icon(
                    selected ? Icons.check_circle : Icons.description_outlined,
                    color: selected
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(entry.displaySource),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              running
                  ? '实际接管中'
                  : selected
                  ? controller.state.phase == 'STOPPED'
                        ? '当前选择 · 接管已停止'
                        : '当前选择 · 接管状态待确认'
                  : '已保存 · 尚未选择',
            ),
            if (entry.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(entry.error!),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(
                  onPressed:
                      controller.canEdit && !selected && entry.body != null
                      ? () => controller.submit({
                          'action': 'select',
                          'id': entry.id,
                        })
                      : null,
                  child: Text(
                    selected
                        ? '已选择'
                        : controller.state.running
                        ? '切换接管'
                        : '选择',
                  ),
                ),
                TextButton(
                  onPressed:
                      controller.canEdit &&
                          !running &&
                          !(selected && controller.state.running)
                      ? () => _delete(context, entry)
                      : null,
                  child: const Text('删除'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _delete(BuildContext context, ConfigEntry entry) async {
    final selected = entry.id == controller.collection.selectedId;
    final remaining = controller.collection.entries
        .where((e) => e.id != entry.id)
        .toList();
    final outcome = !selected
        ? '当前选择与接管不变。'
        : remaining.isEmpty
        ? '删除后没有当前配置。'
        : '删除后选择“${remaining.first.name}”，不会自动启动。';
    final accepted = await confirmAction(
      context,
      title: '删除“${entry.name}”？',
      message: '将删除保存的正文与来源。$outcome',
      confirmLabel: '删除',
    );
    if (accepted && context.mounted) {
      await controller.submit({'action': 'delete', 'id': entry.id});
    }
  }
}
