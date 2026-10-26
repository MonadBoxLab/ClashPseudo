import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/widgets/choice_menu_button.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/messages.dart';
import '../configs/config_entry.dart';
import '../overrides/override_entry.dart';

/// Opens the periodic update settings for one remote target.
Future<void> showAutoUpdateDialog(
  BuildContext context,
  AppController app, {
  required ConfigEntry? config,
  required OverrideEntry? override,
  int? storageEpoch,
}) async {
  final epoch = storageEpoch ?? app.storageEpoch;
  final source = config?.source ?? override?.source;
  final id = config?.id ?? override?.id;
  final policy = config?.update ?? override?.update;
  if (source == null || id == null || policy == null) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _AutoUpdateDialog(
      app: app,
      policy: policy,
      submit: (values, owner) => app.submitAndWait({
        'action': config != null ? 'setConfigUpdate' : 'setOverrideUpdate',
        'id': id,
        ...values,
        'storageEpoch': epoch,
      }, feedbackOwner: owner),
    ),
  );
}

class _AutoUpdateDialog extends StatefulWidget {
  const _AutoUpdateDialog({
    required this.app,
    required this.policy,
    required this.submit,
  });

  final AppController app;
  final UpdatePolicy policy;
  final Future<AppSnapshot?> Function(
    Map<String, Object?> values,
    ValueListenable<bool> feedbackOwner,
  )
  submit;

  @override
  State<_AutoUpdateDialog> createState() => _AutoUpdateDialogState();
}

class _AutoUpdateDialogState extends State<_AutoUpdateDialog> {
  final _feedbackOwner = ValueNotifier<bool>(true);
  late bool _enabled;
  late int _hours;
  bool _saving = false;
  AppMessage? _error;

  @override
  void initState() {
    super.initState();
    _enabled = widget.policy.enabled;
    _hours = widget.policy.hours;
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await widget.submit({
      'enabled': _enabled,
      'hours': _hours,
    }, _feedbackOwner);
    try {
      if (!mounted) return;
      if (result?.resultSuccess != true) {
        setState(() {
          _saving = false;
          _error =
              result?.resultMessageDescription ??
              widget.app.commandErrorMessage ??
              const AppMessage('operationFailed');
        });
        return;
      }
      Navigator.pop(context);
    } finally {
      widget.app.acknowledgeLocalFeedback(_feedbackOwner, result: result);
    }
  }

  @override
  void dispose() {
    _feedbackOwner.value = false;
    _feedbackOwner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final editable = _enabled && !_saving;
    return AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(strings.autoUpdate)),
          Semantics(
            label: strings.autoUpdate,
            child: Switch(
              key: const ValueKey('auto-update-enabled'),
              value: _enabled,
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _enabled = value),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ChoiceMenuButton<int>(
                key: const ValueKey('auto-update-interval'),
                maxHeight: MediaQuery.sizeOf(context).height / 3,
                enabled: editable,
                tooltip: strings.autoUpdateInterval,
                value: _hours,
                onSelected: (value) => setState(() => _hours = value),
                options: {
                  for (final hours in UpdatePolicy.intervals)
                    hours: strings.autoUpdateEvery(hours),
                },
                child: ListTile(
                  enabled: editable,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    strings.autoUpdateInterval,
                    style: theme.textTheme.bodyMedium,
                  ),
                  subtitle: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Text(strings.autoUpdateEvery(_hours)),
                  ),
                  trailing: const Icon(Icons.unfold_more_rounded),
                ),
              ),
              if (widget.policy.lastAttempt != null) ...[
                const SizedBox(height: 8),
                Text(
                  '${strings.autoUpdateAttempt}: '
                  '${MaterialLocalizations.of(context).formatFullDate(widget.policy.lastAttempt!.toLocal())}',
                  style: theme.textTheme.bodySmall,
                ),
                Text(switch (widget.policy.lastResult) {
                  'applied' => strings.autoUpdateApplied,
                  'updated' || 'saved' => strings.autoUpdateSaved,
                  'unchanged' => strings.autoUpdateUnchanged,
                  'applyFailed' => strings.autoUpdateApplyFailed,
                  'failed' => strings.autoUpdateFailed,
                  null => strings.autoUpdateNever,
                  _ => strings.resultUnconfirmed,
                }, style: theme.textTheme.bodySmall),
              ],
              SizedBox(
                key: const ValueKey('auto-update-error'),
                width: double.infinity,
                height: MediaQuery.textScalerOf(context).scale(12) * 2.4 + 8,
                child: _error == null
                    ? null
                    : SingleChildScrollView(
                        primary: false,
                        child: SelectableText(
                          _error!.resolve(strings),
                          style: TextStyle(
                            color: theme.colorScheme.error,
                            fontSize: 12,
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const ValueKey('auto-update-save'),
          onPressed: _saving ? null : _save,
          child: Text(strings.save),
        ),
      ],
    );
  }
}
