import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/app_theme.dart';
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
  }

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
    final rows = (controller.displayed?.records ?? const <ConnectionRecord>[])
        .where(
          (row) =>
              (_filter == null || row.ruleKey == _filter) &&
              (_activeFilter == null || row.active == _activeFilter),
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
      controller.displayed,
      controller.paused,
      controller.loading,
      _filter,
      _activeFilter,
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
    if (_scroll.hasClients &&
        _scroll.offset > _scroll.position.minScrollExtent + .5 &&
        top != null) {
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

  // Digits are tabular; unit or digit-count changes can still reflow the Wrap.
  bool _sameRowLayout(ConnectionRecord a, ConnectionRecord b) {
    (int, String) counter(int? value) {
      final text = _bytes(value);
      return (text.length, text.split(' ').last);
    }

    return a.id == b.id &&
        a.start == b.start &&
        a.active == b.active &&
        a.target == b.target &&
        a.path == b.path &&
        a.network == b.network &&
        counter(a.upload) == counter(b.upload) &&
        counter(a.download) == counter(b.download);
  }

  Future<void> _openDetail(ConnectionRecord record) async {
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

  Future<void> _chooseFilter() async {
    if (_filterOpen) return;
    final rules = <(String, String), String>{
      for (final row in controller.displayed?.records ?? <ConnectionRecord>[])
        row.ruleKey: row.ruleLabel,
      ?_filter: _filter == null || _filter!.$1.isEmpty
          ? '未提供'
          : [_filter!.$1, _filter!.$2].where((s) => s.isNotEmpty).join(' · '),
    };
    final options = <((String, String)?, String)>[
      (null, '全部规则'),
      for (final entry in rules.entries) (entry.key, entry.value),
    ];
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
              _filterButton.currentContext?.findRenderObject() as RenderBox?;
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
          for (var i = 0; i < options.length; i++)
            PopupMenuItem<int>(
              value: i,
              child: Semantics(
                selected: _filter == options[i].$1,
                child: Row(
                  children: [
                    Expanded(child: Text(options[i].$2)),
                    if (_filter == options[i].$1)
                      const Padding(
                        padding: EdgeInsets.only(left: 12),
                        child: Icon(Icons.check_rounded, size: 20),
                      ),
                  ],
                ),
              ),
            ),
        ],
      );
      if (mounted && selected != null && _filter != options[selected].$1) {
        _filter = options[selected].$1;
        _resetFilterPosition();
      }
    } finally {
      if (mounted) {
        _filterOpen = false;
        _visible = false;
        _syncVisibility();
        if (ModalRoute.of(context)?.isCurrent == true) {
          _filterFocus.requestFocus();
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
    final filterLabel = _filter == null
        ? '全部规则'
        : [_filter!.$1, _filter!.$2].where((s) => s.isNotEmpty).join(' · ');
    return Scaffold(
      appBar: AppBar(
        title: const Text('连接'),
        actions: [
          IconButton(
            onPressed: controller.togglePaused,
            tooltip: controller.paused ? '继续刷新' : '暂停刷新',
            color: controller.paused ? colors.primary : colors.onSurface,
            icon: Icon(
              controller.paused
                  ? Icons.play_arrow_rounded
                  : Icons.pause_rounded,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final option in <(bool?, String)>[
                    (null, '全部'),
                    (true, '活跃'),
                    (false, '不活跃'),
                  ])
                    ChoiceChip(
                      label: Text(option.$2),
                      selected: _activeFilter == option.$1,
                      showCheckmark: false,
                      onSelected: (_) {
                        if (_activeFilter == option.$1) return;
                        _activeFilter = option.$1;
                        _resetFilterPosition();
                      },
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Tooltip(
                      message: '筛选命中规则',
                      child: TextButton.icon(
                        key: _filterButton,
                        focusNode: _filterFocus,
                        onPressed: _chooseFilter,
                        style: TextButton.styleFrom(
                          foregroundColor: _filter == null
                              ? colors.onSurfaceVariant
                              : colors.primary,
                          backgroundColor: _filter == null
                              ? colors.surfaceContainerHighest
                              : colors.primaryContainer,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: const Icon(Icons.filter_list_rounded, size: 18),
                        label: Text(
                          filterLabel.isEmpty ? '无规则信息' : filterLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ),
                if (_filter != null)
                  IconButton(
                    tooltip: '清除筛选',
                    onPressed: () {
                      _filter = null;
                      _resetFilterPosition();
                    },
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
              ],
            ),
          ),
          if (_rows.isNotEmpty && status != ConnectionViewStatus.active)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Row(
                children: [
                  Expanded(child: _StatusLabel(status: status)),
                  if (controller.displayedAt != null)
                    Text(
                      _time(controller.displayedAt),
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          if (controller.loading) const LinearProgressIndicator(minHeight: 2),
          if (controller.displayed?.limited == true)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '展示最近 1,000 条活跃连接',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
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
                                  ConnectionViewStatus.unknown => '状态未确认',
                                  ConnectionViewStatus.failed => '更新失败，正在重试',
                                  _ =>
                                    _filter != null || _activeFilter != null
                                        ? '没有匹配的连接'
                                        : controller.paused
                                        ? '刷新已暂停 · 暂无连接'
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
        return Column(
          key: key,
          children: [
            if (index > 0)
              Divider(
                height: 1,
                indent: 14,
                endIndent: 14,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            _row(row),
          ],
        );
      },
      childCount: count,
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
    final palette = ConnectionPalette(
      Theme.of(context).brightness == Brightness.dark,
    );
    return Semantics(
      button: true,
      child: InkWell(
        onTap: () => _openDetail(row),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      row.target,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      row.chains.isEmpty ? '—' : row.path,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 10,
                      runSpacing: 5,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (!row.active)
                          Text(
                            '已不活跃',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        if (row.network.isNotEmpty) _ProtocolLabel(row.network),
                        Text(
                          _time(row.start),
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        Text(
                          '↓ ${_bytes(row.download)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: palette.download,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        Text(
                          '↑ ${_bytes(row.upload)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: palette.upload,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ],
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
      return Scaffold(
        appBar: AppBar(
          title: const Text('连接详情'),
          actions: [
            IconButton(
              onPressed: controller.canClose ? controller.disconnect : null,
              tooltip: controller.closing ? '正在断开' : '断开连接',
              icon: controller.closing
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.link_off_rounded),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      record.target,
                      style: const TextStyle(
                        fontSize: 24,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _StatusLabel(
                          key: const ValueKey('connection-detail-status'),
                          status: controller.detailStatus,
                        ),
                        if (record.network.isNotEmpty)
                          _ProtocolLabel(record.network),
                        if (record.host.isNotEmpty &&
                            record.destinationPort.isNotEmpty)
                          Text(
                            '端口 ${record.destinationPort}',
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (controller.closeMessage != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                  child: Text(
                    controller.closeMessage!,
                    style: TextStyle(color: palette.warning, fontSize: 13),
                  ),
                ),
              if (record.fieldsTruncated)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                  child: Text(
                    '部分长字段已截短',
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12,
                    ),
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
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.alt_route_rounded,
                            size: 20,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SelectableText(
                                record.chains.firstOrNull ?? '—',
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (record.chains.length > 1) ...[
                                const SizedBox(height: 4),
                                SelectableText(
                                  record.path,
                                  style: TextStyle(
                                    fontSize: 13,
                                    height: 1.4,
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ],
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
              if (record.destinationIP.isNotEmpty && record.host.isNotEmpty ||
                  record.sourceIP.isNotEmpty ||
                  record.type.isNotEmpty) ...[
                _section('连接信息'),
                _Group(
                  children: [
                    if (record.host.isNotEmpty &&
                        record.destinationIP.isNotEmpty)
                      _field('目标 IP', record.destinationIP),
                    if (record.sourceIP.isNotEmpty) _field('源地址', source),
                    if (record.type.isNotEmpty) _field('入站', record.type),
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
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
        final data = SelectableText(
          value,
          style: TextStyle(
            fontSize: 14,
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
          crossAxisAlignment: CrossAxisAlignment.start,
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
  const _StatusLabel({super.key, required this.status});
  final ConnectionViewStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = ConnectionPalette(
      Theme.of(context).brightness == Brightness.dark,
    );
    final (label, icon, color) = switch (status) {
      ConnectionViewStatus.active => ('活跃', Icons.circle, palette.active),
      ConnectionViewStatus.paused => (
        '刷新已暂停',
        Icons.pause_circle_outline,
        colors.primary,
      ),
      ConnectionViewStatus.updating => (
        '正在更新',
        Icons.sync_rounded,
        colors.onSurfaceVariant,
      ),
      ConnectionViewStatus.failed => (
        '更新失败',
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
    return Wrap(
      spacing: 5,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Icon(
          icon,
          size: status == ConnectionViewStatus.active ? 8 : 15,
          color: color,
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: color,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
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
        Text.rich(
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
          style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
        ),
        const SizedBox(height: 5),
        Text(
          '累计 ${_bytes(value)}',
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
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
