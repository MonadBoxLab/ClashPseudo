import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

Future<bool> confirmAction(
  BuildContext context, {
  required String Function(AppLocalizations) title,
  required String Function(AppLocalizations) message,
  required String Function(AppLocalizations) confirmLabel,
  String Function(AppLocalizations)? cancelLabel,
  String? subject,
  ValueChanged<ModalRoute<dynamic>?>? onRoute,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) {
        onRoute?.call(ModalRoute.of(context));
        return AlertDialog(
          scrollable: true,
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
          contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          title: Text(title(AppLocalizations.of(context))),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (subject != null) ...[
                SelectableText(
                  subject,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
              ],
              SelectableText(message(AppLocalizations.of(context))),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(
                cancelLabel?.call(AppLocalizations.of(context)) ??
                    AppLocalizations.of(context).cancel,
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(confirmLabel(AppLocalizations.of(context))),
            ),
          ],
        );
      },
    ) ??
    false;
