import 'dart:async';
import 'dart:math' as math;

import '../components/feedback/operation_notice.dart';

import 'package:clash_pseudo/src/ui/navigation/page_route.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:flutter/material.dart';

import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';

import 'package:cross_file/cross_file.dart';

import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/components/input/choice_menu_button.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_feedback.dart';
import 'package:clash_pseudo/src/ui/components/collections/reading_list.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/ui/configs/editor/config_text_page.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/configs/dialogs/config_file.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/ui/configs/dialogs/import_dialog.dart';
import 'package:clash_pseudo/src/ui/components/collections/exact_size_transition.dart';
import 'package:clash_pseudo/src/ui/settings/auto_update_dialog.dart';
import 'package:clash_pseudo/src/ui/components/feedback/confirm_action.dart';
import 'package:clash_pseudo/src/ui/configs/dialogs/config_field_dialog.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';

class OverridesPage extends StatefulWidget {
  const OverridesPage({
    super.key,
    required this.app,
    this.selectFile = selectConfigFile,
    this.active = true,
  });
  final AppController app;
  final bool active;
  final Future<XFile?> Function() selectFile;
  @override
  State<OverridesPage> createState() => _OverridesPageState();
}

// Keep the same card/header content when reduced motion removes its size tween.
class _OverrideSizeTransition extends StatefulWidget {
  const _OverrideSizeTransition({required this.child});
  final Widget child;

  @override
  State<_OverrideSizeTransition> createState() =>
      _OverrideSizeTransitionState();
}

class _OverrideSizeTransitionState extends State<_OverrideSizeTransition> {
  final _content = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final child = KeyedSubtree(key: _content, child: widget.child);
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return ExactSizeTransition(child: child);
  }
}

class _OverridesPageState extends State<OverridesPage> {
  AppController get app => widget.app;
  bool _importing = false;
  final _feedbackOwner = ValueNotifier(true);

  final _scroll = ScrollController();
  int _presentation = 0;
  bool _taskActive = true;
  bool _wasForeground = true;
  ModalRoute<dynamic>? _route;
  ModalRoute<dynamic>? _ownedPopup;

  bool _live(int presentation) =>
      mounted &&
      widget.active &&
      AppTaskActivity.isActive(context, ownedPopup: _ownedPopup) &&
      app.foreground &&
      AppTaskActivity.routeIsActive(_route, ownedPopup: _ownedPopup) &&
      presentation == _presentation;

  bool _canResume(int presentation) =>
      _live(presentation) && (_route?.isCurrent ?? true);

  bool _epochCurrent(int epoch, int presentation) =>
      _live(presentation) &&
      epoch == app.storageEpoch &&
      epoch == app.state.storageEpoch;

  Map<String, Object?> _target(OverrideEntry entry) => {
    'id': entry.id,
    'revision': entry.revision,
    'expectedSource': entry.source,
    'expectedName': entry.name,
    'expectedProxyName': entry.proxyName,
    'expectedAddNoResolve': entry.addNoResolve,
  };

  bool _fileRetired = false;
  ConfigFileSelection? _fileSelection;
  bool Function()? _fileCurrent;

  void _cancelStaleFile() {
    if (_fileCurrent?.call() == false) {
      unawaited(_fileSelection?.cancel().catchError((Object _) {}));
    }
  }

  void _syncOwner() {
    _cancelStaleFile();
    _scheduleReadNotice();
    _scheduleEntryNotice();
    if (_wasForeground && !app.foreground) {
      _presentation++;
    }
    _wasForeground = app.foreground;
    _feedbackOwner.value =
        mounted &&
        widget.active &&
        (_taskActive || _readingFeedback) &&
        app.foreground &&
        (_readingFeedback
            ? (_route?.isActive ?? true) &&
                  _route?.animation?.status != AnimationStatus.reverse
            : AppTaskActivity.routeIsActive(_route, ownedPopup: _ownedPopup));
  }

  @override
  void initState() {
    super.initState();
    app.addListener(_syncOwner);
    _syncOwner();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    final active =
        AppTaskActivity.isActive(context, ownedPopup: _ownedPopup) &&
        AppTaskActivity.routeIsActive(_route, ownedPopup: _ownedPopup);
    if (_taskActive && !active) {
      _presentation++;
    }
    _taskActive = active;
    _syncOwner();
  }

