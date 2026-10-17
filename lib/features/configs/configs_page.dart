import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import '../../app/app_controller.dart';
import '../../app/widgets/operation_feedback.dart';
import 'config_entry.dart';
import 'config_file.dart';
import 'config_text_page.dart';
import 'widgets/confirm_action.dart';
import 'widgets/config_field_dialog.dart';
import 'widgets/import_dialog.dart';

class ConfigsPage extends StatefulWidget {
  const ConfigsPage({
    super.key,
    required this.controller,
    this.selectFile = selectConfigFile,
  });
  final AppController controller;
  final Future<XFile?> Function() selectFile;

  @override
  State<ConfigsPage> createState() => _ConfigsPageState();
}

class _ConfigsPageState extends State<ConfigsPage> {
  AppController get controller => widget.controller;
  final _scroll = ScrollController();
  final _viewport = GlobalKey();
  final _center = GlobalKey();
  final _keys = <String, GlobalKey>{};
  final _indices = <Key, int>{};
  List<String> _ids = [];
  int _centerIndex = 0;
  bool _adding = false;
  List<(String, String, String)> _rowContent = [];

  void _syncEntries() {
    final entries = controller.collection.entries;
    final ids = entries.map((e) => e.id).toList();
    final content = entries
        .map((e) => (e.id, e.name, e.displaySource))
        .toList();
    if (content.length == _rowContent.length &&
        content.indexed.every((e) => e.$2 == _rowContent[e.$1])) {
      return;
    }
    _rowContent = content;
    final remaining = ids.toSet();
    final top = (_viewport.currentContext?.findRenderObject() as RenderBox?)
        ?.localToGlobal(Offset.zero)
        .dy;
    String? anchor;
    double offset = 0;
    if (_scroll.hasClients && top != null) {
      for (final id in _ids) {
        final box = _keys[id]?.currentContext?.findRenderObject() as RenderBox?;
        if (remaining.contains(id) &&
            box != null &&
            box.hasSize &&
            box.localToGlobal(Offset.zero).dy + box.size.height > top) {
          anchor = id;
          offset = top - box.localToGlobal(Offset.zero).dy;
          break;
        }
      }
    }
    _ids = ids;
    _centerIndex = anchor == null ? 0 : ids.indexOf(anchor);
    _keys.removeWhere((id, _) => !remaining.contains(id));
    _indices.clear();
    for (var i = 0; i < ids.length; i++) {
      final key = _keys[ids[i]];
      if (key != null) _indices[key] = i;
    }
    if (_scroll.hasClients) _scroll.position.correctBy(offset - _scroll.offset);
  }

