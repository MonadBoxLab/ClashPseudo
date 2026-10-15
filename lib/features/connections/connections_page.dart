import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
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
  final _keys = <String, GlobalKey>{};
  List<ConnectionRecord> _rows = [];
  (String, String)? _filter;
  bool _detailOpen = false;
  bool _filterOpen = false;
  bool _visible = false;
  int _layout = 0;

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
        .where((row) => _filter == null || row.ruleKey == _filter)
        .toList();
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
    final rows = _records();
    final ids = rows.map((row) => row.id).toSet();
    GlobalKey? anchor;
    double? before;
    final viewport = _viewport.currentContext?.findRenderObject() as RenderBox?;
    final top = viewport?.localToGlobal(Offset.zero).dy;
    if (_scroll.hasClients && _scroll.offset > 0 && top != null) {
      for (final row in _rows) {
        final key = _keys[row.id];
        final box = key?.currentContext?.findRenderObject() as RenderBox?;
        if (ids.contains(row.id) &&
            box != null &&
            box.hasSize &&
            box.localToGlobal(Offset.zero).dy + box.size.height > top) {
          anchor = key;
          before = box.localToGlobal(Offset.zero).dy;
          break;
        }
      }
    }
    final layout = ++_layout;
    setState(() {
      _rows = rows;
      _keys.removeWhere((id, _) => !ids.contains(id));
    });
    if (anchor != null && before != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || layout != _layout || !_scroll.hasClients) return;
        final box = anchor!.currentContext?.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) return;
        final delta = box.localToGlobal(Offset.zero).dy - before!;
        if (delta.abs() > .5) {
          _scroll.jumpTo(
            (_scroll.offset + delta).clamp(
              0.0,
              _scroll.position.maxScrollExtent,
            ),
          );
        }
      });
    }
  }

  Future<void> _openDetail(ConnectionRecord record) async {
    controller.openDetail(record);
    _detailOpen = true;
    final route = MaterialPageRoute<void>(
      builder: (_) => _ConnectionDetail(controller: controller),
    );
    await Navigator.of(context).push<void>(route);
    await route.completed;
    if (!mounted) return;
    _detailOpen = false;
    controller.closeDetail();
    _visible = false;
    _syncVisibility();
  }

  Future<void> _chooseFilter() async {
    final rules = <(String, String), String>{
      for (final row in controller.displayed?.records ?? <ConnectionRecord>[])
        row.ruleKey: row.ruleLabel,
      ?_filter: _filter == null || _filter!.$1.isEmpty
          ? '未提供'
          : [_filter!.$1, _filter!.$2].where((s) => s.isNotEmpty).join(' · '),
    };
    _filterOpen = true;
    controller.setVisible(false);
    await showDialog<void>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('命中规则'),
        children: [
          for (final entry in <(String, String)?, String>{
            null: '全部规则',
            ...rules,
          }.entries)
            ListTile(
              title: Text(entry.value),
              selected: _filter == entry.key,
              trailing: _filter == entry.key ? const Icon(Icons.check) : null,
              onTap: () {
                _filter = entry.key;
                Navigator.of(context).pop();
              },
            ),
        ],
      ),
    );
    if (!mounted) return;
    _filterOpen = false;
    _visible = false;
    _changed();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _syncVisibility();
  }

  @override
  Widget build(BuildContext context) {
    _syncVisibility();
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('连接'),
        actions: [
          IconButton(
            onPressed: _chooseFilter,
            tooltip: '筛选命中规则',
            icon: Icon(
              Icons.filter_list,
              color: _filter == null ? null : colors.primary,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: controller.togglePaused,
                  icon: Icon(
                    controller.paused ? Icons.play_arrow : Icons.pause,
                  ),
                  label: Text(controller.paused ? '继续刷新' : '暂停刷新'),
                ),
                if (_filter != null)
                  InputChip(
                    label: const Text('已筛选命中规则'),
                    onDeleted: () {
                      _filter = null;
                      _changed();
                    },
                  ),
              ],
            ),
          ),
          if (controller.notice != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(
                controller.notice!,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ),
          if (controller.loading) const LinearProgressIndicator(),
          Expanded(
            child: SingleChildScrollView(
              key: _viewport,
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_rows.isEmpty && !controller.loading)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      child: Text(
                        !controller.available
                            ? '接管运行后可查看活动连接'
                            : controller.error != null
                            ? '暂时无法获取连接'
                            : _filter != null
                            ? '没有符合条件的活动连接'
                            : controller.paused
                            ? '暂停时没有活动连接'
                            : '当前未观察到活动连接',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  if (_rows.isNotEmpty)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: colors.outlineVariant),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        children: [
                          for (var i = 0; i < _rows.length; i++) ...[
                            if (i > 0)
                              Divider(height: 1, color: colors.outlineVariant),
                            _row(_rows[i]),
                          ],
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  const _DataSource(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(ConnectionRecord row) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      child: InkWell(
        key: _keys.putIfAbsent(row.id, GlobalKey.new),
        onTap: () => _openDetail(row),
        child: Padding(
          padding: const EdgeInsets.all(14),
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
                      row.path,
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 10,
                      runSpacing: 4,
                      children: [
                        Text(
                          '${_time(row.start)} · ${row.network.isEmpty ? '协议未提供' : row.network.toUpperCase()}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        Text(
                          '↓ ${_bytes(row.download)}  ↑ ${_bytes(row.upload)}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, size: 18),
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
      final at = controller.detailAt;
      final duration = at != null && record.start != null
          ? at.difference(record.start!)
          : null;
      return Scaffold(
        appBar: AppBar(
          title: const Text('连接详情'),
          actions: [
            IconButton(
              onPressed: controller.togglePaused,
              tooltip: controller.paused ? '继续刷新' : '暂停刷新',
              icon: Icon(controller.paused ? Icons.play_arrow : Icons.pause),
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableText(
                record.target,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                '${record.network.toUpperCase()} · 端口 ${record.destinationPort.isEmpty ? '未提供' : record.destinationPort}',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              Text(
                controller.detailStatus,
                key: const ValueKey('connection-detail-status'),
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              if (record.host.isNotEmpty && record.destinationIP.isNotEmpty)
                _field('目标 IP', record.destinationIP),
              _section('分流结果'),
              Text(
                record.chains.firstOrNull ?? '路径未提供',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              _field('命中规则', record.ruleLabel),
              if (record.chains.length > 1) _field('实际路径', record.path),
              _section('活动与流量'),
              _field('下载', _bytes(record.download)),
              _field('上传', _bytes(record.upload)),
              _field('开始时间', _time(record.start)),
              if (duration != null && !duration.isNegative)
                _field(
                  '已观察至',
                  '${duration.inMinutes} 分 ${duration.inSeconds % 60} 秒',
                ),
              _field('最后观察', _time(at)),
              _section('连接信息'),
              _field(
                '源地址',
                ConnectionRecord.endpoint(record.sourceIP, record.sourcePort),
              ),
              _field('入站', record.type.isEmpty ? '未提供' : record.type),
              const SizedBox(height: 16),
              const _DataSource(),
            ],
          ),
        ),
      );
    },
  );

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 8),
    child: Text(
      title,
      style: TextStyle(
        fontSize: 13,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _field(String name, String value) => Container(
    padding: const EdgeInsets.symmetric(vertical: 10),
    decoration: BoxDecoration(
      border: Border(
        bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final label = Text(
          name,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 13,
          ),
        );
        if (constraints.maxWidth < 300 ||
            MediaQuery.textScalerOf(context).scale(14) > 20) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [label, const SizedBox(height: 4), SelectableText(value)],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 80, child: label),
            const SizedBox(width: 12),
            Expanded(child: SelectableText(value, textAlign: TextAlign.right)),
          ],
        );
      },
    ),
  );
}

class _DataSource extends StatelessWidget {
  const _DataSource();
  @override
  Widget build(BuildContext context) => const ExpansionTile(
    tilePadding: EdgeInsets.zero,
    title: Text('数据来源', style: TextStyle(fontSize: 13)),
    children: [
      Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Text(
          '来自内核活动连接快照，不含内核内部连接。短连接与短暂拒绝可能漏采；流量为最后观察到的累计值，不包含精确结束时间或最终计数。目标 IP 不是出口公网 IP。',
          style: TextStyle(fontSize: 12),
        ),
      ),
    ],
  );
}

String _time(DateTime? value) => value == null
    ? '未提供'
    : '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}:${value.second.toString().padLeft(2, '0')}';
String _bytes(int? value) {
  if (value == null) return '未提供';
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KiB';
  if (value < 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
}
