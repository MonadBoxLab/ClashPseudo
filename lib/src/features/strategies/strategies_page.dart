import 'package:flutter/material.dart';

import '../../app/widgets/task_shortcuts.dart';

import '../../app/app_theme.dart';

import '../../app/widgets/operation_feedback.dart';
import '../../app/widgets/reading_list.dart';
import '../../app/widgets/toolbar_search_field.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/messages.dart';
import 'strategy_controller.dart';
import 'strategy_choice.dart';
import 'strategy_icon.dart';
import 'strategy_card_status.dart';
import 'strategy_popup.dart';
import 'strategy_snapshot.dart';

typedef _StrategyGridMetrics = ({
  double scale,
  double statusWidth,
  double minimum,
  int columns,
  double width,
  bool inlineStatus,
  double nameHeight,
  double height,
});

class StrategiesPage extends StatefulWidget {
  const StrategiesPage({
    super.key,
    required this.controller,
    required this.active,
    this.onAdd,
    this.localDefinitions = const [],
    this.onOpenGroup,
  });
  final StrategyController controller;
  final bool active;
  final VoidCallback? onAdd;
  final List<ReadingListItem> localDefinitions;

  /// The all-groups overview opens properties rather than the daily member
  /// popup. The main strategy page leaves this null and keeps its selection
  /// and delay-test interaction unchanged.
  final void Function(StrategyGroup group)? onOpenGroup;

  @override
  State<StrategiesPage> createState() => _StrategiesPageState();
}

class _StrategiesPageState extends State<StrategiesPage> {
  final _scroll = ScrollController();
  final _viewport = GlobalKey();
  final _header = GlobalKey();
  static const _top = ValueKey('strategies-top');
  static const _center = ValueKey('strategies-center');
  final _cardKeys = <String, GlobalKey>{};
  final _keyNames = <Key, String>{};
  Map<String, int> _indices = {};
  List<String> _ids = [];
  _StrategyGridMetrics? _layout;
  int _centerRow = 0;
  bool _anchored = false;

  bool _memberOpen = false;
  String? _openName;
  int? _openGeneration;
  bool _visibilityScheduled = false;
  bool _visibilityReady = false;
  final _searchText = TextEditingController();
  final _searchFocus = FocusNode(canRequestFocus: false);
  String _query = '';
  bool _searching = false;
  bool _searchVisible = false;
  int _searchGeneration = 0;

  @override
  void initState() {
    super.initState();
    _searchText.addListener(_searchChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncSearchFocus();
  }

  @override
  void didUpdateWidget(StrategiesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _searchGeneration++;
    }
    _syncSearchFocus();
  }

  void _syncSearchFocus() {
    final visible =
        widget.active &&
        !widget.controller.allGroups &&
        widget.controller.app.foreground &&
        !_memberOpen &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    if (_searchVisible != visible) {
      _searchVisible = visible;
      _searchGeneration++;
    }
    _searchFocus.canRequestFocus = visible && _searching;
  }

