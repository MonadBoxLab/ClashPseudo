import '../locale/model_text.dart';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../components/input/task_shortcuts.dart';

import '../navigation/task_activity.dart';
import '../theme/app_theme.dart';

import '../components/feedback/operation_notice.dart';
import '../components/collections/reading_list.dart';
import '../components/input/toolbar_search_field.dart';
import '../../l10n/app_localizations.dart';
import 'strategy_controller.dart';
import 'strategy_icon.dart';
import 'strategy_card_status.dart';
import 'strategy_popup.dart';
import '../../model/strategy_snapshot.dart';

typedef _StrategyGridMetrics = ({
  double attributesHeight,
  double statusWidth,
  double minimum,
  int columns,
  double width,
  bool inlineStatus,
  double nameHeight,
  double height,
});

/// Cards can read runtime objects or saved direct definitions; runtime properties are
/// not synthesized from source text.
class StrategyDefinition {
  const StrategyDefinition({this.runtime, this.original = const {}});
  final StrategyGroup? runtime;
  final Map<String, dynamic> original;
  String get name => runtime?.name ?? original['name'] as String;
  String get id => original['localDefinition'] as String? ?? name;
  String get readingId =>
      runtime?.name ?? original['readingDefinition'] as String? ?? id;
  String get rawType => runtime?.rawType ?? original['type'] as String? ?? '';
  Map get _definition => original['definition'] as Map? ?? const {};
  String get icon => runtime?.icon ?? _definition['icon'] as String? ?? '';
  bool get hidden => runtime?.hidden ?? _definition['hidden'] == true;
  bool get selectable => runtime?.selectable ?? false;
  String get now => runtime?.now ?? '';
  List<StrategyMember> get members => runtime?.members ?? const [];
  String typeLabel(AppLocalizations strings) =>
      runtime?.typeLabel(strings) ?? rawType;
}

class StrategiesPage extends StatefulWidget {
  const StrategiesPage({
    super.key,
    required this.controller,
    required this.active,
    this.onAdd,
    this.definitions,
    this.definitionActions,
    this.onOpenGroup,
  });
  final StrategyController controller;
  final bool active;
  final VoidCallback? onAdd;
  final List<StrategyDefinition>? definitions;
  final Widget? Function(BuildContext, StrategyDefinition)? definitionActions;

  /// The all-groups overview opens properties rather than the daily member
  /// popup. The main strategy page leaves this null and keeps its selection
  /// and delay-test interaction unchanged.
  final void Function(StrategyDefinition group)? onOpenGroup;

  @override
  State<StrategiesPage> createState() => _StrategiesPageState();
}

