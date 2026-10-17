import 'package:flutter/material.dart';

import '../../app/widgets/operation_feedback.dart';
import 'strategy_controller.dart';
import 'strategy_icon.dart';
import 'strategy_popup.dart';

class StrategiesPage extends StatefulWidget {
  const StrategiesPage({
    super.key,
    required this.controller,
    required this.active,
  });
  final StrategyController controller;
  final bool active;

  @override
  State<StrategiesPage> createState() => _StrategiesPageState();
}

class _StrategiesPageState extends State<StrategiesPage> {
  bool _memberOpen = false;
  String? _openName;
  int? _openGeneration;
  bool _visibilityScheduled = false;
  bool _visibilityReady = false;

  void _syncVisibility() {
    if (_visibilityScheduled) return;
    _visibilityScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityScheduled = false;
      if (!mounted) return;
      if (!_visibilityReady) setState(() => _visibilityReady = true);
      widget.controller.setVisible(
        widget.active &&
            (_memberOpen || (ModalRoute.of(context)?.isCurrent ?? true)),
      );
    });
  }

  Future<void> _openGroup(BuildContext anchor, String name) async {
    if (_memberOpen) return;
    setState(() {
      _memberOpen = true;
      _openName = name;
      _openGeneration = widget.controller.app.state.core.generation;
    });
    try {
      await showStrategyPopup(
        context: anchor,
        controller: widget.controller,
        name: name,
      );
    } finally {
      if (mounted) {
        setState(() {
          _memberOpen = false;
          _openName = null;
          _openGeneration = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _syncVisibility();
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final app = controller.app;
        final state = app.state;
        final core = state.core;
        final selected = app.collection.selected;
        final id = state.running ? state.configId : selected?.id;
        final config = app.collection.find(id);
        final colors = Theme.of(context).colorScheme;
        final error =
            [
                  app.error,
                  controller.operationError,
                  controller.readError,
                  if (core.blocked || core.configId == id) core.error,
                ]
                .whereType<String>()
                .where((message) => message.trim().isNotEmpty)
                .firstOrNull;
        final groups = controller.groups;
        final data = controller.data;
        return Scaffold(
          appBar: AppBar(
            title: const Text(
              '策略组',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                letterSpacing: -.6,
              ),
            ),
          ),
          body: SafeArea(
            top: false,
            child: CustomScrollView(
              key: const PageStorageKey('strategies-scroll'),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          app.configsCurrent
                              ? config?.name ??
                                    (state.running ? '实际配置未确认' : '尚未选择配置')
                              : '正在确认配置',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Row(
                            children: [
                              Expanded(
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Text(
                                    error != null
                                        ? '策略未更新'
                                        : app.busy ||
                                              (controller.loading &&
                                                  data == null)
                                        ? '正在加载策略…'
                                        : data != null &&
                                              data.unrestored.isNotEmpty
                                        ? '原选择未恢复'
                                        : state.running
                                        ? '接管中'
                                        : '未接管 · 预选',
                                    softWrap: false,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: error == null
                                          ? colors.onSurfaceVariant
                                          : colors.error,
                                    ),
                                  ),
                                ),
                              ),
                              if (error != null ||
                                  (data != null && data.unrestored.isNotEmpty))
                                IconButton(
                                  tooltip: error == null
                                      ? '查看未恢复的选择'
                                      : '查看策略错误',
                                  onPressed: () => showOperationMessage(
                                    context,
                                    [
                                      ?error,
                                      if (data != null &&
                                          data.unrestored.isNotEmpty)
                                        '原选择未恢复：\n${data.unrestored.entries.map((e) => '${e.key}：${e.value}').join('\n')}',
                                    ].join('\n\n'),
                                    title: '策略状态',
                                    error: error != null,
                                  ),
                                  icon: Icon(
                                    error == null
                                        ? Icons.info_outline
                                        : Icons.error_outline,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (data == null) ...[
                          const SizedBox(height: 20),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Text(
                              !app.configsCurrent || !state.confirmed
                                  ? '正在等待接管与配置状态确认。'
                                  : !state.running && selected?.body == null
                                  ? (selected == null
                                        ? '导入并选择完整配置后即可查看策略。'
                                        : '当前配置没有可用正文，请在配置管理中更新。')
                                  : !_visibilityReady ||
                                        app.busy ||
                                        controller.loading
                                  ? '正在准备策略…'
                                  : error == null
                                  ? '策略尚未加载。'
                                  : '策略未加载，请查看错误后重试。',
                              softWrap: false,
                            ),
                          ),
                          TextButton.icon(
                            onPressed:
                                _visibilityReady &&
                                    !app.busy &&
                                    !controller.loading &&
                                    app.configsCurrent &&
                                    state.confirmed &&
                                    (state.running || selected?.body != null) &&
                                    !core.blocked &&
                                    !state.needsHttpConfirmation
                                ? controller.retry
                                : null,
                            icon: const Icon(Icons.refresh),
                            label: const Text('加载策略'),
                          ),
                        ],
                        if (data != null && groups.isEmpty)
                          const Padding(
                            padding: EdgeInsets.only(top: 20),
                            child: Text('当前模式下没有可显示的策略组。'),
                          ),
                      ],
                    ),
                  ),
                ),
                if (groups.isNotEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                    sliver: SliverToBoxAdapter(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final scale =
                              MediaQuery.textScalerOf(context).scale(14) / 14;
                          final minimum = 132 * scale;
                          final columns =
                              ((constraints.maxWidth + 12) / (minimum + 12))
                                  .floor()
                                  .clamp(1, 4);
                          final width =
                              (constraints.maxWidth - (columns - 1) * 12) /
                              columns;
                          return Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              for (final group in groups)
                                SizedBox(
                                  key: ValueKey('strategy-card-${group.name}'),
                                  width: width,
                                  child: Builder(
                                    builder: (anchor) {
                                      final hidden =
                                          _openName == group.name &&
                                          _openGeneration == core.generation;
                                      return ExcludeSemantics(
                                        excluding: hidden,
                                        child: Opacity(
                                          opacity: hidden ? 0 : 1,
                                          child: Material(
                                            color: colors.surface,
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(13),
                                              side: BorderSide(
                                                color: colors.outlineVariant
                                                    .withValues(alpha: .7),
                                              ),
                                            ),
                                            clipBehavior: Clip.antiAlias,
                                            child: InkWell(
                                              key: ValueKey(
                                                'strategy-group-${group.name}',
                                              ),
                                              onTap: () => _openGroup(
                                                anchor,
                                                group.name,
                                              ),
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.fromLTRB(
                                                      14,
                                                      14,
                                                      14,
                                                      13,
                                                    ),
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Row(
                                                      children: [
                                                        StrategyIcon(
                                                          type: group.rawType,
                                                          source: group.icon,
                                                        ),
                                                        const SizedBox(
                                                          width: 8,
                                                        ),
                                                        Expanded(
                                                          child: Text(
                                                            group.typeLabel,
                                                            textAlign:
                                                                TextAlign.end,
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style: TextStyle(
                                                              fontSize: 10,
                                                              color: colors
                                                                  .onSurfaceVariant,
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                    const SizedBox(height: 10),
                                                    ConstrainedBox(
                                                      constraints:
                                                          BoxConstraints(
                                                            minHeight:
                                                                24 * scale,
                                                          ),
                                                      child: Align(
                                                        heightFactor: 1,
                                                        alignment: Alignment
                                                            .centerLeft,
                                                        child: Text(
                                                          group.name,
                                                          maxLines: 2,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style:
                                                              const TextStyle(
                                                                fontSize: 16,
                                                                height: 1.2,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w600,
                                                              ),
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(height: 2),
                                                    Row(
                                                      children: [
                                                        SizedBox(
                                                          width: 16,
                                                          child:
                                                              group.automatic &&
                                                                  group
                                                                      .fixed
                                                                      .isNotEmpty
                                                              ? Tooltip(
                                                                  message:
                                                                      '固定：${group.fixed}',
                                                                  child: Icon(
                                                                    Icons
                                                                        .push_pin_rounded,
                                                                    size: 12,
                                                                    color: colors
                                                                        .onSurfaceVariant,
                                                                  ),
                                                                )
                                                              : null,
                                                        ),
                                                        Expanded(
                                                          child: Text(
                                                            !controller.current
                                                                ? '未更新'
                                                                : group
                                                                      .selectable
                                                                ? (group
                                                                          .now
                                                                          .isEmpty
                                                                      ? '未确认'
                                                                      : group
                                                                            .now)
                                                                : '',
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style: TextStyle(
                                                              fontSize: 12,
                                                              height: 1.3,
                                                              color: colors
                                                                  .onSurfaceVariant,
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