  @override
  void didUpdateWidget(OverridesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active && app.foreground) {
      _fileRetired = true;
    }
    if (oldWidget.active != widget.active || !identical(oldWidget.app, app)) {
      _presentation++;
    }
    if (!identical(oldWidget.app, app)) {
      oldWidget.app.removeListener(_syncOwner);
      app.addListener(_syncOwner);
    }
    _syncOwner();
  }

  Future<T?> _showDialog<T>({required WidgetBuilder builder}) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<T>(
      context: context,
      builder: (context) => OperationNoticeHost(
        onDismiss: () => Navigator.of(context).maybePop(),
        child: ListenableBuilder(
          listenable: app,
          builder: (context, _) => builder(context),
        ),
      ),
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierColor:
          Theme.of(context).dialogTheme.barrierColor ?? Colors.black54,
      animationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
    );
    _ownedPopup = route;
    try {
      return await navigator.push(route);
    } finally {
      if (identical(_ownedPopup, route)) _ownedPopup = null;
    }
  }

  bool _readingFeedback = false;

  Future<bool> _showMessage(
    AppMessage message, {
    String Function(AppLocalizations)? title,
    String? subject,
    VoidCallback? onPresented,
  }) => _showFeedback(
    message.summary,
    technicalDetail: message.technicalDetail,
    title: title,
    subject: subject,
    onPresented: onPresented,
  );

  Future<bool> _showFeedback(
    String Function(AppLocalizations) message, {
    String? Function(AppLocalizations)? technicalDetail,
    String Function(AppLocalizations)? title,
    String? subject,
    VoidCallback? onPresented,
  }) {
    final presentation = _presentation;
    final epoch = app.storageEpoch;
    final owner = app;
    return showLocalizedOperationNotice(
      context,
      message,
      technicalDetail: technicalDetail,
      title: title,
      subject: subject,
      eligibilityChanges: owner,
      isCurrent: () =>
          identical(owner, app) &&
          epoch == owner.storageEpoch &&
          _canResume(presentation),
      onPresented: onPresented,
      onDetails: () => _showDetails(
        message,
        technicalDetail: technicalDetail,
        title: title,
        subject: subject,
      ),
    );
  }

  Future<void> _showDetails(
    String Function(AppLocalizations) message, {
    String? Function(AppLocalizations)? technicalDetail,
    String Function(AppLocalizations)? title,
    String? subject,
    Future<void> Function()? onRetry,
    bool Function()? sourceCurrent,
  }) async {
    final presentation = _presentation;
    final owner = app;
    ModalRoute<dynamic>? feedbackRoute;
    if (!_canResume(presentation)) return;
    _readingFeedback = true;
    try {
      await showLocalizedOperationMessage(
        context,
        message,
        technicalDetail: technicalDetail,
        title: title,
        subject: subject,
        onRetry: onRetry,
        eligibilityChanges: owner,
        isCurrent: () =>
            _canResume(presentation) && (sourceCurrent?.call() ?? true),
        isCurrentWithPopup: (popup) =>
            mounted &&
            (sourceCurrent?.call() ?? true) &&
            identical(owner, app) &&
            presentation == _presentation &&
            widget.active &&
            owner.foreground &&
            AppTaskActivity.isActive(context, ownedPopup: popup) &&
            AppTaskActivity.routeIsActive(_route, ownedPopup: popup),
        onRoute: (route) {
          if (route != null) {
            feedbackRoute = route;
            _ownedPopup = route;
          } else if (identical(_ownedPopup, feedbackRoute)) {
            _ownedPopup = null;
          }
        },
      );
    } finally {
      _readingFeedback = false;
      if (mounted) _syncOwner();
    }
  }

  @override
  void dispose() {
    _fileRetired = true;
    unawaited(_fileSelection?.cancel().catchError((Object _) {}));
    app.removeListener(_syncOwner);
    _feedbackOwner.value = false;
    _feedbackOwner.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Widget _list(BuildContext context, {required double viewportOrigin}) {
    final entries = app.overrides;
    final order = entries.map((entry) => entry.id).toList(growable: false);
    final strings = AppLocalizations.of(context);
    final canEdit =
        _canResume(_presentation) &&
        app.canEditOverrides &&
        app.overridesLoaded &&
        app.overrideErrorMessage == null &&
        !_importing;
    final epoch = app.storageEpoch;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: ReadingList(
            controller: _scroll,
            identity: epoch,
            viewportOrigin: viewportOrigin,
            header: _header(context),
            items: [
              for (final (index, entry) in entries.indexed)
                ReadingListItem(
                  id: entry.id,
                  layoutValues: [entry.name, _summary(strings, entry)],
                  builder: (context) => _row(
                    context,
                    strings,
                    entry,
                    index,
                    canEdit: canEdit,
                    storageEpoch: epoch,
                    order: order,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Object? _readNoticeSource;
  bool _readFault = false;
  bool _readNoticeScheduled = false;

  void _scheduleReadNotice() {
    if (_readNoticeScheduled || !mounted) return;
    _readNoticeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _readNoticeScheduled = false;
      if (!mounted) return;
      final source = (app, app.storageEpoch, _presentation);
      if (_readNoticeSource != source) {
        _readNoticeSource = source;
        _readFault = false;
      }
      final error = app.overrideErrorMessage;
      if (error == null) {
        if (app.overridesLoaded) _readFault = false;
        return;
      }
      if (_readFault || !_canResume(_presentation)) return;
      _readFault = true;
      unawaited(
        showAppNotice(
          context,
          error,
          title: (strings) => strings.overridesUnreadable,
          eligibilityChanges: app,
          isCurrent: () =>
              source == (app, app.storageEpoch, _presentation) &&
              app.overrideErrorMessage != null &&
              _canResume(_presentation),
          onRetry: app.refresh,
          onDetails: () => _showDetails(
            error.summary,
            technicalDetail: error.technicalDetail,
            title: (strings) => strings.overridesUnreadable,
            onRetry: () async {
              if (source == (app, app.storageEpoch, _presentation) &&
                  identical(app.overrideErrorMessage, error) &&
                  _canResume(_presentation)) {
                await app.refresh();
              }
            },
          ),
        ),
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Object? _entryNoticeSource;
  final _entryFaults = <String, (String, AppMessage, DateTime?)>{};
  bool _entryNoticeScheduled = false;

  Map<String, (String, AppMessage, DateTime?)> get _entryErrors => {
    for (final entry in app.overrides)
      if (entry.errorMessage case final error?)
        entry.id: (entry.name, error, entry.update.lastAttempt),
  };

  void _scheduleEntryNotice() {
    if (_entryNoticeScheduled || !mounted) return;
    _entryNoticeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _entryNoticeScheduled = false;
      if (!mounted) return;
      final source = (app, app.storageEpoch, _presentation);
      if (_entryNoticeSource != source) {
        _entryNoticeSource = source;
        _entryFaults.clear();
      }
      final errors = _entryErrors;
      _entryFaults.removeWhere((id, _) => !errors.containsKey(id));
      if (!_canResume(_presentation)) return;
      final fresh = Map.of(errors)
        ..removeWhere((id, value) => _entryFaults[id] == value);
      if (fresh.isEmpty) return;
      _entryFaults.addAll(fresh);
      bool sameSource() =>
          mounted &&
          source == (app, app.storageEpoch, _presentation) &&
          fresh.entries.every(
            (entry) => _entryErrors[entry.key] == entry.value,
          );
      String summary(AppLocalizations strings) => strings.overrideActionFailed;
      String detail(AppLocalizations strings) => fresh.values
          .map((value) {
            final error = value.$2;
            return [
              value.$1,
              if (value.$3 case final time?)
                '${strings.autoUpdateAttempt}: ${time.toLocal()}',
              error.summary(strings),
              ?error.technicalDetail(strings),
            ].join('\n');
          })
          .join('\n\n');
      unawaited(
        showLocalizedOperationNotice(
          context,
          summary,
          technicalDetail: detail,
          eligibilityChanges: app,
          isCurrent: () => sameSource() && _canResume(_presentation),
          isCurrentWithPopup: (_) => sameSource() && _live(_presentation),
          onDetails: () => _showDetails(
            summary,
            technicalDetail: detail,
            title: (strings) => strings.overrideActionFailed,
            sourceCurrent: sameSource,
          ),
          identity: ('override-errors', source, Object.hashAll(fresh.values)),
        ),
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Widget _header(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final entries = app.overrides;
    return _OverrideSizeTransition(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
            child: Text(
              strings.overrideNotice,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (entries.isEmpty &&
              app.overridesLoaded &&
              app.overrideErrorMessage == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Center(child: Text(strings.overrideEmpty)),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final strings = AppLocalizations.of(context);
        final storageEpoch = app.storageEpoch;
        final readError = app.overrideErrorMessage;
        final canEdit =
            _canResume(_presentation) &&
            app.canEditOverrides &&
            app.overridesLoaded &&
            readError == null &&
            !_importing;
        final titleStyle = Theme.of(context).textTheme.titleLarge!
            .copyWith(fontWeight: FontWeight.w600);
        final titleMeasure =
            TextPainter(
              text: TextSpan(text: strings.overridePlugins, style: titleStyle),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout(
              maxWidth: math.max(
                1.0,
                constraints.maxWidth -
                    MediaQuery.paddingOf(context).horizontal -
                    80 -
                    (_route?.impliesAppBarDismissal == true
                        ? kToolbarHeight
                        : 0),
              ),
            );
        final toolbarHeight = math.max(
          kToolbarHeight,
          titleMeasure.height + 16,
        );
        titleMeasure.dispose();
        return Scaffold(
          appBar: AppBar(
            toolbarHeight: toolbarHeight,
            titleTextStyle: titleStyle,
            title: DefaultTextStyle(
              style: titleStyle,
              child: Text(strings.overridePlugins, softWrap: true),
            ),
            actions: [
              _addMenu(context, strings, canEdit, storageEpoch: storageEpoch),
            ],
          ),
          body: SafeArea(
            child: _list(
              context,
              viewportOrigin:
                  toolbarHeight + MediaQuery.paddingOf(context).top + 16,
            ),
          ),
        );
      },
    ),
  );

  String _summary(AppLocalizations strings, OverrideEntry entry) {
    final source = entry.source ?? strings.overrideLocal;
    return [
      source,
      entry.mode == OverrideMode.prepend
          ? strings.overridePrepend
          : strings.overrideReplace,
    ].join(' · ');
  }

  Widget _row(
    BuildContext context,
    AppLocalizations strings,
    OverrideEntry entry,
    int index, {
    required bool canEdit,
    required int storageEpoch,
    required List<String> order,
  }) {
    final presentation = _presentation;
    final theme = Theme.of(context);
    final palette = HomePalette.of(context);
    final titleStyle = theme.textTheme.titleMedium!.copyWith(
      fontWeight: FontWeight.w600,
      leadingDistribution: TextLeadingDistribution.even,
    );
    final firstLine =
        (MediaQuery.textScalerOf(context).scale(titleStyle.fontSize!) *
                (titleStyle.height ?? 1))
            .clamp(24.0, double.infinity);
    final menuOptions = <String, String>{
      'rename': strings.rename,
      'mode': entry.mode == OverrideMode.prepend
          ? strings.overrideReplace
          : strings.overridePrepend,
      'up': strings.overrideMoveUp,
      'down': strings.overrideMoveDown,
      if (entry.remote) ...{
        'source': strings.changeSource,
        'auto': entry.update.enabled
            ? strings.autoUpdateEvery(entry.update.hours)
            : strings.autoUpdate,
      },
      'delete': strings.overrideDelete,
    };
    final menuIcons = {
      'rename': (Icons.drive_file_rename_outline, palette.editAction),
      'mode': (Icons.layers_outlined, palette.moreAction),
      'up': (Icons.arrow_upward, palette.moreAction),
      'down': (Icons.arrow_downward, palette.moreAction),
      'source': (Icons.link, palette.syncAction),
      'auto': (Icons.update, palette.syncAction),
      'delete': (Icons.delete_outline, palette.error),
    };
    final disabledOptions = {
      for (final action in menuOptions.keys)
        if (!canEdit ||
            (action == 'up' && index == 0) ||
            (action == 'down' && index == order.length - 1))
          action,
    };
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: '${entry.name} · ${strings.overrideEnabled}',
          child: Switch(
            value: entry.enabled,
            onChanged: canEdit
                ? (value) {
                    if (!_canResume(presentation)) {
                      return;
                    }
                    _change(entry, {
                      'enabled': value,
                    }, storageEpoch: storageEpoch);
                  }
                : null,
          ),
        ),
        IconButton(
          tooltip: entry.remote ? strings.overrideUpdate : strings.editConfig,
          style: IconButton.styleFrom(
            foregroundColor: entry.remote
                ? palette.syncAction
                : palette.editAction,
          ),
          onPressed: canEdit
              ? () {
                  if (!_canResume(presentation)) {
                    return;
                  }
                  if (entry.remote) {
                    _menu(
                      context,
                      entry,
                      'update',
                      storageEpoch: storageEpoch,
                      order: order,
                    );
                  } else {
                    _edit(context, entry, storageEpoch: storageEpoch);
                  }
                }
              : null,
          icon: Icon(entry.remote ? Icons.refresh : Icons.edit_outlined),
        ),
        ChoiceMenuButton<String>(
          identity: (
            storageEpoch,
            entry.id,
            entry.revision,
            entry.name,
            entry.source,
            entry.mode,
            entry.enabled,
            index,
            order.length,
          ),
          tooltip: strings.moreLabel,
          options: menuOptions,
          disabledOptions: disabledOptions,
          leadingIcon: (action) {
            final (icon, color) = menuIcons[action]!;
            return Icon(
              icon,
              color: disabledOptions.contains(action) ? null : color,
            );
          },
          buttonBuilder: (context, onPressed, focus) => IconButton(
            tooltip: strings.moreLabel,
            focusNode: focus,
            style: IconButton.styleFrom(
              fixedSize: const Size.square(48),
              foregroundColor: palette.moreAction,
            ),
            onPressed: onPressed,
            icon: const Icon(Icons.more_vert),
          ),
          enabled: canEdit,
          onSelected: (action) {
            if (!_canResume(presentation)) {
              return;
            }
            _menu(
              context,
              entry,
              action,
              storageEpoch: storageEpoch,
              order: order,
            );
          },
        ),
      ],
    );
    final time = entry.updatedAt?.toLocal();
    final locale = MaterialLocalizations.of(context);
    final stamp = time == null
        ? entry.remote
              ? strings.updateTimeUnknown
              : strings.saveTimeUnknown
        : entry.remote
        ? strings.updatedAt(
            locale.formatCompactDate(time),
            locale.formatTimeOfDay(TimeOfDay.fromDateTime(time)),
          )
        : strings.savedAt(
            locale.formatCompactDate(time),
            locale.formatTimeOfDay(TimeOfDay.fromDateTime(time)),
          );
    final savedTime = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Text(
        stamp,
        softWrap: false,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    return _OverrideSizeTransition(
      child: Card(
        key: ValueKey('override-${entry.id}'),
        child: InkWell(
          onTap: canEdit
              ? () {
                  if (_canResume(presentation) && _live(presentation)) {
                    _edit(context, entry, storageEpoch: storageEpoch);
                  }
                }
              : null,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 24,
                  height: firstLine,
                  child: Icon(
                    entry.remote
                        ? Icons.cloud_outlined
                        : Icons.description_outlined,
                    color: entry.remote
                        ? palette.remoteSource
                        : palette.localSource,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final compact =
                          constraints.maxWidth <
                          340 * MediaQuery.textScalerOf(context).scale(14) / 14;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(entry.name, style: titleStyle),
                              ),
                              SizedBox(width: 24, height: firstLine),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Tooltip(
                            message: _summary(strings, entry),
                            child: Text(
                              _summary(strings, entry),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (compact) ...[
                            SizedBox(width: double.infinity, child: savedTime),
                            Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: actions,
                            ),
                          ] else
                            Row(
                              children: [
                                Expanded(child: savedTime),
                                const SizedBox(width: 8),
                                actions,
                              ],
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _menu(
    BuildContext context,
    OverrideEntry entry,
    String action, {
    required int storageEpoch,
    required List<String> order,
  }) async {
    final presentation = _presentation;
    if (!_canResume(presentation)) {
      return;
    }
    switch (action) {
      case 'rename':
        await _changeText(entry, storageEpoch: storageEpoch);
      case 'source':
        await _changeText(entry, source: true, storageEpoch: storageEpoch);
      case 'mode':
        _change(entry, {
          'mode': entry.mode == OverrideMode.prepend
              ? OverrideMode.replace.name
              : OverrideMode.prepend.name,
        }, storageEpoch: storageEpoch);
      case 'up':
        _reorder(entry, -1, storageEpoch: storageEpoch, order: order);
      case 'down':
        _reorder(entry, 1, storageEpoch: storageEpoch, order: order);
      case 'update':
        await app.submit({
          'action': 'updateOverride',
          ..._target(entry),
          'storageEpoch': storageEpoch,
        });
      case 'auto':
        if (!context.mounted) return;
        await showAutoUpdateDialog(
          context,
          app,
          config: null,
          override: entry,
          storageEpoch: storageEpoch,
          isCurrent: () => _live(presentation),
          onRoute: (route) => _ownedPopup = route,
        );
      case 'delete':
        if (!context.mounted) return;
        final accepted = await confirmAction(
          context,
          title: (strings) => strings.overrideDeleteTitle,
          subject: entry.name,
          message: (strings) => strings.overrideDeleteMessage,
          confirmLabel: (strings) => strings.overrideDelete,
          isCurrent: () => _live(presentation),
          onRoute: (route) => _ownedPopup = route,
        );
        if (accepted && _canResume(presentation)) {
          await app.submit({
            'action': 'deleteOverride',
            ..._target(entry),
            'storageEpoch': storageEpoch,
          });
        }
    }
  }

  Future<bool> _submitFormReceipt(
    BuildContext dialogContext,
    Map<String, Object?> command,
    int presentation,
  ) async {
    final owner = app;
    final pageRoute = _route;
    final editRoute = ModalRoute.of(dialogContext)!;
    final taskCurrent = AppTaskActivity.capture(context);
    final marker = ValueNotifier<bool>(true);
    ModalRoute<dynamic>? feedbackRoute;
    Map<String, Object?>? submitted;
    var released = false;
    var accepted = false;
    var presented = false;
    late VoidCallback checkOwner;

    bool readerCurrent({ModalRoute<dynamic>? popup}) =>
        (!released ? marker.value : presented) &&
        identical(owner.lastCommand, submitted) &&
        mounted &&
        dialogContext.mounted &&
        identical(owner, app) &&
        widget.active &&
        owner.foreground &&
        presentation == _presentation &&
        taskCurrent(ownedPopup: popup ?? editRoute) &&
        AppTaskActivity.routeIsActive(
          pageRoute,
          ownedPopup: popup ?? editRoute,
        ) &&
        AppTaskActivity.routeIsActive(editRoute, ownedPopup: popup);

    void release() {
      if (released) return;
      released = true;
      owner.removeListener(checkOwner);
      _feedbackOwner.removeListener(checkOwner);
      marker.value = false;
      marker.dispose();
    }

    checkOwner = () {
      if (!_feedbackOwner.value ||
          !identical(owner.lastCommand, submitted) ||
          !readerCurrent(popup: feedbackRoute)) {
        release();
      }
    };
    try {
      final pending = owner.submitForReceipt(command, feedbackOwner: marker);
      submitted = owner.lastCommand;
      owner.addListener(checkOwner);
      _feedbackOwner.addListener(checkOwner);
      final receipt = await pending;
      if (receipt.command == null ||
          !identical(receipt.command, submitted) ||
          !identical(owner.lastCommand, submitted) ||
          !readerCurrent()) {
        return false;
      }
      if (receipt.operationId != null) {
        accepted = true;
        // The form retires itself after this callback returns. Retain ownership
        // until that captured route is popped, not merely until admission returns.
        editRoute.popped.then((_) => release());
        if (!editRoute.isActive) release();
        return true;
      }
      final error = receipt.error;
      if (error == null) return false;

      if (!dialogContext.mounted) return false;
      await showAppNotice(
        dialogContext,
        error,
        isCurrent: readerCurrent,
        eligibilityChanges: owner,
        onPresented: () {
          presented = true;
          owner.acknowledgeLocalFeedback(marker);
        },
        onDetails: () async {
          _readingFeedback = true;
          try {
            await showAppMessage(
              dialogContext,
              error,
              isCurrent: readerCurrent,
              isCurrentWithPopup: (popup) => readerCurrent(popup: popup),
              eligibilityChanges: owner,
              onRoute: (route) {
                feedbackRoute = route;
                _ownedPopup = route ?? editRoute;
              },
            );
          } finally {
            _readingFeedback = false;
            if (mounted) _syncOwner();
          }
        },
      );
      return false;
    } finally {
      if (!accepted) release();
    }
  }

  Future<void> _changeText(
    OverrideEntry entry, {
    bool source = false,
    required int storageEpoch,
  }) async {
    final presentation = _presentation;
    if (!_canResume(presentation)) {
      return;
    }
    if (source) {
      await _showDialog<Map<String, Object?>>(
        builder: (dialogContext) => ImportDialog(
          isCurrent: () => _live(presentation),
          fragment: true,
          editingSource: true,
          source: entry.source,
          proxyName: entry.proxyName,
          addNoResolve: entry.addNoResolve,
          storageEpoch: storageEpoch,
          onSubmit: (input) async {
            if (!dialogContext.mounted ||
                !AppTaskActivity.routeIsActive(ModalRoute.of(dialogContext))) {
              return false;
            }
            if (!_live(presentation) || !app.canEditOverrides) {
              return false;
            }
            return _submitFormReceipt(dialogContext, {
              'action': 'changeOverrideSource',
              ..._target(entry),
              ...input,
              'storageEpoch': storageEpoch,
            }, presentation);
          },
        ),
      );
      return;
    }
    await _showDialog<String>(
      builder: (dialogContext) => ConfigFieldDialog(
        isCurrent: () => _live(presentation),
        initial: entry.name,
        title: (strings) => strings.rename,
        onSubmit: (value) async {
          if (!dialogContext.mounted ||
              !AppTaskActivity.routeIsActive(ModalRoute.of(dialogContext))) {
            return false;
          }
          if (!_live(presentation) || !app.canEditOverrides) {
            return false;
          }
          return _submitFormReceipt(dialogContext, {
            'action': 'changeOverride',
            ..._target(entry),
            'name': value,
            'storageEpoch': storageEpoch,
          }, presentation);
        },
      ),
    );
  }

  void _reorder(
    OverrideEntry entry,
    int delta, {
    required int storageEpoch,
    required List<String> order,
  }) {
    if (!_canResume(_presentation) || !app.canEditOverrides) {
      return;
    }
    final ids = List<String>.of(order);
    final from = ids.indexOf(entry.id);
    final to = from + delta;
    if (from < 0 || to < 0 || to >= ids.length) return;
    final moved = ids.removeAt(from);
    ids.insert(to, moved);
    app.submit({
      'action': 'reorderOverrides',
      ..._target(entry),
      'expectedOrder': order,
      'ids': ids,
      'storageEpoch': storageEpoch,
    });
  }

  void _change(
    OverrideEntry entry,
    Map<String, Object?> values, {
    required int storageEpoch,
  }) {
    if (!_canResume(_presentation) || !app.canEditOverrides) {
      return;
    }
    app.submit({
      'action': 'changeOverride',
      ..._target(entry),
      ...values,
      'storageEpoch': storageEpoch,
    });
  }

  Future<void> _edit(
    BuildContext context,
    OverrideEntry entry, {
    required int storageEpoch,
  }) async {
    if (!_canResume(_presentation)) {
      return;
    }
    await Navigator.of(context).push<void>(
      FocusedPageRoute(
        builder: (_) => ConfigTextPage(
          app: app,
          storageEpoch: storageEpoch,
          entry: null,
          initialName: entry.name,
          initialText: entry.body,
          readOnly: entry.remote,
          saveLabel: (strings) => strings.save,
          onSave: (command, owner) => app.saveOverride({
            ...command,
            'id': command['id'] ?? entry.id,
            'revision': command['revision'] ?? entry.revision,
            'storageEpoch': storageEpoch,
          }, feedbackOwner: owner),
        ),
      ),
    );
  }

  Widget _addMenu(
    BuildContext context,
    AppLocalizations strings,
    bool enabled, {
    required int storageEpoch,
  }) {
    final palette = HomePalette.of(context);
    final presentation = _presentation;
    return ChoiceMenuButton<String>(
      enabled: _canResume(presentation) && !_importing,
      identity: (storageEpoch, presentation),
      tooltip: strings.addOverride,
      iconColor: Theme.of(context).colorScheme.primary,
      icon: Icons.add,
      buttonBuilder: (context, onPressed, focus) => IconButton(
        tooltip: strings.addOverride,
        focusNode: focus,
        onPressed: onPressed,
        icon: !app.overridesLoaded && app.overrideErrorMessage == null
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add),
      ),
      options: {
        'new': strings.newOverride,
        'file': strings.importFromFile,
        'url': strings.remoteOverride,
      },
      disabledOptions: {
        if (!enabled) ...['new', 'file', 'url'],
      },
      leadingIcon: (kind) => Icon(switch (kind) {
        'url' => Icons.link,
        'file' => Icons.file_open_outlined,
        _ => Icons.note_add_outlined,
      }, color: kind == 'url' ? palette.remoteSource : palette.localSource),
      onSelected: (kind) {
        if (!mounted ||
            !_canResume(presentation) ||
            !_epochCurrent(storageEpoch, presentation)) {
          return;
        }
        switch (kind) {
          case 'new':
            _newLocal(context, storageEpoch: storageEpoch);
          case 'file':
            _importFile(storageEpoch: storageEpoch);
          case 'url':
            _newRemote(context, storageEpoch: storageEpoch);
        }
      },
    );
  }

  Future<void> _importFile({required int storageEpoch}) async {
    var presentation = _presentation;
    if (!mounted ||
        !_canResume(presentation) ||
        !_epochCurrent(storageEpoch, presentation) ||
        _importing ||
        !app.canEditOverrides) {
      return;
    }
    final owner = app;
    final taskCurrent = AppTaskActivity.captureSource(context);
    final route = _route;
    var retired = false;
    bool sourceCurrent() {
      retired |=
          _fileRetired ||
          !mounted ||
          !identical(owner, app) ||
          !taskCurrent() ||
          !AppTaskActivity.routeIsActive(route) ||
          storageEpoch != owner.storageEpoch ||
          storageEpoch != owner.state.storageEpoch;
      return !retired;
    }

    Future<bool> resumeFile() async {
      final rebuild = !owner.interactive || !widget.active;
      if (!sourceCurrent()) {
        if (mounted &&
            identical(owner, app) &&
            _canResume(presentation) &&
            (storageEpoch != owner.storageEpoch ||
                storageEpoch != owner.state.storageEpoch)) {
          await _showMessage(messages.storageContextChanged);
        }
        return false;
      }
      if (!await owner.waitUntilInteractive()) return false;
      if (rebuild) await WidgetsBinding.instance.endOfFrame;
      if (!sourceCurrent() || !owner.interactive) return false;
      presentation = _presentation;
      return _canResume(presentation);
    }

    setState(() => _importing = true);
    AppSnapshot? result;
    _fileRetired = false;
    _fileCurrent = sourceCurrent;
    try {
      final selection = widget.selectFile == selectConfigFile
          ? (_fileSelection = ConfigFileSelection(owner.platform))
          : null;
      final file = await (selection?.select() ?? widget.selectFile());
      if (file == null || !await resumeFile()) return;
      final body = await readConfigFile(file);
      if (!await resumeFile() || !mounted) return;
      if (!app.canEditOverrides) {
        await _showFeedback((strings) => strings.operationBusyFile);
        return;
      }
      result = await app.saveOverride({
        'name': file.name.trim().isEmpty
            ? AppLocalizations.of(context).newOverride
            : configFileName(file.name),
        'body': body,
        'storageEpoch': storageEpoch,
      }, feedbackOwner: _feedbackOwner);
      if (!mounted ||
          !_canResume(presentation) ||
          !_epochCurrent(storageEpoch, presentation)) {
        return;
      }
      if (result?.resultSuccess != true ||
          !const ['saved', 'applied'].contains(result?.overrideStatus)) {
        await _showMessage(
          result?.resultMessageDescription ??
              app.commandErrorMessage ??
              messages.importResultUnconfirmed,
          onPresented: () =>
              app.acknowledgeLocalFeedback(_feedbackOwner, result: result),
        );
      }
    } catch (error) {
      if (!await resumeFile()) return;
      if (mounted &&
          _canResume(presentation) &&
          _epochCurrent(storageEpoch, presentation)) {
        await _showMessage(
          error is ConfigFailure
              ? error.message
              : messages.fileUnreadable.withDetail(error),
        );
      }
    } finally {
      _fileCurrent = null;
      _fileSelection = null;
      if (result?.resultSuccess == true &&
          const ['saved', 'applied'].contains(result?.overrideStatus)) {
        owner.acknowledgeLocalFeedback(_feedbackOwner, result: result);
      }
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _newLocal(
    BuildContext context, {
    required int storageEpoch,
  }) async {
    final presentation = _presentation;
    if (!mounted ||
        !_canResume(presentation) ||
        !_epochCurrent(storageEpoch, presentation)) {
      return;
    }
    final strings = AppLocalizations.of(context);
    final name = await _showDialog<String>(
      builder: (dialogContext) => ConfigFieldDialog(
        isCurrent: () => _live(presentation),
        initial: strings.newOverride,
        title: (strings) => strings.overrideName,
        confirmLabel: (strings) => strings.continueLabel,
      ),
    );
    if (!context.mounted || name == null || !_canResume(presentation)) {
      return;
    }
    await Navigator.of(context).push<void>(
      FocusedPageRoute(
        builder: (_) => ConfigTextPage(
          app: app,
          storageEpoch: storageEpoch,
          initialName: name,
          initialText: '{}',
          onSave: (command, owner) => app.saveOverride({
            ...command,
            'storageEpoch': storageEpoch,
          }, feedbackOwner: owner),
        ),
      ),
    );
    if (_canResume(presentation) && _epochCurrent(storageEpoch, presentation)) {
      app.refresh();
    }
  }

  Future<void> _newRemote(
    BuildContext context, {
    required int storageEpoch,
  }) async {
    final presentation = _presentation;
    if (!mounted ||
        !_canResume(presentation) ||
        !_epochCurrent(storageEpoch, presentation)) {
      return;
    }
    await _showDialog<Map<String, Object?>>(
      builder: (dialogContext) => ImportDialog(
        isCurrent: () => _live(presentation),
        fragment: true,
        storageEpoch: storageEpoch,
        onSubmit: (input) async {
          if (!dialogContext.mounted ||
              !AppTaskActivity.routeIsActive(ModalRoute.of(dialogContext))) {
            return false;
          }
          if (!_live(presentation) || !app.canEditOverrides) {
            return false;
          }
          final receipt = await app.submit({
            'action': 'importOverride',
            ...input,
            'storageEpoch': storageEpoch,
          });
          return receipt != null;
        },
      ),
    );
  }
}
