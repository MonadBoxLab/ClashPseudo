import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'package:flutter/material.dart';

import '../../app/widgets/task_shortcuts.dart';

import '../../app/app_controller.dart';
import '../../app/app_theme.dart';
import '../../app/widgets/reading_list.dart';
import '../../app/widgets/provenance_details.dart';
import '../../l10n/app_localizations.dart';
import '../../model/definition_provenance.dart';
import '../overrides/local_custom_editor.dart';
import '../overrides/local_yaml_edit.dart';
import '../../app/widgets/collection_workspace.dart';
import 'nodes_controller.dart';
import 'result_page_bar.dart';

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
      (node['sourceKind'], node['source'], node['name']);

  void _closeDetails() => setState(() => _selected = null);

  @override
  void initState() {
    super.initState();
    _controller.setVisible(true);
  }

  @override
  void dispose() {
    _controller.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _page(bool next) async {
    if (next) {
      await _controller.next();
    } else {
      await _controller.previous();
    }
    if (mounted && _controller.current && _scroll.hasClients) _scroll.jumpTo(0);
  }

  void _details(Map<String, dynamic> node) {
    _searchFocus.unfocus();
    setState(() {
      _detailKey = UniqueKey();
      _selected = node;
      _selectedSource = _controller.source;
      _selectedEpoch = widget.app.storageEpoch;
      _selectionExpired = false;
    });
  }

  Widget _nodeDetails(Map<String, dynamic> node) {
    final strings = AppLocalizations.of(context);
    return Scaffold(
      key: _detailKey,
      appBar: AppBar(
        leading: BackButton(onPressed: _closeDetails),
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
                node['name'] as String,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(strings.nodeHistoryNotice),
              ProvenanceDetails(
                provenance: node['provenance'] as DefinitionProvenance?,
              ),
              ProvenanceDetails(
                provenance: node['providerProvenance'] as DefinitionProvenance?,
                providerDefinition: true,
              ),
              const SizedBox(height: 16),
              Text(strings.nodeRuntimePropertiesOnly),
              const SizedBox(height: 12),
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
                  subtitle: SelectableText(switch (node[key]) {
                    true => strings.proxyTrue,
                    false => strings.proxyFalse,
                    _ => strings.notProvided,
                  }),
                ),
              const Divider(),
              ..._historyRows(context, node['history'] as List? ?? const []),
              for (final test in node['tests'] as List? ?? const [])
                if (test is Map) ...[
                  const Divider(),
                  SelectableText(
                    test['target'] as String? ?? strings.notProvided,
                  ),
                  if (test['alive'] is bool)
                    Text(
                      test['alive'] == true
                          ? strings.proxyTrue
                          : strings.proxyFalse,
                    ),
                  ..._historyRows(
                    context,
                    test['history'] as List? ?? const [],
                  ),
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
        if (sample is Map)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: SelectableText(
              sample['time'] as String? ?? strings.notProvided,
            ),
            subtitle: SelectableText(
              sample['delay'] is int && (sample['delay'] as int) > 0
                  ? '${sample['delay']} ms'
                  : strings.delayFailed,
            ),
          ),
    ];
  }

  Future<void> _localCustom(int storageEpoch) async {
    _controller.setVisible(false);
    try {
      await showLocalCustomForm(
        context,
        app: widget.app,
        section: LocalYamlSection.proxies,
        storageEpoch: storageEpoch,
      );
    } finally {
      if (mounted) _controller.setVisible(true);
    }
  }

  void _searchTask() {
    _workspace.currentState?.showMaster();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          widget.app.interactive &&
          ModalRoute.of(context)?.isCurrent == true) {
        _searchFocus.requestFocus();
      }
    });
  }

  void _escape() {
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
    child: _content(context),
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
            _selectedSource?.matchesIdentity(widget.app.state.core) != true;
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
      Widget content(List<ReadingListItem> local) => Align(
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
                  TextField(
                    enabled:
                        widget.provider == null || !_controller.sourceExpired,
                    controller: _search,
                    focusNode: _searchFocus,
                    onChanged: _controller.filter,
                    decoration: InputDecoration(
                      labelText: strings.nodeSearch,
                      prefixIconColor: WidgetStateColor.resolveWith(
                        (states) => states.contains(WidgetState.disabled)
                            ? Theme.of(context).disabledColor
                            : HomePalette.of(context).moreAction,
                      ),
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: IconButton(
                        tooltip: strings.clearSearch,
                        onPressed: () {
                          _search.clear();
                          _controller.filter('');
                        },
                        icon: const Icon(Icons.close),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Tooltip(
                    message: status,
                    child: Text(
                      status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
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
                  id: (
                    'runtime-node',
                    _controller.source?.generation,
                    _controller.source?.composition,
                    node['sourceKind'],
                    node['source'],
                    node['name'],
                  ),
                  builder: (context) {
                    final source = node['source'] as String;
                    final fromProvider = node['sourceKind'] == 'proxyProvider';
                    final plugin = provenanceSummary(
                      strings,
                      node[fromProvider ? 'providerProvenance' : 'provenance']
                          as DefinitionProvenance?,
                    );
                    final description = [
                      node['type'] as String,
                      if (node['builtin'] == true)
                        strings.builtinNode
                      else if (fromProvider)
                        source.isEmpty ? '""' : source,
                      if (plugin != null)
                        fromProvider
                            ? '$plugin · ${strings.provenanceProviderHeading}'
                            : plugin,
                    ].join(' · ');
                    return ListTile(
                      key: ValueKey((node['sourceKind'], source, node['name'])),
                      selected:
                          !_selectionExpired &&
                          _selected != null &&
                          _nodeIdentity(node) == _nodeIdentity(_selected!) &&
                          node['sourceVersion'] == _selected!['sourceVersion'],
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
                        node['name'] as String,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: SizedBox(
                        height: MediaQuery.textScalerOf(context).scale(14) * 3,
                        child: Text(
                          description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          strutStyle: const StrutStyle(
                            fontSize: 14,
                            height: 1.5,
                            forceStrutHeight: true,
                          ),
                        ),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _controller.current && !_controller.loading
                          ? () => _details(node)
                          : null,
                    );
                  },
                ),
              ...local,
            ],
          ),
        ),
      );
      return CollectionWorkspace(
        key: _workspace,
        onClose: _closeDetails,
        detail: _selected == null ? null : _nodeDetails(_selected!),
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
              IconButton(
                tooltip: strings.refresh,
                onPressed:
                    _controller.active &&
                        !_controller.sourceExpired &&
                        !_controller.loading &&
                        !widget.app.busy
                    ? _controller.refresh
                    : null,
                color: HomePalette.of(context).syncAction,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: widget.provider == null
              ? LocalDefinitions(
                  app: widget.app,
                  sections: const {LocalYamlSection.proxies},
                  query: _controller.search,
                  loadedSource: _controller.current ? _controller.source : null,
                  loadedContributors: [
                    if (_controller.current)
                      for (final node in _controller.nodes)
                        ...?(node['provenance'] as DefinitionProvenance?)
                            ?.contributors,
                  ],
                  builder: (context, local) => content(local),
                )
              : content(const []),
          bottomNavigationBar: Align(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: ResultPageBar(
                label:
                    _controller.loading ||
                        widget.app.busy ||
                        !_controller.current
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
