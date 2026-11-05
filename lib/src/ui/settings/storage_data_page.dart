import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../navigation/task_activity.dart';
import '../navigation/route_observer.dart';
import '../components/reading/format_bytes.dart';
import '../components/feedback/operation_feedback.dart';
import '../components/feedback/operation_notice.dart';
import '../../l10n/app_localizations.dart';
import '../../model/messages.dart';
import '../../model/application_contract.dart';
import '../backup/backup_settings_actions.dart';
import '../components/feedback/confirm_action.dart';
import 'core_cleanup_action.dart';
import '../locale/message_text.dart';

class StorageDataPage extends StatefulWidget {
  const StorageDataPage({super.key, required this.app});

  final AppController app;

  @override
  State<StorageDataPage> createState() => _StorageDataPageState();
}

class _StorageDataPageState extends State<StorageDataPage> {
  AppController get app => widget.app;
  Map<String, dynamic> _usage = const {};
  AppMessage? _usageError;
  bool _readAgain = false;
  bool _readAgainReport = false;
  Future<void>? _usageRead;
  int _usageRequest = 0;
  int _usageFailures = 0;
  Timer? _usageRetry;
  Timer? _usageDeadline;
  bool _active = false;
  bool _cleaning = false;
  int? _usageEpoch;
  late (int, int, String?) _observed;
  ModalRoute<dynamic>? _dialogRoute;
  ModalRoute<dynamic>? _detailsRoute;
  bool _readingDetails = false;
  final _noticeChanges = ValueNotifier(0);
  final _readFaults = <String>{};
  Object? _noticeSource;

  Map<String, AppMessage> get _readErrors {
    final errors = <String, AppMessage>{
      'backup': ?AppMessage.fromNullable(app.state.backup['errorDetail']),
      'storage': ?app.state.storageError,
      'usage': ?_usageError,
      'configurations': ?app.configErrorMessage,
      'overrides': ?app.overrideErrorMessage,
      'preferences': ?app.preferencesErrorMessage,
    };
    if (_usageEpoch == app.state.storageEpoch) {
      for (final entry in _usage.entries) {
        if (entry.value case final Map value) {
          if (AppMessage.fromNullable(value['error']) case final error?) {
            errors['usage-${entry.key}'] = error;
          }
        }
      }
    }
    return errors;
  }