  bool _ownsSearch(StrategyController owner, int epoch, int generation) =>
      mounted &&
      widget.active &&
      !widget.controller.allGroups &&
      widget.controller.app.foreground &&
      !_memberOpen &&
      identical(widget.controller, owner) &&
      owner.app.storageEpoch == epoch &&
      _searchGeneration == generation &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  void _enterSearch(StrategyController owner, int epoch, int generation) {
    if (_searching || !_ownsSearch(owner, epoch, generation)) return;
    setState(() {
      _searching = true;
      _searchGeneration++;
    });
    _syncSearchFocus();
    final opened = _searchGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_searching && _ownsSearch(owner, epoch, opened)) {
        _searchFocus.requestFocus();
      }
    });
  }

  void _exitSearch() {
    if (!_searching) return;
    _searchFocus.unfocus();
    _searchText.clear();
    setState(() {
      _searching = false;
      _searchGeneration++;
    });
    _searchFocus.canRequestFocus = false;
  }

  void _searchChanged() {
    final query = _searchText.text.trim().toLowerCase();
    if (_query == query) return;
    setState(() {
      _query = query;
      _ids = [];
      _layout = null;
      _centerRow = 0;
      _anchored = false;
    });
    if (_scroll.hasClients) _scroll.position.correctBy(-_scroll.offset);
  }

  Widget _searchTitle(AppLocalizations strings) {
    final owner = widget.controller;
    final epoch = owner.app.storageEpoch;
    final generation = _searchGeneration;
    return AnimatedSwitcher(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 200),
      layoutBuilder: (current, _) => current ?? const SizedBox.shrink(),
      child: _searching
          ? Row(
              key: const ValueKey('strategy-search'),
              children: [
                const SizedBox(width: 8),
                Expanded(
                  child: ExcludeFocus(
                    excluding: !_searchVisible,
                    child: ToolbarSearchField(
                      controller: _searchText,
                      focusNode: _searchFocus,
                      hintText: strings.searchStrategies,
                      trailing: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _searchText,
                        builder: (context, value, _) => IconButton(
                          tooltip: value.text.isEmpty
                              ? strings.exitSearch
                              : strings.clearSearch,
                          onPressed: () {
                            if (!_ownsSearch(owner, epoch, generation) ||
                                !_searching) {
                              return;
                            }
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
                    ),
                  ),
                ),
              ],
            )
          : Row(
              key: const ValueKey('strategy-title'),
              children: [
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    strings.strategyGroups,
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.6,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: strings.searchStrategies,
                  onPressed: () => _enterSearch(owner, epoch, generation),
                  color: HomePalette.of(context).moreAction,
                  icon: const Icon(Icons.search),
                ),
              ],
            ),
    );
  }

  _StrategyGridMetrics _measureGrid(BuildContext context, double extent) {
    final strings = AppLocalizations.of(context);
    final controller = widget.controller;
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final statusWidth = StrategyCardStatus.width(context);
    final minimum = statusWidth + 56 * scale + 48;
    final columns = ((extent + 12) / (minimum + 12)).floor().clamp(1, 4);
    final width = (extent - (columns - 1) * 12) / columns;
    final inlineStatus = width >= minimum;
    double lineHeight(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: Theme.of(context).textTheme.bodyMedium!.merge(style),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }

    final nameHeight =
        2 *
        lineHeight(
          strings.strategyGroups,
          const TextStyle(
            fontSize: 16,
            height: 1.2,
            fontWeight: FontWeight.w600,
          ),
        );
    final typeHeight = lineHeight(
      strings.strategyGroups,
      const TextStyle(fontSize: 10),
    );
    final currentHeight = lineHeight(
      strings.unconfirmed,
      const TextStyle(fontSize: 12, height: 1.3),
    );
    final delayHeight = MediaQuery.textScalerOf(context).scale(11) * 1.3;
    final topHeight = typeHeight > 30 ? typeHeight : 30.0;
    final footerHeight = controller.allGroups
        ? (currentHeight > 20 ? currentHeight : 20.0)
        : (currentHeight > delayHeight ? currentHeight : delayHeight);
    final height =
        27 +
        topHeight +
        10 +
        nameHeight +
        (controller.allGroups ? 20 * scale : 0) +
        2 +
        footerHeight +
        (!controller.allGroups && !inlineStatus ? delayHeight : 0);
    return (
      scale: scale,
      statusWidth: statusWidth,
      minimum: minimum,
      columns: columns,
      width: width,
      inlineStatus: inlineStatus,
      nameHeight: nameHeight,
      height: height,
    );
  }

  // Rebase the SDK viewport on a surviving visible card before layout.
  void _prepareGrid(_StrategyGridMetrics layout, List<StrategyGroup> groups) {
    final ids = groups.map((group) => group.name).toList();
    if (_layout == layout &&
        ids.length == _ids.length &&
        ids.indexed.every((item) => item.$2 == _ids[item.$1])) {
      return;
    }
    final indices = {for (var i = 0; i < ids.length; i++) ids[i]: i};
    final viewport = _viewport.currentContext?.findRenderObject();
    final header = _header.currentContext?.findRenderObject();
    String? anchor;
    var offset = 0.0;
    if (_scroll.hasClients && viewport is RenderBox && viewport.hasSize) {
      final top = viewport.localToGlobal(Offset.zero).dy;
      final bottom = top + viewport.size.height;
      final headerVisible =
          header is RenderBox &&
          header.hasSize &&
          header.localToGlobal(Offset(0, header.size.height)).dy > top;
      if (!headerVisible) {
        for (final id in _ids) {
          if (!indices.containsKey(id)) continue;
          final box = _cardKeys[id]?.currentContext?.findRenderObject();
          if (box is! RenderBox || !box.hasSize) continue;
          final y = box.localToGlobal(Offset.zero).dy;
          if (y >= top && y < bottom) {
            anchor = id;
            offset = y - top;
            break;
          }
        }
      }
      if (anchor != null) {
        _centerRow = indices[anchor]! ~/ layout.columns;
        _anchored = true;
        _scroll.position.correctBy(-offset - _scroll.offset);
      } else if (_anchored) {
        final y = header is RenderBox && header.hasSize
            ? header.localToGlobal(Offset.zero).dy - top
            : 0.0;
        _centerRow = 0;
        _anchored = false;
        _scroll.position.correctBy(-y - _scroll.offset);
      }
    }
    _layout = layout;
    _ids = ids;
    _indices = indices;
    _cardKeys.removeWhere((name, _) => !indices.containsKey(name));
    _keyNames.removeWhere((_, name) => !indices.containsKey(name));
  }

  @override
  void dispose() {
    _searchGeneration++;
    _searchText.removeListener(_searchChanged);
    _searchText.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _syncVisibility() {
    _syncSearchFocus();
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

  Future<void> _openGroup(StrategyGroup group, BuildContext anchor) async {
    if (!widget.active || _memberOpen) return;
    if (widget.controller.allGroups) {
      // Diagnostic group cards open properties and reserve their slot for attributes.
      widget.onOpenGroup?.call(group);
      return;
    }
    _searchFocus.unfocus();
    setState(() {
      _memberOpen = true;
      _openName = group.name;
      _openGeneration = widget.controller.app.state.core.generation;
    });
    try {
      await showStrategyPopup(
        context: anchor,
        controller: widget.controller,
        name: group.name,
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
  Widget build(BuildContext context) => TaskShortcuts(
    enabled: widget.active && !widget.controller.allGroups && !_memberOpen,
    onSearch: () => _enterSearch(
      widget.controller,
      widget.controller.app.storageEpoch,
      _searchGeneration,
    ),
    onEscape: _searching ? _exitSearch : null,
    child: _content(context),
  );

  Widget _content(BuildContext context) {
    _syncVisibility();
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        _syncSearchFocus();
        final controller = widget.controller;
        final app = controller.app;
        final state = app.state;
        final core = state.core;
        final selected = app.collection.selected;
        final id = state.running ? state.configId : selected?.id;
        final config = app.collection.find(id);
        final strings = AppLocalizations.of(context);
        final colors = Theme.of(context).colorScheme;
        final errorMessage = [
          app.errorMessage,
          controller.operationErrorMessage,
          controller.readErrorMessage,
          if (core.blocked || core.configId == id) core.errorMessage,
        ].whereType<AppMessage>().firstOrNull;
        final error = errorMessage?.resolve(strings);
        final visibleGroups = controller.groups;
        final groups = controller.allGroups || _query.isEmpty
            ? visibleGroups
            : visibleGroups
                  .where((group) => group.name.toLowerCase().contains(_query))
                  .toList();
        final data = controller.data;
        final searchGeneration = _searchGeneration;
        final searchEpoch = app.storageEpoch;
        return PopScope<void>(
          canPop: controller.allGroups || !widget.active || !_searching,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop ||
                !_searching ||
                !_ownsSearch(controller, searchEpoch, searchGeneration)) {
              return;
            }
            if (_searchFocus.hasFocus ||
                MediaQuery.viewInsetsOf(context).bottom > 0) {
              _searchFocus.unfocus();
            } else {
              _exitSearch();
            }
          },
          child: Scaffold(
            appBar: AppBar(
              titleSpacing: controller.allGroups ? null : 0,
              actions: [
                if (controller.allGroups)
                  IconButton(
                    tooltip: strings.strategyGroupFormTitle,
                    onPressed: app.canEdit ? widget.onAdd : null,
                    color: Theme.of(context).colorScheme.primary,
                    icon: const Icon(Icons.add),
                  )
                else
                  IconButton(
                    tooltip: controller.showHidden
                        ? strings.hideHiddenGroups
                        : strings.showHiddenGroups,
                    isSelected: controller.showHidden,
                    onPressed: () =>
                        controller.setShowHidden(!controller.showHidden),
                    color: HomePalette.of(context).moreAction,
                    icon: const Icon(Icons.visibility_off_outlined),
                    selectedIcon: const Icon(Icons.visibility_outlined),
                  ),
              ],
              title: controller.allGroups
                  ? SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Text(strings.allStrategyGroups, softWrap: false),
                    )
                  : _searchTitle(strings),
            ),
            body: SafeArea(
              top: false,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final layout = _measureGrid(
                    context,
                    (constraints.maxWidth - 40).clamp(0.0, double.infinity),
                  );
                  if (!controller.allGroups) _prepareGrid(layout, groups);
                  final (
                    :scale,
                    :statusWidth,
                    :minimum,
                    :columns,
                    :width,
                    :inlineStatus,
                    :nameHeight,
                    :height,
                  ) = layout;
                  Widget card(BuildContext anchor, StrategyGroup group) {
                    final hidden =
                        _openName == group.name &&
                        _openGeneration == core.generation;
                    final inlineStatus = width >= minimum;
                    final cardStatus = StrategyCardStatus(
                      key: ValueKey('strategy-status-${group.name}'),
                      slotWidth: statusWidth.clamp(0.0, width - 28).toDouble(),
                      result: controller.cardDelay(group),
                      rejected:
                          controller.current &&
                          group.selectable &&
                          group.members.any(
                            (member) =>
                                member.name == group.now &&
                                member.type == 'Reject',
                          ),
                    );
                    return ExcludeSemantics(
                      excluding: hidden,
                      child: Opacity(
                        opacity: hidden ? 0 : 1,
                        child: Material(
                          color: colors.surface,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(13),
                            side: BorderSide(
                              color: colors.outlineVariant.withValues(
                                alpha: .7,
                              ),
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            key: ValueKey('strategy-group-${group.name}'),
                            onTap: () => _openGroup(group, anchor),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                14,
                                14,
                                14,
                                13,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      StrategyIcon(
                                        type: group.rawType,
                                        source: group.icon,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          group.typeLabel(strings),
                                          textAlign: TextAlign.end,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: colors.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  ConstrainedBox(
                                    constraints: BoxConstraints.tightFor(
                                      height: nameHeight,
                                    ),
                                    child: Align(
                                      heightFactor: 1,
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        group.name,
                                        key: ValueKey(
                                          'strategy-name-${group.name}',
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          height: 1.2,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (controller.allGroups)
                                    SizedBox(
                                      key: ValueKey(
                                        'strategy-attributes-${group.name}',
                                      ),
                                      width: double.infinity,
                                      height: 20 * scale,
                                      child: SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        child: Align(
                                          alignment: Alignment.centerLeft,
                                          child: Text(
                                            [
                                              if (group.hidden)
                                                strings.hiddenGroupAttribute,
                                              if (group.name == 'GLOBAL')
                                                strings.globalGroupAttribute,
                                            ].join(' · '),
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: colors.onSurfaceVariant,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  const SizedBox(height: 2),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          !controller.current
                                              ? strings.notUpdated
                                              : group.selectable
                                              ? (group.now.isEmpty
                                                    ? strings.unconfirmed
                                                    : group.now)
                                              : '',
                                          key: ValueKey(
                                            'strategy-current-${group.name}',
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12,
                                            height: 1.3,
                                            color: colors.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                      if (controller.allGroups) ...[
                                        const SizedBox(width: 8),
                                        SizedBox.square(
                                          key: ValueKey(
                                            'strategy-source-${group.name}',
                                          ),
                                          dimension: 20,
                                          child:
                                              controller.current &&
                                                  group
                                                          .provenance
                                                          ?.plugins
                                                          .isNotEmpty ==
                                                      true
                                              ? Tooltip(
                                                  message: strings
                                                      .strategyGroupPluginContribution,
                                                  excludeFromSemantics: true,
                                                  child: Icon(
                                                    Icons.extension_outlined,
                                                    size: 20,
                                                    color: SettingsPalette(
                                                      Theme.of(context)
                                                              .brightness ==
                                                          Brightness.dark,
                                                    ).extension,
                                                    semanticLabel: strings
                                                        .strategyGroupPluginContribution,
                                                  ),
                                                )
                                              : null,
                                        ),
                                      ] else ...[
                                        if (inlineStatus) ...[
                                          const SizedBox(width: 4),
                                          cardStatus,
                                        ],
                                        SizedBox(
                                          key: ValueKey(
                                            'strategy-pin-${group.name}',
                                          ),
                                          width: 16,
                                          height: 12,
                                          child:
                                              group.automatic &&
                                                  group.fixed.isNotEmpty
                                              ? Tooltip(
                                                  message: strings.fixedTo(
                                                    group.fixed,
                                                  ),
                                                  child: Icon(
                                                    Icons.push_pin_rounded,
                                                    size: 12,
                                                    color: colors.primary,
                                                  ),
                                                )
                                              : null,
                                        ),
                                      ],
                                    ],
                                  ),
                                  if (!controller.allGroups && !inlineStatus)
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: cardStatus,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }

                  Widget grid({required bool before}) {
                    final count = before
                        ? _centerRow * columns
                        : groups.length - _centerRow * columns;
                    int indexOf(int local) => before
                        ? (_centerRow - 1 - local ~/ columns) * columns +
                              local % columns
                        : _centerRow * columns + local;
                    return SliverPadding(
                      key: before ? null : _center,
                      padding: EdgeInsets.fromLTRB(20, 0, 20, before ? 12 : 24),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          mainAxisExtent: height,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, local) {
                            final group = groups[indexOf(local)];
                            final key = _cardKeys.putIfAbsent(
                              group.name,
                              GlobalKey.new,
                            );
                            _keyNames[key] = group.name;
                            return KeyedSubtree(
                              key: key,
                              child: SizedBox(
                                key: ValueKey('strategy-card-${group.name}'),
                                width: width,
                                child: Builder(
                                  builder: (anchor) => card(anchor, group),
                                ),
                              ),
                            );
                          },
                          childCount: count,
                          findChildIndexCallback: (key) {
                            final index = _indices[_keyNames[key]];
                            if (index == null) return null;
                            final local = before
                                ? (_centerRow - 1 - index ~/ columns) *
                                          columns +
                                      index % columns
                                : index - _centerRow * columns;
                            return local < 0 || local >= count ? null : local;
                          },
                        ),
                      ),
                    );
                  }

                  final header = Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                    child: Column(
                      key: _header,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          app.configsCurrent
                              ? config?.name ??
                                    (state.running
                                        ? strings.actualConfigUnconfirmed
                                        : strings.noConfigSelected)
                              : strings.confirmingConfig,
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
                                        ? data == null
                                              ? strings.strategiesLoadFailed
                                              : strings.strategiesNotUpdated
                                        : app.busy ||
                                              controller.loading ||
                                              !_visibilityReady
                                        ? strings.loadingStrategies
                                        : data == null
                                        ? !app.configsCurrent ||
                                                  !state.confirmed
                                              ? strings.waitingTakeoverConfig
                                              : !state.running &&
                                                    selected == null
                                              ? strings
                                                    .importConfigForStrategies
                                              : strings.strategiesNotLoaded
                                        : data.unrestored.isNotEmpty
                                        ? strings.selectionsNotRestored
                                        : state.running
                                        ? strings.underTakeover
                                        : strings.notUnderTakeover,
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
                                      ? strings.viewUnrestored
                                      : strings.viewStrategyError,
                                  onPressed: () => showLocalizedOperationMessage(
                                    context,
                                    (strings) => [
                                      if (errorMessage != null)
                                        errorMessage.resolve(strings),
                                      if (data != null &&
                                          data.unrestored.isNotEmpty)
                                        '${strings.selectionsNotRestored}:\n${data.unrestored.entries.map((e) => strings.unrestoredLine(e.key, strategyUnrestoredReason(e.value, strings))).join('\n')}',
                                    ].join('\n\n'),
                                    title: (strings) => strings.strategyStatus,
                                    error: error != null,
                                  ),
                                  icon: Icon(
                                    error == null
                                        ? Icons.info_outline
                                        : Icons.error_outline,
                                    color: error == null
                                        ? colors.primary
                                        : colors.error,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (data == null) ...[
                          TextButton.icon(
                            onPressed:
                                _visibilityReady &&
                                    !app.busy &&
                                    !controller.loading &&
                                    app.configsCurrent &&
                                    state.confirmed &&
                                    (state.running || selected != null) &&
                                    !core.blocked
                                ? controller.retry
                                : null,
                            style: TextButton.styleFrom(
                              iconColor: HomePalette.of(context).syncAction,
                            ),
                            icon: const Icon(Icons.refresh),
                            label: Text(strings.loadStrategies),
                          ),
                        ],
                        if (data != null && groups.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 20),
                            child: Text(
                              controller.allGroups
                                  ? strings.noStrategyGroups
                                  : _query.isNotEmpty
                                  ? strings.noMatchingStrategies
                                  : strings.noVisibleGroups,
                            ),
                          ),
                      ],
                    ),
                  );
                  if (controller.allGroups) {
                    final names = groups.map((group) => group.name).toSet();
                    _cardKeys.removeWhere((name, _) => !names.contains(name));
                    Object groupId(StrategyGroup group) => (
                      'runtime-group',
                      core.generation,
                      core.composition,
                      group.name,
                    );
                    return ReadingList(
                      controller: _scroll,
                      identity: app.storageEpoch,
                      header: header,
                      items: [
                        for (
                          var start = 0;
                          start < groups.length;
                          start += columns
                        )
                          ReadingListItem(
                            id: groupId(groups[start]),
                            semanticChildCount: (groups.length - start).clamp(
                              1,
                              columns,
                            ),
                            anchors: [
                              for (
                                var i = start + 1;
                                i < start + columns && i < groups.length;
                                i++
                              )
                                groupId(groups[i]),
                            ],
                            builder: (context) => Padding(
                              padding: EdgeInsets.fromLTRB(
                                20,
                                0,
                                20,
                                start + columns < groups.length ? 12 : 24,
                              ),
                              child: SizedBox(
                                height: height,
                                child: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    for (
                                      var column = 0;
                                      column < columns;
                                      column++
                                    ) ...[
                                      if (column != 0)
                                        const SizedBox(width: 12),
                                      SizedBox(
                                        width: width,
                                        child: start + column < groups.length
                                            ? IndexedSemantics(
                                                index: start + column,
                                                child: Semantics(
                                                  container: true,
                                                  child: KeyedSubtree(
                                                    key: _cardKeys.putIfAbsent(
                                                      groups[start + column]
                                                          .name,
                                                      GlobalKey.new,
                                                    ),
                                                    child: SizedBox(
                                                      key: ValueKey(
                                                        'strategy-card-${groups[start + column].name}',
                                                      ),
                                                      child: Builder(
                                                        builder: (anchor) =>
                                                            card(
                                                              anchor,
                                                              groups[start +
                                                                  column],
                                                            ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              )
                                            : null,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ...widget.localDefinitions,
                      ],
                    );
                  }
                  return KeyedSubtree(
                    key: _viewport,
                    child: CustomScrollView(
                      controller: _scroll,
                      center: _anchored ? _center : _top,
                      key: const PageStorageKey('strategies-scroll'),
                      slivers: [
                        SliverToBoxAdapter(key: _top, child: header),
                        if (_centerRow > 0) grid(before: true),
                        grid(before: false),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
