import 'dart:async';

import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../navigation/route_observer.dart';
import '../navigation/task_activity.dart';
import '../locale/message_text.dart';
import '../components/input/choice_menu_button.dart';
import '../components/feedback/operation_notice.dart';
import '../../l10n/app_localizations.dart';
import '../../model/messages.dart';
import '../../model/config_entry.dart';
import '../../model/override_entry.dart';

/// Opens the periodic update settings for one remote target.
Future<void> showAutoUpdateDialog(
  BuildContext context,
  AppController app, {
  required ConfigEntry? config,
  required OverrideEntry? override,
  int? storageEpoch,
  bool Function()? isCurrent,
  ValueChanged<ModalRoute<dynamic>?>? onRoute,
}) async {
  final epoch = storageEpoch ?? app.storageEpoch;
  final source = config?.source ?? override?.source;
  final id = config?.id ?? override?.id;
  final policy = config?.update ?? override?.update;
  if (source == null || id == null || policy == null) return;
  final history = config?.errorMessage ?? override?.errorMessage;
  bool sameHistory(UpdatePolicy? current, AppMessage? error) =>
      current != null &&
      current.lastAttempt == policy.lastAttempt &&
      current.lastResult == policy.lastResult &&
      error == history;
  bool historyCurrent() {
    if (epoch != app.storageEpoch || epoch != app.state.storageEpoch) {
      return false;
    }
    if (config != null) {
      if (!app.configsLoaded) return true;
      final current = app.collection.find(id);
      return current != null &&
          current.remote &&
          current.source == source &&
          current.revision == config.revision &&
          sameHistory(current.update, current.errorMessage);
    }
    if (!app.overridesLoaded) return true;
    final current = app.overrides.where((entry) => entry.id == id).firstOrNull;
    return current != null &&
        override!.sameDownloadInput(current) &&
        sameHistory(current.update, current.errorMessage);
  }

  final originRoute = ModalRoute.of(context);
  ModalRoute<dynamic>? ownedPopup;
  bool ownerCurrent({Route<dynamic>? popup}) =>
      context.mounted &&
      app.foreground &&
      AppTaskActivity.isActive(context, ownedPopup: popup ?? ownedPopup) &&
      AppTaskActivity.routeIsActive(
        originRoute,
        ownedPopup: popup ?? ownedPopup,
      );
  if (!ownerCurrent() || originRoute?.isCurrent == false) return;
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
    context: context,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    barrierColor: Theme.of(context).dialogTheme.barrierColor ?? Colors.black54,
    animationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (dialogContext) => OperationNoticeHost(
      onDismiss: () => Navigator.of(dialogContext).maybePop(),
      child: _AutoUpdateDialog(
        app: app,
        policy: policy,
        historyError: history,
        historyCurrent: historyCurrent,
        ownerCurrent: ownerCurrent,
        targetCurrent: () => isCurrent?.call() ?? true,
        staleMessage: () =>
            epoch != app.storageEpoch || epoch != app.state.storageEpoch
            ? messages.storageContextChanged
            : (config != null
                  ? messages.configChangedReopen
                  : messages.overrideChangedReopen),
        submit: (values, owner) => app.submitAndWait({
          'action': config != null ? 'setConfigUpdate' : 'setOverrideUpdate',
          'id': id,
          'revision': config?.revision ?? override!.revision,
          'expectedSource': source,
          if (override != null) ...{
            'expectedProxyName': override.proxyName,
            'expectedAddNoResolve': override.addNoResolve,
          },
          ...values,
          'storageEpoch': epoch,
        }, feedbackOwner: owner),
      ),
    ),
  );
  ownedPopup = route;
  onRoute?.call(route);
  try {
    await navigator.push(route);
  } finally {
    ownedPopup = null;
    onRoute?.call(null);
  }
}

class _AutoUpdateDialog extends StatefulWidget {
  const _AutoUpdateDialog({
    required this.app,
    required this.policy,
    required this.historyError,
    required this.historyCurrent,
    required this.submit,
    required this.ownerCurrent,
    required this.targetCurrent,
    required this.staleMessage,
  });

  final AppController app;
  final UpdatePolicy policy;
  final AppMessage? historyError;
  final bool Function() historyCurrent;
  final bool Function({Route<dynamic>? popup}) ownerCurrent;
  final bool Function() targetCurrent;
  final AppMessage Function() staleMessage;
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
  bool _historyScheduled = false;
  bool _historyQueued = false;
  AppMessage? _error;
  ModalRoute<dynamic>? _route;
  Listenable? _routeChanges;
  bool _current({ModalRoute<dynamic>? popup}) =>
      mounted &&
      widget.ownerCurrent(popup: popup) &&
      AppTaskActivity.routeIsActive(_route, ownedPopup: popup);

  bool get _eligible => _current();

