import 'dart:async';

import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../model/messages.dart';
import '../app/app_controller.dart';
import '../components/feedback/confirm_action.dart';
import '../components/feedback/operation_feedback.dart';
import '../components/feedback/operation_notice.dart';
import '../locale/message_text.dart';
import '../navigation/task_activity.dart';

List<(String, bool, AppMessage?)> coreCleanupFiles(Map cleanup) => [
  for (final item in cleanup['files'] as List? ?? const [])
    if (item is Map)
      (
        item['path'] as String? ?? '',
        item['completed'] == true,
        AppMessage.fromNullable(item['error']),
      ),
];

String coreCleanupDetails(
  AppLocalizations strings,
  Map cleanup, {
  AppMessage? message,
}) {
  final error = AppMessage.fromNullable(cleanup['error']);
  return [
    ?message?.technicalDetail(strings),
    if (error != null && error != message)
      error.technicalDetail(strings) ?? error.summary(strings),
    for (final file in coreCleanupFiles(cleanup))
      [
        '${file.$1} · ${file.$2
            ? strings.cleanupFileCompleted
            : file.$3 != null
            ? strings.cleanupFileFailed
            : strings.cleanupFilePending}',
        if (file.$3 case final itemError?)
          itemError.technicalDetail(strings) ?? itemError.summary(strings),
      ].join('\n'),
  ].join('\n\n');
}

class CoreCleanupAction extends StatefulWidget {
  const CoreCleanupAction({
    super.key,
    required this.app,
    required this.request,
    required this.title,
    required this.description,
    required this.icon,
    this.subject,
    this.enabled = true,
    this.canStart,
    this.isCurrent,
    this.isCurrentWithPopup,
  });

  final AppController app;
  final Map<String, Object?> request;
  final String Function(AppLocalizations) title;
  final String Function(AppLocalizations) description;
  final IconData icon;
  final String? subject;
  final bool enabled;
  final bool Function()? canStart;
  final bool Function()? isCurrent;
  final bool Function(ModalRoute<dynamic>)? isCurrentWithPopup;

  @override
  State<CoreCleanupAction> createState() => _CoreCleanupActionState();
}

class _CoreCleanupActionState extends State<CoreCleanupAction> {
  final _feedbackOwner = ValueNotifier(false);
  final _presentations = <Object>{};
  final _content = GlobalKey();
  bool _working = false;
  bool _pending = false;
  bool _retired = false;
  int _sourceRevision = 0;
  Object? _feedbackPeriod;
  ModalRoute<dynamic>? _popup;

  bool get _live =>
      mounted &&
      AppTaskActivity.isActive(context, ownedPopup: _popup) &&
      (_popup != null && widget.isCurrentWithPopup != null
          ? widget.isCurrentWithPopup!(_popup!)
          : widget.isCurrent?.call() ?? true) &&
      (ModalRoute.of(context)?.isActive ?? true) &&
      ModalRoute.of(context)?.animation?.status != AnimationStatus.reverse;

