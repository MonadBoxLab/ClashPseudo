import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../navigation/task_activity.dart';
import '../theme/app_theme.dart';
import '../components/feedback/operation_notice.dart';
import '../../l10n/app_localizations.dart';
import '../../model/messages.dart';
import '../../model/app_snapshot.dart';
import '../../model/config_entry.dart';
import '../components/feedback/confirm_action.dart';
import '../../model/backup_data.dart';
import '../locale/message_text.dart';

/// Two settings actions. Candidates and mechanical recovery stay internal.
class BackupSettingsActions extends StatefulWidget {
  const BackupSettingsActions({
    super.key,
    required this.app,
    this.active = true,
  });

  final AppController app;
  final bool active;

  @override
  State<BackupSettingsActions> createState() => _BackupSettingsActionsState();
}

class _BackupSettingsActionsState extends State<BackupSettingsActions> {
  final _feedbackOwner = ValueNotifier(false);
  final _presentations = <Object>{};
  final _rowKeys = {true: GlobalKey(), false: GlobalKey()};
  bool _working = false;
  bool _waiting = false;
  bool _importing = false;
  bool _cancelRequested = false;
  bool _relinquished = false;
  bool _ownerCheckScheduled = false;
  AppController? _operationApp;
  Completer<void>? _resume;
  String? _requestId;
  int _runner = 0;
  ModalRoute<dynamic>? _dialogRoute;
  ModalRoute<dynamic>? _observedRoute;
  Animation<double>? _routeAnimation;
  ModalRoute<dynamic>? _originRoute;
  (AppTask, Object)? _originTask;
  AppMessage? _message;
  AppMessage? _cleanupMessage;
  Future<void>? _cancellation;
  Map<String, dynamic>? _outcome;
  bool? _resultSuccess;

  AppController get app => widget.app;
  bool get _interactive => app.foreground && app.interactive;

  bool get _routeCurrent {
    if (!mounted || !widget.active) return false;
    final route = ModalRoute.of(context);
    if (_working) {
      if (!identical(_operationApp, app) || !identical(_originRoute, route)) {
        return false;
      }
      final task = AppTaskScope.maybeOf(context);
      final origin = _originTask;
      if (origin == null
          ? task != null
          : task == null ||
                task.task != origin.$1 ||
                !identical(task.owner, origin.$2)) {
        return false;
      }
    }
    return AppTaskActivity.routeIsActive(route, ownedPopup: _dialogRoute);
  }

  bool get _current =>
      _routeCurrent &&
      AppTaskActivity.isActive(context, ownedPopup: _dialogRoute);
  bool _live(int run) => mounted && run == _runner;
  bool _usable(int run) =>
      _live(run) && !_cancelRequested && _current && _interactive;

  Future<bool> _awaitForeground(int run) async {
    final app = this.app;
    while (_live(run) && !_relinquished) {
      if (!_routeCurrent || (_interactive && !_current)) {
        _relinquish();
        return false;
      }
      if (_interactive) return true;
      // SAF may return during inactive, before resumed restores task eligibility.
      final resume = Completer<void>();
      _resume = resume;
      void changed() {
        if (!resume.isCompleted &&
            (_interactive || !_live(run) || _relinquished || !_routeCurrent)) {
          resume.complete();
        }
      }

      app.addListener(changed);
      try {
        changed();
        await resume.future;
      } finally {
        app.removeListener(changed);
        if (identical(_resume, resume)) _resume = null;
      }
    }
    return false;
  }

  void _releaseResume() {
    final resume = _resume;
    if (resume != null && !resume.isCompleted) resume.complete();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    final animation = route?.animation;
    if (!identical(_observedRoute, route) ||
        !identical(_routeAnimation, animation)) {
      _routeAnimation?.removeStatusListener(_routeStatusChanged);
      _observedRoute = route;
      _routeAnimation = animation;
      animation?.addStatusListener(_routeStatusChanged);
    }
    _syncOwner();
  }

  void _routeStatusChanged(AnimationStatus _) {
    if (mounted) _syncOwner();
  }

