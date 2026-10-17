import 'package:flutter/material.dart';

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = '取消',
  String? subject,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
        contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (subject != null) ...[
              Text(
                subject,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
            ],
            Text(message),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(cancelLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ) ??
    false;
