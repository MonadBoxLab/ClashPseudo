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
    final state = controller.state;
    final consequence = !state.confirmed
        ? '接管状态尚未确认，请先核实运行状态。'
        : state.running && state.configId == existing.id
        ? '将停止此配置的接管；更新成功后重新启动。'
        : state.running
        ? '不会切换或停止其他配置的接管。'
        : '更新后不会自动启动接管。';
    final accepted = await confirmAction(
      context,
      title: '覆盖更新配置？',
      subject: existing.name,
      message:
          '此来源已保存，将更新该条目，不新增配置。'
          '\n\n旧正文将失效，下载失败后也不能再次启动。$consequence',
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
  int get _nameLength => _name.text.trim().runes.length;

  @override
  void dispose() {
    _source.dispose();
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    if (_nameLength > 80) return;
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
                label: Semantics(
                  liveRegion: true,
                  label: _error == null ? '完整配置 URL' : '完整配置 URL，输入无效',
                  child: ExcludeSemantics(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Flexible(
                          child: Text(
                            '完整配置 URL',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        SizedBox.square(
                          dimension: 16,
                          child: _error == null
                              ? null
                              : Icon(
                                  Icons.error_outline,
                                  size: 16,
                                  color: Theme.of(context).colorScheme.error,
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
                helperText: _error ?? '请输入完整的 HTTP 或 HTTPS 配置 URL。',
                helperMaxLines: 4,
                helperStyle: TextStyle(
                  color: _error == null
                      ? null
                      : Theme.of(context).colorScheme.error,
                ),
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
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: '名称（可选）',
                helperText: '留空使用来源主机名',
                counterText: '$_nameLength/80',
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
      FilledButton(
        onPressed: _nameLength <= 80 ? _submit : null,
        child: const Text('下载并保存'),
      ),
    ],
  );
}