  @override
  void didUpdateWidget(BackupSettingsActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app != app || !widget.active) _relinquish();
    _syncOwner();
  }

  void _syncOwner() {
    _feedbackOwner.value =
        (_working || _presentations.isNotEmpty) &&
        _interactive &&
        _current &&
        !_relinquished;
    if (!_working) return;
    // Lifecycle suspension preserves I/O, never a changed task or route identity.
    if (!_routeCurrent || (_interactive && !_current)) {
      if (!_ownerCheckScheduled) {
        _ownerCheckScheduled = true;
        final run = _runner;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _ownerCheckScheduled = false;
          if (_live(run) &&
              _working &&
              (!_routeCurrent || (_interactive && !_current))) {
            _relinquish();
          }
        });
      }
    }
  }

  void _relinquish() {
    if (!_working || _relinquished) return;
    _relinquished = true;
    _cancelRequested = true;
    _releaseResume();
    _feedbackOwner.value = false;
    if (_requestId case final request?) unawaited(_cancel(request));
  }

  void _observeDialog(ModalRoute<dynamic>? route) {
    if (!mounted) return;
    _dialogRoute = route;
    _syncOwner();
  }

  int _begin(bool importing) {
    final run = ++_runner;
    _operationApp = app;
    _originRoute = ModalRoute.of(context);
    final task = AppTaskScope.maybeOf(context);
    _originTask = task == null ? null : (task.task, task.owner);
    setState(() {
      _working = true;
      _waiting = false;
      _importing = importing;
      _cancelRequested = false;
      _relinquished = false;
      _message = null;
      _cleanupMessage = null;
      _cancellation = null;
      _outcome = null;
      _resultSuccess = null;
    });
    _syncOwner();
    return run;
  }

  void _finish(int run) {
    if (!_live(run)) return;
    setState(() {
      _working = false;
      _waiting = false;
      _requestId = null;
      _originRoute = null;
      _originTask = null;
    });
    _syncOwner();
  }

  void _wait(int run, bool value) {
    if (!_live(run) || _waiting == value) return;
    setState(() => _waiting = value);
  }

  Future<void> _cancel(String request) =>
      _cancellation ??= _sendCancel(request);

  Future<void> _sendCancel(String request) async {
    try {
      await (_operationApp ?? app).platform.backupCancel(request);
    } catch (error) {
      _cleanupMessage = (_cleanupMessage ?? const AppMessage('backupFailed'))
          .withDetail(_failureMessage(error));
    }
  }

  Future<void> _discard(String token) async {
    try {
      await (_operationApp ?? app).platform.backupDiscard(token);
    } catch (error) {
      _cleanupMessage = (_cleanupMessage ?? const AppMessage('backupFailed'))
          .withDetail(_failureMessage(error));
    }
  }

  Future<void> _requestCancel() async {
    final request = _requestId;
    if (!_working ||
        !_interactive ||
        !_current ||
        request == null ||
        _cancelRequested) {
      return;
    }
    setState(() => _cancelRequested = true);
    await _cancel(request);
  }

  Future<bool> _confirm(BackupCandidate candidate) async {
    try {
      final state = app.state;
      return await confirmAction(
        context,
        onRoute: _observeDialog,
        title: (strings) => strings.backupConfirmTitle,
        message: (strings) => [
          strings.backupConfirmMessage,
          candidate.summary.hasSelection
              ? strings.backupSelected(candidate.summary.selectedName!)
              : strings.backupNoSelection,
          !state.confirmed
              ? strings.backupConfirmUnconfirmed
              : state.running
              ? strings.backupConfirmRunning
              : strings.backupConfirmStopped,
        ].join('\n\n'),
        subject: AppLocalizations.of(context).backupCounts(
          candidate.summary.configurations,
          candidate.summary.overrides,
        ),
        confirmLabel: (strings) => strings.backupRestore,
      );
    } finally {
      _dialogRoute = null;
      if (mounted) _syncOwner();
    }
  }

  bool _canStart(int epoch) =>
      !_working &&
      widget.active &&
      _current &&
      _interactive &&
      app.canManageStoredData &&
      app.state.storageEpoch == epoch;

  Future<void> _export(int epoch) async {
    final app = this.app;
    if (!_canStart(epoch)) return;
    final run = _begin(false);
    String? token;
    AppSnapshot? result;
    try {
      _wait(run, true);
      final request = _newRequest();
      _requestId = request;
      result = await app.submitAndWait({
        'action': 'prepareBackup',
        'requestId': request,
        'createdAtMillis': DateTime.now().millisecondsSinceEpoch,
        'storageEpoch': epoch,
      }, feedbackOwner: _feedbackOwner);
      final detail = result?.backupResult;
      if (isBackupToken(detail?['token'])) token = detail!['token'] as String;
      if (!await _awaitForeground(run) || !_usable(run)) return;
      if (result == null) {
        await _cancel(request);
        _message = _submissionMessage(request);
      } else if (!result.resultSuccess) {
        _message =
            result.resultMessageDescription ?? const AppMessage('backupFailed');
      } else {
        if (detail == null ||
            detail['retired'] == true ||
            detail['status'] != 'prepared' ||
            detail['requestId'] != request) {
          throw const FormatException('Unexpected prepared backup result');
        }
        final prepared = BackupCandidate.fromMap(detail);
        token = prepared.token;
        // Adopt the prepared candidate for the requested operation.
        app.acknowledgeLocalFeedback(_feedbackOwner, result: result);
        final saveRequest = _newRequest();
        _requestId = saveRequest;
        final saved = await app.platform.backupSaveExport(
          requestId: saveRequest,
          token: token,
          title: 'clash-pseudo-backup.zip',
        );
        if (!_live(run)) return;
        if (saved['requestId'] != saveRequest) {
          throw const FormatException('Retired export request');
        }
        _outcome = Map<String, dynamic>.of(saved);
        _message = saved['status'] == 'saved'
            ? const AppMessage('backupExportSaved')
            : _documentMessage(saved);
      }
    } catch (error) {
      _message = _failureMessage(error);
    } finally {
      if (_live(run) && !_relinquished && !_interactive) {
        await _awaitForeground(run);
      }
      if (token != null) {
        _wait(run, true);
        await _discard(token);
      }
      await _cancellation;
      if (_cleanupMessage case final error?) {
        _message = (_message ?? const AppMessage('backupFailed')).withDetail(
          error,
        );
      }
      if (_message != null || _outcome != null) {
        _presentResult(run, result);
      }
      _finish(run);
    }
  }

  Future<void> _import(int epoch) async {
    final app = this.app;
    if (!_canStart(epoch)) return;
    final run = _begin(true);
    String? token;
    AppSnapshot? result;
    var submitted = false;
    try {
      final pickRequest = _newRequest();
      _requestId = pickRequest;
      _wait(run, true);
      final picked = await app.platform.backupPickImport(pickRequest);
      if (isBackupToken(picked['token'])) token = picked['token'] as String;
      if (!await _awaitForeground(run) || !_usable(run)) return;
      if (picked['requestId'] != pickRequest) {
        throw const FormatException('Retired import request');
      }
      if (picked['status'] != 'ready' || picked['retired'] == true) {
        _message = _documentMessage(picked);
      } else {
        if (token == null) {
          throw const FormatException('Missing private backup token');
        }
        result = await app.submitAndWait({
          'action': 'inspectBackup',
          'requestId': pickRequest,
          'token': token,
          'storageEpoch': epoch,
        }, feedbackOwner: _feedbackOwner);
        if (!await _awaitForeground(run) || !_usable(run)) return;
        if (result == null) {
          await _cancel(pickRequest);
          _message = _submissionMessage(pickRequest);
        } else if (!result.resultSuccess) {
          _message =
              result.resultMessageDescription ??
              const AppMessage('backupInvalid');
        } else {
          final detail = result.backupResult;
          if (detail == null ||
              detail['retired'] == true ||
              detail['status'] != 'inspected' ||
              detail['requestId'] != pickRequest) {
            throw const FormatException('Unexpected inspected backup result');
          }
          final candidate = BackupCandidate.fromMap(detail);
          if (candidate.token != token) {
            throw const FormatException('Inspected token changed');
          }
          app.acknowledgeLocalFeedback(_feedbackOwner, result: result);
          result = null;
          _requestId = null;
          _wait(run, false);
          if (!app.state.storageReady ||
              app.state.storageRestoring ||
              app.state.storageEpoch != epoch) {
            throw ConfigFailure(messages.storageUnavailable);
          }
          if (!await _confirm(candidate) || !_usable(run)) {
            return;
          }
          final restoreRequest = _newRequest();
          _requestId = restoreRequest;
          _wait(run, true);
          submitted = true;
          result = await app.submitAndWait({
            'action': 'restoreBackup',
            'requestId': restoreRequest,
            'token': token,
            'storageEpoch': epoch,
          }, feedbackOwner: _feedbackOwner);
          if (!_live(run)) return;
          if (result == null) {
            await _cancel(restoreRequest);
            submitted = app.lastCommand?['requestId'] == restoreRequest;
            _message = submitted
                ? const AppMessage('backupRestoreUnconfirmed')
                : messages.requestNotAccepted;
            if (submitted) _outcome = {'committed': null};
          } else {
            _resultSuccess = result.resultSuccess;
            final restored = result.backupResult;
            if (restored == null ||
                restored['token'] != token ||
                !restored.containsKey('committed')) {
              _outcome = {'committed': null};
              _message = const AppMessage('backupRestoreUnconfirmed');
            } else {
              _outcome = Map<String, dynamic>.of(restored);
              _message =
                  result.resultMessageDescription ??
                  (result.resultSuccess
                      ? null
                      : const AppMessage('backupFailed'));
            }
          }
        }
      }
    } catch (error) {
      if (submitted) {
        if (_requestId case final request?) await _cancel(request);
        _outcome ??= {'committed': null};
        _message = (_message ?? const AppMessage('backupRestoreUnconfirmed'))
            .withDetail(error);
      } else {
        _message = _failureMessage(error);
      }
    } finally {
      if (_live(run) && !_relinquished && !_interactive) {
        await _awaitForeground(run);
      }
      if (token != null) {
        _wait(run, true);
        await _discard(token);
      }
      await _cancellation;
      if (_cleanupMessage case final error?) {
        _message = (_message ?? const AppMessage('backupFailed')).withDetail(
          error,
        );
      }
      if (_message != null || _outcome != null) {
        _presentResult(run, result);
      }
      _finish(run);
    }
  }

  AppMessage _submissionMessage(String request) =>
      app.lastCommand?['requestId'] == request
      ? app.commandErrorMessage ?? messages.operationNotCompletedRetry
      : messages.requestNotAccepted;

  void _presentResult(int run, AppSnapshot? result) {
    if (!_live(run) || _relinquished || !_current || !_interactive) return;
    final owner = app;
    final command = owner.lastCommand;
    final epoch = owner.storageEpoch;
    final importing = _importing;
    final message = _message;
    final detail = _outcome;
    final resultSuccess = _resultSuccess;
    if (message?.id == 'backupCancelled' &&
        message?.detail == null &&
        (detail == null || !detail.containsKey('committed'))) {
      owner.acknowledgeLocalFeedback(_feedbackOwner, result: result);
      return;
    }
    final issue =
        resultSuccess == false ||
        (detail != null && detail.containsKey('committed')
            ? detail['committed'] != true ||
                  detail['ready'] == false ||
                  const [
                    'failed',
                    'unconfirmed',
                    'cancelled',
                  ].contains(detail['connectionStatus']) ||
                  const [
                    'failed',
                    'cancelled',
                  ].contains(detail['settingsStatus']) ||
                  const [
                    'failed',
                    'cancelled',
                  ].contains(detail['scheduleStatus'])
            : message?.id != 'backupExportSaved') ||
        message?.detail != null ||
        detail?['errorCode'] != null ||
        detail?['errorDetail'] != null ||
        detail?['cleanupError'] != null;
    final identity = Object();
    _presentations.add(identity);
    bool current({ModalRoute<dynamic>? popup}) =>
        mounted &&
        identical(app, owner) &&
        widget.active &&
        _interactive &&
        owner.storageEpoch == epoch &&
        AppTaskActivity.isActive(context, ownedPopup: popup) &&
        AppTaskActivity.routeIsActive(
          ModalRoute.of(context),
          ownedPopup: popup,
        );
    void release() {
      if (!mounted) return;
      _presentations.remove(identity);
      _syncOwner();
    }

    unawaited(
      showLocalizedOperationNotice(
        context,
        (strings) =>
            _resultText(strings, detail, message, resultSuccess: resultSuccess),
        technicalDetail: (strings) =>
            _resultTechnicalText(strings, detail, message),
        title: (strings) =>
            importing ? strings.backupImport : strings.backupExport,
        error: issue,
        identity: identity,
        eligibilityChanges: owner,
        isCurrent: current,
        isCurrentWithPopup: (popup) => current(popup: popup),
        onPresented: () {
          if (identical(owner.lastCommand, command)) {
            owner.acknowledgeLocalFeedback(_feedbackOwner, result: result);
          }
          release();
        },
      ).then((presented) {
        if (!presented) release();
      }),
    );
  }

  Widget _slot(BuildContext context, Widget child) {
    final reduced =
        MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled;
    return AnimatedSwitcher(
      duration: reduced ? Duration.zero : const Duration(milliseconds: 180),
      switchInCurve: Curves.easeInOutCubic,
      switchOutCurve: Curves.easeInOutCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: reduced ? const AlwaysStoppedAnimation(1) : animation,
        child: child,
      ),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.center,
        children: [
          if (!reduced)
            for (final child in previous)
              ExcludeFocus(
                child: IgnorePointer(child: ExcludeSemantics(child: child)),
              ),
          ?current,
        ],
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      _syncOwner();
      final state = app.state;
      final enabled =
          widget.active &&
          _interactive &&
          _current &&
          !_working &&
          app.canManageStoredData;
      final palette = HomePalette.of(context);
      Widget action(bool importing) {
        final busy = _working && _importing == importing;
        final waiting = busy && _waiting && _current && _interactive;
        final color = importing ? palette.localSource : palette.syncAction;
        final row = KeyedSubtree(
          key: _rowKeys[importing],
          child: ListTile(
            key: ValueKey(importing ? 'backup-import' : 'backup-export'),
            enabled: enabled || busy,
            leading: SizedBox.square(
              dimension: 24,
              child: _slot(
                context,
                waiting
                    ? CircularProgressIndicator(strokeWidth: 2, color: color)
                    : Icon(
                        importing ? Icons.folder_open_outlined : Icons.save_alt,
                        color: enabled
                            ? color
                            : Theme.of(context).disabledColor,
                      ),
              ),
            ),
            title: _actionLabel(
              context,
              (strings) =>
                  importing ? strings.backupImport : strings.backupExport,
            ),
            trailing: SizedBox.square(
              dimension: 48,
              child: _slot(
                context,
                busy
                    ? IconButton(
                        key: const ValueKey('backup-cancel'),
                        tooltip: AppLocalizations.of(context).cancel,
                        onPressed:
                            waiting && _requestId != null && !_cancelRequested
                            ? _requestCancel
                            : null,
                        icon: const Icon(Icons.close),
                      )
                    : Icon(
                        Icons.chevron_right,
                        color: enabled
                            ? color
                            : Theme.of(context).disabledColor,
                      ),
              ),
            ),
            onTap: enabled
                ? () => importing
                      ? _import(state.storageEpoch)
                      : _export(state.storageEpoch)
                : null,
          ),
        );
        return MediaQuery.disableAnimationsOf(context) ||
                !TickerMode.valuesOf(context).enabled
            ? row
            : AnimatedSize(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeInOutCubic,
                alignment: Alignment.topCenter,
                child: row,
              );
      }

      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [action(true), action(false)],
      );
    },
  );

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_routeStatusChanged);
    _runner++;
    _releaseResume();
    _feedbackOwner.value = false;
    _feedbackOwner.dispose();
    if (_requestId case final request?) unawaited(_cancel(request));
    super.dispose();
  }
}