  bool get _current =>
      _live &&
      !_retired &&
      (_popup?.isCurrent == true ||
          (ModalRoute.of(context)?.isCurrent ?? true));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _checkOwner();
  }

  @override
  void didUpdateWidget(CoreCleanupAction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.app, widget.app)) {
      _sourceRevision++;
      _retired = true;
      _feedbackPeriod = null;
    }
    _checkOwner();
  }

  void _checkOwner() {
    if (!_working) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_working || _current) return;
      _retired = true;
      _feedbackOwner.value = false;
    });
  }

  void _syncFeedbackOwner() {
    _feedbackOwner.value = _pending || _presentations.isNotEmpty;
  }

  Future<void> _clean(
    AppController app,
    Map<String, Object?> sourceRequest,
    int epoch,
  ) async {
    final period = Object();
    final sourceRevision = _sourceRevision;
    bool current() =>
        _current &&
        identical(app, widget.app) &&
        epoch == app.storageEpoch &&
        identical(_feedbackPeriod, period);
    bool feedbackCurrent({ModalRoute<dynamic>? popup}) =>
        mounted &&
        sourceRevision == _sourceRevision &&
        identical(app, widget.app) &&
        epoch == app.storageEpoch &&
        app.interactive &&
        AppTaskActivity.isActive(context, ownedPopup: popup) &&
        AppTaskActivity.routeIsActive(
          ModalRoute.of(context),
          ownedPopup: popup,
        ) &&
        (popup != null && widget.isCurrentWithPopup != null
            ? widget.isCurrentWithPopup!(popup)
            : widget.isCurrent?.call() ?? true);
    bool popupCurrent(ModalRoute<dynamic> route) =>
        identical(_popup, route) && feedbackCurrent(popup: route);

    void present(
      AppMessage message, {
      bool error = true,
      Map? cleanup,
      String Function(AppLocalizations)? title,
      VoidCallback? onPresented,
    }) {
      String? technicalDetail(AppLocalizations strings) {
        final detail = cleanup == null
            ? message.technicalDetail(strings)
            : coreCleanupDetails(strings, cleanup, message: message);
        return detail == null || detail.isEmpty ? null : detail;
      }

      _presentations.add(period);
      unawaited(
        showLocalizedOperationNotice(
          context,
          message.summary,
          technicalDetail: technicalDetail,
          title: title,
          subject: widget.subject,
          error: error,
          identity: period,
          isCurrent: feedbackCurrent,
          isCurrentWithPopup: popupCurrent,
          eligibilityChanges: app,
          onDetails: error || message.detail != null
              ? () => showLocalizedOperationMessage(
                  context,
                  message.summary,
                  technicalDetail: technicalDetail,
                  title: title,
                  subject: widget.subject,
                  error: error,
                  isCurrent: feedbackCurrent,
                  isCurrentWithPopup: popupCurrent,
                  eligibilityChanges: app,
                  onRoute: (route) => _popup = route,
                )
              : null,
        ).then((presented) {
          _presentations.remove(period);
          if (!mounted) return;
          if (presented) onPresented?.call();
          _syncFeedbackOwner();
        }),
      );
    }

    if (_working ||
        !_live ||
        !identical(app, widget.app) ||
        !identical(sourceRequest, widget.request) ||
        epoch != app.storageEpoch ||
        !(ModalRoute.of(context)?.isCurrent ?? true) ||
        !app.interactive ||
        !widget.enabled ||
        !(widget.canStart?.call() ?? true) ||
        !app.canManageStoredData) {
      return;
    }
    setState(() {
      _working = true;
      _retired = false;
      _feedbackPeriod = period;
    });
    try {
      final candidates = await app.platform.coreCleanupCandidates();
      if (!mounted ||
          !current() ||
          !app.interactive ||
          !app.canManageStoredData) {
        return;
      }
      final items = (candidates['items'] as List? ?? const [])
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      final home = candidates['home'] as String?;
      final expectedPath = sourceRequest['expectedPath'];
      bool selectedInitially(Map<String, dynamic> row) {
        final path = row['path'] as String;
        if (sourceRequest['scope'] == 'cache' && row['kind'] == 'cache') {
          return true;
        }
        if (expectedPath == path) return true;
        return home != null &&
            expectedPath is String &&
            Uri.directory(home).resolveUri(Uri(path: path)).normalizePath() ==
                Uri.file(expectedPath).normalizePath();
      }

      final selected = <String>{
        for (final row in items)
          if (selectedInitially(row)) row['path'] as String,
      };
      var restart = false;
      final confirmed = await confirmAction(
        context,
        title: (strings) => strings.coreCleanupSelect,
        message: widget.description,
        subject: widget.subject,
        confirmLabel: (strings) => strings.coreCleanupDeleteSelected,
        canConfirm: () => selected.isNotEmpty,
        eligibilityChanges: app,
        isCurrent: () =>
            current() && app.interactive && app.canManageStoredData,
        onRoute: (route) => _popup = route,
        contentBuilder: (context, change) {
          final strings = AppLocalizations.of(context);
          return SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                Text(strings.coreCleanupSelectionNotice),
                if (items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(strings.coreCleanupNoCandidates),
                  ),
                for (final item in items)
                  CheckboxListTile(
                    key: ValueKey(('cleanup-file', item['path'])),
                    contentPadding: EdgeInsets.zero,
                    title: SelectableText(item['path'] as String),
                    value: selected.contains(item['path']),
                    onChanged: (value) => change(() {
                      if (value == true) {
                        selected.add(item['path'] as String);
                      } else {
                        selected.remove(item['path']);
                      }
                    }),
                  ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(strings.coreCleanupRestartLatest),
                  value: restart,
                  onChanged: (value) => change(() => restart = value == true),
                ),
              ],
            ),
          );
        },
      );
      if (!confirmed ||
          !current() ||
          !app.interactive ||
          !app.canManageStoredData) {
        return;
      }
      _feedbackOwner.value = true;
      setState(() => _pending = true);
      final result = await (() async {
        try {
          return await app.submitAndWait({
            'action': 'scheduleCoreCleanup',
            'paths': selected.toList(),
            'restart': restart,
            'storageEpoch': epoch,
          }, feedbackOwner: _feedbackOwner);
        } finally {
          if (mounted) setState(() => _pending = false);
        }
      })();
      if (!current() ||
          !await app.waitUntilInteractive() ||
          !mounted ||
          !current()) {
        return;
      }
      final success =
          result?.resultSuccess == true && app.commandErrorMessage == null;
      final command = app.lastCommand;
      present(
        result?.resultMessageDescription ??
            app.commandErrorMessage ??
            messages.operationNotCompletedRetry,
        title: (strings) =>
            success ? strings.operationFinished : strings.operationNotCompleted,
        error: !success,
        cleanup: success ? null : result?.coreCleanup,
        onPresented: () {
          if (identical(app.lastCommand, command)) {
            app.acknowledgeLocalFeedback(_feedbackOwner, result: result);
          }
        },
      );
    } catch (error) {
      if (current() &&
          await app.waitUntilInteractive() &&
          mounted &&
          current()) {
        present(
          error is PlatformFailure
              ? messageFromFailure(
                  error,
                  fallback: const AppMessage('coreCleanupFailed'),
                )
              : const AppMessage('coreCleanupFailed').withDetail(error),
        );
      }
    } finally {
      if (mounted && identical(_feedbackPeriod, period)) {
        setState(() => _working = false);
        _syncFeedbackOwner();
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.app,
    builder: (context, _) {
      _checkOwner();
      final app = widget.app;
      final epoch = app.storageEpoch;
      final sourceRequest = widget.request;
      final reduced =
          MediaQuery.disableAnimationsOf(context) ||
          !TickerMode.valuesOf(context).enabled;
      final content = KeyedSubtree(
        key: _content,
        child: ListTile(
          leading: SizedBox.square(
            dimension: 24,
            child: AnimatedSwitcher(
              duration: reduced
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              switchInCurve: Curves.easeInOutCubic,
              switchOutCurve: Curves.easeInOutCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: reduced ? const AlwaysStoppedAnimation(1) : animation,
                child: child,
              ),
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.center,
                children: [if (!reduced) ...previous, ?current],
              ),
              child: _pending && _current
                  ? const CircularProgressIndicator(strokeWidth: 2)
                  : Icon(widget.icon),
            ),
          ),
          title: Text(widget.title(AppLocalizations.of(context))),
          onTap: !_working && widget.enabled && app.canManageStoredData
              ? () => _clean(app, sourceRequest, epoch)
              : null,
        ),
      );
      return reduced
          ? content
          : AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeInOutCubic,
              alignment: Alignment.topCenter,
              child: content,
            );
    },
  );

  @override
  void dispose() {
    _retired = true;
    _feedbackOwner.value = false;
    _feedbackOwner.dispose();
    super.dispose();
  }
}
