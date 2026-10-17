import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/app_theme.dart';
import '../../app/widgets/operation_feedback.dart';
import '../strategies/strategy_icon.dart';
import 'connection_controller.dart';
import 'connection_snapshot.dart';

class ConnectionsPage extends StatefulWidget {
  const ConnectionsPage({super.key, required this.app});
  final AppController app;

  @override
  State<ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends State<ConnectionsPage> {
  late final ConnectionController controller;
  final _scroll = ScrollController();
  final _viewport = GlobalKey();
  final _filterButton = GlobalKey();
  final _filterFocus = FocusNode();
  final _lifecycleButton = GlobalKey();
  final _lifecycleFocus = FocusNode();
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
  bool _filterOpen = false;
  bool _visible = false;
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
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _searching && !_detailOpen && !_filterOpen) {
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

  void _syncVisibility() {
    final visible =
        !_filterOpen &&
        (_detailOpen || (ModalRoute.of(context)?.isCurrent ?? true));
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
    if (!mounted || _detailOpen) return;
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
    // A center sliver keeps the visible row fixed without estimating the
    // heights of unbuilt rows inserted or removed before it.
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

  Future<void> _openDetail(ConnectionRecord record) async {
    _searchFocus.unfocus();
    _detailOpen = true;
    controller.openDetail(record);
    final route = MaterialPageRoute<void>(
      builder: (_) => _ConnectionDetail(controller: controller),
    );
    await Navigator.of(context).push<void>(route);
    await route.completed;
    if (!mounted) return;
    _detailOpen = false;
    controller.closeDetail();
    _changed();
    _visible = false;
    _syncVisibility();
  }

  Future<void> _chooseFilter({bool lifecycle = false}) async {
    if (_filterOpen) return;
    _searchFocus.unfocus();
    final rules = <(String, String), String>{
      for (final row in controller.data?.records ?? <ConnectionRecord>[])
        row.ruleKey: row.ruleLabel,
      ?_filter: _filter == null || _filter!.$1.isEmpty
          ? '未提供'
          : [_filter!.$1, _filter!.$2].where((s) => s.isNotEmpty).join(' · '),
    };
    final options = <((String, String)?, String)>[
      (null, '全部规则'),
      for (final entry in rules.entries) (entry.key, entry.value),
    ];
    final labels = lifecycle
        ? const ['全部连接', '活跃中', '不活跃']
        : options.map((option) => option.$2).toList();
    final current = lifecycle
        ? (_activeFilter == null ? 0 : (_activeFilter! ? 1 : 2))
        : options.indexWhere((option) => option.$1 == _filter);
    final anchor = lifecycle ? _lifecycleButton : _filterButton;
    final focus = lifecycle ? _lifecycleFocus : _filterFocus;
    final colors = Theme.of(context).colorScheme;
    final palette = ConnectionPalette(
      Theme.of(context).brightness == Brightness.dark,
    );
    _filterOpen = true;
    controller.setVisible(false);
    try {
      final selected = await showMenu<int>(
        context: context,
        requestFocus: true,
        popUpAnimationStyle: MediaQuery.disableAnimationsOf(context)
            ? AnimationStyle.noAnimation
            : const AnimationStyle(
                duration: Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                reverseCurve: Curves.easeInCubic,
              ),
        positionBuilder: (context, constraints) {
          final overlay =
              Navigator.of(context).overlay!.context.findRenderObject()!
                  as RenderBox;
          final button =
              anchor.currentContext?.findRenderObject() as RenderBox?;
          final origin =
              button?.localToGlobal(Offset.zero, ancestor: overlay) ??
              const Offset(16, 80);
          return RelativeRect.fromRect(
            Rect.fromLTWH(
              origin.dx,
              origin.dy + (button?.size.height ?? 0),
              button?.size.width ?? 200,
              0,
            ),
            Offset.zero & overlay.size,
          );
        },
        constraints: BoxConstraints(
          maxWidth: (MediaQuery.sizeOf(context).width - 32).clamp(200, 420),
        ),
        items: [
          for (var i = 0; i < labels.length; i++)
            PopupMenuItem<int>(
              value: i,
              child: Semantics(
                selected: current == i,
                child: Row(
                  children: [
                    if (lifecycle) ...[
                      Icon(
                        switch (i) {
                          1 => Icons.link_rounded,
                          2 => Icons.link_off_rounded,
                          _ => Icons.list_rounded,
                        },
                        size: 20,
                        color: i == 1
                            ? palette.active
                            : colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(child: Text(labels[i])),
                    const SizedBox(width: 12),
                    SizedBox.square(
                      dimension: 20,
                      child: current == i
                          ? Icon(
                              Icons.check_rounded,
                              size: 20,
                              color: colors.primary,
                            )
                          : null,
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
      if (mounted && selected != null && selected != current) {
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
      }
    } finally {
      if (mounted) {
        _filterOpen = false;
        _visible = false;
        _syncVisibility();
        if (ModalRoute.of(context)?.isCurrent == true) {
          focus.requestFocus();
        }
      }
    }
  }

  void _resetFilterPosition() {
    _changed();
    _centerIndex = 0;
    if (_scroll.hasClients) _scroll.position.correctBy(-_scroll.offset);
  }

  @override
  Widget build(BuildContext context) {
    _syncVisibility();
    final colors = Theme.of(context).colorScheme;
    final status = controller.status;
    final notice = switch (status) {
      ConnectionViewStatus.active =>
        controller.data?.limited == true ? '记录达上限' : '',
      ConnectionViewStatus.updating => '正在更新',
      ConnectionViewStatus.failed => '刷新失败',
      ConnectionViewStatus.stopped => '接管已停止',
      _ => '状态未确认',
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
        ? '全部规则'
        : [_filter!.$1, _filter!.$2].where((s) => s.isNotEmpty).join(' · ');
    return PopScope<void>(
      canPop: !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !_searching) return;
        if (MediaQuery.viewInsetsOf(context).bottom > 0) {
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
                      IconButton(
                        tooltip: '退出搜索',
                        onPressed: _exitSearch,
                        icon: const Icon(Icons.arrow_back),
                      ),
                      Expanded(
                        child: SearchBar(
                          controller: _searchText,
                          focusNode: _searchFocus,
                          leading: const Icon(Icons.search, size: 20),
                          trailing: [
                            ValueListenableBuilder<TextEditingValue>(
                              valueListenable: _searchText,
                              builder: (context, value, _) => IconButton(
                                tooltip: '清除搜索',
                                onPressed: value.text.isEmpty
                                    ? null
                                    : () {
                                        _searchText.clear();
                                        _searchFocus.requestFocus();
                                      },
                                icon: const Icon(Icons.close_rounded),
                              ),
                            ),
                          ],
                          hintText: '搜索连接',
                          constraints: const BoxConstraints(
                            minHeight: 48,
                            maxHeight: 48,
                          ),
                          elevation: const WidgetStatePropertyAll(0),
                          backgroundColor: WidgetStatePropertyAll(
                            colors.surfaceContainer,
                          ),
                          surfaceTintColor: const WidgetStatePropertyAll(
                            Colors.transparent,
                          ),
                          shape: WidgetStatePropertyAll(
                            RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          padding: const WidgetStatePropertyAll(
                            EdgeInsets.symmetric(horizontal: 12),
                          ),
                          textStyle: WidgetStatePropertyAll(
                            TextStyle(fontSize: 16, color: colors.onSurface),
                          ),
                          hintStyle: WidgetStatePropertyAll(
                            TextStyle(
                              fontSize: 16,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : Row(
                    key: const ValueKey('connection-title'),
                    children: [
                      const BackButton(),
                      const Expanded(child: Text('最近连接')),
                      IconButton(
                        tooltip: '搜索连接',
                        onPressed: _enterSearch,
                        icon: const Icon(Icons.search),
                      ),
                    ],
                  ),
          ),
          actions: const [SizedBox(width: 8)],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      key: _lifecycleButton,
                      focusNode: _lifecycleFocus,
                      onPressed: () => _chooseFilter(lifecycle: true),
                      style: TextButton.styleFrom(
                        foregroundColor: colors.onSurface,
                        minimumSize: const Size(48, 48),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _activeFilter == null
                                  ? '全部连接'
                                  : (_activeFilter! ? '活跃中' : '不活跃'),
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
                                const Icon(Icons.expand_more_rounded, size: 18),
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
                      message: '筛选命中规则',
                      child: TextButton(
                        key: _filterButton,
                        focusNode: _filterFocus,
                        onPressed: _chooseFilter,
                        style: TextButton.styleFrom(
                          foregroundColor: colors.onSurface,
                          minimumSize: const Size(48, 48),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                filterLabel.isEmpty ? '未提供' : filterLabel,
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
                                ? '正在更新'
                                : switch (status) {
                                    ConnectionViewStatus.updating => '正在更新',
                                    ConnectionViewStatus.unknown => '状态未确认',
                                    ConnectionViewStatus.failed => '刷新失败，正在重试',
                                    _ =>
                                      _query.isNotEmpty ||
                                              _filter != null ||
                                              _activeFilter != null
                                          ? '没有匹配的连接'
                                          : controller.app.state.phase ==
                                                'STOPPED'
                                          ? '暂无近期连接'
                                          : '暂无连接',
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
    final colors = Theme.of(context).colorScheme;
    final confirmed =
        controller.current &&
        controller.data?.matches(controller.app.state.core) == true;
    final palette = ConnectionPalette(
      Theme.of(context).brightness == Brightness.dark,
    );
    final state = row.active
        ? confirmed
              ? '活跃'
              : '待确认'
        : '已不活跃';
    final stateColor = row.active
        ? confirmed
              ? palette.active
              : palette.warning
        : colors.onSurfaceVariant;
    return Semantics(
      button: true,
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
                    color: colors.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                row.chains.isEmpty ? '—' : row.path,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
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
                            fontFeatures: const [FontFeature.tabularFigures()],
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
                  // Choose the structure from available space, never from
                  // changing state labels or traffic magnitudes.
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
                        child: SizedBox(width: size * 13 + 10, child: traffic),
                      ),
                    ],
                  );
                },
              ),
            ],
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
    _filterFocus.dispose();
    _lifecycleFocus.dispose();
    _searchText.removeListener(_searchChanged);
    _searchText.dispose();
    _searchFocus.dispose();
    super.dispose();
  }
}

class _ConnectionDetail extends StatefulWidget {
  const _ConnectionDetail({required this.controller});
  final ConnectionController controller;
  @override
  State<_ConnectionDetail> createState() => _ConnectionDetailState();
}

class _ConnectionDetailState extends State<_ConnectionDetail> {
  bool? _visible;
  String? _shownError;
  final _infoFields = <String>[];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_resultChanged);
  }

  void _resultChanged() {
    final message = widget.controller.closeMessage;
    if (message == _shownError) return;
    _shownError = message;
    if (message == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        showOperationMessage(context, message, title: '断开连接未完成');
      }
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_resultChanged);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = ModalRoute.of(context)?.isCurrent ?? true;
    if (_visible == visible) return;
    _visible = visible;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.setVisible(_visible!);
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final record = controller.detail!;
      final colors = Theme.of(context).colorScheme;
      final palette = ConnectionPalette(
        Theme.of(context).brightness == Brightness.dark,
      );
      final at = controller.detailAt;
      final duration = at != null && record.start != null
          ? at.difference(record.start!)
          : null;
      final source = ConnectionRecord.endpoint(
        record.sourceIP,
        record.sourcePort,
      );
      final info = {
        if (record.host.isNotEmpty && record.destinationIP.isNotEmpty)
          '目标 IP': record.destinationIP,
        if (record.sourceIP.isNotEmpty) '源地址': source,
        if (record.type.isNotEmpty) '入站': record.type,
      };
      for (final name in info.keys) {
        if (!_infoFields.contains(name)) _infoFields.add(name);
      }
      return Scaffold(
        appBar: AppBar(
          title: const Text('连接详情'),
          actions: [
            IconButton(
              onPressed: controller.canClose ? controller.disconnect : null,
              tooltip: controller.closing ? '正在断开' : '断开连接',
              color: colors.error,
              icon: controller.closing
                  ? SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.error,
                      ),
                    )
                  : const Icon(Icons.link_off_rounded),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: SingleChildScrollView(
          key: const ValueKey('connection-detail-scroll'),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DetailValue(
                      record.target,
                      style: const TextStyle(
                        fontSize: 24,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final fontSize = MediaQuery.textScalerOf(context)
                            .scale(13);
                        final stacked = constraints.maxWidth < fontSize * 25;
                        final status = InkWell(
                          onTap: () => showOperationMessage(
                            context,
                            [
                              if (controller.closeMessage != null)
                                controller.closeMessage!,
                              if (controller.error != null) controller.error!,
                              if (record.fieldsTruncated) '部分长字段已截短',
                              '最后观察：${_time(controller.detailAt)}',
                            ].join('\n\n'),
                            title: '连接状态',
                            error:
                                controller.closeMessage != null ||
                                controller.error != null,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _StatusLabel(
                                key: const ValueKey('connection-detail-status'),
                                status: controller.detailStatus,
                                trailing: true,
                              ),
                              SizedBox.square(
                                dimension: 18,
                                child: record.fieldsTruncated
                                    ? const Tooltip(
                                        message: '部分长字段已截短',
                                        child: Icon(
                                          Icons.info_outline,
                                          size: 16,
                                        ),
                                      )
                                    : null,
                              ),
                            ],
                          ),
                        );
                        final metadata = SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              if (record.network.isNotEmpty)
                                _ProtocolLabel(record.network),
                              if (record.host.isNotEmpty &&
                                  record.destinationPort.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(left: 8),
                                  child: Text(
                                    '端口 ${record.destinationPort}',
                                    softWrap: false,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                        final lineHeight = fontSize * 2 + 4;
                        if (stacked) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(
                                height: lineHeight,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: metadata,
                                ),
                              ),
                              SizedBox(
                                height: lineHeight,
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: status,
                                ),
                              ),
                            ],
                          );
                        }
                        return SizedBox(
                          height: lineHeight,
                          child: Row(
                            children: [
                              Expanded(child: metadata),
                              const SizedBox(width: 12),
                              status,
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              _section('分流结果'),
              _Group(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height:
                              (MediaQuery.textScalerOf(context).scale(16) * 1.4)
                                  .ceilToDouble()
                                  .clamp(32, double.infinity) +
                              4,
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: colors.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: StrategyIcon(
                                type: record.strategyType,
                                source: record.strategyIcon,
                                size: 20,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _DetailValue(
                            record.path.isEmpty ? '—' : record.path,
                            minHeight: 36,
                            style: const TextStyle(
                              fontSize: 16,
                              height: 1.4,
                              leadingDistribution: TextLeadingDistribution.even,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _field(
                    '命中规则',
                    record.rule.isEmpty ? '—' : record.ruleLabel,
                    stacked: true,
                  ),
                ],
              ),
              _section('流量'),
              _Group(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final values = [
                          _TrafficValue(
                            label: '下载',
                            value: record.download,
                            speed: controller.detailActive
                                ? record.downloadSpeed
                                : null,
                            color: palette.download,
                            icon: Icons.south_west_rounded,
                          ),
                          _TrafficValue(
                            label: '上传',
                            value: record.upload,
                            speed: controller.detailActive
                                ? record.uploadSpeed
                                : null,
                            color: palette.upload,
                            icon: Icons.north_east_rounded,
                          ),
                        ];
                        if (constraints.maxWidth < 240 ||
                            MediaQuery.textScalerOf(context).scale(14) > 20) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              values[0],
                              const SizedBox(height: 20),
                              values[1],
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: values[0]),
                            const SizedBox(width: 16),
                            Expanded(child: values[1]),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
              _section('时间'),
              _Group(
                children: [
                  _field('开始时间', _time(record.start)),
                  _field(
                    '持续时长',
                    duration != null && !duration.isNegative
                        ? _duration(duration)
                        : '—',
                    color: controller.detailActive
                        ? palette.active
                        : colors.onSurfaceVariant,
                  ),
                ],
              ),
              if (_infoFields.isNotEmpty) ...[
                _section('连接信息'),
                _Group(
                  children: [
                    for (final name in _infoFields)
                      KeyedSubtree(
                        key: ValueKey(name),
                        child: _field(name, info[name] ?? '未提供'),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      );
    },
  );

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
    child: Text(
      title,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _field(
    String name,
    String value, {
    bool stacked = false,
    Color? color,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final label = Text(
          name,
          style: TextStyle(
            fontSize: 13,
            height: 1.4,
            leadingDistribution: TextLeadingDistribution.even,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
        final data = _DetailValue(
          value,
          style: TextStyle(
            fontSize: 14,
            height: 1.4,
            leadingDistribution: TextLeadingDistribution.even,
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        );
        if (stacked ||
            constraints.maxWidth < 260 ||
            MediaQuery.textScalerOf(context).scale(14) > 20) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [label, const SizedBox(height: 5), data],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            label,
            const SizedBox(width: 16),
            Expanded(
              child: Align(alignment: Alignment.centerRight, child: data),
            ),
          ],
        );
      },
    ),
  );
}

// Size to the first visible value, not to subsequent network updates. Longer
// replacements remain selectable and scrollable without moving the next field.
class _DetailValue extends StatefulWidget {
  const _DetailValue(this.text, {required this.style, this.minHeight = 0});
  final String text;
  final TextStyle style;
  final double minHeight;

  @override
  State<_DetailValue> createState() => _DetailValueState();
}

class _DetailValueState extends State<_DetailValue> {
  final _scroll = ScrollController();
  (double, double)? _geometry;
  double? _height;
  bool _singleLine = true;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scaler = MediaQuery.textScalerOf(context);
      final style = DefaultTextStyle.of(context).style.merge(widget.style);
      final geometry = (
        constraints.maxWidth,
        scaler.scale(style.fontSize ?? 14),
      );
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: style),
        textDirection: Directionality.of(context),
        textScaler: scaler,
      )..layout(maxWidth: constraints.maxWidth);
      if (_geometry != geometry) {
        _geometry = geometry;
        _height = (painter.height.clamp(geometry.$2, geometry.$2 * 6) + 4)
            .clamp(widget.minHeight, double.infinity);
        _singleLine = painter.computeLineMetrics().length <= 1;
      }
      final overflow = painter.height + 4 > _height!;
      painter.dispose();
      return SizedBox(
        height: _height,
        child: Scrollbar(
          controller: _scroll,
          thumbVisibility: overflow,
          child: SingleChildScrollView(
            controller: _scroll,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: _height! - 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: _singleLine
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [SelectableText(widget.text, style: style)],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0)
            Divider(
              height: 1,
              indent: 16,
              endIndent: 16,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          children[i],
        ],
      ],
    ),
  );
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({super.key, required this.status, this.trailing = false});
  final ConnectionViewStatus status;
  final bool trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = ConnectionPalette(
      Theme.of(context).brightness == Brightness.dark,
    );
    final (label, icon, color) = switch (status) {
      ConnectionViewStatus.active => ('活跃', Icons.circle, palette.active),
      ConnectionViewStatus.updating => (
        '正在更新',
        Icons.sync_rounded,
        colors.onSurfaceVariant,
      ),
      ConnectionViewStatus.failed => (
        '刷新失败',
        Icons.error_outline_rounded,
        palette.warning,
      ),
      ConnectionViewStatus.closed => (
        '已断开',
        Icons.link_off_rounded,
        colors.onSurfaceVariant,
      ),
      ConnectionViewStatus.inactive => (
        '已不活跃',
        Icons.circle_outlined,
        colors.onSurfaceVariant,
      ),
      ConnectionViewStatus.stopped => (
        '接管已停止',
        Icons.stop_circle_outlined,
        colors.onSurfaceVariant,
      ),
      ConnectionViewStatus.unknown => (
        '状态未确认',
        Icons.help_outline_rounded,
        palette.warning,
      ),
      ConnectionViewStatus.replaced => (
        '会话已切换',
        Icons.swap_horiz_rounded,
        colors.onSurfaceVariant,
      ),
    };
    return SizedBox(
      width: 20 + MediaQuery.textScalerOf(context).scale(13) * 5,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: trailing,
        child: Row(
          children: [
            SizedBox.square(
              dimension: 15,
              child: Icon(
                icon,
                size: status == ConnectionViewStatus.active ? 8 : 15,
                color: color,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              softWrap: false,
              style: TextStyle(
                fontSize: 13,
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProtocolLabel extends StatelessWidget {
  const _ProtocolLabel(this.network);
  final String network;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        network.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _TrafficValue extends StatelessWidget {
  const _TrafficValue({
    required this.label,
    required this.value,
    required this.speed,
    required this.color,
    required this.icon,
  });
  final String label;
  final int? value;
  final double? speed;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final parts = (speed == null ? '—' : '${_bytes(speed!.round())}/s').split(
      ' ',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(icon, color: color, size: 16),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: parts.first,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
                if (parts.length > 1)
                  TextSpan(
                    text: ' ${parts.last}',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            softWrap: false,
            style: const TextStyle(
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(height: 5),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text(
            '累计 ${_bytes(value)}',
            softWrap: false,
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

String _duration(Duration value) {
  if (value.inHours > 0) return '${value.inHours} 小时 ${value.inMinutes % 60} 分';
  if (value.inMinutes > 0) {
    return '${value.inMinutes} 分 ${value.inSeconds % 60} 秒';
  }
  return '${value.inSeconds} 秒';
}

String _time(DateTime? value) => value == null
    ? '—'
    : '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}:${value.second.toString().padLeft(2, '0')}';
String _bytes(int? value) {
  if (value == null) return '—';
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KiB';
  if (value < 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
}