Widget _actionLabel(
  BuildContext context,
  String Function(AppLocalizations) label,
) => Text(
  label(AppLocalizations.of(context)),
  style:
      ListTileTheme.of(context).titleTextStyle ??
      Theme.of(context).textTheme.bodyLarge,
);

String _resultText(
  AppLocalizations strings,
  Map<String, dynamic>? detail,
  AppMessage? message, {
  bool? resultSuccess,
}) {
  final texts = <String>[];
  void addCause(String field) {
    final value = detail?[field];
    if (value == null) return;
    String text;
    try {
      if (value is String) return;
      text = AppMessage.fromMap(value).summary(strings);
    } on FormatException {
      return;
    }
    if (!texts.contains(text)) texts.add(text);
  }

  if (detail != null && detail.containsKey('committed')) {
    texts.add(switch (detail['committed']) {
      true => strings.backupRestored,
      false => strings.backupNotRestored,
      _ => strings.backupRestoreUnconfirmed,
    });
    final connection = switch (detail['connectionStatus']) {
      'stopped' => strings.backupConnectionStopped,
      'notStarted' => strings.backupConnectionNotStarted,
      'restored' => strings.backupConnectionRestored,
      'cancelled' => strings.backupConnectionCancelled,
      'failed' => strings.backupConnectionFailed,
      'unconfirmed' => strings.temporaryStatusUnavailable,
      _ => null,
    };
    if (connection != null) {
      texts.add(connection);
      addCause('connectionMessage');
    }
    if (const ['failed', 'cancelled'].contains(detail['settingsStatus'])) {
      texts.add(strings.backupSettingsRefreshFailed);
      addCause('settingsMessage');
    }
    if (const ['failed', 'cancelled'].contains(detail['scheduleStatus'])) {
      texts.add(strings.backupSchedulesFailed);
      addCause('scheduleMessage');
    }
    if (detail['ready'] == false) texts.add(strings.storageUnavailable);
  }
  addCause('errorCode');
  addCause('errorDetail');
  addCause('cleanupError');
  if (message != null) {
    final issue =
        detail?['committed'] == true && message.id == 'backupRestoredWithIssue'
        ? message.args['issue']
        : null;
    final text = (issue is AppMessage ? issue : message).summary(strings);
    if (!texts.contains(text)) texts.add(text);
  }
  if (resultSuccess == false &&
      !texts.contains(strings.operationNotCompleted)) {
    texts.add(strings.operationNotCompleted);
  }
  return texts.join('\n\n');
}

