import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/widgets/operation_feedback.dart';
import '../configs/configs_page.dart';
import '../configs/widgets/import_dialog.dart';
import 'widgets/status_card.dart';

class OverviewPage extends StatelessWidget {
  const OverviewPage({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final selected = controller.collection.selected;
      return Scaffold(
        appBar: AppBar(
          title: const Text('总览'),
          actions: [
            IconButton(
              tooltip: '核实状态',
              onPressed: controller.refresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                children: [
                  StatusCard(controller: controller),
                  OperationFeedback(controller: controller),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    controller.state.running
                                        ? '当前选择'
                                        : '下次启动配置',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelLarge,
                                  ),
                                ),
                                IconButton(
                                  tooltip: '导入完整配置',
                                  onPressed: controller.canEdit
                                      ? () => openImport(context, controller)
                                      : null,
                                  icon: const Icon(Icons.add_link),
                                ),
                              ],
                            ),
                          ),
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 4,
                            ),
                            leading: const Icon(Icons.description_outlined),
                            title: Text(
                              selected?.name ?? '尚未导入配置',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              selected?.displaySource ?? '导入、选择和管理完整配置',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    ConfigsPage(controller: controller),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '启动结果以实际接管状态为准。打开应用不会自动启动。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
