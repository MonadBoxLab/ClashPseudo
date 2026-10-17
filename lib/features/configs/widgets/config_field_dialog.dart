import 'package:flutter/material.dart';

class ConfigFieldDialog extends StatefulWidget {
  const ConfigFieldDialog({
    super.key,
    required this.initial,
    this.source = false,
    this.title,
    this.confirmLabel,
  });
  final String? confirmLabel;
  final String? title;
  final String initial;
  final bool source;

  @override
  State<ConfigFieldDialog> createState() => _ConfigFieldDialogState();
}

class _ConfigFieldDialogState extends State<ConfigFieldDialog> {
  late final _text = TextEditingController(text: widget.initial);
  int get _nameLength => _text.text.trim().runes.length;

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.title ?? (widget.source ? '修改配置来源' : '重命名配置')),
    content: SizedBox(
      width: 360,
      child: TextField(
        controller: _text,
        autofocus: true,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: widget.source ? '完整配置 URL' : '配置名称',
          counterText: widget.source ? null : '$_nameLength/80',
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      TextButton(
        onPressed: widget.source || (_nameLength > 0 && _nameLength <= 80)
            ? () => Navigator.pop(context, _text.text.trim())
            : null,
        child: Text(widget.confirmLabel ?? (widget.source ? '保存并更新' : '保存')),
      ),
    ],
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }
}
