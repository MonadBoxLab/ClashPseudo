import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../app/widgets/task_shortcuts.dart';
import '../../app/widgets/collection_workspace.dart';
import '../../app/widgets/reading_list.dart';
import '../../app/format_bytes.dart';
import '../../app/widgets/choice_menu_button.dart';

import '../../app/app_controller.dart';
import '../../app/widgets/provenance_details.dart';
import '../../l10n/app_localizations.dart';
import '../../model/definition_provenance.dart';
import '../overrides/local_custom_editor.dart';
import '../overrides/local_yaml_edit.dart';
import 'resources_controller.dart';
import 'nodes_page.dart';
import 'rules_page.dart';

class ResourcesPage extends StatefulWidget {
  const ResourcesPage({
    super.key,
    required this.app,
    this.geoName,
    this.expectedSource,
  });
  final AppController app;
  final String? geoName;
  final CoreSnapshot? expectedSource;
  @override
  State<ResourcesPage> createState() => _ResourcesPageState();
}

class _ResourcesPageState extends State<ResourcesPage> {
  late final _controller = ResourcesController(
    widget.app,
    expectedSource: widget.expectedSource,
  );
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _workspace = GlobalKey<CollectionWorkspaceState>();
  String _query = '';
  Map<String, dynamic>? _selected;
  Key? _detailKey;
  CoreSnapshot? _selectedSource;
  int? _selectedEpoch;
  bool _selectionExpired = false;

  void _closeDetails() => setState(() => _selected = null);