  SliverChildBuilderDelegate _rows({required bool before}) {
    final entries = controller.collection.entries;
    final count = before ? _centerIndex : entries.length - _centerIndex;
    return SliverChildBuilderDelegate(
      (context, local) {
        final index = before ? _centerIndex - local - 1 : _centerIndex + local;
        final entry = entries[index];
        final key = _keys.putIfAbsent(entry.id, GlobalKey.new);
        _indices[key] = index;
        return KeyedSubtree(key: key, child: _tile(context, entry));
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

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      _syncEntries();
      return Scaffold(
        appBar: AppBar(
          title: Text(
            controller.configsCurrent
                ? '配置'
                : controller.configError == null
                ? '配置 · 读取中'
                : '配置 · 未更新',
            maxLines: 1,
          ),
          actions: [
            if (controller.configError != null)
              IconButton(
                tooltip: '配置读取失败',
                onPressed: () => showOperationMessage(
                  context,
                  controller.configError!,
                  title: '配置读取失败',
                ),
                icon: const Icon(Icons.error_outline),
              ),
            _addMenu(),
          ],
        ),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: CustomScrollView(
                  key: _viewport,
                  controller: _scroll,
                  center: _center,
                  semanticChildCount: _ids.length,
                  slivers: [
                    if (_ids.isEmpty)
                      SliverToBoxAdapter(
                        key: _center,
                        child: controller.configsCurrent
                            ? Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 48,
                                ),
                                child: Column(
                                  children: [
                                    Icon(
                                      Icons.description_outlined,
                                      size: 48,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary,
                                    ),
                                    const SizedBox(height: 16),
                                    const Text('尚未保存配置'),
                                    const SizedBox(height: 8),
                                    const Text('从 URL、文件导入，或新建本地配置。'),
                                    const SizedBox(height: 24),
                                    _addMenu(labeled: true),
                                  ],
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    if (_ids.isNotEmpty) ...[
                      SliverList(delegate: _rows(before: true)),
                      SliverList(key: _center, delegate: _rows(before: false)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _addMenu({bool labeled = false}) => MenuAnchor(
    menuChildren: [
      MenuItemButton(
        leadingIcon: Icon(
          Icons.link,
          color: Theme.of(context).colorScheme.tertiary,
        ),
        onPressed: () => _add('url'),
        child: const Text('从 URL 导入'),
      ),
      MenuItemButton(
        leadingIcon: Icon(
          Icons.file_open_outlined,
          color: Theme.of(context).colorScheme.secondary,
        ),
        onPressed: () => _add('file'),
        child: const Text('从文件导入'),
      ),
      MenuItemButton(
        leadingIcon: const Icon(Icons.note_add_outlined),
        onPressed: () => _add('new'),
        child: const Text('新建本地配置'),
      ),
    ],
    builder: (context, menu, _) {
      final enabled = controller.canEdit && !_adding;
      void toggle() => menu.isOpen ? menu.close() : menu.open();
      return labeled
          ? FilledButton.icon(
              onPressed: enabled ? toggle : null,
              icon: const Icon(Icons.add),
              label: const Text('添加配置'),
            )
          : IconButton(
              tooltip: '添加配置',
              onPressed: enabled ? toggle : null,
              icon: const Icon(Icons.add),
            );
    },
  );

  Future<void> _add(String kind) async {
    if (_adding || !controller.canEdit) return;
    setState(() => _adding = true);
    try {
      if (kind == 'url') {
        await openImport(context, controller);
      } else if (kind == 'new') {
        final name = await showDialog<String>(
          context: context,
          builder: (_) => const ConfigFieldDialog(
            initial: '本地配置',
            title: '新建本地配置',
            confirmLabel: '继续',
          ),
        );
        if (!mounted || name == null) return;
        if (name.isEmpty || name.runes.length > 80) {
          await showOperationMessage(context, '请输入 1 至 80 个字符的配置名称。');
          return;
        }
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => ConfigTextPage(app: controller, initialName: name),
          ),
        );
      } else {
        final file = await widget.selectFile();
        if (file == null || !mounted) return;
        final body = await readConfigFile(file);
        if (!mounted) return;
        if (!controller.canEdit) {
          await showOperationMessage(context, '当前有操作正在处理，文件未提交。请等待操作完成后重新选择。');
          return;
        }
        final result = await controller.saveLocal({
          'name': configFileName(file.name),
          'body': body,
        });
        if (!mounted) return;
        if (result?.configStatus != 'saved') {
          await showOperationMessage(
            context,
            result?.resultMessage ?? '导入结果未确认，已重新读取配置列表；未自动重复导入，请先核实是否已经保存。',
          );
        }
      }
    } catch (error) {
      if (mounted) {
        await showOperationMessage(
          context,
          error is ConfigFailure ? error.message : '无法读取所选文件，未创建配置。请检查文件后重试。',
        );
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  void _openText(ConfigEntry entry) {
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ConfigTextPage(app: controller, entry: entry),
      ),
    );
  }

  Future<void> _changeText(ConfigEntry entry, {bool source = false}) async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => ConfigFieldDialog(
        initial: source ? entry.source! : entry.name,
        source: source,
      ),
    );
    if (!mounted || value == null || !controller.canEdit) return;
    if (source) {
      await _update(entry, source: value);
    } else {
      await controller.submit({
        'action': 'renameConfig',
        'id': entry.id,
        'name': value,
      });
    }
  }

  Future<void> _update(ConfigEntry entry, {String? source}) async {
    final url = source ?? entry.source!;
    var allowHttp = false;
    if (Uri.tryParse(url)?.scheme == 'http') {
      allowHttp = await confirmAction(
        context,
        title: '允许此次 HTTP 传输？',
        message: '配置和凭据将以明文传输，可能被读取或篡改。更新会使旧正文失效。',
        confirmLabel: '确认并更新',
      );
      if (!allowHttp || !mounted) return;
    }
    if (!controller.canEdit) return;
    await controller.submit({
      'action': 'updateConfig',
      'id': entry.id,
      'source': url,
      'allowHttp': allowHttp,
    });
  }

  Widget _tile(BuildContext context, ConfigEntry entry) {
    final selected = entry.id == controller.collection.selectedId;
    final running =
        controller.configsCurrent &&
        controller.state.running &&
        entry.id == controller.state.configId;
    final canSelect = controller.canEdit && !selected && entry.body != null;
    final colors = Theme.of(context).colorScheme;
    final titleStyle = Theme.of(context).textTheme.titleMedium!
        .copyWith(leadingDistribution: TextLeadingDistribution.even);
    final titleLineHeight =
        (MediaQuery.textScalerOf(context).scale(titleStyle.fontSize!) *
                (titleStyle.height ?? 1))
            .clamp(24.0, double.infinity);
    final status = running
        ? controller.state.revision != entry.revision
              ? '接管中 · 旧正文'
              : '接管中'
        : entry.body == null
        ? '正文不可用'
        : entry.error != null
        ? '操作未完成'
        : null;
    return Semantics(
      selected: selected,
      child: Card(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: selected ? colors.primary : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: InkWell(
          onTap: canSelect
              ? () => controller.submit({'action': 'select', 'id': entry.id})
              : null,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: SizedBox(
                        width: 24,
                        height: titleLineHeight,
                        child: Icon(
                          entry.remote
                              ? Icons.cloud_outlined
                              : Icons.description_outlined,
                          color: entry.remote
                              ? colors.tertiary
                              : colors.secondary,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(entry.name, style: titleStyle),
                          const SizedBox(height: 4),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                Text(entry.displaySource, softWrap: false),
                                if (status != null) ...[
                                  const SizedBox(width: 8),
                                  Text(status, softWrap: false),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 24,
                      height: titleLineHeight,
                      child: selected
                          ? Icon(Icons.check, color: colors.primary)
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Text(
                          _savedTime(context, entry),
                          softWrap: false,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: entry.remote ? '更新配置' : '编辑配置',
                      onPressed: controller.canEdit
                          ? () =>
                                entry.remote ? _update(entry) : _openText(entry)
                          : null,
                      icon: Icon(
                        entry.remote ? Icons.refresh : Icons.edit_outlined,
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: '更多操作',
                      enabled:
                          controller.canEdit ||
                          entry.error != null ||
                          entry.body == null,
                      onSelected: (action) {
                        switch (action) {
                          case 'error':
                            showOperationMessage(
                              context,
                              entry.error ?? '此配置没有可用正文，请更新后重试。',
                              title: '配置操作未完成',
                              subject: entry.name,
                            );
                          case 'rename':
                            _changeText(entry);
                          case 'source':
                            _changeText(entry, source: true);
                          case 'view':
                            _openText(entry);
                          case 'delete':
                            _delete(context, entry);
                        }
                      },
                      itemBuilder: (_) => [
                        if (entry.error != null || entry.body == null)
                          const PopupMenuItem(
                            value: 'error',
                            child: Text('查看配置错误'),
                          ),
                        PopupMenuItem(
                          value: 'rename',
                          enabled: controller.canEdit,
                          child: const Text('重命名'),
                        ),
                        if (entry.remote) ...[
                          PopupMenuItem(
                            value: 'source',
                            enabled: controller.canEdit,
                            child: const Text('修改来源并更新'),
                          ),
                          PopupMenuItem(
                            value: 'view',
                            enabled: controller.canEdit && entry.body != null,
                            child: const Text('查看正文'),
                          ),
                        ],
                        PopupMenuItem(
                          value: 'delete',
                          enabled: controller.canEdit && !running,
                          child: const Text('删除'),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _savedTime(BuildContext context, ConfigEntry entry) {
    final time = entry.updatedAt?.toLocal();
    final label = entry.remote ? '更新' : '保存';
    if (time == null) return '$label时间未知';
    final locale = MaterialLocalizations.of(context);
    return '$label于 ${locale.formatCompactDate(time)} ${locale.formatTimeOfDay(TimeOfDay.fromDateTime(time))}';
  }

  Future<void> _delete(BuildContext context, ConfigEntry entry) async {
    final selected = entry.id == controller.collection.selectedId;
    final remaining = controller.collection.entries
        .where((e) => e.id != entry.id)
        .toList();
    final outcome = !selected
        ? '当前选择与接管不变。'
        : remaining.isEmpty
        ? '删除后没有当前配置。'
        : '删除后选择“${remaining.first.name}”，不会自动启动。';
    final accepted = await confirmAction(
      context,
      title: '删除配置？',
      subject: entry.name,
      message: '${entry.remote ? '将删除保存的正文与来源。' : '将删除保存的本地正文。'}\n\n$outcome',
      confirmLabel: '删除',
    );
    if (accepted && context.mounted) {
      await controller.submit({'action': 'delete', 'id': entry.id});
    }
  }
}
