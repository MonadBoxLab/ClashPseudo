import '../../components/feedback/operation_notice.dart';

import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'package:flutter/material.dart';

import '../../components/input/task_shortcuts.dart';
import '../../components/input/toolbar_search_field.dart';

import '../../app/app_controller.dart';
import '../../navigation/task_activity.dart';
import '../../theme/app_theme.dart';
import '../../components/collections/reading_list.dart';
import '../../../l10n/app_localizations.dart';
import '../../overrides/definitions/local_custom_editor.dart';
import '../../../logic/overrides/local_yaml_edit.dart';
import '../../components/collections/collection_workspace.dart';
import 'nodes_controller.dart';
import '../result_page_bar.dart';

class NodesPage extends StatefulWidget {
  const NodesPage({
    super.key,
    required this.app,
    this.provider,
    this.expectedSource,
  });
  final AppController app;
  final String? provider;
  final CoreSnapshot? expectedSource;
  @override
  State<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<NodesPage> {
  late final _controller = NodesController(
    widget.app,
    provider: widget.provider,
    expectedSource: widget.expectedSource,
  );
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  final _workspace = GlobalKey<CollectionWorkspaceState>();
  Map<String, dynamic>? _selected;
  Key? _detailKey;
  CoreSnapshot? _selectedSource;
  int? _selectedEpoch;
  bool _selectionExpired = false;

  Object _nodeIdentity(Map<String, dynamic> node) =>
      _local.readingIdentity(node) ??
      (node['sourceKind'], node['source'], node['name']);

  LocalDefinitionCollection _local = const LocalDefinitionCollection();
  String? _scheduledDefinitions;
  Object? _noticeSource;
  bool _readNoticed = false;

  void _readFeedback() {
    final identity = (widget.app.storageEpoch, widget.app.state.core.identity);
    if (_noticeSource != identity) {
      _noticeSource = identity;
      _readNoticed = false;
    }
    final error =
        _controller.readError ??
        widget.app.platformErrorMessage ??
        widget.app.state.core.errorMessage ??
        widget.app.commandErrorMessage;
    if (error == null) {
      _readNoticed = false;
      return;
    }
    if (_readNoticed || !_pageLive) return;
    _readNoticed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageLive || _noticeSource != identity) return;
      showAppNotice(
        context,
        error,
        isCurrent: () => _pageLive && _noticeSource == identity,
        isCurrentWithPopup: (popup) =>
            _masterWithPopup(popup) && _noticeSource == identity,
        eligibilityChanges: _controller,
        onRetry: _controller.refresh,
      );
    });
  }

  Widget _definitions(BuildContext context) {
    if (widget.provider != null) return _content(context);
    return LocalDefinitions(
      app: widget.app,
      sections: const {LocalYamlSection.proxies},
      builder: (context, local) {
        _local = local;
        if (_scheduledDefinitions != local.identity) {
          _scheduledDefinitions = local.identity;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _local.identity == local.identity) {
              _controller.setDefinitions(local.identity, local.rows);
            }
          });
        }
        return _content(context);
      },
    );
  }

  void _closeDetails() => setState(() => _selected = null);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_readFeedback);
    _controller.setVisible(true);
  }

  ModalRoute<dynamic>? _route;

  bool get _pageLive =>
      mounted &&
      widget.app.foreground &&
      AppTaskActivity.isActive(context) &&
      (_route?.isCurrent ?? true) &&
      _route?.animation?.status != AnimationStatus.reverse;
  bool get _masterLive =>
      _pageLive && (_workspace.currentState?.masterVisible ?? true);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_route != route) {
      _route?.animation?.removeListener(_syncVisibility);
      _route = route;
      route?.animation?.addListener(_syncVisibility);
    }
    _syncVisibility();
  }

  bool _visibilityScheduled = false;
  void _syncVisibility() {
    if (!mounted || _visibilityScheduled) return;
    _visibilityScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityScheduled = false;
      if (!mounted) return;
      _controller.setVisible(_pageLive);
      if (!_pageLive) _searchFocus.unfocus();
    });
  }

  bool _masterWithPopup(ModalRoute<dynamic> popup) =>
      mounted &&
      widget.app.foreground &&
      AppTaskActivity.isActive(context, ownedPopup: popup) &&
      AppTaskActivity.routeIsActive(_route, ownedPopup: popup) &&
      _workspace.currentState?.masterPresented == true;

  @override
  void dispose() {
    _route?.animation?.removeListener(_syncVisibility);
    _controller.removeListener(_readFeedback);
    _controller.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _page(bool next) async {
    if (!_masterLive) return;
    if (next) {
      await _controller.next();
    } else {
      await _controller.previous();
    }
    if (_masterLive && _controller.current && _scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  void _details(Map<String, dynamic> node) {
    if (!_masterLive) return;
    _searchFocus.unfocus();
    setState(() {
      _detailKey = UniqueKey();
      _selected = node;
      _selectedSource = _controller.source;
      _selectedEpoch = widget.app.storageEpoch;
      _selectionExpired = false;
    });
    final failures = <String>[];
    void collect(Object? history, String target) {
      if (history is! List) return;
      for (final sample in history.whereType<Map>()) {
        if (sample['delay'] is num && (sample['delay'] as num) <= 0) {
          final time = sample['time'];
          failures.add('$target · ${time is String ? time : '—'}');
        }
      }
    }

    collect(node['history'], node['name'] as String);
    if (node['extra'] case final Map extra) {
      for (final entry in extra.entries) {
        if (entry.key is String && entry.value is Map) {
          collect((entry.value as Map)['history'], entry.key as String);
        }
      }
    }
    if (failures.isEmpty) return;
    final detailKey = _detailKey;
    bool sameSelection() =>
        mounted &&
        _detailKey == detailKey &&
        _selected != null &&
        _selectedEpoch == widget.app.storageEpoch &&
        !_selectionExpired &&
        _nodeIdentity(_selected!) == _nodeIdentity(node) &&
        _selectedSource?.matchesIdentity(widget.app.state.core) == true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!sameSelection() ||
          !_pageLive ||
          _workspace.currentState?.detailVisible != true) {
        return;
      }
      showLocalizedOperationNotice(
        context,
        (strings) => strings.nodeDelayHistoryFailed,
        technicalDetail: (_) => failures.join('\n'),
        identity: (detailKey, 'delay-history'),
        eligibilityChanges: Listenable.merge([widget.app, _controller]),
        isCurrent: () =>
            sameSelection() &&
            _pageLive &&
            _workspace.currentState?.detailVisible == true,
        isCurrentWithPopup: (popup) =>
            sameSelection() &&
            widget.app.foreground &&
            AppTaskActivity.isActive(context, ownedPopup: popup) &&
            AppTaskActivity.routeIsActive(_route, ownedPopup: popup) &&
            _workspace.currentState?.detailPresented == true,
      );
    });
  }

  Widget _nodeDetails(BuildContext context, Map<String, dynamic> node) {
    final detailKey = _detailKey;
    bool current() =>
        mounted &&
        context.mounted &&
        _pageLive &&
        _workspace.currentState?.detailVisible == true &&
        _selected != null &&
        _detailKey == detailKey &&
        CollectionWorkspace.paneActiveOf(context, listen: false);
    final properties = node['definition'] as Map? ?? node;
    final strings = AppLocalizations.of(context);
    return Scaffold(
      key: _detailKey,
      appBar: AppBar(
        leading: BackButton(
          onPressed: () {
            if (current()) _closeDetails();
          },
        ),
        title: Text(strings.details),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SelectableText(
                node['name'].toString(),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              ?_local.actions(context, node),
              const SizedBox(height: 16),
              for (final (key, label) in [
                ('type', strings.proxyFormType),
                ('source', strings.provenanceProviderHeading),
              ])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(label),
                  subtitle: SelectableText(
                    node[key] is String && (node[key] as String).isNotEmpty
                        ? node[key] as String
                        : strings.notProvided,
                  ),
                ),
              const Divider(),
              for (final (key, label) in [
                ('udp', 'UDP'),
                ('uot', 'UDP over TCP'),
                ('xudp', 'XUDP'),
                ('tfo', 'TCP Fast Open'),
                ('mptcp', 'MPTCP'),
                ('smux', 'SMUX'),
              ])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(label),
                  subtitle: SelectableText(switch (properties[key]) {
                    true => strings.proxyTrue,
                    false => strings.proxyFalse,
                    _ => strings.notProvided,
                  }),
                ),
              const Divider(),
              ..._historyRows(context, switch (properties['history']) {
                List value => value,
                _ => const [],
              }),
              for (final entry in switch (properties['extra']) {
                Map value => value.entries,
                _ => const <MapEntry>[],
              })
                if (entry.key is String && entry.value is Map) ...[
                  const Divider(),
                  SelectableText(entry.key as String),
                  ..._historyRows(context, switch ((entry.value
                      as Map)['history']) {
                    List value => value,
                    _ => const [],
                  }),
                ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _historyRows(BuildContext context, List history) {
    final strings = AppLocalizations.of(context);
    if (history.isEmpty) return [Text(strings.notProvided)];
    return [
      for (final sample in history)
        if (sample is Map &&
            sample['delay'] is int &&
            (sample['delay'] as int) > 0)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: SelectableText(
              sample['time']?.toString() ?? strings.notProvided,
            ),
            subtitle: SelectableText('${sample['delay']} ms'),
          ),
    ];
  }

  Future<void> _localCustom(int storageEpoch) async {
    if (!_masterLive) return;
    final origin = _route;
    _controller.setVisible(false);
    try {
      await showLocalCustomForm(
        context,
        app: widget.app,
        section: LocalYamlSection.proxies,
        storageEpoch: storageEpoch,
        isContextCurrent: () =>
            mounted &&
            (origin?.isActive ?? true) &&
            origin?.animation?.status != AnimationStatus.reverse &&
            storageEpoch == widget.app.storageEpoch,
      );
    } finally {
      if (mounted) _syncVisibility();
    }
  }

  void _searchTask() {
    if (!_pageLive) return;
    _workspace.currentState?.showMaster();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _masterLive && widget.app.interactive) {
        _searchFocus.requestFocus();
      }
    });
  }

  void _escape() {
    if (!_pageLive) return;
    if (_workspace.currentState?.showingDetail == true) {
      _closeDetails();
    } else if (_searchFocus.hasFocus) {
      _searchFocus.unfocus();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) => TaskShortcuts(
    onSearch: _searchTask,
    onEscape: _escape,
    child: _definitions(context),
  );

  Widget _content(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final strings = AppLocalizations.of(context);
      final storageEpoch = widget.app.storageEpoch;
      var inList = false;
      if (_selected case final selected?) {
        _selectionExpired |=
            _selectedEpoch != storageEpoch ||
            (selected.containsKey('entryId')
                ? !_local.rows.any(
                    (row) =>
                        row['localDefinition'] == selected['localDefinition'],
                  )
                : _selectedSource?.matchesIdentity(widget.app.state.core) !=
                      true);
        if (!_selectionExpired && _controller.current) {
          final current = _controller.nodes
              .where((row) => _nodeIdentity(row) == _nodeIdentity(selected))
              .firstOrNull;
          inList = current != null;
          if (current != null) {
            if (current['sourceVersion'] != selected['sourceVersion']) {
              _selectionExpired = true;
            } else {
              _selected = current;
            }
          }
        }
      }
      final canWrite =
          widget.app.canEdit &&
          widget.app.overridesLoaded &&
          widget.app.overrideErrorMessage == null;
      final status = _controller.sourceExpired
          ? strings.coreSnapshotStale
          : _controller.loading || widget.app.busy
          ? strings.coreReadLoading
          : _controller.failed
          ? strings.coreReadFailed
          : !_controller.current
          ? (_controller.nodes.isEmpty
                ? strings.runtimeConfigEmpty
                : strings.coreSnapshotStale)
          : _controller.preview
          ? strings.runtimeConfigPreview
          : strings.runtimeConfigLive;
      final subtitleStyle = Theme.of(context).textTheme.bodySmall!
          .copyWith(height: 1.5);
      final subtitleStrut = StrutStyle.fromTextStyle(
        subtitleStyle,
        forceStrutHeight: true,
      );
      final subtitleMeasure = TextPainter(
        text: TextSpan(text: 'Ag', style: subtitleStyle),
        strutStyle: subtitleStrut,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
      )..layout();
      final subtitleHeight = subtitleMeasure.height * 2;
      subtitleMeasure.dispose();
      Widget content() => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: ReadingList(
            controller: _scroll,
            identity: (
              storageEpoch,
              widget.provider,
              _controller.search,
              _controller.offset,
            ),
            header: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ToolbarSearchField(
                    enabled:
                        widget.provider == null || !_controller.sourceExpired,
                    controller: _search,
                    focusNode: _searchFocus,
                    hintText: strings.nodeSearch,
                    onChanged: _controller.filter,
                  ),
                ],
              ),
            ),
            items: [
              if (_controller.nodes.isEmpty && _controller.current)
                ReadingListItem(
                  id: 'runtime-empty',
                  builder: (context) => Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(strings.noNodes),
                  ),
                ),
              for (final node in _controller.nodes)
                ReadingListItem(
                  id: node.containsKey('entryId')
                      ? _nodeIdentity(node)
                      : (
                          'runtime-node',
                          _controller.source?.generation,
                          _controller.source?.composition,
                          _nodeIdentity(node),
                        ),
                  builder: (context) {
                    final source = node['source']?.toString() ?? '';
                    final fromProvider = node['sourceKind'] == 'proxyProvider';
                    final description = [
                      node['type'].toString(),
                      if (node['builtin'] == true)
                        strings.builtinNode
                      else if (fromProvider)
                        source.isEmpty ? '""' : source,
                    ].join(' · ');
                    final selected =
                        !_selectionExpired &&
                        _selected != null &&
                        _nodeIdentity(node) == _nodeIdentity(_selected!) &&
                        node['sourceVersion'] == _selected!['sourceVersion'];
                    final colors = Theme.of(context).colorScheme;
                    return ListTile(
                      key: ValueKey(_nodeIdentity(node)),
                      selected: selected,
                      selectedTileColor: Theme.of(context)
                          .colorScheme
                          .secondaryContainer,
                      selectedColor: Theme.of(context)
                          .colorScheme
                          .onSecondaryContainer,
                      leading: Icon(
                        node['builtin'] == true
                            ? Icons.settings_ethernet
                            : Icons.dns_outlined,
                        color: SettingsPalette(
                          Theme.of(context).brightness == Brightness.dark,
                        ).network,
                      ),
                      title: Text(
                        node['name'].toString(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: SizedBox(
                        height: subtitleHeight,
                        child: Text(
                          description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: subtitleStyle.copyWith(
                            color: selected
                                ? colors.onSecondaryContainer
                                : colors.onSurfaceVariant,
                          ),
                          strutStyle: subtitleStrut,
                        ),
                      ),
                      trailing:
                          _local.actions(context, node) ??
                          const Icon(Icons.chevron_right),
                      onTap: () => _details(node),
                    );
                  },
                ),
            ],
          ),
        ),
      );
      return CollectionWorkspace(
        key: _workspace,
        onClose: _closeDetails,
        active: _pageLive,
        detail: _selected == null
            ? null
            : Builder(
                key: _detailKey,
                builder: (context) => _nodeDetails(context, _selected!),
              ),
        detailStatus: _selectionExpired
            ? strings.coreSnapshotStale
            : _controller.current && !inList
            ? strings.selectionOutsideList
            : status,
        master: Scaffold(
          appBar: AppBar(
            title: Text(
              widget.provider == null
                  ? strings.proxyNodes
                  : widget.provider!.isEmpty
                  ? '""'
                  : widget.provider!,
            ),
            actions: [
              const CollectionDetailsAction(),
              if (widget.provider == null) ...[
                IconButton(
                  key: const ValueKey('local-custom-add'),
                  tooltip: strings.proxyFormTitle,
                  onPressed: canWrite ? () => _localCustom(storageEpoch) : null,
                  color: Theme.of(context).colorScheme.primary,
                  icon: const Icon(Icons.add),
                ),
              ],
            ],
          ),
          body: content(),
          bottomNavigationBar: Align(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: ResultPageBar(
                label:
                    _controller.loading ||
                        widget.app.busy ||
                        !(_controller.current || _controller.localCurrent)
                    ? '—'
                    : _controller.total == 0
                    ? strings.resultCount(0)
                    : strings.resultRange(
                        _controller.offset + 1,
                        _controller.offset + _controller.nodes.length,
                        _controller.total,
                      ),
                onPrevious: _controller.canPage && _controller.offset > 0
                    ? () => _page(false)
                    : null,
                onNext: _controller.canPage && _controller.nextOffset >= 0
                    ? () => _page(true)
                    : null,
              ),
            ),
          ),
        ),
      );
    },
  );
}