  Future<bool> _showError(AppMessage message) {
    final epoch = widget.app.storageEpoch;
    bool current({ModalRoute<dynamic>? popup}) =>
        _current(popup: popup) &&
        epoch == widget.app.storageEpoch &&
        identical(_error, message);
    return showAppNotice(
      context,
      message,
      title: (strings) => strings.autoUpdate,
      identity: message,
      eligibilityChanges: widget.app,
      isCurrent: current,
      isCurrentWithPopup: (popup) => current(popup: popup),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    final changes = AppTaskNavigatorObserver.changesFor(_route);
    if (!identical(_routeChanges, changes)) {
      _routeChanges?.removeListener(_scheduleHistory);
      _routeChanges = changes;
      _routeChanges?.addListener(_scheduleHistory);
    }
    _scheduleHistory();
  }

  void _scheduleHistory() {
    if (!mounted ||
        _historyScheduled ||
        _historyQueued ||
        !const ['failed', 'applyFailed'].contains(widget.policy.lastResult)) {
      return;
    }
    _historyQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _historyQueued = false;
      if (!mounted ||
          _historyScheduled ||
          !_current() ||
          _saving ||
          !widget.targetCurrent() ||
          !widget.historyCurrent()) {
        return;
      }
      _historyScheduled = true;
      unawaited(_showHistory());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _showHistory() async {
    final history = widget.historyError;
    bool current({ModalRoute<dynamic>? popup}) =>
        _current(popup: popup) && !_saving && widget.historyCurrent();
    String summary(AppLocalizations strings) =>
        widget.policy.lastResult == 'applyFailed'
        ? strings.autoUpdateApplyFailed
        : history?.summary(strings) ?? strings.autoUpdateFailed;
    String? detail(AppLocalizations strings) {
      if (history == null) return null;
      final values = [
        if (widget.policy.lastResult == 'applyFailed') history.summary(strings),
        ?history.technicalDetail(strings),
      ];
      return values.isEmpty ? null : values.join('\n\n');
    }

    final shown = await showLocalizedOperationNotice(
      context,
      summary,
      technicalDetail: detail,
      title: (strings) => strings.autoUpdate,
      eligibilityChanges: widget.app,
      isCurrent: current,
      isCurrentWithPopup: (popup) => current(popup: popup),
      identity: (
        'auto-update-history',
        widget.policy.lastAttempt,
        widget.policy.lastResult,
      ),
    );
    if (!shown && mounted) _historyScheduled = false;
  }

  @override
  void initState() {
    super.initState();
    _enabled = widget.policy.enabled;
    _hours = widget.policy.hours;
    widget.app.addListener(_scheduleHistory);
  }

  Future<void> _save() async {
    if (_saving || !_eligible) return;
    if (!widget.targetCurrent()) {
      final message = widget.staleMessage();
      setState(() => _error = message);
      await _showError(message);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await widget.submit({
      'enabled': _enabled,
      'hours': _hours,
    }, _feedbackOwner);
    if (!mounted || !_eligible) return;
    if (result?.resultSuccess != true) {
      final message =
          result?.resultMessageDescription ??
          widget.app.commandErrorMessage ??
          const AppMessage('operationFailed');
      setState(() {
        _saving = false;
        _error = message;
      });
      if (await _showError(message)) {
        widget.app.acknowledgeLocalFeedback(_feedbackOwner, result: result);
      }
      return;
    }
    widget.app.acknowledgeLocalFeedback(_feedbackOwner, result: result);
    Navigator.pop(context);
  }

  @override
  void dispose() {
    widget.app.removeListener(_scheduleHistory);
    _routeChanges?.removeListener(_scheduleHistory);
    _feedbackOwner.value = false;
    _feedbackOwner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final editable = _enabled && !_saving && _eligible;
    final dialog = AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(strings.autoUpdate)),
          Semantics(
            label: strings.autoUpdate,
            child: Switch(
              key: const ValueKey('auto-update-enabled'),
              value: _enabled,
              onChanged: _saving || !_eligible
                  ? null
                  : (value) {
                      if (_eligible && !_saving) {
                        setState(() => _enabled = value);
                      }
                    },
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
                onSelected: (value) {
                  if (_eligible && !_saving && _enabled) {
                    setState(() => _hours = value);
                  }
                },
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
                if (!const [
                  'failed',
                  'applyFailed',
                ].contains(widget.policy.lastResult))
                  Text(switch (widget.policy.lastResult) {
                    'applied' => strings.autoUpdateApplied,
                    'updated' || 'saved' => strings.autoUpdateSaved,
                    'unchanged' => strings.autoUpdateUnchanged,
                    null => strings.autoUpdateNever,
                    _ => strings.resultUnconfirmed,
                  }, style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving || !_eligible
              ? null
              : () {
                  if (_eligible) Navigator.pop(context);
                },
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const ValueKey('auto-update-save'),
          onPressed: _saving || !_eligible ? null : _save,
          child: Text(strings.save),
        ),
      ],
    );
    return AnimatedBuilder(
      animation: _route?.animation ?? const AlwaysStoppedAnimation<double>(1),
      builder: (_, child) {
        final active = _eligible;
        return IgnorePointer(
          ignoring: !active,
          child: ExcludeFocus(
            excluding: !active,
            child: ExcludeSemantics(excluding: !active, child: child!),
          ),
        );
      },
      child: dialog,
    );
  }
}
