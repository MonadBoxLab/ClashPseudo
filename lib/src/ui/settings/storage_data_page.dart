import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../navigation/task_activity.dart';
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
  bool _reading = false;
  bool _readAgain = false;
  Future<void>? _usageRead;
  bool _cleaning = false;
  int? _usageEpoch;
  late (bool, int, String?) _observed;
  ModalRoute<dynamic>? _dialogRoute;
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
    final fresh = errors.keys.any((key) => !_readFaults.contains(key));
    _readFaults.addAll(errors.keys);
    if (!fresh || !_current) return;
    bool sameSource() =>
        mounted &&
        source == (app, app.state.storageEpoch, app.storageEpoch) &&
        errors.entries.every((entry) => _readErrors[entry.key] == entry.value);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!sameSource() || !_current) return;
      unawaited(
        showLocalizedOperationNotice(
          context,
          (strings) => errors.values
              .map((error) => error.summary(strings))
              .toSet()
              .join('\n'),
          technicalDetail: (strings) => errors.values
              .map((error) => error.technicalDetail(strings))
              .whereType<String>()
              .toSet()
              .join('\n\n'),
          eligibilityChanges: Listenable.merge([app, _noticeChanges]),
          isCurrent: () => sameSource() && _current,
          isCurrentWithPopup: (popup) =>
              sameSource() && _feedbackCurrent(popup),
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

  @override
  void initState() {
    super.initState();
    _observed = (app.foreground, app.state.storageEpoch, app.state.resultId);
    app.addListener(_changed);
    unawaited(_loadUsage());
  }

  @override
  void didUpdateWidget(StorageDataPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.app, app)) return;
    oldWidget.app.removeListener(_changed);
    app.addListener(_changed);
    _usage = const {};
    _usageEpoch = null;
    _usageError = null;
    _observed = (app.foreground, app.state.storageEpoch, app.state.resultId);
    unawaited(_loadUsage());
  }

  void _changed() {
    final observed = (
      app.foreground,
      app.state.storageEpoch,
      app.state.resultId,
    );
    if (observed != _observed) {
      _observed = observed;
      if (app.foreground) unawaited(_loadUsage());
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadUsage() {
    if (!mounted) return Future.value();
    if (_usageRead case final read?) {
      _readAgain = true;
      return read;
    }
    return _usageRead = _readUsage().whenComplete(() => _usageRead = null);
  }

  Future<void> _readUsage() async {
    setState(() => _reading = true);
    try {
      do {
        _readAgain = false;
        final owner = app;
        final epoch = owner.state.storageEpoch;
        try {
          final usage = await owner.platform.storageUsage();
          if (!mounted) return;
          if (!identical(owner, app) || epoch != app.state.storageEpoch) {
            _readAgain = true;
            continue;
          }
          setState(() {
            _usage = usage;
            _usageEpoch = epoch;
            _usageError = null;
          });
        } catch (failure) {
          if (!mounted) return;
          if (!identical(owner, app) || epoch != app.state.storageEpoch) {
            _readAgain = true;
            continue;
          }
          setState(() {
            // A previous measurement is not a successful current read.
            _usage = const {};
            _usageEpoch = null;
            _usageError = _failure(failure, 'storageUsageFailed');
          });
        }
      } while (mounted && _readAgain);
    } finally {
      if (mounted) {
        setState(() => _reading = false);
        _noticeChanges.value++;
      }
    }
  }

  Future<void> _refresh() async {
    if (!_current) return;
    _readFaults.clear();
    await app.refresh();
    if (_current) await _loadUsage();
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
      await _loadUsage();
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

  Widget _detailAction(
    List<AppMessage> errors,
    String identity,
    bool Function() sourceCurrent,
  ) {
    final strings = AppLocalizations.of(context);
    if (!errors.any((error) => error.technicalDetail(strings) != null)) {
      return const SizedBox.shrink();
    }
    final owner = app;
    final epoch = owner.storageEpoch;
    bool sameSource() =>
        mounted &&
        identical(owner, app) &&
        owner.storageEpoch == epoch &&
        sourceCurrent();
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: TextButton.icon(
        key: ValueKey('$identity-details'),
        icon: const Icon(Icons.error_outline),
        label: Text(strings.errorDetails),
        onPressed: () => unawaited(
          showLocalizedOperationMessage(
            context,
            (strings) =>
                errors.map((error) => error.summary(strings)).join('\n\n'),
            technicalDetail: (strings) => errors
                .map((error) => error.technicalDetail(strings))
                .whereType<String>()
                .join('\n\n'),
            title: (strings) => strings.errorDetails,
            isCurrent: () => _current && sameSource(),
            isCurrentWithPopup: (popup) =>
                _feedbackCurrent(popup) && sameSource(),
          ),
        ),
      ),
    );
  }

  Widget _inlineMessage(
    AppMessage error,
    String identity,
    bool Function() sourceCurrent,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      SelectableText(error.summary(AppLocalizations.of(context))),
      _detailAction([error], identity, sourceCurrent),
    ],
  );

  Widget? _cleanupState() {
    final strings = AppLocalizations.of(context);
    final cleanup = app.state.coreCleanup;
    final epoch = app.state.storageEpoch;
    final status = cleanup['status'];
    final title = switch (status) {
      'initializing' => strings.coreCleanupInitializing,
      'scheduled' => strings.coreCleanupScheduled,
      'failed' => strings.coreCleanupFailed,
      'completed' => strings.coreCleanupCompleted,
      'partial' => strings.coreCleanupPartial,
      'needsSelection' => strings.coreCleanupSelect,
      _ => null,
    };
    if (title == null) return null;
    final error = AppMessage.fromNullable(cleanup['error']);
    final subject = switch ((cleanup['scope'], cleanup['path'])) {
      ('cache', _) => 'cache.db',
      ('needsSelection', _) => strings.coreCleanupSelect,
      ('resource', final String path) => path.split('/').last,
      _ => null,
    };
    return Column(
      key: ValueKey(('storage-cleanup', status)),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          key: const ValueKey('storage-core-cleanup-state'),
          leading: Icon(switch (status) {
            'failed' => Icons.error_outline,
            'completed' => Icons.check_circle_outline,
            _ => Icons.schedule,
          }),
          title: Text(title),
          subtitle: subject == null && error == null
              ? null
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      [
                        ?subject,
                        if (error != null) error.summary(strings),
                      ].join('\n'),
                    ),
                    if (error != null)
                      _detailAction(
                        [error],
                        'storage-core-cleanup-state',
                        () =>
                            app.storageEpoch == epoch &&
                            identical(app.state.coreCleanup, cleanup),
                      ),
                  ],
                ),
        ),
        for (final item in cleanup['files'] as List? ?? const [])
          Builder(
            builder: (context) {
              final row = item as Map;
              final path = row['path'] as String? ?? '';
              final itemError = AppMessage.fromNullable(row['error']);
              return ListTile(
                leading: Icon(
                  row['completed'] == true
                      ? Icons.check_circle_outline
                      : Icons.error_outline,
                ),
                title: SelectableText(path),
                subtitle: itemError == null
                    ? null
                    : _inlineMessage(
                        itemError,
                        'storage-core-cleanup-file-$path',
                        () =>
                            app.storageEpoch == epoch &&
                            identical(app.state.coreCleanup, cleanup),
                      ),
              );
            },
          ),
      ],
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
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.storageData),
        actions: [
          IconButton(
            tooltip: strings.refresh,
            onPressed: _reading ? null : _refresh,
            icon: SizedBox.square(
              dimension: 24,
              child: _reading
                  ? const Center(
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : const Icon(Icons.refresh),
            ),
          ),
        ],
      ),
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
              child: RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  key: const PageStorageKey('storage-data'),
                  physics: const AlwaysScrollableScrollPhysics(),
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
      ),
    );
  }

  @override
  void dispose() {
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
