import '../../components/feedback/operation_notice.dart';
import '../../navigation/page_route.dart';

import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../components/reading/original_text_view.dart';
import '../../components/input/task_shortcuts.dart';

import '../../theme/app_theme.dart';
import '../../components/collections/reading_list.dart';
import '../../components/input/choice_menu_button.dart';

import '../../app/app_controller.dart';
import '../../navigation/task_activity.dart';
import '../../../l10n/app_localizations.dart';
import '../../../model/messages.dart';
import '../../overrides/definitions/local_custom_editor.dart';
import '../../../logic/overrides/local_yaml_edit.dart';
import 'rules_controller.dart';
import '../../components/collections/collection_workspace.dart';
import '../resources/resources_page.dart';
import '../result_page_bar.dart';

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
  bool _selectionExpired = false;

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
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => LocalDefinitions(
        app: widget.app,
        sections: const {LocalYamlSection.rules},
        ruleProviders: [
          for (final scope in _controller.scopes)
            if (scope['kind'] == 'provider') scope['name'] as String,
        ],
        subRules: [
          for (final scope in _controller.scopes)
            if (scope['kind'] == 'sub') scope['name'] as String,
        ],
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
      ),
    );
  }

  void _closeDetails() => setState(() => _selected = null);

  Future<void> _localCustom(int storageEpoch, CoreSnapshot core) async {
    if (_opening || !_masterLive) return;
    if (storageEpoch != widget.app.storageEpoch ||
        storageEpoch != widget.app.state.storageEpoch) {
      await showAppNotice(
        context,
        messages.storageContextChanged,
        isCurrent: () => _masterLive,
        isCurrentWithPopup: _masterWithPopup,
      );
      return;
    }
    final scopes = List<Map<String, dynamic>>.of(_controller.scopes);
    final hasSource = _controller.current;
    final origin = _route;
    setState(() => _opening = true);
    _controller.setVisible(false);
    try {
      final targets = <String>{'DIRECT', 'REJECT'};
      if (core.ready && hasSource) {
        var matches = true;
        try {
          final snapshot = await widget.app.platform
              .strategies(core)
              .timeout(const Duration(seconds: 8));
          matches = snapshot.matches(core);
          if (matches) {
            targets.addAll(snapshot.groups.map((group) => group.name));
          }
        } catch (_) {
          // Local-rule management uses the captured Store/source identity; runtime
          // suggestions are optional.
        }
        if (!mounted || !_masterLive) return;
        if (storageEpoch != widget.app.storageEpoch ||
            !core.matchesIdentity(widget.app.state.core) ||
            !matches) {
          await showAppNotice(
            context,
            messages.strategyContextChangedRetry,
            isCurrent: () => _masterLive,
            isCurrentWithPopup: _masterWithPopup,
          );
          return;
        }
      }
      if (!mounted || !_masterLive) return;
      await showLocalCustomForm(
        context,
        app: widget.app,
        section: LocalYamlSection.rules,
        storageEpoch: storageEpoch,
        isContextCurrent: () =>
            mounted &&
            (origin?.isActive ?? true) &&
            origin?.animation?.status != AnimationStatus.reverse &&
            storageEpoch == widget.app.storageEpoch &&
            (!hasSource || core.matchesIdentity(widget.app.state.core)),
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
        await showAppNotice(
          context,
          messages.operationNotCompletedRetry,
          isCurrent: () => _masterLive,
          isCurrentWithPopup: _masterWithPopup,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _opening = false);
        _syncVisibility();
      }
    }
  }

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
    if (!mounted || !_masterLive) return;
    if (next) {
      await _controller.next();
    } else {
      await _controller.previous();
    }
    if (_masterLive && _controller.current && _scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  Object? _rowIdentity(Map<String, dynamic> row) =>
      _local.readingIdentity(row) ?? row['index'];

  void _details(Map<String, dynamic> row, CoreSnapshot? source) {
    if (!_masterLive) return;
    _searchFocus.unfocus();
    setState(() {
      _detailKey = UniqueKey();
      _selected = row;
      _selectedSource = source;
      _selectedEpoch = widget.app.storageEpoch;
      _selectedScope = (_controller.kind, _controller.name);
      _selectedSourceToken = _controller.sourceToken;
      _selectionExpired = false;
    });
  }

  void _showRaw(Object? value, {Object? query, bool Function()? isCurrent}) {
    if (!(isCurrent?.call() ?? _masterLive)) return;
    final strings = AppLocalizations.of(context);
    Navigator.of(context).push<void>(
      FocusedPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(strings.resourceRawData)),
          body: OriginalTextView(
            text: const JsonEncoder.withIndent('  ').convert(value),
            header: query == null
                ? null
                : Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(
                      const JsonEncoder.withIndent('  ')
                          .convert({'query': query}),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _ruleDetails(
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
    bool actionable() =>
        current() &&
        !_selectionExpired &&
        _selectedEpoch == widget.app.storageEpoch &&
        _controller.canPage &&
        source?.matchesIdentity(widget.app.state.core) == true;
    final paneActive = CollectionWorkspace.paneActiveOf(context);
    final resources = switch (row['resources']) {
      List value => value.whereType<String>().toList(),
      _ => const <String>[],
    };
    final providers = switch (row['providers']) {
      List value => value.whereType<String>().toList(),
      _ => const <String>[],
    };
    final strings = AppLocalizations.of(context);
    final valid =
        paneActive &&
        !_selectionExpired &&
        _controller.canPage &&
        source?.matchesIdentity(widget.app.state.core) == true;
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
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              [if (row['index'] != null) row['index'], row['type']].join(' · '),
            ),
            const SizedBox(height: 12),
            SelectableText(row['payload'].toString()),
            const SizedBox(height: 12),
            Text(
              strings.ruleTarget,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            SelectableText(
              (row['target'].toString()).isEmpty
                  ? '—'
                  : row['target'].toString(),
            ),
            ?_local.actions(context, row),
            TextButton.icon(
              key: const ValueKey('rule-raw-data'),
              onPressed: () => _showRaw(row, isCurrent: current),
              icon: const Icon(Icons.data_object),
              label: Text(strings.resourceRawData),
            ),
            for (final resource in resources)
              TextButton(
                onPressed: valid
                    ? () {
                        if (!actionable()) return;
                        _openGeoResource(resource, source!);
                      }
                    : null,
                child: Text('${strings.resourceGeo} · $resource'),
              ),
            for (final provider in providers)
              TextButton(
                onPressed: valid
                    ? () {
                        if (!actionable()) return;
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
      FocusedPageRoute(
        builder: (_) => ResourcesPage(
          app: widget.app,
          geoName: name,
          expectedSource: source,
        ),
      ),
    );
    if (mounted) _syncVisibility();
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
        final sameScope =
            _selectedScope == (_controller.kind, _controller.name);
        _selectionExpired |=
            _selectedEpoch != storageEpoch ||
            (selected.containsKey('entryId')
                ? !_local.rows.any(
                    (row) =>
                        row['localDefinition'] == selected['localDefinition'],
                  )
                : _selectedSource?.matchesIdentity(widget.app.state.core) !=
                      true) ||
            (!selected.containsKey('entryId') &&
                _controller.current &&
                sameScope &&
                _selectedSourceToken != _controller.sourceToken);
        if (!_selectionExpired && _controller.current && sameScope) {
          final current = _controller.rows
              .where((row) => _rowIdentity(row) == _rowIdentity(selected))
              .firstOrNull;
          inList = current != null;
          if (current != null) {
            _selected = current;
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
      final runtimeIds = [
        for (final row in _controller.rows)
          _local.readingIdentity(row) ??
              (
                'runtime-rule',
                coreSource?.identity,
                _controller.kind,
                _controller.name,
                row['index'],
              ),
      ];
      Widget content() => Align(
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
                    onSelected: (value) {
                      if (_masterLive) _select(value.$1, value.$2);
                    },
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
                    final target = row['target'].toString();
                    final description = target.isEmpty
                        ? row['type'].toString()
                        : '${row['type']} → $target';
                    return ListTile(
                      key: ValueKey(runtimeIds[index]),
                      selected:
                          !_selectionExpired &&
                          _selected != null &&
                          _selectedScope ==
                              (_controller.kind, _controller.name) &&
                          _rowIdentity(_selected!) == _rowIdentity(row),
                      selectedTileColor: Theme.of(context)
                          .colorScheme
                          .secondaryContainer,
                      selectedColor: Theme.of(context)
                          .colorScheme
                          .onSecondaryContainer,
                      leading: SizedBox(
                        width: 44,
                        child: Text(
                          row['index']?.toString() ?? '',
                          maxLines: 1,
                        ),
                      ),
                      title: Text(
                        (row['payload'].toString()).isEmpty
                            ? row['type'].toString()
                            : row['payload'].toString(),
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
                      trailing:
                          _local.actions(context, row) ??
                          const Icon(Icons.chevron_right),
                      onTap: () => _details(row, coreSource),
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
                    _ruleDetails(context, _selected!, _selectedSource),
              ),
        detailStatus: _selectionExpired
            ? strings.coreSnapshotStale
            : _controller.current && !inList
            ? strings.selectionOutsideList
            : status,
        master: Scaffold(
          appBar: AppBar(
            title: Text(strings.rules),
            actions: [
              IconButton(
                tooltip: strings.resourceRawData,
                icon: const Icon(Icons.data_object),
                onPressed: _controller.data == null
                    ? null
                    : () => _showRaw(
                        _controller.data,
                        query: _controller.dataQuery,
                      ),
              ),
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
                    ? () {
                        if (_masterLive) {
                          (_local.retry ?? _controller.refresh)();
                        }
                      }
                    : null,
                color: HomePalette.of(context).syncAction,
                icon: _controller.loading
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
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