  Future<void> _localCustom(
    int storageEpoch, {
    required LocalYamlSection section,
  }) async {
    _controller.setVisible(false);
    try {
      await showLocalCustomForm(
        context,
        app: widget.app,
        section: section,
        storageEpoch: storageEpoch,
      );
    } finally {
      if (mounted) _controller.setVisible(true);
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
    super.dispose();
  }

  List<Map<String, dynamic>> get _visible {
    final query = _query.trim().toLowerCase();
    final strings = AppLocalizations.of(context);
    return _controller.resources.where((row) {
      if (widget.geoName != null &&
          (row['kind'] != 'geo' || row['name'] != widget.geoName)) {
        return false;
      }
      if (query.isEmpty) return true;
      return [
        row['name'],
        row['vehicleType'],
        row['source'],
        row['kind'],
        row['behavior'],
        _kindLabel(strings, row['kind'] as String),
      ].whereType<String>().any((value) => value.toLowerCase().contains(query));
    }).toList();
  }

  String _time(BuildContext context, String value) {
    final time = DateTime.tryParse(value)?.toLocal();
    if (time == null) return value;
    final material = MaterialLocalizations.of(context);
    return '${material.formatCompactDate(time)} '
        '${material.formatTimeOfDay(TimeOfDay.fromDateTime(time))}';
  }

  String _kindLabel(AppLocalizations strings, String kind) => switch (kind) {
    'proxyProvider' => strings.resourceProxyProvider,
    'ruleProvider' => strings.resourceRuleProvider,
    _ => strings.resourceGeo,
  };

  String _detail(AppLocalizations strings, Map<String, dynamic> row) {
    final parts = <String>[
      if (row['count'] case final int count) strings.resourceCountValue(count),
      _kindLabel(strings, row['kind'] as String),
    ];
    if (row['behavior'] case final String behavior when behavior.isNotEmpty) {
      parts.add(strings.resourceBuiltInBehavior(behavior));
    } else if (row['kind'] != 'geo') {
      parts.add(row['vehicleType'] as String);
    }
    if (row['bytes'] case final int bytes) {
      parts.add(formatBytes(bytes));
    }
    if (row['fileStatus'] case final String status) {
      parts.add(switch (status) {
        'present' => strings.resourceFilePresent,
        'missing' => strings.resourceFileMissing,
        _ => strings.resourceFileUnreadable,
      });
    }
    if (row['autoUpdateTarget'] case final bool target) {
      parts.add(
        target ? strings.resourceAutoTarget : strings.resourceNotAutoTarget,
      );
    }
    return parts.join(' · ');
  }

  Future<void> _update(String kind, String name, CoreSnapshot? source) async {
    if (source == null ||
        !_controller.current ||
        !source.matchesIdentity(widget.app.state.core)) {
      return;
    }
    await _controller.update(kind, name);
  }

  String _interval(AppLocalizations strings, int seconds) {
    if (seconds >= 3600 && seconds % 60 == 0) {
      return strings.durationHoursMinutes(
        seconds ~/ 3600,
        seconds % 3600 ~/ 60,
      );
    }
    if (seconds >= 60) {
      return strings.durationMinutesSeconds(seconds ~/ 60, seconds % 60);
    }
    return strings.durationSeconds(seconds);
  }

  Future<void> _openProvider(
    String kind,
    String name,
    CoreSnapshot source,
  ) async {
    if (!_controller.current ||
        !source.matchesIdentity(widget.app.state.core)) {
      return;
    }
    _controller.setVisible(false);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => kind == 'proxyProvider'
            ? NodesPage(app: widget.app, provider: name, expectedSource: source)
            : RulesPage(
                app: widget.app,
                provider: name,
                expectedSource: source,
              ),
      ),
    );
    if (mounted) _controller.setVisible(true);
  }

  void _showDetails(Map<String, dynamic> row, CoreSnapshot? source) {
    FocusScope.of(context).unfocus();
    setState(() {
      _detailKey = UniqueKey();
      _selected = row;
      _selectedSource = source;
      _selectedEpoch = widget.app.storageEpoch;
      _selectionExpired = false;
    });
  }

  Widget _resourceDetails(Map<String, dynamic> row, CoreSnapshot? source) {
    final kind = row['kind'] as String;
    final name = row['name'] as String;
    final strings = AppLocalizations.of(context);
    final valid =
        !_selectionExpired &&
        source != null &&
        _controller.current &&
        source.matchesIdentity(widget.app.state.core);
    final details = <String>[
      _detail(strings, row),
      if ((row['source'] as String).isNotEmpty) row['source'] as String,
      if (row['updatedAt'] case final String time)
        strings.resourceUpdatedAt(_time(context, time))
      else
        strings.resourceUpdateUnknown,
      if (row['fileModifiedAt'] case final String time)
        strings.resourceFileModifiedAt(_time(context, time)),
      if (row['autoUpdate'] case final bool enabled)
        enabled ? strings.autoUpdateEnabled : strings.autoUpdateDisabled,
      if (row['updateIntervalSeconds'] case final int seconds when seconds > 0)
        strings.resourceUpdateInterval(_interval(strings, seconds)),
      if (kind != 'geo' && row['vehicleType'] == 'File')
        strings.resourceWatchFile,
      if (row['lastAttempt'] case final String time)
        '${strings.autoUpdateAttempt}: ${_time(context, time)}',
      if (row['lastResult'] case final String result when result.isNotEmpty)
        switch (result) {
          'ok' => strings.resourceUpdateSuccess,
          'running' => strings.resourceUpdating,
          'failed' => strings.resourceUpdateFailed,
          _ => strings.resultUnconfirmed,
        },
      if (row['lastSuccessfulCheck'] case final String time)
        strings.resourceLastCheckAt(_time(context, time)),
      if (kind == 'geo') strings.resourceAutoScope,
    ];
    return Scaffold(
      key: _detailKey,
      appBar: AppBar(
        leading: BackButton(onPressed: _closeDetails),
        title: Text(strings.details),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                name.isEmpty ? '""' : name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text(
                  valid
                      ? source.purpose == 'PREVIEW'
                            ? strings.runtimeConfigPreview
                            : strings.runtimeConfigLive
                      : strings.coreSnapshotStale,
                  softWrap: false,
                ),
              ),
              const SizedBox(height: 12),
              if (kind != 'geo') ...[
                Text(
                  strings.providerRuntimePropertiesOnly,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                if (row['format'] case final String format)
                  SelectableText('format: $format'),
              ],
              for (final detail in details)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: SelectableText(detail),
                ),
              ProvenanceDetails(
                provenance: row['provenance'] as DefinitionProvenance?,
                providerDefinition: true,
              ),
            ],
          ),
          if (kind == 'proxyProvider' || kind == 'ruleProvider')
            TextButton(
              onPressed: valid ? () => _openProvider(kind, name, source) : null,
              child: Text(
                kind == 'proxyProvider' ? strings.proxyNodes : strings.ruleSets,
              ),
            ),
        ],
      ),
    );
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
    onSearch: widget.geoName == null ? _searchTask : null,
    onEscape: _escape,
    child: _content(context),
  );

  Widget _content(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final strings = AppLocalizations.of(context);
      final storageEpoch = widget.app.storageEpoch;
      if (_selected case final selected?) {
        _selectionExpired |=
            _selectedEpoch != storageEpoch ||
            _selectedSource?.matchesIdentity(widget.app.state.core) != true;
        if (!_selectionExpired && _controller.current) {
          final current = _controller.resources
              .where(
                (row) =>
                    ResourcesController.key(row) ==
                    ResourcesController.key(selected),
              )
              .firstOrNull;
          if (current == null) {
            _selectionExpired = true;
          } else {
            _selected = current;
          }
        }
      }
      final canWrite =
          widget.app.canEdit &&
          widget.app.overridesLoaded &&
          widget.app.overrideErrorMessage == null;
      final rows = _visible;
      final coreSource = _controller.source;
      final status = _controller.sourceExpired
          ? strings.coreSnapshotStale
          : _controller.loading || widget.app.busy
          ? strings.coreReadLoading
          : _controller.status == ResourcesStatus.failed
          ? strings.coreReadFailed
          : _controller.status == ResourcesStatus.stale
          ? strings.coreSnapshotStale
          : _controller.status == ResourcesStatus.empty
          ? strings.runtimeConfigEmpty
          : _controller.status == ResourcesStatus.preview
          ? strings.runtimeConfigPreview
          : strings.runtimeConfigLive;
      Widget content(List<ReadingListItem> local) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: ReadingList(
            identity: (
              storageEpoch,
              widget.geoName,
              _query.trim().toLowerCase(),
            ),
            header: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.geoName == null) ...[
                    TextField(
                      controller: _search,
                      focusNode: _searchFocus,
                      onChanged: (value) => setState(() => _query = value),
                      decoration: InputDecoration(
                        labelText: strings.resourceSearch,
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
                            setState(() => _query = '');
                          },
                          icon: const Icon(Icons.close),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
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
              if (rows.isEmpty && _controller.current)
                ReadingListItem(
                  id: 'runtime-empty',
                  builder: (context) => Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(strings.noResources),
                  ),
                ),
              for (final (index, row) in rows.indexed)
                ReadingListItem(
                  id: (
                    'runtime-resource',
                    coreSource?.generation,
                    coreSource?.composition,
                    ResourcesController.key(row),
                  ),
                  builder: (context) {
                    final kind = row['kind'] as String;
                    final name = row['name'] as String;
                    final source = row['source'] as String;
                    final updating = _controller.isUpdating(kind, name);
                    final updated = row['updatedAt'] as String?;
                    final supported = row['updateSupported'] == true;
                    final plugin = provenanceSummary(
                      strings,
                      row['provenance'] as DefinitionProvenance?,
                    );
                    final tile = ListTile(
                      key: ValueKey(ResourcesController.key(row)),
                      selected:
                          !_selectionExpired &&
                          _selected != null &&
                          ResourcesController.key(row) ==
                              ResourcesController.key(_selected!),
                      selectedTileColor: Theme.of(context)
                          .colorScheme
                          .secondaryContainer,
                      selectedColor: Theme.of(context)
                          .colorScheme
                          .onSecondaryContainer,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      onTap: () => _showDetails(row, coreSource),
                      title: Text(
                        name.isEmpty ? '""' : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        strutStyle: const StrutStyle(
                          fontSize: 16,
                          height: 1.5,
                          forceStrutHeight: true,
                        ),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            height:
                                MediaQuery.textScalerOf(context).scale(14) * 3,
                            child: plugin == null
                                ? Text(
                                    _detail(strings, row),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    strutStyle: const StrutStyle(
                                      fontSize: 14,
                                      height: 1.5,
                                      forceStrutHeight: true,
                                    ),
                                  )
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Tooltip(
                                        message:
                                            '${strings.provenanceProviderHeading}: $plugin',
                                        child: Text(
                                          plugin,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          strutStyle: const StrutStyle(
                                            fontSize: 14,
                                            height: 1.5,
                                            forceStrutHeight: true,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        _detail(strings, row),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        strutStyle: const StrutStyle(
                                          fontSize: 14,
                                          height: 1.5,
                                          forceStrutHeight: true,
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                          Text(
                            source.isEmpty
                                ? strings.resourceNoExternalSource
                                : source,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            strutStyle: const StrutStyle(
                              fontSize: 14,
                              height: 1.5,
                              forceStrutHeight: true,
                            ),
                          ),
                          Text(
                            updated == null
                                ? strings.resourceUpdateUnknown
                                : strings.resourceUpdatedAt(
                                    _time(context, updated),
                                  ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            strutStyle: const StrutStyle(
                              fontSize: 14,
                              height: 1.5,
                              forceStrutHeight: true,
                            ),
                          ),
                        ],
                      ),
                      trailing: SizedBox(
                        width: 96,
                        child: supported
                            ? TextButton(
                                onPressed:
                                    updating ||
                                        !_controller.canRefresh ||
                                        !_controller.current
                                    ? null
                                    : () => _update(kind, name, coreSource),
                                child: Text(
                                  updating
                                      ? strings.resourceUpdating
                                      : strings.resourceUpdate,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              )
                            : Tooltip(
                                message: strings.resourceNoExternalSource,
                                child: Icon(
                                  Icons.cloud_off_outlined,
                                  size: 20,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                      ),
                    );
                    return Column(
                      children: [
                        tile,
                        if (index + 1 < rows.length)
                          const Divider(height: 1, indent: 16, endIndent: 16),
                      ],
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
            : _resourceDetails(_selected!, _selectedSource),
        detailStatus: _selectionExpired
            ? strings.coreSnapshotStale
            : _selected != null &&
                  !rows.any(
                    (row) =>
                        ResourcesController.key(row) ==
                        ResourcesController.key(_selected!),
                  )
            ? strings.selectionOutsideList
            : status,
        master: Scaffold(
          appBar: AppBar(
            title: Text(strings.externalResources),
            actions: [
              const CollectionDetailsAction(),
              if (widget.geoName == null) ...[
                ChoiceMenuButton<LocalYamlSection>(
                  key: const ValueKey('local-custom-add'),
                  enabled: canWrite,
                  identity: storageEpoch,
                  tooltip: strings.proxyAddItem(strings.externalResources),
                  iconColor: Theme.of(context).colorScheme.primary,
                  icon: Icons.add,
                  onSelected: (section) =>
                      _localCustom(storageEpoch, section: section),
                  options: {
                    LocalYamlSection.proxyProviders:
                        strings.providerProxyFormTitle,
                    LocalYamlSection.ruleProviders:
                        strings.providerRuleFormTitle,
                  },
                ),
              ],
              IconButton(
                tooltip: strings.refresh,
                onPressed: _controller.canRefresh ? _controller.refresh : null,
                color: HomePalette.of(context).syncAction,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: widget.geoName == null
              ? LocalDefinitions(
                  app: widget.app,
                  sections: const {
                    LocalYamlSection.proxyProviders,
                    LocalYamlSection.ruleProviders,
                  },
                  query: _query,
                  loadedSource: _controller.current ? _controller.source : null,
                  loadedContributors: [
                    if (_controller.current)
                      for (final row in _controller.resources)
                        ...?(row['provenance'] as DefinitionProvenance?)
                            ?.contributors,
                  ],
                  builder: (context, local) => content(local),
                )
              : content(const []),
        ),
      );
    },
  );
}
