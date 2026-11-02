import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../model/messages.dart';
import '../app/app_controller.dart';
import '../components/feedback/confirm_action.dart';
import '../components/feedback/operation_feedback.dart';
import '../components/feedback/operation_notice.dart';
import '../navigation/task_activity.dart';

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
  final _content = GlobalKey();
  bool _working = false;
  bool _pending = false;
  bool _retired = false;
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

  Future<void> _clean(
    AppController app,
    Map<String, Object?> sourceRequest,
    int epoch,
  ) async {
    final period = Object();
    bool current() =>
        _current &&
        identical(app, widget.app) &&
        epoch == app.storageEpoch &&
        identical(_feedbackPeriod, period);
    bool popupCurrent(ModalRoute<dynamic> route) {
      if (!identical(_popup, route)) return false;
      if (current() && app.interactive) return true;
      _retired = true;
      _feedbackOwner.value = false;
      return false;
    }

    Future<bool> present(
      AppMessage message, {
      bool error = true,
      String Function(AppLocalizations)? title,
    }) => showAppNotice(
      context,
      message,
      title: title,
      subject: widget.subject,
      error: error,
      identity: period,
      isCurrent: () => current() && app.interactive,
      isCurrentWithPopup: popupCurrent,
      eligibilityChanges: app,
      onDetails: error || message.detail != null
          ? () => showAppMessage(
              context,
              message,
              title: title,
              subject: widget.subject,
              error: error,
              isCurrent: current,
              isCurrentWithPopup: popupCurrent,
              eligibilityChanges: app,
              onRoute: (route) => _popup = route,
            )
          : null,
    );

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
      final presented = await present(
        result?.resultMessageDescription ??
            app.commandErrorMessage ??
            messages.operationNotCompletedRetry,
        title: (strings) =>
            success ? strings.operationFinished : strings.operationNotCompleted,
        error: !success,
      );
      if (presented && current()) {
        app.acknowledgeLocalFeedback(_feedbackOwner, result: result);
      }
    } catch (error) {
      if (current() &&
          await app.waitUntilInteractive() &&
          mounted &&
          current()) {
        await present(
          error is PlatformFailure
              ? messageFromFailure(
                  error,
                  fallback: const AppMessage('coreCleanupFailed'),
                )
              : const AppMessage('coreCleanupFailed').withDetail(error),
        );
      }
    } finally {
      if (mounted) {
        _feedbackOwner.value = false;
        setState(() => _working = false);
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