String? _resultTechnicalText(
  AppLocalizations strings,
  Map<String, dynamic>? detail,
  AppMessage? message,
) {
  final parts = <String>{};
  for (final field in const [
    'connectionMessage',
    'settingsMessage',
    'scheduleMessage',
    'errorCode',
    'errorDetail',
    'cleanupError',
  ]) {
    final value = detail?[field];
    if (value == null) continue;
    if (value is String) {
      if (value.isNotEmpty) parts.add(value);
      continue;
    }
    try {
      parts.add(AppMessage.fromMap(value).resolve(strings));
    } on FormatException {
      final cause = value is Map ? value['detail'] : null;
      parts.add(
        cause is String && cause.isNotEmpty
            ? cause
            : 'Invalid backup $field message',
      );
    }
  }
  final original = message?.technicalDetail(strings);
  if (original != null) parts.add(original);
  return parts.isEmpty ? null : parts.join('\n\n');
}

String _newRequest() =>
    'backup-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
    '${Random.secure().nextInt(1 << 32).toRadixString(36)}';

AppMessage _documentMessage(Map<String, dynamic> response) {
  final message = response['externalMayBePartial'] == true
      ? const AppMessage('backupDocumentWriteUnconfirmed')
      : switch (response['status']) {
          'cancelled' => const AppMessage('backupCancelled'),
          'expired' => const AppMessage('backupCandidateExpired'),
          'busy' => messages.operationInProgress,
          _ => const AppMessage('backupFailed'),
        };
  if (message.id == 'backupCancelled' &&
      response['errorCode'] == null &&
      response['errorDetail'] == null &&
      response['cleanupError'] == null) {
    return message;
  }
  return message.withDetail({
    for (final key in [
      'status',
      'errorCode',
      'errorDetail',
      'cleanupError',
      'externalMayBePartial',
      'retired',
    ])
      if (response[key] != null) key: response[key],
  });
}

AppMessage _failureMessage(Object error) => switch (error) {
  ConfigFailure() => error.message,
  PlatformFailure() => messageFromFailure(
    error,
    fallback: const AppMessage('backupFailed'),
  ),
  FormatException() => const AppMessage('backupInvalid').withDetail(error),
  _ => const AppMessage('backupFailed').withDetail(error),
};
