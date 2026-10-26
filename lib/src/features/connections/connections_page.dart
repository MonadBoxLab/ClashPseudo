import 'package:flutter/material.dart';

import '../../app/widgets/collection_workspace.dart';
import '../../app/widgets/task_shortcuts.dart';

import '../../app/app_controller.dart';
import '../../app/app_theme.dart';
import '../../app/widgets/operation_feedback.dart';
import '../../app/widgets/choice_menu_button.dart';
import '../../app/widgets/toolbar_search_field.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/messages.dart';
import '../configs/config_entry.dart';
import '../overrides/local_custom_editor.dart';
import '../overrides/local_yaml_edit.dart';
import '../strategies/strategy_icon.dart';
import 'connection_controller.dart';
import 'connection_snapshot.dart';

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
  final _viewport = GlobalKey();
  final _filterButton = GlobalKey();
  final _lifecycleButton = GlobalKey();
  final _searchText = TextEditingController();
  final _searchFocus = FocusNode();
  bool _searching = false;
  String _query = '';
  bool? _activeFilter;
  final _keys = <String, GlobalKey>{};
  final _indices = <Key, int>{};
  List<ConnectionRecord> _rows = [];
  Object? _contentKey;
  ConnectionViewStatus? _lastStatus;
  (String, String)? _filter;
  bool _detailOpen = false;
  Key? _detailKey;
  final _workspace = GlobalKey<CollectionWorkspaceState>();
  bool _filterOpen = false;
  bool _visible = false;
  bool _masterVisible = true;
  final _center = GlobalKey();
  int _centerIndex = 0;

  @override
  void initState() {
    super.initState();
    controller = ConnectionController(widget.app)..addListener(_changed);
    _searchText.addListener(_searchChanged);
  }

  void _searchChanged() {
    final query = _searchText.text.trim().toLowerCase();
    if (_query == query) return;
    _query = query;
    _resetFilterPosition();
  }

  void _enterSearch() {
    if (!widget.active) return;
    _workspace.currentState?.showMaster();
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          widget.active &&
          widget.app.interactive &&
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
    final visible =
        widget.active && (ModalRoute.of(context)?.isCurrent ?? true);
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
    if (!mounted || !_masterVisible) return;
    final contentKey = (
      controller.data,
      controller.loading,
      _filter,
      _activeFilter,
      _query,
    );
    final status = controller.status;
    final sameStatus = status == _lastStatus;
    _lastStatus = status;
    if (_contentKey == contentKey && sameStatus) return;
    _contentKey = contentKey;
    final rows = _records();
    if (sameStatus &&
        rows.length == _rows.length &&
        rows.indexed.every(
          (entry) => _sameRowLayout(_rows[entry.$1], entry.$2),
        )) {
      setState(() => _rows = rows);
      return;
    }
    final ids = rows.map((row) => row.id).toSet();
    String? anchor;
    double offset = 0;
    final viewport = _viewport.currentContext?.findRenderObject() as RenderBox?;
    final top = viewport?.localToGlobal(Offset.zero).dy;
    if (_scroll.hasClients && top != null) {
      for (final row in _rows) {
        final box =
            _keys[row.id]?.currentContext?.findRenderObject() as RenderBox?;
        if (ids.contains(row.id) &&
            box != null &&
            box.hasSize &&
            box.localToGlobal(Offset.zero).dy + box.size.height > top) {
          anchor = row.id;
          offset = top - box.localToGlobal(Offset.zero).dy;
          break;
        }
      }
    }
    // A center sliver preserves the visible row through changes to preceding unbuilt
    // rows.
    setState(() {
      _rows = rows;
      _centerIndex = anchor == null
          ? 0
          : rows.indexWhere((row) => row.id == anchor);
      _keys.removeWhere((id, _) => !ids.contains(id));
      _indices.clear();
      for (var i = 0; i < rows.length; i++) {
        final key = _keys[rows[i].id];
        if (key != null) _indices[key] = i;
      }
      if (_scroll.hasClients) {
        _scroll.position.correctBy(offset - _scroll.offset);
      }
    });
  }

  // Status and counters have stable slots; only identity and text can reflow.
  bool _sameRowLayout(ConnectionRecord a, ConnectionRecord b) =>
      a.id == b.id &&
      a.start == b.start &&
      a.target == b.target &&
      a.path == b.path &&
      a.network == b.network;

  void _openDetail(ConnectionRecord record) {
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
    return ChoiceMenuButton<int>(
      identity: (
        widget.app.storageEpoch,
        widget.app.state.core.generation,
        widget.app.state.core.composition,
      ),
      value: current,
      options: {for (final (index, label) in labels.indexed) index: label},
      onOpened: () {
        _searchFocus.unfocus();
        _filterOpen = true;
      },
      onClosed: () => _filterOpen = false,
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
        if (selected == current) return;
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
    _centerIndex = 0;
    if (_scroll.hasClients) _scroll.position.correctBy(-_scroll.offset);
  }

  @override
  Widget build(BuildContext context) => TaskShortcuts(
    enabled: widget.active && !_filterOpen,
    onSearch: _enterSearch,
    onEscape: _detailOpen || _searching
        ? () {
            if (_workspace.currentState?.showingDetail == true) {
              _closeDetail();
            } else if (_searching) {
              _exitSearch();
            }
          }
        : null,
    child: _content(context),
  );

  Widget _content(BuildContext context) {
    _syncVisibility();
    final strings = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final status = controller.status;
    final notice = switch (status) {
      ConnectionViewStatus.active =>
        controller.data?.limited == true ? strings.recordLimitReached : '',
      ConnectionViewStatus.updating => strings.connectionUpdating,
      ConnectionViewStatus.failed => strings.connectionRefreshFailed,
      ConnectionViewStatus.stopped => strings.takeoverStopped,
      _ => strings.statusUnconfirmed,
    };
    final palette = ConnectionPalette(
      Theme.of(context).brightness == Brightness.dark,
    );
    final noticeIcon = switch (status) {
      ConnectionViewStatus.failed => Icons.error_outline_rounded,
      ConnectionViewStatus.updating => Icons.sync_rounded,
      ConnectionViewStatus.stopped => Icons.stop_circle_outlined,
      ConnectionViewStatus.active => Icons.info_outline_rounded,
      _ => Icons.help_outline_rounded,
    };
    final noticeColor = switch (status) {
      ConnectionViewStatus.failed ||
      ConnectionViewStatus.unknown => palette.warning,
      _ => colors.onSurfaceVariant,
    };
    final filterLabel = _filter == null
        ? strings.allRules
        : [_filter!.$1, _filter!.$2].where((s) => s.isNotEmpty).join(' · ');
    final detailOpen = _detailOpen;
    final selected = controller.detail;
    return CollectionWorkspace(
      key: _workspace,
      active: widget.active,
      onMasterVisibilityChanged: (visible) {
        _masterVisible = visible;
        if (visible) _changed();
      },
      onClose: _closeDetail,
      detail: detailOpen && selected != null
          ? _ConnectionDetail(
              key: _detailKey,
              controller: controller,
              active: widget.active,
              onClose: _closeDetail,
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
            actions: const [CollectionDetailsAction(), SizedBox(width: 8)],
          ),
          body: Column(
            children: [
              Padding(
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
                            Tooltip(
                              message: _rows.isEmpty ? '' : notice,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox.square(
                                    dimension: 18,
                                    child: _rows.isNotEmpty && notice.isNotEmpty
                                        ? Icon(
                                            noticeIcon,
                                            size: 16,
                                            color: noticeColor,
                                          )
                                        : null,
                                  ),
                                  const SizedBox(width: 4),
                                  const Icon(
                                    Icons.expand_more_rounded,
                                    size: 18,
                                  ),
                                ],
                              ),
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
                              const Icon(Icons.expand_more_rounded, size: 18),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: _rows.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              controller.loading
                                  ? strings.connectionUpdating
                                  : switch (status) {
                                      ConnectionViewStatus.updating =>
                                        strings.connectionUpdating,
                                      ConnectionViewStatus.unknown =>
                                        strings.statusUnconfirmed,
                                      ConnectionViewStatus.failed =>
                                        strings.connectionRefreshRetrying,
                                      _ =>
                                        _query.isNotEmpty ||
                                                _filter != null ||
                                                _activeFilter != null
                                            ? strings.noMatchingConnections
                                            : controller.app.state.phase ==
                                                  'STOPPED'
                                            ? strings.noRecentConnections
                                            : strings.noConnections,
                                    },
                              textAlign: TextAlign.center,
                              style: TextStyle(color: colors.onSurfaceVariant),
                            ),
                          ),
                        )
                      : Material(
                          color: colors.surface,
                          borderRadius: BorderRadius.circular(16),
                          clipBehavior: Clip.antiAlias,
                          child: CustomScrollView(
                            key: _viewport,
                            controller: _scroll,
                            center: _center,
                            semanticChildCount: _rows.length,
                            slivers: [
                              SliverList(delegate: _rowsDelegate(before: true)),
                              SliverList(
                                key: _center,
                                delegate: _rowsDelegate(before: false),
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
    );
  }

  SliverChildBuilderDelegate _rowsDelegate({required bool before}) {
    final count = before ? _centerIndex : _rows.length - _centerIndex;
    return SliverChildBuilderDelegate(
      (context, local) {
        final index = before ? _centerIndex - local - 1 : _centerIndex + local;
        final row = _rows[index];
        final key = _keys.putIfAbsent(row.id, GlobalKey.new);
        _indices[key] = index;
        return Stack(
          key: key,
          children: [
            _row(row),
            if (index < _rows.length - 1)
              Positioned(
                left: 14,
                right: 14,
                bottom: 0,
                height: 1,
                child: ColoredBox(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
          ],
        );
      },
      childCount: count,
      semanticIndexCallback: (_, local) =>
          before ? _centerIndex - local - 1 : _centerIndex + local,
      findChildIndexCallback: (key) {
        final index = _indices[key];
        if (index == null) return null;
        final local = before ? _centerIndex - index - 1 : index - _centerIndex;
        return local < 0 || local >= count ? null : local;
      },
    );
  }

  Widget _row(ConnectionRecord row) {
    final strings = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final confirmed =
        controller.current &&
        controller.data?.matches(controller.app.state.core) == true;
    final palette = ConnectionPalette(
      Theme.of(context).brightness == Brightness.dark,
    );
    final state = row.active
        ? confirmed
              ? strings.connectionActive
              : strings.connectionPending
        : strings.connectionInactive;
    final stateColor = row.active
        ? confirmed
              ? palette.active
              : palette.warning
        : colors.onSurfaceVariant;
    final selected =
        _detailOpen &&
        controller.detail?.id == row.id &&
        controller.detailStatus != ConnectionViewStatus.replaced;
    return Semantics(
      button: true,
      selected: selected,
      child: DecoratedBox(
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
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
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
                  style: TextStyle(
                    fontSize: 13,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final size = MediaQuery.textScalerOf(context).scale(12);
                    final badge = Container(
                      key: ValueKey('connection-state-${row.id}'),
                      width: size * 4.8 + 12,
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: stateColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        state,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: stateColor,
                        ),
                      ),
                    );
                    Widget metric(String value, Color color) =>
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Text(
                            value,
                            softWrap: false,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: color,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
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
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: metric(
                            '↑ ${_bytes(row.upload)}',
                            palette.upload,
                          ),
                        ),
                      ],
                    );
                    // Choose structure from available workspace.
                    if (constraints.maxWidth < size * 25 + 32) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
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
