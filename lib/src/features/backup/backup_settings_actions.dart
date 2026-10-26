import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../app/app_theme.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/messages.dart';
import '../../model/app_snapshot.dart';
import '../configs/config_entry.dart';
import '../configs/widgets/confirm_action.dart';
import 'backup_data.dart';

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
  AppMessage? _message;
  Map<String, dynamic>? _outcome;

  AppController get app => widget.app;
  bool get _current =>
      widget.active &&
      (_dialogRoute?.isCurrent == true ||
          (ModalRoute.of(context)?.isCurrent ?? true));
  bool _live(int run) => mounted && run == _runner;
  bool _usable(int run) =>
      _live(run) && !_cancelRequested && _current && app.foreground;

  Future<bool> _awaitForeground(int run) async {
    if (!_live(run) || _relinquished || !_current) return false;
    final app = this.app;
    if (!app.foreground) {
      // SAF results may arrive before resumed. Preserve the live task through that
      // lifecycle interval.
      final resume = Completer<void>();
      _resume = resume;
      void changed() {
        if (!resume.isCompleted &&
            (app.foreground || !_live(run) || _relinquished)) {
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
    return _live(run) && !_relinquished && _current && app.foreground;
  }

  void _releaseResume() {
    final resume = _resume;
    if (resume != null && !resume.isCompleted) resume.complete();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncOwner();
  }

  @override
  void didUpdateWidget(BackupSettingsActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app != app || !widget.active) _relinquish();
    _syncOwner();
  }

  void _syncOwner() {
    if (_working && !_current) {
      // Evaluate route ownership after both the dialog and covered page observe the
      // route update.
      if (!_ownerCheckScheduled) {
        _ownerCheckScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _ownerCheckScheduled = false;
          if (mounted && _working && !_current) _relinquish();
        });
      }
      return;
    }
    _feedbackOwner.value = _working && _current && !_relinquished;
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
    setState(() {
      _working = true;
      _waiting = false;
      _importing = importing;
      _cancelRequested = false;
      _relinquished = false;
      _message = null;
      _outcome = null;
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
    });
    _feedbackOwner.value = false;
  }

  void _wait(int run, bool value) {
    if (!_live(run) || _waiting == value) return;
    setState(() => _waiting = value);
  }

  Future<void> _cancel(String request) async {
    try {
      await (_operationApp ?? app).platform.backupCancel(request);
    } catch (_) {
      // Native drain retains its gate through actual execution and cancellation reply
      // handling.
    }
  }

  Future<void> _discard(String token) async {
    try {
      await (_operationApp ?? app).platform.backupDiscard(token);
    } catch (_) {
      // Native reader pins defer retirement until the actual I/O has finished.
    }
  }

  Future<void> _requestCancel() async {
    final request = _requestId;
    if (!_working || request == null || _cancelRequested) return;
    setState(() => _cancelRequested = true);
    await _cancel(request);
  }

  Future<bool> _confirm({
    required bool importing,
    BackupCandidate? candidate,
  }) async {
    try {
      final state = app.state;
      return await confirmAction(
        context,
        onRoute: _observeDialog,
        title: (strings) =>
            importing ? strings.backupConfirmTitle : strings.backupExport,
        message: (strings) => importing
            ? [
                strings.backupConfirmMessage,
                candidate!.summary.hasSelection
                    ? strings.backupSelected(candidate.summary.selectedName!)
                    : strings.backupNoSelection,
                state.running
                    ? strings.backupConfirmRunning
                    : strings.backupConfirmStopped,
              ].join('\n\n')
            : '${strings.backupSensitiveNotice}\n\n${strings.backupScopeNotice}',
        subject: candidate == null
            ? null
            : AppLocalizations.of(context).backupCounts(
                candidate.summary.configurations,
                candidate.summary.overrides,
              ),
        confirmLabel: (strings) =>
            importing ? strings.backupRestore : strings.backupExport,
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
      app.foreground &&
      !app.busy &&
      app.platformErrorMessage == null &&
      app.state.storageReady &&
      !app.state.storageRestoring &&
      app.state.storageEpoch == epoch;

  Future<void> _export(int epoch) async {
    final app = this.app;
    if (!_canStart(epoch)) return;
    final run = _begin(false);
    String? token;
    AppSnapshot? result;
    var adopted = false;
    try {
      if (!await _confirm(importing: false) || !_usable(run)) return;
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
            detail['status'] != 'prepared' ||
            detail['requestId'] != request) {
          throw const FormatException('Unexpected prepared backup result');
        }
        final prepared = BackupCandidate.fromMap(detail);
        token = prepared.token;
        // Adopt the prepared candidate for the requested operation.
        app.acknowledgeLocalFeedback(_feedbackOwner, result: result);
        adopted = true;
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
        _message = saved['status'] == 'saved'
            ? const AppMessage('backupExportSaved')
            : _documentMessage(saved);
      }
      adopted = await _presentResult(run) || adopted;
    } catch (error) {
      _message = _failureMessage(error);
      adopted = await _presentResult(run) || adopted;
    } finally {
      if (token != null) {
        _wait(run, true);
        await _discard(token);
      }
      if (adopted) app.acknowledgeLocalFeedback(_feedbackOwner, result: result);
      _finish(run);
    }
  }

  Future<void> _import(int epoch) async {
    final app = this.app;
    if (!_canStart(epoch)) return;
    final run = _begin(true);
    String? token;
    AppSnapshot? result;
    var adopted = false;
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
      if (picked['status'] != 'ready') {
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
          if (!app.state.confirmed || app.state.storageEpoch != epoch) {
            throw ConfigFailure(messages.statusUnconfirmedVerify);
          }
          if (!await _confirm(importing: true, candidate: candidate) ||
              !_usable(run)) {
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
            final restored = result.backupResult;
            if (restored == null ||
                restored['token'] != token ||
                !restored.containsKey('committed')) {
              _outcome = {'committed': null};
              _message = const AppMessage('backupRestoreUnconfirmed');
            } else {
              _outcome = Map<String, dynamic>.of(restored);
              _message = result.resultMessageDescription;
            }
          }
        }
      }
      adopted = await _presentResult(run);
    } catch (error) {
      if (submitted) {
        if (_requestId case final request?) await _cancel(request);
        _outcome = {'committed': null};
        _message = const AppMessage('backupRestoreUnconfirmed');
      } else {
        _message = _failureMessage(error);
      }
      adopted = await _presentResult(run);
    } finally {
      if (token != null) {
        _wait(run, true);
        await _discard(token);
      }
      if (adopted) app.acknowledgeLocalFeedback(_feedbackOwner, result: result);
      _finish(run);
    }
  }

  AppMessage _submissionMessage(String request) =>
      app.lastCommand?['requestId'] == request
      ? app.commandErrorMessage ?? messages.operationNotCompletedRetry
      : messages.requestNotAccepted;

  Future<bool> _presentResult(int run) async {
    _wait(run, false);
    if (!await _awaitForeground(run) || !mounted) return false;
    final message = _message;
    final detail = _outcome;
    if (message?.id == 'backupCancelled' && detail == null) return true;
    final issue = detail != null
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
              const ['failed', 'cancelled'].contains(detail['scheduleStatus'])
        : message?.id != 'backupExportSaved';
    if (!issue) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Builder(
            builder: (context) => Text(
              _resultText(AppLocalizations.of(context), detail, message),
            ),
          ),
        ),
      );
      return true;
    }
    try {
      await showDialog<void>(
        context: context,
        builder: (context) {
          _observeDialog(ModalRoute.of(context));
          final strings = AppLocalizations.of(context);
          return AlertDialog(
            title: Text(
              _importing ? strings.backupImport : strings.backupExport,
            ),
            scrollable: true,
            content: SelectableText(_resultText(strings, detail, message)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(strings.close),
              ),
            ],
          );
        },
      );
      return true;
    } finally {
      _dialogRoute = null;
      if (mounted) _syncOwner();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      _syncOwner();
      final state = app.state;
      final enabled =
          widget.active &&
          !_working &&
          !app.busy &&
          app.platformErrorMessage == null &&
          state.storageReady &&
          !state.storageRestoring;
      final palette = HomePalette.of(context);
      Widget action(bool importing) {
        final busy = _working && _importing == importing;
        final waiting = busy && _waiting && _current && app.foreground;
        final color = importing ? palette.localSource : palette.syncAction;
        return ListTile(
          key: ValueKey(importing ? 'backup-import' : 'backup-export'),
          enabled: enabled || busy,
          leading: SizedBox.square(
            dimension: 24,
            child: waiting
                ? CircularProgressIndicator(strokeWidth: 2, color: color)
                : Icon(
                    importing ? Icons.folder_open_outlined : Icons.save_alt,
                    color: enabled ? color : Theme.of(context).disabledColor,
                  ),
          ),
          title: _actionLabel(
            context,
            (strings) =>
                importing ? strings.backupImport : strings.backupExport,
          ),
          trailing: SizedBox.square(
            dimension: 48,
            child: busy
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
                    color: enabled ? color : Theme.of(context).disabledColor,
                  ),
          ),
          onTap: enabled
              ? () => importing
                    ? _import(state.storageEpoch)
                    : _export(state.storageEpoch)
              : null,
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
) => LayoutBuilder(
  builder: (context, constraints) {
    final style =
        ListTileTheme.of(context).titleTextStyle ??
        Theme.of(context).textTheme.bodyLarge!;
    final scaler = MediaQuery.textScalerOf(context);
    double height = 0;
    for (final locale in AppLocalizations.supportedLocales) {
      final painter = TextPainter(
        text: TextSpan(
          text: label(lookupAppLocalizations(locale)),
          style: style,
        ),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        locale: locale,
      )..layout(maxWidth: constraints.maxWidth);
      height = max(height, painter.height);
      painter.dispose();
    }
    return SizedBox(
      height: height,
      child: Text(label(AppLocalizations.of(context)), style: style),
    );
  },
);

String _resultText(
  AppLocalizations strings,
  Map<String, dynamic>? detail,
  AppMessage? message,
) {
  final texts = <String>[];
  void addCause(String field) {
    try {
      final cause = AppMessage.fromNullable(detail?[field]);
      if (cause != null && !texts.contains(cause.resolve(strings))) {
        texts.add(cause.resolve(strings));
      }
    } on FormatException {
      // Map native failures to stable, localized application messages.
    }
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
  if (message != null) {
    final issue =
        detail?['committed'] == true && message.id == 'backupRestoredWithIssue'
        ? message.args['issue']
        : null;
    final text = (issue is AppMessage ? issue : message).resolve(strings);
    if (!texts.contains(text)) texts.add(text);
  }
  return texts.join('\n\n');
}

String _newRequest() =>
    'backup-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
    '${Random.secure().nextInt(1 << 32).toRadixString(36)}';

AppMessage _documentMessage(Map<String, dynamic> response) {
  if (response['externalMayBePartial'] == true) {
    return const AppMessage('backupDocumentWriteUnconfirmed');
  }
  return switch (response['status']) {
    'cancelled' => const AppMessage('backupCancelled'),
    'expired' => const AppMessage('backupCandidateExpired'),
    'busy' => messages.operationInProgress,
    _ => const AppMessage('backupFailed'),
  };
}

AppMessage _failureMessage(Object error) => switch (error) {
  ConfigFailure() => error.message,
  PlatformException() => messageFromPlatform(
    error,
    fallback: const AppMessage('backupFailed'),
  ),
  FormatException() => const AppMessage('backupInvalid'),
  _ => const AppMessage('backupFailed'),
};