class _StrategiesPageState extends State<StrategiesPage> {
  final _scroll = ScrollController();
  final _viewport = GlobalKey();
  final _header = GlobalKey();
  final _headerContent = GlobalKey();
  static const _top = ValueKey('strategies-top');
  static const _center = ValueKey('strategies-center');
  final _cardKeys = <String, GlobalKey>{};
  final _keyNames = <Key, String>{};
  Map<String, int> _indices = {};
  List<String> _ids = [];
  _StrategyGridMetrics? _layout;
  _StrategyGridMetrics? _motionLayout;
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
    widget.controller.addListener(_feedbackChanged);
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
      oldWidget.controller.removeListener(_feedbackChanged);
      widget.controller.addListener(_feedbackChanged);
      _searchGeneration++;
    }
    _syncSearchFocus();
  }

  void _syncSearchFocus() {
    final visible = _pageInteractive && !_memberOpen;
    if (_searchVisible != visible) {
      _searchVisible = visible;
      _searchGeneration++;
    }
    _searchFocus.canRequestFocus = visible && _searching;
  }

  bool _ownsSearch(StrategyController owner, int epoch, int generation) =>
      _pageInteractive &&
      !_memberOpen &&
      identical(widget.controller, owner) &&
      owner.app.storageEpoch == epoch &&
      _searchGeneration == generation;

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
                    widget.controller.allGroups
                        ? strings.allStrategyGroups
                        : strings.strategyGroups,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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

  _StrategyGridMetrics _measureGrid(
    BuildContext context,
    double extent,
    List<StrategyDefinition> groups,
  ) {
    final strings = AppLocalizations.of(context);
    final controller = widget.controller;
    final text = Theme.of(context).textTheme;
    final nameStyle = text.bodyLarge!.copyWith(
      height: 1.2,
      fontWeight: FontWeight.w600,
    );
    final typeStyle = text.bodySmall!;
    final currentStyle = text.bodySmall!.copyWith(height: 1.3);
    final defaultStyle = DefaultTextStyle.of(context).style;
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.localeOf(context),
      maxLines: 1,
    );
    double lineHeight(String value, TextStyle style) {
      painter.text = TextSpan(text: value, style: defaultStyle.merge(style));
      painter.layout();
      return painter.height;
    }

    painter.text = TextSpan(text: 'MMMM', style: defaultStyle.merge(nameStyle));
    painter.layout();
    final statusWidth = StrategyCardStatus.width(context);
    final minimum =
        statusWidth + painter.width.clamp(56.0, double.infinity) + 48;
    final columns = ((extent + 12) / (minimum + 12)).floor().clamp(1, 4);
    final width = (extent - (columns - 1) * 12) / columns;
    final inlineStatus = width >= minimum;
    final nameHeight = 2 * lineHeight(strings.strategyGroups, nameStyle);
    final typeHeight = lineHeight(strings.strategyGroups, typeStyle);
    final attributesHeight = typeHeight.clamp(20.0, double.infinity);
    final currentNames = {
      strings.unconfirmed,
      for (final group in groups)
        if (group.selectable && group.now.isNotEmpty) group.now,
    };
    painter
      ..text = TextSpan(
        text: currentNames.join('\n'),
        style: defaultStyle.merge(currentStyle),
      )
      ..maxLines = null
      ..layout();
    final currentHeight = painter.computeLineMetrics().fold<double>(
      0,
      (height, line) => line.height > height ? line.height : height,
    );
    painter.dispose();
    final delayHeight = StrategyCardStatus.height(context);
    final topHeight = typeHeight > 30 ? typeHeight : 30.0;
    final footerHeight = controller.allGroups
        ? (currentHeight > 48 ? currentHeight : 48.0)
        : (currentHeight > delayHeight ? currentHeight : delayHeight);
    final height =
        27 +
        topHeight +
        10 +
        nameHeight +
        (controller.allGroups ? attributesHeight : 0) +
        2 +
        footerHeight +
        (!controller.allGroups && !inlineStatus ? delayHeight : 0);
    return (
      attributesHeight: attributesHeight,
      statusWidth: statusWidth,
      minimum: minimum,
      columns: columns,
      width: width,
      inlineStatus: inlineStatus,
      nameHeight: nameHeight,
      height: height,
    );
  }

  void _captureCardMotion(_StrategyGridMetrics layout) {
    if (_motionLayout == layout) return;
    _motionLayout = layout;
    void capture(RenderObject render) {
      if (render is _RenderStrategyCardGeometry) {
        render._captureVisual();
      } else {
        render.visitChildren(capture);
      }
    }

    // Capture before either lazy consumer rebases or regroups existing cells.
    for (final key in _cardKeys.values) {
      final render = key.currentContext?.findRenderObject();
      if (render != null && render.attached) capture(render);
    }
  }

  // Rebase the SDK viewport on a surviving visible card before layout.
  void _prepareGrid(
    _StrategyGridMetrics layout,
    List<StrategyDefinition> groups,
  ) {
    final ids = groups.map((group) => group.id).toList();
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
    widget.controller.removeListener(_feedbackChanged);
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
        widget.active && (_memberOpen || AppTaskActivity.isVisible(context)),
      );
    });
  }

  bool get _pageInteractive =>
      mounted &&
      widget.active &&
      widget.controller.app.interactive &&
      AppTaskActivity.isActive(context) &&
      AppTaskActivity.routeIsActive(ModalRoute.of(context));

  Future<void> _openGroup(StrategyDefinition group, BuildContext anchor) async {
    if (!_pageInteractive || _memberOpen) {
      return;
    }
    if (widget.controller.allGroups) {
      // Diagnostic group cards open properties and reserve their slot for attributes.
      widget.onOpenGroup?.call(group);
      return;
    }
    if (!identical(widget.controller.data?.find(group.name), group.runtime)) {
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
        ownerContext: context,
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
    enabled: _pageInteractive,
    shortcutsEnabled: !_memberOpen,
    onSearch: () => _enterSearch(
      widget.controller,
      widget.controller.app.storageEpoch,
      _searchGeneration,
    ),
    onEscape: _searching ? _exitSearch : null,
    child: ExcludeSemantics(
      excluding: !_pageInteractive,
      child: ExcludeFocus(
        excluding: !_pageInteractive,
        child: IgnorePointer(
          ignoring: !_pageInteractive,
          child: _content(context),
        ),
      ),
    ),
  );

  Object? _noticeSource;
  bool _readNoticed = false;
  Object? _unrestoredNoticed;

  void _feedbackChanged() {
    final controller = widget.controller;
    final app = controller.app;
    final source = (app.storageEpoch, app.state.core.identity);
    if (source != _noticeSource) {
      _noticeSource = source;
      _readNoticed = false;
    }
    final read =
        controller.readErrorMessage ??
        app.state.core.errorMessage ??
        app.platformErrorMessage;
    if (read == null) _readNoticed = false;
    final message = !_readNoticed ? read : null;
    if (message != null && _pageInteractive) {
      _readNoticed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pageInteractive || _noticeSource != source) return;
        showAppNotice(
          context,
          message,
          isCurrent: () => mounted && widget.active && _noticeSource == source,
          isCurrentWithPopup: (popup) =>
              mounted &&
              widget.active &&
              app.foreground &&
              _noticeSource == source &&
              AppTaskActivity.isActive(context, ownedPopup: popup) &&
              AppTaskActivity.routeIsActive(
                ModalRoute.of(context),
                ownedPopup: popup,
              ),
          eligibilityChanges: controller,
          onRetry: controller.retry,
        );
      });
    }
    final data = controller.data;
    if (data == null || data.unrestored.isEmpty || !_pageInteractive) return;
    final unrestored = (source, jsonEncode(data.unrestored));
    if (_unrestoredNoticed == unrestored) return;
    _unrestoredNoticed = unrestored;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageInteractive || _noticeSource != source) return;
      showLocalizedOperationNotice(
        context,
        (strings) => strings.selectionsNotRestored,
        technicalDetail: (strings) => data.unrestored.entries
            .map(
              (entry) => strings.unrestoredLine(
                entry.key,
                strategyUnrestoredReason(entry.value, strings),
              ),
            )
            .join('\n'),
        isCurrent: () => mounted && widget.active && _noticeSource == source,
        isCurrentWithPopup: (popup) =>
            mounted &&
            widget.active &&
            app.foreground &&
            _noticeSource == source &&
            AppTaskActivity.isActive(context, ownedPopup: popup) &&
            AppTaskActivity.routeIsActive(
              ModalRoute.of(context),
              ownedPopup: popup,
            ),
        eligibilityChanges: controller,
      );
    });
  }

  Widget _sizeHeader(BuildContext context, {required Widget child}) =>
      MediaQuery.disableAnimationsOf(context)
      ? child
      : AnimatedSize(
          alignment: Alignment.topLeft,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: child,
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
        final visibleGroups =
            widget.definitions ??
            controller.groups
                .map((group) => StrategyDefinition(runtime: group))
                .toList();
        final groups = _query.isEmpty
            ? visibleGroups
            : visibleGroups
                  .where((group) => group.name.toLowerCase().contains(_query))
                  .toList();
        final data = controller.data;
        final searchGeneration = _searchGeneration;
        final searchEpoch = app.storageEpoch;
        return PopScope<void>(
          canPop: !widget.active || !_searching,
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
                    onPressed: app.canEdit
                        ? () {
                            if (_pageInteractive &&
                                app.storageEpoch == searchEpoch) {
                              widget.onAdd?.call();
                            }
                          }
                        : null,
                    color: Theme.of(context).colorScheme.primary,
                    icon: const Icon(Icons.add),
                  )
                else
                  IconButton(
                    tooltip: controller.showHidden
                        ? strings.hideHiddenGroups
                        : strings.showHiddenGroups,
                    isSelected: controller.showHidden,
                    onPressed: () {
                      if (_pageInteractive && app.storageEpoch == searchEpoch) {
                        controller.setShowHidden(!controller.showHidden);
                      }
                    },
                    color: HomePalette.of(context).moreAction,
                    icon: const Icon(Icons.visibility_off_outlined),
                    selectedIcon: const Icon(Icons.visibility_outlined),
                  ),
              ],
              title: _searchTitle(strings),
            ),
            body: SafeArea(
              top: false,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final layout = _measureGrid(
                    context,
                    (constraints.maxWidth - 40).clamp(0.0, double.infinity),
                    visibleGroups,
                  );
                  _captureCardMotion(layout);
                  if (!controller.allGroups) _prepareGrid(layout, groups);
                  final (
                    :attributesHeight,
                    :statusWidth,
                    :minimum,
                    :columns,
                    :width,
                    :inlineStatus,
                    :nameHeight,
                    :height,
                  ) = layout;
                  Widget card(BuildContext anchor, StrategyDefinition group) {
                    final hidden =
                        _openName == group.name &&
                        _openGeneration == core.generation;
                    final inlineStatus = width >= minimum;
                    final cardStatus = StrategyCardStatus(
                      key: ValueKey('strategy-status-${group.id}'),
                      slotWidth: statusWidth.clamp(0.0, width - 28).toDouble(),
                      result: group.runtime == null
                          ? null
                          : controller.cardDelay(group.runtime!),
                      rejected:
                          controller.current &&
                          group.selectable &&
                          group.members.any(
                            (member) =>
                                member.name == group.now &&
                                member.type == 'Reject',
                          ),
                    );
                    return _StrategyCardMotion(
                      key: ValueKey('strategy-motion-${group.id}'),
                      geometry: layout,
                      reducedMotion: MediaQuery.disableAnimationsOf(context),
                      child: ExcludeSemantics(
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
                              key: ValueKey('strategy-group-${group.id}'),
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
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.end,
                                            style: Theme.of(anchor)
                                                .textTheme
                                                .bodySmall!
                                                .copyWith(
                                                  color:
                                                      colors.onSurfaceVariant,
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
                                            'strategy-name-${group.id}',
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(anchor)
                                              .textTheme
                                              .bodyLarge!
                                              .copyWith(
                                                height: 1.2,
                                                fontWeight: FontWeight.w600,
                                              ),
                                        ),
                                      ),
                                    ),
                                    if (controller.allGroups)
                                      SizedBox(
                                        key: ValueKey(
                                          'strategy-attributes-${group.id}',
                                        ),
                                        width: double.infinity,
                                        height: attributesHeight,
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
                                              style: Theme.of(anchor)
                                                  .textTheme
                                                  .bodySmall!
                                                  .copyWith(
                                                    color:
                                                        colors.onSurfaceVariant,
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
                                            group.selectable
                                                ? (group.now.isEmpty
                                                      ? strings.unconfirmed
                                                      : group.now)
                                                : '',
                                            key: ValueKey(
                                              'strategy-current-${group.id}',
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(anchor)
                                                .textTheme
                                                .bodySmall!
                                                .copyWith(
                                                  height: 1.3,
                                                  color:
                                                      colors.onSurfaceVariant,
                                                ),
                                          ),
                                        ),
                                        if (controller.allGroups) ...[
                                          ?widget.definitionActions?.call(
                                            anchor,
                                            group,
                                          ),
                                        ] else ...[
                                          if (inlineStatus) ...[
                                            const SizedBox(width: 4),
                                            cardStatus,
                                          ],
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
                              group.id,
                              GlobalKey.new,
                            );
                            _keyNames[key] = group.name;
                            return KeyedSubtree(
                              key: key,
                              child: SizedBox(
                                key: ValueKey('strategy-card-${group.id}'),
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

                  final header = _sizeHeader(
                    context,
                    child: Padding(
                      key: _headerContent,
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                      child: Column(
                        key: _header,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!controller.allGroups)
                            Text(
                              config?.name ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall!
                                  .copyWith(color: colors.onSurfaceVariant),
                            ),
                          if (data == null && controller.loading)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(strings.coreReadLoading),
                            ),
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
                    ),
                  );
                  if (controller.allGroups) {
                    final names = groups
                        .map((group) => group.readingId)
                        .toSet();
                    _cardKeys.removeWhere((name, _) => !names.contains(name));
                    Object groupId(StrategyDefinition group) =>
                        group.runtime == null
                        ? group.readingId
                        : (
                            'runtime-group',
                            data?.generation,
                            data?.composition,
                            group.readingId,
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
                                                          .readingId,
                                                      GlobalKey.new,
                                                    ),
                                                    child: SizedBox(
                                                      key: ValueKey(
                                                        'strategy-card-${groups[start + column].id}',
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

/// Animate only mounted cards' visual geometry. The SDK grid/ReadingList remains
/// lazy and owns final layout, scroll anchoring and the one business subtree.
class _StrategyCardMotion extends StatefulWidget {
  const _StrategyCardMotion({
    super.key,
    required this.geometry,
    required this.reducedMotion,
    required this.child,
  });
  final Object geometry;
  final bool reducedMotion;
  final Widget child;

  @override
  State<_StrategyCardMotion> createState() => _StrategyCardMotionState();
}

class _StrategyCardMotionState extends State<_StrategyCardMotion>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: 1,
  );

  @override
  void didUpdateWidget(_StrategyCardMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reducedMotion) {
      _animation.value = 1;
    } else if (widget.geometry != oldWidget.geometry) {
      _animation.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) => _StrategyCardGeometry(
    geometry: widget.geometry,
    reducedMotion: widget.reducedMotion,
    animation: _animation,
    retarget: (begin) => WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      begin();
    }),
    child: widget.child,
  );

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }
}

class _StrategyCardGeometry extends SingleChildRenderObjectWidget {
  const _StrategyCardGeometry({
    required this.geometry,
    required this.reducedMotion,
    required this.animation,
    required this.retarget,
    required super.child,
  });
  final Object geometry;
  final bool reducedMotion;
  final Animation<double> animation;
  final void Function(VoidCallback begin) retarget;

  @override
  _RenderStrategyCardGeometry createRenderObject(BuildContext context) =>
      _RenderStrategyCardGeometry(this);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderStrategyCardGeometry renderObject,
  ) => renderObject.update(this);
}

class _RenderStrategyCardGeometry extends RenderProxyBox {
  _RenderStrategyCardGeometry(_StrategyCardGeometry widget) : _widget = widget;
  _StrategyCardGeometry _widget;
  Rect? _visual;
  Rect? _target;
  Rect? _from;
  Matrix4 _transform = Matrix4.identity();
  bool _retarget = false;
  bool _pending = false;
  int _revision = 0;

  void _captureVisual() {
    if (!attached || !hasSize || _visual == null) return;
    // A clean ancestor layer may have moved without repainting this object.
    _visual = MatrixUtils.transformRect(
      getTransformTo(null)..multiply(_transform),
      Offset.zero & size,
    );
  }

  void update(_StrategyCardGeometry widget) {
    if (_widget.geometry != widget.geometry) _retarget = true;
    _widget = widget;
    if (widget.reducedMotion) {
      _from = null;
      _retarget = _pending = false;
      _revision++;
    }
    markNeedsPaint();
  }

  void _tick() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _widget.animation.addListener(_tick);
  }

  @override
  void detach() {
    _widget.animation.removeListener(_tick);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final target = localToGlobal(Offset.zero) & size;
    if (_retarget && _visual != null && !_widget.reducedMotion) {
      _from = _visual;
      _pending = true;
      final revision = ++_revision;
      _widget.retarget(() {
        if (attached && revision == _revision) {
          _pending = false;
          _tick();
        }
      });
    } else if (_from != null && _target != null) {
      // Scrolling and IME translation follow the viewport directly, rather than
      // becoming another animation. Only a capacity change rebases the tween.
      _from = _from!.shift(target.topLeft - _target!.topLeft);
    }
    _retarget = false;
    _target = target;
    final progress = _pending
        ? 0.0
        : Curves.easeOutCubic.transform(_widget.animation.value);
    final atRest =
        _from == null || _widget.reducedMotion || (!_pending && progress == 1);
    final visual = _visual = atRest
        ? target
        : Rect.lerp(_from, target, progress)!;
    if (!_pending && progress == 1) _from = null;
    _transform = atRest
        ? Matrix4.identity()
        : (Matrix4.translationValues(
            visual.left - target.left,
            visual.top - target.top,
            0,
          )..scaleByDouble(
            size.width == 0 ? 1.0 : visual.width / size.width,
            size.height == 0 ? 1.0 : visual.height / size.height,
            1.0,
            1.0,
          ));
    context.pushTransform(needsCompositing, offset, _transform, super.paint);
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.multiply(_transform);

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // The lazy sliver indexes hits using final cells. A travelling card must not
    // turn a positional tap into an action on another cell's business identity.
    if (_pending || _from != null) return false;
    return result.addWithPaintTransform(
      transform: _transform,
      position: position,
      hitTest: (result, position) => super.hitTest(result, position: position),
    );
  }
}
