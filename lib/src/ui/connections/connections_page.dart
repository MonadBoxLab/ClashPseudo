import '../locale/model_text.dart';
import '../locale/message_text.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../components/collections/collection_workspace.dart';
import '../components/collections/reading_list.dart';
import '../components/input/task_shortcuts.dart';

import '../app/app_controller.dart';
import '../navigation/task_activity.dart';
import '../theme/app_theme.dart';
import '../components/feedback/operation_feedback.dart';
import '../components/feedback/operation_notice.dart';
import '../components/input/choice_menu_button.dart';
import '../components/input/toolbar_search_field.dart';
import '../../l10n/app_localizations.dart';
import '../../model/messages.dart';
import '../../model/config_entry.dart';
import '../overrides/definitions/local_custom_editor.dart';
import '../../logic/overrides/local_yaml_edit.dart';
import '../strategies/strategy_icon.dart';
import 'connection_controller.dart';
import '../../model/connection_snapshot.dart';

part 'connection_detail_page.dart';

class ConnectionsPage extends StatefulWidget {
  const ConnectionsPage({
    super.key,
    required this.app,
    this.active = true,
    this.embedded = false,
  });
  final AppController app;
  final bool active;
  final bool embedded;

  @override
  State<ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends State<ConnectionsPage> {
  late final ConnectionController controller;
  final _scroll = ScrollController();
  final _filterButton = GlobalKey();
  final _lifecycleButton = GlobalKey();
  final _searchText = TextEditingController();
  final _searchFocus = FocusNode();
  bool _searching = false;
  String _query = '';
  bool? _activeFilter;
  List<ConnectionRecord> _rows = [];
  ReadingList? _masterList;
  Object? _contentKey;
  (String, String)? _filter;
  bool _detailOpen = false;
  Key? _detailKey;
  final _workspace = GlobalKey<CollectionWorkspaceState>();
  final _filterOwners = <GlobalKey>{};
  bool get _filterOpen => _filterOwners.isNotEmpty;
  bool _visible = false;
  final _actionsMenu = GlobalKey();
  Object? _feedbackSource;
  int _seenRead = 0;
  bool _fault = false;
  bool _quiet = false;
  bool _confirmed = false;
  Object? _pendingNotice;
  Object? _seenOperationError;
  final _operationErrors =
      <({Object identity, Object source, AppMessage message})>[];
  bool _schedulingOperations = false;

  Object get _sourceIdentity => (
    widget.app.storageEpoch,
    widget.app.state.generation,
    widget.app.state.core.identity,
  );

  bool get _feedbackSourceCurrent =>
      mounted &&
      (widget.active || !widget.app.foreground) &&
      AppTaskActivity.captureSource(context)();

  bool _feedbackLive({ModalRoute<dynamic>? popup}) =>
      mounted &&
      widget.active &&
      widget.app.interactive &&
      !_filterOpen &&
      AppTaskActivity.isActive(context, ownedPopup: popup) &&
      AppTaskActivity.routeIsActive(ModalRoute.of(context), ownedPopup: popup);

  void _retireNotice() {
    _pendingNotice = null;
  }

  void _syncFeedback() {
    final source = _sourceIdentity;
    if (_feedbackSource != source) {
      _retireNotice();
      _feedbackSource = source;
      _fault = _quiet = _confirmed = false;
      _seenRead = controller.readRevision;
    }
    if (_seenRead != controller.readRevision) {
      _seenRead = controller.readRevision;
      if (controller.readFailed == false) {
        _fault = _quiet = _confirmed = false;
        _retireNotice();
      } else if (controller.readFailed == true) {
        _fault = true;
        _confirmed = _feedbackLive();
      }
    }
    if (!_feedbackSourceCurrent) _confirmed = false;
    if (!_noticeEligible) _retireNotice();
  }

  bool get _noticeEligible =>
      _fault &&
      !_quiet &&
      _confirmed &&
      controller.available &&
      controller.errorSource == ConnectionErrorSource.read &&
      _feedbackSource == _sourceIdentity &&
      _feedbackSourceCurrent;

  void _scheduleOperationNotices(BuildContext noticeContext) {
    _operationErrors.removeWhere(
      (failure) => failure.source != _sourceIdentity,
    );
    if (_operationErrors.isEmpty || _schedulingOperations || !_feedbackLive()) {
      return;
    }
    _schedulingOperations = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _schedulingOperations = false;
      if (!noticeContext.mounted || !_feedbackLive()) return;
      final failures = List.of(_operationErrors);
      _operationErrors.clear();
      for (final failure in failures) {
        bool current() =>
            failure.source == _sourceIdentity && _feedbackSourceCurrent;
        if (!current()) continue;
        unawaited(
          showAppNotice(
            noticeContext,
            failure.message,
            title: (strings) => strings.errorDetails,
            identity: failure.identity,
            eligibilityChanges: controller,
            isCurrent: current,
            canPresent: _feedbackLive,
            isCurrentWithPopup: (popup) =>
                current() && _feedbackLive(popup: popup),
          ),
        );
      }
    });
  }

  void _scheduleNotice(BuildContext noticeContext) {
    _syncFeedback();
    if (!_noticeEligible || _pendingNotice != null) return;
    final ticket = _pendingNotice = Object();
    final source = _sourceIdentity;
    bool current() =>
        mounted &&
        _pendingNotice == ticket &&
        source == _sourceIdentity &&
        _noticeEligible;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!noticeContext.mounted || !current()) return;
      unawaited(
        showLocalizedOperationNotice(
          noticeContext,
          (strings) => strings.connectionRefreshFailed,
          persist: true,
          identity: ticket,
          isCurrent: current,
          canPresent: _feedbackLive,
          eligibilityChanges: controller,
          onDetails: () async {
            if (!current()) return;
            _quiet = true;
            await _showError();
          },
          onClosed: (reason) {
            if (!mounted ||
                _pendingNotice != ticket ||
                source != _sourceIdentity) {
              return;
            }
            _pendingNotice = null;
            if (reason == SnackBarClosedReason.action ||
                reason == SnackBarClosedReason.dismiss ||
                reason == SnackBarClosedReason.swipe) {
              _quiet = true;
            }
          },
        ).then((presented) {
          if (!presented && mounted && _pendingNotice == ticket) {
            _pendingNotice = null;
          }
        }),
      );
    });
  }

  void _setFilterOpen(GlobalKey owner, bool open) {
    if (!mounted) return;
    final changed = open
        ? _filterOwners.add(owner)
        : _filterOwners.remove(owner);
    if (!changed) return;
    _syncFeedback();
    // Retire the callback gate synchronously, even when SDK menu teardown
    // happens during build. Only the visual rebuild may wait for that frame.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  bool get _reading =>
      mounted &&
      widget.active &&
      widget.app.foreground &&
      AppTaskActivity.isVisible(context) &&
      AppTaskActivity.routeIsActive(ModalRoute.of(context));

  bool get _active =>
      _reading && widget.app.interactive && AppTaskActivity.isActive(context);

  bool get _masterLive =>
      _active &&
      widget.app.interactive &&
      (_workspace.currentState?.masterVisible ?? true);

  @override
  void initState() {
    super.initState();
    _feedbackSource = _sourceIdentity;
    controller = ConnectionController(widget.app, isActive: () => _reading)
      ..addListener(_changed);
    _searchText.addListener(_searchChanged);
  }

  void _searchChanged() {
    final query = _searchText.text.trim().toLowerCase();
    if (_query == query) return;
    _query = query;
    _resetFilterPosition();
  }

  void _enterSearch() {
    if (!_active || !widget.app.interactive) return;
    _workspace.currentState?.showMaster();
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_masterLive &&
          _searching &&
          !_filterOpen &&
          ModalRoute.of(context)?.isCurrent == true) {
        _searchFocus.requestFocus();
      }
    });
  }

  void _exitSearch() {
    _searchFocus.unfocus();
    _searchText.clear();
    setState(() => _searching = false);
  }

  bool _matchesQuery(ConnectionRecord row) =>
      _query.isEmpty ||
      [
        row.host,
        row.destinationIP,
        row.destinationPort,
        if (row.chains.isNotEmpty) row.path,
        row.rule,
        row.rulePayload,
      ].any((field) => field.toLowerCase().contains(_query));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncVisibility();
  }

  @override
  void didUpdateWidget(ConnectionsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _syncVisibility();
  }

  void _syncVisibility() {
    // MenuAnchor remains in this route; only an actual covering route hides it.
    if (_detailOpen) return;
    final visible = _reading;
    if (_visible == visible) return;
    _visible = visible;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) controller.setVisible(_visible);
    });
  }

  List<ConnectionRecord> _records() {
    final rows = (controller.data?.records ?? const <ConnectionRecord>[])
        .where(
          (row) =>
              (_filter == null || row.ruleKey == _filter) &&
              (_activeFilter == null || row.active == _activeFilter) &&
              _matchesQuery(row),
        )
        .toList();
    if (rows.length == _rows.length) {
      final byId = {for (final row in rows) row.id: row};
      if (_rows.every(
        (row) => byId[row.id]?.start == row.start && byId.containsKey(row.id),
      )) {
        return [for (final row in _rows) byId[row.id]!];
      }
    }
    rows.sort((a, b) {
      final order = (b.start?.millisecondsSinceEpoch ?? 0).compareTo(
        a.start?.millisecondsSinceEpoch ?? 0,
      );
      return order != 0 ? order : a.id.compareTo(b.id);
    });
    return rows;
  }

  void _changed() {
    if (!mounted) return;
    final failure = controller.operationError;
    if (failure != null && failure.identity != _seenOperationError) {
      _seenOperationError = failure.identity;
      if (failure.source == _sourceIdentity) _operationErrors.add(failure);
    }
    _syncFeedback();
    if (_detailOpen && controller.detail == null) {
      setState(() => _detailOpen = false);
      _visible = false;
      _syncVisibility();
    }
    final contentKey = (controller.data, _filter, _activeFilter, _query);
    if (_contentKey == contentKey) {
      setState(() {});
      return;
    }
    _contentKey = contentKey;
    // ReadingList owns source-aware anchoring, including width/locale changes.
    setState(() => _rows = _records());
  }

  void _openDetail(ConnectionRecord record) {
    if (!_masterLive) return;
    _searchFocus.unfocus();
    controller.openDetail(record);
    setState(() {
      _detailKey = UniqueKey();
      _detailOpen = true;
    });
  }

  void _closeDetail() {
    setState(() => _detailOpen = false);
    controller.closeDetail();
    _changed();
    _visible = false;
    _syncVisibility();
  }

  Widget _filterMenu({bool lifecycle = false, required Widget child}) {
    final strings = AppLocalizations.of(context);
    final rules = <(String, String), String>{
      for (final row in controller.data?.records ?? <ConnectionRecord>[])
        row.ruleKey: row.ruleLabel,
      ?_filter: _filter == null || _filter!.$1.isEmpty
          ? strings.notProvided
          : [_filter!.$1, _filter!.$2].where((s) => s.isNotEmpty).join(' · '),
    };
    final options = <((String, String)?, String)>[
      (null, strings.allRules),
      for (final entry in rules.entries) (entry.key, entry.value),
    ];
    final labels = lifecycle
        ? [strings.allConnections, strings.activeOnly, strings.inactiveOnly]
        : options.map((option) => option.$2).toList();
    final current = lifecycle
        ? (_activeFilter == null ? 0 : (_activeFilter! ? 1 : 2))
        : options.indexWhere((option) => option.$1 == _filter);
    final colors = Theme.of(context).colorScheme;
    final palette = ConnectionPalette(
      Theme.of(context).brightness == Brightness.dark,
    );
    final owner = lifecycle ? _lifecycleButton : _filterButton;
    return ChoiceMenuButton<int>(
      identity: (
        widget.active,
        widget.app.storageEpoch,
        widget.app.state.core.generation,
        widget.app.state.core.composition,
      ),
      enabled: _masterLive,
      value: current,
      options: {for (final (index, label) in labels.indexed) index: label},
      onOpened: () {
        _searchFocus.unfocus();
        _setFilterOpen(owner, true);
      },
      onClosed: () => _setFilterOpen(owner, false),
      leadingIcon: lifecycle
          ? (value) => Icon(
              switch (value) {
                1 => Icons.link_rounded,
                2 => Icons.link_off_rounded,
                _ => Icons.list_rounded,
              },
              size: 20,
              color: switch (value) {
                0 => colors.primary,
                1 => palette.active,
                _ => colors.onSurfaceVariant,
              },
            )
          : null,
      onSelected: (selected) {
        if (!_masterLive || selected == current) {
          return;
        }
        if (lifecycle) {
          _activeFilter = switch (selected) {
            1 => true,
            2 => false,
            _ => null,
          };
        } else {
          _filter = options[selected].$1;
        }
        _resetFilterPosition();
      },
      buttonBuilder: (context, onPressed, focus) => TextButton(
        key: lifecycle ? _lifecycleButton : _filterButton,
        focusNode: focus,
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: colors.onSurface,
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: child,
      ),
    );
  }

  void _resetFilterPosition() {
    _changed();
    if (_scroll.hasClients) _scroll.position.correctBy(-_scroll.offset);
  }

  @override
  Widget build(BuildContext context) => TaskShortcuts(
    enabled: _active,
    shortcutsEnabled: !_filterOpen,
    onSearch: () {
      if (_active && !_filterOpen) _enterSearch();
    },
    onEscape: _detailOpen || _searching
        ? () {
            if (!_active || _filterOpen) return;
            if (_workspace.currentState?.showingDetail == true) {
              _closeDetail();
            } else if (_searching) {
              _exitSearch();
            }
          }
        : null,
    child: ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: OperationNoticeHost(
        child: Builder(
          builder: (noticeContext) {
            _scheduleOperationNotices(noticeContext);
            _scheduleNotice(noticeContext);
            return _content(noticeContext);
          },
        ),
      ),
    ),
  );

  Widget _content(BuildContext context) {
    _syncVisibility();
    final strings = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final notice = [
      if (controller.data?.limited == true) strings.connectionLimitedNotice,
      if ((controller.data?.omitted ?? 0) > 0)
        strings.connectionOmitted(controller.data!.omitted),
    ].where((text) => text.isNotEmpty).join('\n');
    final badgeStyle = DefaultTextStyle.of(context).style
        .merge(Theme.of(context).textTheme.bodySmall!.copyWith(height: 1.4));
    var badgeWidth = 0.0;
    for (final label in [
      strings.connectionActive,
      strings.connectionInactive,
    ]) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: badgeStyle),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
        maxLines: 1,
      )..layout();
      if (painter.width > badgeWidth) badgeWidth = painter.width;
      painter.dispose();
    }
    badgeWidth = badgeWidth.ceilToDouble() + 12;
    final filterLabel = _filter == null
        ? strings.allRules
        : [_filter!.$1, _filter!.$2].where((s) => s.isNotEmpty).join(' · ');
    final detailOpen = _detailOpen;
    final selected = controller.detail;
    final listIdentity = (
      controller.data?.sessionGeneration,
      controller.data?.generation,
      controller.data?.configId,
      controller.data?.revision,
      controller.data?.composition,
      _filter,
      _activeFilter,
      _query,
    );
    if (_rows.isEmpty) _masterList = null;
    return CollectionWorkspace(
      key: _workspace,
      active: _active,
      onMasterVisibilityChanged: (visible) {
        if (visible) _changed();
      },
      onClose: _closeDetail,
      detail: detailOpen && selected != null
          ? _ConnectionDetail(
              key: _detailKey,
              controller: controller,
              active: widget.active,
              isPresented: () =>
                  mounted && _workspace.currentState?.detailPresented == true,
              onClose: _closeDetail,
              onMenuChanged: _setFilterOpen,
            )
          : null,
      detailStatus:
          selected != null && !_rows.any((row) => row.id == selected.id)
          ? strings.selectionOutsideList
          : '',
      master: PopScope<void>(
        canPop: !_searching || detailOpen,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop || detailOpen || !_searching) return;
          if (_searchFocus.hasFocus ||
              MediaQuery.viewInsetsOf(context).bottom > 0) {
            _searchFocus.unfocus();
          } else {
            _exitSearch();
          }
        },
        child: Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            titleSpacing: 0,
            title: AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 200),
              // Retiring controls leave immediately, including their focus and
              // semantics; only the current toolbar fades into the fixed slot.
              layoutBuilder: (current, _) => current ?? const SizedBox.shrink(),
              child: _searching
                  ? Row(
                      key: const ValueKey('connection-search'),
                      children: [
                        const SizedBox(width: 8),
                        Expanded(
                          child: ToolbarSearchField(
                            controller: _searchText,
                            focusNode: _searchFocus,
                            trailing: ValueListenableBuilder<TextEditingValue>(
                              valueListenable: _searchText,
                              builder: (context, value, _) => IconButton(
                                tooltip: value.text.isEmpty
                                    ? strings.exitSearch
                                    : strings.clearSearch,
                                onPressed: () {
                                  if (_searchText.text.isEmpty) {
                                    _exitSearch();
                                  } else {
                                    _searchText.clear();
                                    _searchFocus.requestFocus();
                                  }
                                },
                                icon: const Icon(Icons.close_rounded),
                              ),
                            ),
                            hintText: strings.searchConnections,
                          ),
                        ),
                      ],
                    )
                  : Row(
                      key: const ValueKey('connection-title'),
                      children: [
                        if (!widget.embedded)
                          const BackButton()
                        else
                          const SizedBox(width: 16),
                        Expanded(child: Text(strings.recentConnections)),
                        IconButton(
                          tooltip: strings.searchConnections,
                          onPressed: _enterSearch,
                          color: HomePalette.of(context).moreAction,
                          icon: const Icon(Icons.search),
                        ),
                      ],
                    ),
            ),
            actions: [
              ChoiceMenuButton<String>(
                key: _actionsMenu,
                identity: _sourceIdentity,
                enabled: _masterLive,
                tooltip: strings.moreActions,
                icon: Icons.more_vert_rounded,
                buttonBuilder: (context, onPressed, focus) => IconButton(
                  key: const ValueKey('connection-list-actions'),
                  focusNode: focus,
                  onPressed: onPressed,
                  tooltip: strings.moreActions,
                  icon: const Icon(Icons.more_vert_rounded),
                ),
                options: {
                  'connection-clear-inactive': strings.clearInactiveConnections,
                },
                disabledOptions: {
                  if (controller.clearing) 'connection-clear-inactive',
                },
                leadingIcon: (_) =>
                    const Icon(Icons.clear_all_rounded, size: 20),
                onOpened: () => _setFilterOpen(_actionsMenu, true),
                onClosed: () => _setFilterOpen(_actionsMenu, false),
                onSelected: (_) {
                  if (!_masterLive) return;
                  _setFilterOpen(_actionsMenu, false);
                  if (!controller.clearing) controller.clearInactive();
                },
              ),
              const CollectionDetailsAction(),
              const SizedBox(width: 8),
            ],
          ),
          body: LayoutBuilder(
            builder: (context, constraints) => Column(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: constraints.maxHeight),
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: _filterMenu(
                              lifecycle: true,
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      _activeFilter == null
                                          ? strings.allConnections
                                          : (_activeFilter!
                                                ? strings.activeOnly
                                                : strings.inactiveOnly),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const Icon(
                                    Icons.expand_more_rounded,
                                    size: 18,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Tooltip(
                              message: strings.filterMatchedRule,
                              child: _filterMenu(
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        filterLabel.isEmpty
                                            ? strings.notProvided
                                            : filterLabel,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const Icon(
                                      Icons.expand_more_rounded,
                                      size: 18,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    child: _rows.isEmpty
                        ? CustomScrollView(
                            slivers: [
                              SliverToBoxAdapter(
                                child: _capacityNotice(notice),
                              ),
                              SliverFillRemaining(
                                hasScrollBody: false,
                                child: Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Text(
                                      _query.isNotEmpty ||
                                              _filter != null ||
                                              _activeFilter != null
                                          ? strings.noMatchingConnections
                                          : controller.app.state.phase ==
                                                'STOPPED'
                                          ? strings.noRecentConnections
                                          : strings.noConnections,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : Material(
                            color: colors.surface,
                            borderRadius: BorderRadius.circular(16),
                            clipBehavior: Clip.antiAlias,
                            child: Builder(
                              builder: (context) {
                                // Freeze only the hidden list presentation. The
                                // controller and _rows continue consuming results;
                                // the pane dependency refreshes this child in the
                                // same frame that the master becomes eligible.
                                if (!CollectionWorkspace.paneActiveOf(
                                      context,
                                    ) &&
                                    _masterList?.identity == listIdentity) {
                                  return _masterList!;
                                }
                                return _masterList = ReadingList(
                                  key: const ValueKey(
                                    'connection-reading-list',
                                  ),
                                  controller: _scroll,
                                  identity: listIdentity,
                                  header: _capacityNotice(notice),
                                  items: [
                                    for (final (index, row) in _rows.indexed)
                                      ReadingListItem(
                                        id: (row.id, row.start),
                                        layoutValues: [
                                          if (index == 0) notice,
                                          row.target,
                                          row.path,
                                          row.network,
                                        ],
                                        builder: (context) => Column(
                                          children: [
                                            _row(row, badgeWidth),
                                            if (index < _rows.length - 1)
                                              Divider(
                                                height: 1,
                                                indent: 14,
                                                endIndent: 14,
                                                color: colors.outlineVariant,
                                              ),
                                          ],
                                        ),
                                      ),
                                  ],
                                );
                              },
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showError() async {
    if (!_feedbackLive()) return;
    final message = controller.errorMessage;
    if (message == null) return;
    final source = _sourceIdentity;
    if (_fault) _quiet = true;
    _retireNotice();
    await showLocalizedOperationMessage(
      context,
      message.summary,
      technicalDetail: message.technicalDetail,
      title: (strings) => strings.errorDetails,
      error: true,
      eligibilityChanges: controller,
      isCurrent: () => _feedbackLive() && source == _sourceIdentity,
      isCurrentWithPopup: (popup) =>
          _feedbackLive(popup: popup) && source == _sourceIdentity,
    );
  }

  Widget _capacityNotice(String notice) {
    if (notice.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      key: const ValueKey('connection-capacity-notice'),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Icon(
              Icons.info_outline_rounded,
              size: 20,
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              notice,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(ConnectionRecord row, double badgeWidth) {
    final strings = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final palette = ConnectionPalette(
      Theme.of(context).brightness == Brightness.dark,
    );
    final state = row.active
        ? strings.connectionActive
        : strings.connectionInactive;
    final stateColor = row.active ? palette.active : colors.onSurfaceVariant;
    final selected =
        _detailOpen &&
        controller.detail?.id == row.id &&
        controller.detailSource?.matchesIdentity(controller.app.state.core) ==
            true;
    return Semantics(
      button: true,
      selected: selected,
      child: AnimatedContainer(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              width: 3,
              color: selected ? colors.primary : Colors.transparent,
            ),
          ),
        ),
        child: InkWell(
          onTap: () => _openDetail(row),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        row.target,
                        style: Theme.of(context).textTheme.bodyLarge!
                            .copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: colors.primary,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  row.chains.isEmpty ? '—' : row.path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall!
                      .copyWith(color: colors.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final size = MediaQuery.textScalerOf(
                      context,
                    ).scale(Theme.of(context).textTheme.bodySmall!.fontSize!);
                    final badge = AnimatedContainer(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 180),
                      key: ValueKey('connection-state-${row.id}'),
                      width: badgeWidth.clamp(0.0, constraints.maxWidth),
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: stateColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        state,
                        softWrap: false,
                        style: Theme.of(context).textTheme.bodySmall!
                            .copyWith(height: 1.4, color: stateColor),
                      ),
                    );
                    Widget metric(
                      String value,
                      Color color, {
                      bool numeric = false,
                    }) => SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Text(
                        value,
                        softWrap: false,
                        style: Theme.of(context).textTheme.bodySmall!.copyWith(
                          height: 1.4,
                          color: color,
                          fontFeatures: numeric
                              ? const [FontFeature.tabularFigures()]
                              : null,
                        ),
                      ),
                    );
                    final protocol = metric(
                      row.network.toUpperCase(),
                      colors.onSurfaceVariant,
                    );
                    final traffic = Row(
                      children: [
                        Expanded(
                          child: metric(
                            '↓ ${_bytes(row.download)}',
                            palette.download,
                            numeric: true,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: metric(
                            '↑ ${_bytes(row.upload)}',
                            palette.upload,
                            numeric: true,
                          ),
                        ),
                      ],
                    );
                    // Choose structure from available workspace.
                    if (constraints.maxWidth < size * 25 + 32) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (constraints.maxWidth <
                              badgeWidth + size * 3 + 12) ...[
                            badge,
                            const SizedBox(height: 6),
                            protocol,
                          ] else
                            Row(
                              children: [
                                badge,
                                const SizedBox(width: 12),
                                Expanded(child: protocol),
                              ],
                            ),
                          const SizedBox(height: 6),
                          SizedBox(
                            width: (size * 13 + 10).clamp(
                              0,
                              constraints.maxWidth,
                            ),
                            child: traffic,
                          ),
                        ],
                      );
                    }
                    return Row(
                      children: [
                        badge,
                        const SizedBox(width: 10),
                        SizedBox(width: size * 3, child: protocol),
                        const SizedBox(width: 10),
                        Flexible(
                          child: SizedBox(
                            width: size * 13 + 10,
                            child: traffic,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    controller.dispose();
    _scroll.dispose();
    _searchText.removeListener(_searchChanged);
    _searchText.dispose();
    _searchFocus.dispose();
    super.dispose();
  }
}

String _bytes(int? value) {
  if (value == null) return '—';
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KiB';
  if (value < 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
}