  void _scheduleReadNotice() {
    final source = (app, app.state.storageEpoch, app.storageEpoch);
    if (_noticeSource != source) {
      _noticeSource = source;
      _readFaults.clear();
    }
    final errors = _readErrors;
    _readFaults.removeWhere((key) => !errors.containsKey(key));
    if (!_current) return;
    final fresh = errors.keys.any((key) => !_readFaults.contains(key));
    _readFaults.addAll(errors.keys);
    if (!fresh) return;
    bool sameSource() =>
        mounted &&
        source == (app, app.state.storageEpoch, app.storageEpoch) &&
        errors.entries.every((entry) => _readErrors[entry.key] == entry.value);
    String summary(AppLocalizations strings) =>
        errors.values.map((error) => error.summary(strings)).toSet().join('\n');
    String technicalDetail(AppLocalizations strings) => errors.values
        .map((error) => error.technicalDetail(strings))
        .whereType<String>()
        .toSet()
        .join('\n\n');
    Future<void> retry() async {
      if (!sameSource() || !_current) return;
      _readFaults.clear();
      await app.refresh();
      if (_current &&
          source == (app, app.state.storageEpoch, app.storageEpoch)) {
        await _loadUsage(reportFailure: true);
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!sameSource() || !_current) return;
      unawaited(
        showLocalizedOperationNotice(
          context,
          summary,
          technicalDetail: technicalDetail,
          eligibilityChanges: Listenable.merge([app, _noticeChanges]),
          isCurrent: () => sameSource() && _current,
          isCurrentWithPopup: (popup) =>
              sameSource() && _feedbackCurrent(popup),
          onDetails: () => _showDetails(
            summary,
            technicalDetail,
            sameSource,
            onRetry: retry,
          ),
          onRetry: retry,
          identity: ('storage-read', source, Object.hashAll(errors.values)),
        ),
      );
    });
  }

  bool get _routeLive =>
      mounted &&
      (ModalRoute.of(context)?.isActive ?? true) &&
      ModalRoute.of(context)?.animation?.status != AnimationStatus.reverse;

  // Own confirmations may cover this route; they do not retire the page.
  bool get _live =>
      _routeLive && AppTaskActivity.isActive(context, ownedPopup: _dialogRoute);

  bool get _current =>
      _live && app.interactive && (ModalRoute.of(context)?.isCurrent ?? true);

  bool _feedbackCurrent(ModalRoute<dynamic> popup) =>
      _routeLive &&
      app.interactive &&
      AppTaskActivity.isActive(context, ownedPopup: popup);

  Future<void> _showDetails(
    String Function(AppLocalizations) summary,
    String? Function(AppLocalizations) technicalDetail,
    bool Function() sameSource, {
    Future<void> Function()? onRetry,
  }) async {
    _readingDetails = true;
    try {
      await showLocalizedOperationMessage(
        context,
        summary,
        technicalDetail: technicalDetail,
        title: (strings) => strings.errorDetails,
        isCurrent: () => sameSource() && _current,
        isCurrentWithPopup: (popup) => sameSource() && _feedbackCurrent(popup),
        eligibilityChanges: Listenable.merge([app, _noticeChanges]),
        onRoute: (route) => _detailsRoute = route,
        onRetry: onRetry,
      );
    } finally {
      _readingDetails = false;
      _detailsRoute = null;
      if (mounted && _syncVisibility()) unawaited(_loadUsage());
    }
  }

  @override
  void initState() {
    super.initState();
    _observed = (app.state.storageEpoch, app.storageEpoch, app.state.resultId);
    app.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_syncVisibility()) unawaited(_loadUsage());
  }

  @override
  void didUpdateWidget(StorageDataPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.app, app)) return;
    oldWidget.app.removeListener(_changed);
    app.addListener(_changed);
    _usageRequest++;
    _usage = const {};
    _usageEpoch = null;
    _usageError = null;
    _usageFailures = 0;
    _observed = (app.state.storageEpoch, app.storageEpoch, app.state.resultId);
    if (_current) unawaited(_loadUsage());
  }

  bool _syncVisibility() {
    if (_readingDetails &&
        app.interactive &&
        _routeLive &&
        AppTaskActivity.isActive(context, ownedPopup: _detailsRoute)) {
      return false;
    }
    final active = _current;
    if (_active == active) return false;
    _active = active;
    if (active) {
      _usageFailures = 0;
      return true;
    }
    final route = ModalRoute.of(context);
    if (app.interactive &&
        (route == null ||
            AppTaskNavigatorObserver.coveringPopup(route) == null)) {
      _readFaults.clear();
    }
    _usageRequest++;
    _usageRetry?.cancel();
    return false;
  }

  void _changed() {
    final observed = (
      app.state.storageEpoch,
      app.storageEpoch,
      app.state.resultId,
    );
    final sourceChanged =
        (observed.$1, observed.$2) != (_observed.$1, _observed.$2);
    final resultChanged =
        observed.$3 != _observed.$3 &&
        const {
          'import',
          'updateConfig',
          'renameConfig',
          'saveLocal',
          'delete',
          'clearConfigurations',
          'clearOverrides',
          'scheduleCoreCleanup',
          'prepareBackup',
          'inspectBackup',
          'setConfigUpdate',
          'setPreference',
          'setApplicationAccess',
          'saveOverride',
          'saveLanProxy',
          'setLanProxyEnabled',
          'importOverride',
          'updateOverride',
          'changeOverrideSource',
          'changeOverride',
          'reorderOverrides',
          'deleteOverride',
          'setOverrideUpdate',
          'saveLocalDefinition',
          'deleteLocalDefinition',
        }.contains(app.lastCommand?['action']);
    _observed = observed;
    final entered = _syncVisibility();
    if (sourceChanged) {
      _usageRequest++;
      _usageFailures = 0;
    }
    if ((sourceChanged || resultChanged || entered) && _current) {
      unawaited(_loadUsage());
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadUsage({bool reportFailure = false}) {
    if (!_current) return Future.value();
    if (_usageRead case final read?) {
      if (reportFailure) _usageRequest++;
      _readAgain = true;
      _readAgainReport |= reportFailure;
      return read;
    }
    _usageRetry?.cancel();
    _readAgain = _readAgainReport = false;
    final read = _readUsage(reportFailure: reportFailure);
    _usageRead = read;
    return read.whenComplete(() {
      _usageRead = null;
      if (!mounted || !_current) return;
      if (_readAgain) {
        final report = _readAgainReport;
        unawaited(_loadUsage(reportFailure: report));
      } else if (_usageFailures > 0) {
        const backoff = [30, 60, 120, 300];
        final seconds = backoff[(_usageFailures - 1).clamp(0, 3)];
        _usageRetry = Timer(Duration(seconds: seconds), _loadUsage);
      }
    });
  }

  Future<void> _readUsage({required bool reportFailure}) async {
    final owner = app;
    final epoch = (owner.state.storageEpoch, owner.storageEpoch);
    final request = ++_usageRequest;
    bool current() =>
        mounted &&
        identical(owner, app) &&
        _current &&
        epoch == (owner.state.storageEpoch, owner.storageEpoch) &&
        request == _usageRequest;
    var failed = false;
    void failure(Object error) {
      if (!current()) return;
      if (!failed) _usageFailures++;
      if (reportFailure || failed) _readFaults.remove('usage');
      failed = true;
      setState(() => _usageError = _failure(error, 'storageUsageFailed'));
      _noticeChanges.value++;
    }

    _usageDeadline = Timer(const Duration(seconds: 5), () {
      failure(TimeoutException('Reading storage usage is still in progress'));
    });
    try {
      final usage = await owner.platform.storageUsage();
      if (!current()) return;
      final hasErrors = usage.values.any(
        (value) => value is Map && value['error'] != null,
      );
      if (hasErrors) {
        if (!failed) _usageFailures++;
        if (reportFailure) {
          _readFaults.removeWhere((key) => key.startsWith('usage-'));
        }
      } else {
        _usageFailures = 0;
      }
      setState(() {
        _usage = usage;
        _usageEpoch = epoch.$1;
        _usageError = null;
      });
      _noticeChanges.value++;
    } catch (failureValue) {
      failure(failureValue);
    } finally {
      _usageDeadline?.cancel();
      _usageDeadline = null;
    }
  }

  Future<void> _clearCollection(
    bool configurations,
    AppController owner,
    int epoch,
  ) async {
    if (!_current ||
        _cleaning ||
        !identical(owner, app) ||
        app.state.storageEpoch != epoch ||
        !owner.canManageStoredData) {
      return;
    }
    setState(() => _cleaning = true);
    try {
      final confirmed = await confirmAction(
        context,
        onRoute: (route) => _dialogRoute = route,
        isCurrent: () => _live,
        title: (strings) => configurations
            ? strings.clearConfigurations
            : strings.clearOverrides,
        message: (strings) => configurations
            ? strings.clearConfigurationsMessage
            : strings.clearOverridesMessage,
        confirmLabel: (strings) => strings.delete,
      );
      _dialogRoute = null;
      if (!confirmed ||
          !_current ||
          !identical(owner, app) ||
          !owner.canManageStoredData) {
        return;
      }
      await owner.submit({
        'action': configurations ? 'clearConfigurations' : 'clearOverrides',
        'storageEpoch': epoch,
      });
      unawaited(_loadUsage());
    } finally {
      _dialogRoute = null;
      if (mounted) setState(() => _cleaning = false);
    }
  }

  Future<void> _clearConnections() async {
    if (!_current || _cleaning) return;
    final owner = app;
    final epoch = (owner.state.storageEpoch, owner.storageEpoch);
    bool sameSource() =>
        mounted &&
        identical(owner, app) &&
        epoch == (owner.state.storageEpoch, owner.storageEpoch);
    setState(() => _cleaning = true);
    try {
      await owner.platform.clearInactiveConnections();
      if (mounted && sameSource() && _current) {
        await showLocalizedOperationNotice(
          context,
          (strings) => strings.inactiveConnectionsCleared,
          error: false,
          eligibilityChanges: owner,
          isCurrent: () => sameSource() && _current,
          isCurrentWithPopup: (popup) =>
              sameSource() && _feedbackCurrent(popup),
        );
      }
    } catch (failure) {
      if (mounted && sameSource()) {
        await showAppNotice(
          context,
          _failure(failure, 'inactiveConnectionsClearFailed'),
          eligibilityChanges: owner,
          isCurrent: () => sameSource() && _current,
          isCurrentWithPopup: (popup) =>
              sameSource() && _feedbackCurrent(popup),
        );
      }
    } finally {
      if (mounted) setState(() => _cleaning = false);
    }
  }

  Object? _cleanupNotice;

  void _scheduleCleanupNotice() {
    final cleanup = app.state.coreCleanup;
    final status = cleanup['status'];
    if (status != 'failed' && status != 'partial') {
      _cleanupNotice = null;
      return;
    }
    final error = AppMessage.fromNullable(cleanup['error']);
    final files = coreCleanupFiles(cleanup);
    final source = (
      app,
      app.state.storageEpoch,
      app.storageEpoch,
      status,
      error,
      Object.hashAll(files),
    );
    final command = app.lastCommand;
    bool representedByLocal() =>
        identical(app.lastCommand, command) &&
        command?['action'] == 'scheduleCoreCleanup' &&
        app.state.resultId != null &&
        (app.hasLocalFeedbackOwner ||
            app.feedbackHandledLocally(
              command!,
              submissionFailed: false,
              resultId: app.state.resultId,
            ));
    if (representedByLocal()) {
      if (!app.hasLocalFeedbackOwner) _cleanupNotice = source;
      return;
    }
    if (_cleanupNotice == source || !_current) return;
    _cleanupNotice = source;
    bool sameSource() =>
        mounted &&
        !representedByLocal() &&
        _cleanupNotice == source &&
        identical(app, source.$1) &&
        app.state.storageEpoch == source.$2 &&
        app.storageEpoch == source.$3 &&
        app.state.coreCleanup['status'] == status &&
        AppMessage.fromNullable(app.state.coreCleanup['error']) == error &&
        listEquals(files, coreCleanupFiles(app.state.coreCleanup));
    String summary(AppLocalizations strings) => status == 'partial'
        ? strings.coreCleanupPartial
        : strings.coreCleanupFailed;
    String technicalDetail(AppLocalizations strings) =>
        coreCleanupDetails(strings, cleanup);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!sameSource() || !_current) return;
      unawaited(
        showLocalizedOperationNotice(
          context,
          summary,
          technicalDetail: technicalDetail,
          eligibilityChanges: Listenable.merge([app, _noticeChanges]),
          isCurrent: () => sameSource() && _current,
          isCurrentWithPopup: (popup) =>
              sameSource() && _feedbackCurrent(popup),
          onDetails: () => _showDetails(summary, technicalDetail, sameSource),
          identity: ('storage-cleanup', source),
        ),
      );
    });
  }

  Widget? _cleanupState() {
    final strings = AppLocalizations.of(context);
    final cleanup = app.state.coreCleanup;
    final title = switch (cleanup['status']) {
      'initializing' => strings.coreCleanupInitializing,
      'scheduled' => strings.coreCleanupScheduled,
      'completed' => strings.coreCleanupCompleted,
      'needsSelection' => strings.coreCleanupSelect,
      _ => null,
    };
    if (title == null) return null;
    return ListTile(
      key: const ValueKey('storage-core-cleanup-state'),
      title: Text(title),
    );
  }

  AppMessage _failure(Object failure, String id) => failure is PlatformFailure
      ? messageFromFailure(failure, fallback: AppMessage(id))
      : AppMessage(id).withDetail(failure);

  Widget _heading(String text) => _StorageTransition(
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: Theme.of(context).textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
    ),
  );

  Widget _usageRow(
    String kind,
    String title, {
    required IconData icon,
    int? limit,
    int? count,
    String? description,
    bool showCount = false,
  }) {
    final strings = AppLocalizations.of(context);
    final value = _usageEpoch == app.state.storageEpoch ? _usage[kind] : null;
    final rawBytes = value is Map ? value['bytes'] : null;
    final bytes = rawBytes is int && rawBytes >= 0 ? rawBytes : null;
    return _StorageTransition(
      ListTile(
        key: ValueKey('storage-usage-$kind'),
        leading: Icon(icon),
        title: Text(title),
        subtitle: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                [
                  [
                    limit == null
                        ? strings.storageBytes(formatBytes(bytes))
                        : strings.storageFileBytes(
                            formatBytes(bytes),
                            formatBytes(limit),
                          ),
                    if (bytes != null && limit != null && bytes > limit)
                      strings.storageLimitExceeded,
                  ].join(' · '),
                  if (showCount)
                    count == null
                        ? strings.storageEntryCountUnavailable
                        : strings.storageEntryCount(
                            count,
                            ApplicationContract.backupCollectionEntries,
                          ),
                ].join('\n'),
              ),
            ),
            if (description != null) Text(description),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Listen to the real route animation, including the first reverse frame.
    final animation = ModalRoute.of(context)?.animation;
    final page = _buildPage(context);
    return AnimatedBuilder(
      animation: animation ?? const AlwaysStoppedAnimation<double>(1),
      child: page,
      builder: (context, child) {
        final active = _live && (ModalRoute.of(context)?.isCurrent ?? true);
        return IgnorePointer(
          ignoring: !active,
          child: ExcludeFocus(
            excluding: !active,
            child: ExcludeSemantics(excluding: !active, child: child!),
          ),
        );
      },
    );
  }

  Widget _buildPage(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final owner = app;
    final epoch = owner.state.storageEpoch;
    _scheduleReadNotice();
    _scheduleCleanupNotice();
    return Scaffold(
      appBar: AppBar(title: Text(strings.storageData)),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: ListTileTheme.merge(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              minLeadingWidth: 24,
              horizontalTitleGap: 16,
              child: ListView(
                key: const PageStorageKey('storage-data'),
                children: [
                  _heading(strings.backupTitle),
                  _StorageTransition(
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(strings.backupScopeNotice),
                    ),
                  ),
                  BackupSettingsActions(app: app, active: _routeLive),
                  const Divider(indent: 16, endIndent: 16),
                  _heading(strings.storageUsage),
                  _usageRow(
                    'configurations',
                    strings.configurations,
                    icon: Icons.description_outlined,
                    limit: ApplicationContract.backupConfigurationsJsonBytes,
                    count: app.configsCurrent
                        ? app.collection.entries.length
                        : null,
                    showCount: true,
                  ),
                  _usageRow(
                    'overrides',
                    strings.overridePlugins,
                    icon: Icons.extension_outlined,
                    limit: ApplicationContract.backupOverridesJsonBytes,
                    count: app.overridesCurrent ? app.overrides.length : null,
                    showCount: true,
                  ),
                  _usageRow(
                    'preferences',
                    strings.settings,
                    icon: Icons.tune,
                    limit: ApplicationContract.backupPreferencesJsonBytes,
                  ),
                  _usageRow(
                    'core',
                    strings.coreDataDirectory,
                    icon: Icons.storage_outlined,
                    description: strings.storageCoreNotice,
                  ),
                  _StorageTransition(_cleanupState()),
                  const Divider(indent: 16, endIndent: 16),
                  _heading(strings.storageCleanup),
                  _StorageTransition(
                    ListTile(
                      key: const ValueKey('storage-clear-configurations'),
                      leading: const Icon(Icons.delete_outline),
                      title: Text(strings.clearConfigurations),
                      onTap: !_cleaning && app.canManageStoredData
                          ? () => _clearCollection(true, owner, epoch)
                          : null,
                    ),
                  ),
                  _StorageTransition(
                    ListTile(
                      key: const ValueKey('storage-clear-overrides'),
                      leading: const Icon(Icons.delete_outline),
                      title: Text(strings.clearOverrides),
                      onTap: !_cleaning && app.canManageStoredData
                          ? () => _clearCollection(false, owner, epoch)
                          : null,
                    ),
                  ),
                  _StorageTransition(
                    ListTile(
                      key: const ValueKey('storage-clear-connections'),
                      leading: const Icon(Icons.clear_all),
                      title: Text(strings.clearInactiveConnections),
                      subtitle: Text(strings.storageMemoryNotice),
                      onTap: _cleaning ? null : _clearConnections,
                    ),
                  ),
                  CoreCleanupAction(
                    key: const ValueKey('storage-cleanup-files'),
                    app: app,
                    enabled: !_cleaning,
                    isCurrent: () => _routeLive,
                    request: const {},
                    title: (strings) => strings.coreCleanupSelect,
                    description: (strings) =>
                        strings.coreCleanupSelectionNotice,
                    icon: Icons.delete_sweep_outlined,
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _usageRequest++;
    _usageRetry?.cancel();
    _usageDeadline?.cancel();
    app.removeListener(_changed);
    _noticeChanges.dispose();
    super.dispose();
  }
}

class _StorageTransition extends StatefulWidget {
  const _StorageTransition(this.child);

  final Widget? child;

  @override
  State<_StorageTransition> createState() => _StorageTransitionState();
}

class _StorageTransitionState extends State<_StorageTransition> {
  final _content = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final reduced =
        MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled;
    final content = AnimatedSwitcher(
      key: _content,
      duration: reduced ? Duration.zero : const Duration(milliseconds: 180),
      switchInCurve: Curves.easeInOutCubic,
      switchOutCurve: Curves.easeInOutCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: reduced ? const AlwaysStoppedAnimation(1) : animation,
        child: child,
      ),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topCenter,
        clipBehavior: Clip.none,
        children: [
          if (!reduced)
            for (final child in previous)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: ExcludeFocus(
                  child: IgnorePointer(child: ExcludeSemantics(child: child)),
                ),
              ),
          if (current != null) SizedBox(width: double.infinity, child: current),
        ],
      ),
      child:
          widget.child ??
          const SizedBox(
            key: ValueKey('storage-empty'),
            width: double.infinity,
            height: 0,
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
  }
}
