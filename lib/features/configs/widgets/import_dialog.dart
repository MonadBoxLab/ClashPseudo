import 'package:flutter/material.dart';

import '../../../app/app_controller.dart';
import '../config_downloader.dart';
import '../config_entry.dart';
import 'confirm_action.dart';

Future<void> openImport(
  BuildContext context,
  AppController controller, {
  String? source,
}) async {
  final input = await showDialog<Map<String, String>>(
    context: context,
    builder: (_) => ImportDialog(source: source),
  );
  if (input == null || !context.mounted) return;
  final uri = ConfigDownloader.sourceUri(input['source']!);
  final existing = controller.collection.entries
      .where((e) => e.source == uri.toString())
      .firstOrNull;
  if (existing != null) {
    final current = existing.id == controller.collection.selectedId;
    final accepted = await confirmAction(
      context,
      title: '覆盖更新“${existing.name}”？',
      message: current
          ? '该来源已经保存。确认后重新下载并替换正文；更新失败将使旧正文不可再次启动。当前正在接管时会停止，成功后使用新正文启动。'
          : '该来源已经保存。确认后更新此条目，不新增配置，也不切换当前接管。',
      confirmLabel: '覆盖更新',
    );
    if (!accepted || !context.mounted) return;
  }
  var allowHttp = false;
  if (uri.scheme == 'http') {
    allowHttp = await confirmAction(
      context,
      title: '使用 HTTP 明文来源？',
      message: '配置正文与 URL 中的凭据可能被传输链路上的第三方读取或篡改。建议使用 HTTPS。',
      confirmLabel: '仍然下载',
    );
    if (!allowHttp || !context.mounted) return;
  }
  await controller.submit({
    'action': 'import',
    ...input,
    'source': uri.toString(),
    'replace': existing != null,
    'allowHttp': allowHttp,
  });
}

class ImportDialog extends StatefulWidget {
  const ImportDialog({super.key, this.source});
  final String? source;
  @override
  State<ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<ImportDialog> {
  late final _source = TextEditingController(text: widget.source);
  final _name = TextEditingController();
  String? _error;
  bool _obscured = true;

  @override
  void dispose() {
    _source.dispose();
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      final uri = ConfigDownloader.sourceUri(_source.text);
      Navigator.pop(context, {
        'source': uri.toString(),
        'name': _name.text.trim(),
      });
    } on ConfigFailure catch (failure) {
      setState(() => _error = failure.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('导入完整配置'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('保存完整 mihomo 配置，实际启动时由内核解析。不转换节点订阅。'),
            const SizedBox(height: 20),
            TextField(
              controller: _source,
              obscureText: _obscured,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: '完整配置 URL',
                errorText: _error,
                suffixIcon: IconButton(
                  tooltip: _obscured ? '显示 URL' : '隐藏 URL',
                  onPressed: () => setState(() => _obscured = !_obscured),
                  icon: Icon(
                    _obscured
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: '名称（可选）',
                helperText: '不填写时使用来源主机名',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '监听、控制接口和 TUN 由应用管理，保存的原文不变。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('下载并保存')),
    ],
  );
}
