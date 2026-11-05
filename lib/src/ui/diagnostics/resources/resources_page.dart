import '../../../logic/diagnostics/core_collection_page.dart';
import '../../components/feedback/operation_notice.dart';
import '../../navigation/page_route.dart';

import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:flutter/material.dart';

import '../../components/input/task_shortcuts.dart';
import '../../components/input/toolbar_search_field.dart';
import '../../components/collections/collection_workspace.dart';
import '../../components/collections/reading_list.dart';
import '../../components/reading/format_bytes.dart';
import '../../components/input/choice_menu_button.dart';

import '../../app/app_controller.dart';
import '../../navigation/task_activity.dart';
import '../../../l10n/app_localizations.dart';
import '../../overrides/definitions/local_custom_editor.dart';
import '../../../logic/overrides/local_yaml_edit.dart';
import '../../settings/core_cleanup_action.dart';
import 'resources_controller.dart';
import '../nodes/nodes_page.dart';
import '../rules/rules_page.dart';

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
  GlobalKey _statusContent = GlobalKey();

  Widget _statusMotion(Widget child) {
    final content = KeyedSubtree(key: _statusContent, child: child);
    return KeyedSubtree(
      key: const ValueKey('resource-detail-status-motion'),
      child: MediaQuery.disableAnimationsOf(context)
          ? content
          : AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeInOutCubic,
              alignment: Alignment.topLeft,
              child: content,
            ),
    );
  }

  LocalDefinitionCollection _local = const LocalDefinitionCollection();
  Object? _noticeSource;
  bool _readNoticed = false;
  Object? _resultNoticed;

  Object _rowIdentity(Map<String, dynamic> row) =>
      _local.readingIdentity(row) ?? ResourcesController.key(row);

  List<Map<String, dynamic>> get _rows =>
      _controller.source?.matchesIdentity(widget.app.state.core) == true
      ? DefinitionRows.merge(_controller.resources, _local.rows)
      : [..._controller.resources, ..._local.rows];

  bool _withPopup(ModalRoute<dynamic> popup) =>
      mounted &&
      widget.app.foreground &&
      AppTaskActivity.isActive(context, ownedPopup: popup) &&
      AppTaskActivity.routeIsActive(_route, ownedPopup: popup);

  void _feedbackChanged() {
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
    if (error == null) _readNoticed = false;
    if (error != null && !_readNoticed && _pageLive) {
      _readNoticed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pageLive || _noticeSource != identity) return;
        showAppNotice(
          context,
          error,
          isCurrent: () => _pageLive && _noticeSource == identity,
          isCurrentWithPopup: (popup) =>
              _withPopup(popup) && _noticeSource == identity,
          eligibilityChanges: _controller,
          onRetry: _controller.refresh,
        );
      });
    }
    final result = _controller.resultMessage;
    if (result == null || identical(result, _resultNoticed) || !_pageLive) {
      return;
    }
    _resultNoticed = result;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageLive || !identical(result, _resultNoticed)) return;
      showAppNotice(
        context,
        result,
        isCurrent: () => _pageLive && _noticeSource == identity,
        isCurrentWithPopup: (popup) =>
            _withPopup(popup) && _noticeSource == identity,
        eligibilityChanges: _controller,
      );
    });
  }

  Widget _definitions(BuildContext context) {
    if (widget.geoName != null) return _content(context);
    return LocalDefinitions(
      app: widget.app,
      sections: const {
        LocalYamlSection.proxyProviders,
        LocalYamlSection.ruleProviders,
      },
      builder: (context, local) {
        _local = local;
        return _content(context);
      },
    );
  }

  void _closeDetails() => setState(() => _selected = null);

  Future<void> _localCustom(
    int storageEpoch, {
    required LocalYamlSection section,
  }) async {
    if (!_masterLive) return;
    final origin = _route;
    _controller.setVisible(false);
    try {
      await showLocalCustomForm(
        context,
        app: widget.app,
        section: section,
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

  @override
  void initState() {
    super.initState();
    _controller.addListener(_feedbackChanged);
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

  @override
  void dispose() {
    _route?.animation?.removeListener(_syncVisibility);
    _controller.removeListener(_feedbackChanged);
    _controller.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _visible {
    final query = _query.trim().toLowerCase();
    final strings = AppLocalizations.of(context);
    return _rows.where((row) {
      if (widget.geoName != null &&
          (row['kind'] != 'geo' || row['name'] != widget.geoName)) {
        return false;
      }
      if (query.isEmpty) return true;
      return [
        row['name'],
        row['vehicleType'],
        row['type'],
        row['source'],
        row['kind'],
        row['behavior'],
        _kindLabel(strings, row['kind']?.toString() ?? ''),
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
    'geo' => strings.resourceGeo,
    _ => kind,
  };

  String _detail(AppLocalizations strings, Map<String, dynamic> row) {
    final parts = <String>[
      if (row['count'] case final int count) strings.resourceCountValue(count),
      _kindLabel(strings, row['kind']?.toString() ?? ''),
    ];
    if (row['behavior'] case final String behavior when behavior.isNotEmpty) {
      parts.add(strings.resourceBuiltInBehavior(behavior));
    } else if (row['vehicleType'] case final String vehicleType
        when row['kind'] != 'geo' && vehicleType.isNotEmpty) {
      parts.add(vehicleType);
    }
    if (row['bytes'] case final int bytes) {
      parts.add(formatBytes(bytes));
    }
    if (row['fileStatus'] case final String status) {
      parts.add(switch (status) {
        'present' => strings.resourceFilePresent,
        'missing' => strings.resourceFileMissing,
        'unreadable' => strings.resourceFileUnreadable,
        _ => status,
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
    if (!_masterLive ||
        source == null ||
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
      FocusedPageRoute(
        builder: (_) => kind == 'proxyProvider'
            ? NodesPage(app: widget.app, provider: name, expectedSource: source)
            : RulesPage(
                app: widget.app,
                provider: name,
                expectedSource: source,
              ),
      ),
    );
    if (mounted) _syncVisibility();
  }

  void _showDetails(Map<String, dynamic> row, CoreSnapshot? source) {
    if (!_masterLive) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _detailKey = UniqueKey();
      _statusContent = GlobalKey();
      _selected = row;
      _selectedSource = source;
      _selectedEpoch = widget.app.storageEpoch;
      _selectionExpired = false;
    });
  }

  Widget _resourceDetails(
    BuildContext context,
    Map<String, dynamic> row,
    CoreSnapshot? source,
  ) {
    final detailKey = _detailKey;
    bool current() =>
        mounted &&
        context.mounted &&
        _pageLive &&
        _workspace.currentState?.detailVisible == true &&
        _selected != null &&
        _detailKey == detailKey &&
        CollectionWorkspace.paneActiveOf(context, listen: false);
    bool selectionCurrent() =>
        mounted &&
        _selected != null &&
        _detailKey == detailKey &&
        !_selectionExpired &&
        _selectedEpoch == widget.app.storageEpoch &&
        _selectedEpoch == widget.app.state.storageEpoch &&
        widget.app.state.confirmed &&
        source != null &&
        source.matchesIdentity(widget.app.state.core) &&
        _selectedSource?.matchesIdentity(source) == true &&
        _controller.source?.matchesIdentity(source) == true;
    bool actionable() => current() && selectionCurrent() && _controller.current;
    bool actionableWithPopup(ModalRoute<dynamic> popup) =>
        mounted &&
        context.mounted &&
        widget.app.foreground &&
        AppTaskActivity.isActive(this.context, ownedPopup: popup) &&
        AppTaskActivity.routeIsActive(_route, ownedPopup: popup) &&
        _workspace.currentState?.detailPresented == true &&
        selectionCurrent();
    final paneActive = CollectionWorkspace.paneActiveOf(context);
    final kind = row['kind']?.toString() ?? '';
    final name = row['name']?.toString() ?? '';
    final strings = AppLocalizations.of(context);
    final valid =
        paneActive &&
        !_selectionExpired &&
        source != null &&
        !row.containsKey('entryId') &&
        _controller.current &&
        source.matchesIdentity(widget.app.state.core);
    final details = <String>[
      _detail(strings, row),
      if ((row['source']?.toString() ?? '').isNotEmpty)
        row['source']?.toString() ?? '',
      if (row['path'] case final String path when path.isNotEmpty)
        strings.resourceLocalFile(path),
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
      if (row['lastSuccessfulCheck'] case final String time)
        strings.resourceLastCheckAt(_time(context, time)),
      if (kind == 'geo') strings.resourceAutoScope,
    ];
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
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _statusMotion(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SelectableText(
                  name.isEmpty ? '""' : name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (row['format'] case final String format when kind != 'geo')
                  SelectableText('format: $format'),
                for (final detail in details)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: SelectableText(detail),
                  ),
                ?_local.actions(context, row),
              ],
            ),
          ),
          if (kind == 'proxyProvider' || kind == 'ruleProvider')
            TextButton(
              onPressed: valid
                  ? () {
                      if (!actionable()) return;
                      _openProvider(kind, name, source);
                    }
                  : null,
              child: Text(
                kind == 'proxyProvider' ? strings.proxyNodes : strings.ruleSets,
              ),
            ),
          if (source != null && kind == 'geo')
            if (row['path'] case final String path when path.isNotEmpty)
              CoreCleanupAction(
                key: const ValueKey('resource-delete-file'),
                app: widget.app,
                enabled: valid,
                canStart: actionable,
                // A captured session can return from its own popup before the
                // pane's cached active scope has rebuilt. New admission above
                // still requires that scope and a current controller read.
                isCurrent: () =>
                    mounted &&
                    context.mounted &&
                    _pageLive &&
                    _workspace.currentState?.detailPresented == true &&
                    selectionCurrent(),
                isCurrentWithPopup: actionableWithPopup,
                request: {
                  'scope': 'resource',
                  'generation': source.generation,
                  'composition': source.composition,
                  'configId': source.configId,
                  'revision': source.revision,
                  'purpose': source.purpose,
                  'kind': kind,
                  'name': name,
                  'expectedPath': path,
                },
                title: (strings) => strings.coreCleanupResource,
                description: (strings) => strings.coreCleanupResourceMessage,
                icon: Icons.delete_outline,
                subject: path,
              ),
        ],
      ),
    );
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
    onSearch: widget.geoName == null ? _searchTask : null,
    onEscape: _escape,
    child: _definitions(context),
  );

  Widget _content(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final strings = AppLocalizations.of(context);
      final storageEpoch = widget.app.storageEpoch;
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
          final current = _rows
              .where((row) => _rowIdentity(row) == _rowIdentity(selected))
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
                    ToolbarSearchField(
                      controller: _search,
                      focusNode: _searchFocus,
                      hintText: strings.resourceSearch,
                      onChanged: (value) => setState(() => _query = value),
                    ),
                    const SizedBox(height: 12),
                  ],
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
                  id: row.containsKey('entryId')
                      ? _rowIdentity(row)
                      : (
                          'runtime-resource',
                          coreSource?.generation,
                          coreSource?.composition,
                          _rowIdentity(row),
                        ),
                  builder: (context) {
                    final kind = row['kind']?.toString() ?? '';
                    final name = row['name']?.toString() ?? '';
                    final source = row['source']?.toString() ?? '';
                    final updating = _controller.isUpdating(kind, name);
                    final updated = row['updatedAt']?.toString();
                    final supported = row['updateSupported'] == true;
                    final selected =
                        !_selectionExpired &&
                        _selected != null &&
                        _rowIdentity(row) == _rowIdentity(_selected!);
                    final colors = Theme.of(context).colorScheme;
                    final rowSubtitleStyle = subtitleStyle.copyWith(
                      color: selected
                          ? colors.onSecondaryContainer
                          : colors.onSurfaceVariant,
                    );
                    final tile = ListTile(
                      key: ValueKey(_rowIdentity(row)),
                      selected: selected,
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
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            height: subtitleHeight,
                            child: Text(
                              _detail(strings, row),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: rowSubtitleStyle,
                              strutStyle: subtitleStrut,
                            ),
                          ),
                          Text(
                            source.isEmpty
                                ? strings.resourceNoExternalSource
                                : source,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: rowSubtitleStyle,
                            strutStyle: subtitleStrut,
                          ),
                          Text(
                            updated == null
                                ? strings.resourceUpdateUnknown
                                : strings.resourceUpdatedAt(
                                    _time(context, updated),
                                  ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: rowSubtitleStyle,
                            strutStyle: subtitleStrut,
                          ),
                        ],
                      ),
                      trailing:
                          _local.actions(context, row) ??
                          SizedBox(
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
                builder: (context) =>
                    _resourceDetails(context, _selected!, _selectedSource),
              ),
        detailStatus: _selectionExpired
            ? strings.coreSnapshotStale
            : _selected != null &&
                  !rows.any(
                    (row) => _rowIdentity(row) == _rowIdentity(_selected!),
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
            ],
          ),
          body: content(),
        ),
      );
    },
  );
}
