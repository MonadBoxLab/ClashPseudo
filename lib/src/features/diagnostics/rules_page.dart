import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:flutter/material.dart';

import '../../app/widgets/task_shortcuts.dart';

import '../../app/app_theme.dart';
import '../../app/widgets/reading_list.dart';
import '../../app/widgets/choice_menu_button.dart';

import '../../app/app_controller.dart';
import '../../app/widgets/operation_feedback.dart';
import '../../app/widgets/provenance_details.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/messages.dart';
import '../../model/definition_provenance.dart';
import '../overrides/local_custom_editor.dart';
import '../overrides/local_yaml_edit.dart';
import 'rules_controller.dart';
import '../../app/widgets/collection_workspace.dart';
import 'resources_page.dart';
import 'result_page_bar.dart';

class RulesPage extends StatefulWidget {
  const RulesPage({
    super.key,
    required this.app,
    this.provider,
    this.expectedSource,
  });
  final AppController app;
  final String? provider;
  final CoreSnapshot? expectedSource;
  @override
  State<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<RulesPage> {
  late final _controller = RulesController(
    widget.app,
    provider: widget.provider,
    expectedSource: widget.expectedSource,
  );
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  final _workspace = GlobalKey<CollectionWorkspaceState>();
  bool _opening = false;
  Map<String, dynamic>? _selected;
  Key? _detailKey;
  CoreSnapshot? _selectedSource;
  int? _selectedEpoch;
  (String, String)? _selectedScope;
  String? _selectedSourceToken;
  DefinitionProvenance? _selectedProvenance;
  bool _selectionExpired = false;

  void _closeDetails() => setState(() => _selected = null);

  Future<void> _localCustom(int storageEpoch, CoreSnapshot core) async {
    if (_opening) return;
    if (storageEpoch != widget.app.storageEpoch ||
        storageEpoch != widget.app.state.storageEpoch) {
      await showAppMessage(context, messages.storageContextChanged);
      return;
    }
    final scopes = List<Map<String, dynamic>>.of(_controller.scopes);
    final hasSource = _controller.current;
    setState(() => _opening = true);
    _controller.setVisible(false);
    try {
      final targets = <String>{'DIRECT', 'REJECT'};
      if (core.ready && hasSource) {
        var matches = true;
        try {
          final snapshot = await widget.app.platform
              .strategies(core.generation)
              .timeout(const Duration(seconds: 8));
          matches = snapshot.matches(core);
          if (matches) {
            targets.addAll(snapshot.groups.map((group) => group.name));
          }
        } catch (_) {
          // Local-rule management uses the captured Store/source identity; runtime
          // suggestions are optional.
        }
        if (!mounted) return;
        if (storageEpoch != widget.app.storageEpoch ||
            !core.matchesIdentity(widget.app.state.core) ||
            !matches) {
          await showAppMessage(context, messages.strategyContextChangedRetry);
          return;
        }
      }
      if (!mounted) return;
      await showLocalCustomForm(
        context,
        app: widget.app,
        section: LocalYamlSection.rules,
        storageEpoch: storageEpoch,
        targets: targets.toList(),
        ruleProviders: [
          if (hasSource)
            for (final scope in scopes)
              if (scope['kind'] == 'provider') scope['name'] as String,
        ],
        subRules: [
          if (hasSource)
            for (final scope in scopes)
              if (scope['kind'] == 'sub') scope['name'] as String,
        ],
      );
    } catch (_) {
      if (mounted) {
        await showAppMessage(context, messages.operationNotCompletedRetry);
      }
    } finally {
      if (mounted) {
        setState(() => _opening = false);
        _controller.setVisible(true);
      }
    }
  }

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

  String _scopeLabel(AppLocalizations strings, String kind, String name) =>
      switch (kind) {
        'main' => strings.mainRules,
        'sub' => '${strings.subRules} · $name',
        _ => '${strings.ruleSets} · $name',
      };

  void _select(String kind, String name) {
    final before = (_controller.kind, _controller.name);
    _controller.selectScope(kind, name);
    if (before != (_controller.kind, _controller.name) && _scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  Future<void> _page(bool next) async {
    if (next) {
      await _controller.next();
    } else {
      await _controller.previous();
    }
    if (mounted && _controller.current && _scroll.hasClients) _scroll.jumpTo(0);
  }

  void _details(Map<String, dynamic> row, CoreSnapshot? source) {
    if (source == null ||
        !_controller.current ||
        !source.matchesIdentity(widget.app.state.core)) {
      return;
    }
    _searchFocus.unfocus();
    setState(() {
      _detailKey = UniqueKey();
      _selected = row;
      _selectedSource = source;
      _selectedEpoch = widget.app.storageEpoch;
      _selectedScope = (_controller.kind, _controller.name);
      _selectedSourceToken = _controller.sourceToken;
      _selectedProvenance = _controller.kind == 'provider'
          ? _controller.providerProvenance
          : row['provenance'] as DefinitionProvenance?;
      _selectionExpired = false;
    });
  }

  Widget _ruleDetails(Map<String, dynamic> row, CoreSnapshot source) {
    final resources = List<String>.from(row['resources'] as List? ?? const []);
    final providers = List<String>.from(row['providers'] as List);
    final providerDefinition = _selectedScope?.$1 == 'provider';
    final strings = AppLocalizations.of(context);
    final valid =
        !_selectionExpired &&
        _controller.canPage &&
        source.matchesIdentity(widget.app.state.core);
    return Scaffold(
      key: _detailKey,
      appBar: AppBar(
        leading: BackButton(onPressed: _closeDetails),
        title: Text(strings.details),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${row['index']} · ${row['type']}'),
            const SizedBox(height: 12),
            SelectableText(row['payload'] as String),
            const SizedBox(height: 12),
            Text(
              strings.ruleTarget,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            SelectableText(
              (row['target'] as String).isEmpty ? '—' : row['target'] as String,
            ),
            ProvenanceDetails(
              provenance: _selectedProvenance,
              providerDefinition: providerDefinition,
            ),
            for (final resource in resources)
              TextButton(
                onPressed: valid
                    ? () {
                        _openGeoResource(resource, source);
                      }
                    : null,
                child: Text('${strings.resourceGeo} · $resource'),
              ),
            for (final provider in providers)
              TextButton(
                onPressed: valid
                    ? () {
                        _closeDetails();
                        _select('provider', provider);
                      }
                    : null,
                child: Text('${strings.ruleSets} · $provider'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openGeoResource(String name, CoreSnapshot source) async {
    if (!_controller.current ||
        !source.matchesIdentity(widget.app.state.core)) {
      return;
    }
    _controller.setVisible(false);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ResourcesPage(
          app: widget.app,
          geoName: name,
          expectedSource: source,
        ),
      ),
    );
    if (mounted) _controller.setVisible(true);
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
        final sameScope =
            _selectedScope == (_controller.kind, _controller.name);
        _selectionExpired |=
            _selectedEpoch != storageEpoch ||
            _selectedSource?.matchesIdentity(widget.app.state.core) != true ||
            (_controller.current &&
                sameScope &&
                _selectedSourceToken != _controller.sourceToken);
        if (!_selectionExpired && _controller.current && sameScope) {
          final current = _controller.rows
              .where((row) => row['index'] == selected['index'])
              .firstOrNull;
          inList = current != null;
          if (current != null) {
            _selected = current;
            _selectedProvenance = _controller.kind == 'provider'
                ? _controller.providerProvenance
                : current['provenance'] as DefinitionProvenance?;
          }
        }
      }
      final openingCore = widget.app.state.core;
      final canWrite =
          !_opening &&
          widget.app.canEdit &&
          widget.app.overridesLoaded &&
          widget.app.overrideErrorMessage == null;
      final coreSource = _controller.source;
      final status = _controller.sourceExpired
          ? strings.coreSnapshotStale
          : _controller.loading || widget.app.busy
          ? strings.coreReadLoading
          : _controller.failed
          ? strings.coreReadFailed
          : !_controller.current
          ? (_controller.rows.isEmpty
                ? strings.runtimeConfigEmpty
                : strings.coreSnapshotStale)
          : _controller.preview
          ? strings.runtimeConfigPreview
          : strings.runtimeConfigLive;
      final origin = switch (_controller.origin) {
        'compiled-rules' => strings.compiledRules,
        'normalized-rules' => strings.normalizedRules,
        _ => strings.sourceRules,
      };
      final definitionSource = _controller.kind == 'provider'
          ? provenanceSummary(strings, _controller.providerProvenance)
          : null;
      final originLabel = [
        origin,
        if (definitionSource != null)
          '${strings.provenanceProviderHeading}: $definitionSource',
      ].join(' · ');
      final sourceError = switch (_controller.sourceError) {
        'sourceUnavailable' => strings.ruleSourceUnavailable,
        'sourceInvalid' => strings.ruleSourceInvalid,
        'sourceChanged' => strings.ruleSourceChanged,
        'sourceUnsupported' => strings.ruleSourceUnsupported,
        _ => null,
      };
      // Read continuity follows the displayed rule and duplicate occurrence;
      // details and writes still use the current source and actual index.
      final occurrences = <(Object?, Object?, Object?), int>{};
      final runtimeIds = [
        for (final row in _controller.rows)
          (
            'runtime-rule',
            _controller.source?.generation,
            _controller.source?.composition,
            _controller.kind,
            _controller.name,
            row['type'],
            row['payload'],
            row['target'],
            occurrences.update(
              (row['type'], row['payload'], row['target']),
              (value) => value + 1,
              ifAbsent: () => 0,
            ),
          ),
      ];
      Widget content(List<ReadingListItem> local) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: ReadingList(
            controller: _scroll,
            identity: (
              storageEpoch,
              widget.provider,
              _controller.kind,
              _controller.name,
              _controller.search,
              _controller.offset,
            ),
            header: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ChoiceMenuButton<(String, String)>(
                    identity: (
                      storageEpoch,
                      _controller.source?.generation,
                      _controller.source?.configId,
                      _controller.source?.revision,
                      _controller.source?.composition,
                      _controller.source?.purpose,
                    ),
                    enabled:
                        _controller.canRead &&
                        !_controller.loading &&
                        _controller.scopes.isNotEmpty,
                    tooltip: strings.ruleScope,
                    value: (_controller.kind, _controller.name),
                    onSelected: (value) => _select(value.$1, value.$2),
                    options: {
                      for (final scope in _controller.scopes)
                        (
                          scope['kind'] as String,
                          scope['name'] as String,
                        ): '${_scopeLabel(strings, scope['kind'] as String, scope['name'] as String)} (${scope['count']})',
                    },
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        _scopeLabel(
                          strings,
                          _controller.kind,
                          _controller.name,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.unfold_more),
                    ),
                  ),
                  TextField(
                    enabled:
                        widget.provider == null || !_controller.sourceExpired,
                    controller: _search,
                    focusNode: _searchFocus,
                    onChanged: _controller.filter,
                    decoration: InputDecoration(
                      labelText: strings.ruleSearch,
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
                    message: sourceError ?? '$status · $originLabel',
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Text(
                        sourceError ?? '$status · $originLabel',
                        softWrap: false,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: sourceError == null
                              ? null
                              : Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            items: [
              if (_controller.rows.isEmpty && _controller.current)
                ReadingListItem(
                  id: 'runtime-empty',
                  builder: (context) => Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(strings.noRules),
                  ),
                ),
              for (final (index, row) in _controller.rows.indexed)
                ReadingListItem(
                  id: runtimeIds[index],
                  builder: (context) {
                    final target = row['target'] as String;
                    final plugin = provenanceSummary(
                      strings,
                      row['provenance'] as DefinitionProvenance?,
                    );
                    final description = [
                      target.isEmpty
                          ? row['type'] as String
                          : '${row['type']} → $target',
                      ?plugin,
                    ].join(' · ');
                    return ListTile(
                      key: ValueKey(runtimeIds[index]),
                      selected:
                          !_selectionExpired &&
                          _selected != null &&
                          _selectedScope ==
                              (_controller.kind, _controller.name) &&
                          _selected!['index'] == row['index'],
                      selectedTileColor: Theme.of(context)
                          .colorScheme
                          .secondaryContainer,
                      selectedColor: Theme.of(context)
                          .colorScheme
                          .onSecondaryContainer,
                      leading: SizedBox(
                        width: 44,
                        child: Text('${row['index']}', maxLines: 1),
                      ),
                      title: Text(
                        (row['payload'] as String).isEmpty
                            ? row['type'] as String
                            : row['payload'] as String,
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
                          ? () => _details(row, coreSource)
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
        detail: _selected == null
            ? null
            : _ruleDetails(_selected!, _selectedSource!),
        detailStatus: _selectionExpired
            ? strings.coreSnapshotStale
            : _controller.current && !inList
            ? strings.selectionOutsideList
            : status,
        master: Scaffold(
          appBar: AppBar(
            title: Text(strings.rules),
            actions: [
              const CollectionDetailsAction(),
              if (widget.provider == null) ...[
                IconButton(
                  key: const ValueKey('local-custom-add'),
                  tooltip: strings.ruleFormTitle,
                  onPressed: canWrite
                      ? () => _localCustom(storageEpoch, openingCore)
                      : null,
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
                  sections: const {LocalYamlSection.rules},
                  query: _controller.search,
                  loadedSource: _controller.current ? _controller.source : null,
                  loadedContributors: [
                    if (_controller.current)
                      for (final row in _controller.rows)
                        ...?(row['provenance'] as DefinitionProvenance?)
                            ?.contributors,
                  ],
                  ruleProviders: [
                    if (_controller.current)
                      for (final scope in _controller.scopes)
                        if (scope['kind'] == 'provider')
                          scope['name'] as String,
                  ],
                  subRules: [
                    if (_controller.current)
                      for (final scope in _controller.scopes)
                        if (scope['kind'] == 'sub') scope['name'] as String,
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
                        _controller.offset + _controller.rows.length,
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
