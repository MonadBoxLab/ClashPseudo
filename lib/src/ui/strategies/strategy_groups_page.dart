import '../../logic/diagnostics/core_collection_page.dart';
import '../navigation/page_route.dart';

import 'package:flutter/material.dart';

import '../navigation/task_activity.dart';

import '../app/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../overrides/definitions/local_custom_editor.dart';
import '../../logic/overrides/local_yaml_edit.dart';
import '../../model/override_entry.dart';
import 'strategies_page.dart';
import 'strategy_controller.dart';
import 'strategy_icon.dart';
import '../../model/strategy_snapshot.dart';

class StrategyGroupsPage extends StatefulWidget {
  const StrategyGroupsPage({super.key, required this.app});
  final AppController app;

  @override
  State<StrategyGroupsPage> createState() => _StrategyGroupsPageState();
}

class _StrategyGroupsPageState extends State<StrategyGroupsPage> {
  late final StrategyController _controller;
  bool _editing = false;
  ModalRoute<dynamic>? _formRoute;

  bool get _eligible =>
      mounted &&
      widget.app.foreground &&
      AppTaskActivity.isActive(context) &&
      AppTaskActivity.routeIsActive(ModalRoute.of(context));

  @override
  void initState() {
    super.initState();
    _controller = StrategyController(widget.app, allGroups: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<String> _members(StrategySnapshot? actual) => <String>{
    'DIRECT',
    'REJECT',
    if (actual != null)
      for (final group in actual.groups) ...[
        group.name,
        for (final member in group.members) member.name,
      ],
  }.toList();

  /// Direct proxy-provider names in the saved local body supply suggestions for use.
  List<String> _providers() {
    if (!widget.app.overridesLoaded) return const [];
    final entries = widget.app.overrides
        .where((entry) => entry.role == OverrideRole.localCustom)
        .toList();
    if (entries.length != 1) return const [];
    try {
      return LocalYamlEdit(entries.single.body)
          .definitions(LocalYamlSection.proxyProviders)
          .map((definition) => definition.value)
          .toList();
    } on LocalYamlEditException {
      return const [];
    }
  }

  Future<void> _add(int storageEpoch) async {
    if (!_eligible || _editing) return;
    final origin = ModalRoute.of(context);
    final source = _controller.current ? widget.app.state.core : null;
    setState(() => _editing = true);
    try {
      await showLocalCustomForm(
        context,
        app: widget.app,
        section: LocalYamlSection.strategyGroups,
        storageEpoch: storageEpoch,
        members: _members(_controller.current ? _controller.data : null),
        providers: _providers(),
        onRoute: (route) => _formRoute = route,
        isContextCurrent: () =>
            mounted &&
            widget.app.foreground &&
            widget.app.storageEpoch == storageEpoch &&
            (origin?.isActive ?? true) &&
            origin?.animation?.status != AnimationStatus.reverse &&
            (_formRoute?.isActive ?? true) &&
            _formRoute?.animation?.status != AnimationStatus.reverse &&
            (source == null || source.matchesIdentity(widget.app.state.core)),
      );
    } finally {
      _formRoute = null;
      if (mounted) setState(() => _editing = false);
    }
  }

  Future<void> _openProperties(
    StrategyDefinition group,
    LocalDefinitionCollection definitions,
    List<String> members,
  ) async {
    if (!_eligible || _editing) return;
    final local = definitions.target?.call(group.id);
    final epoch = widget.app.storageEpoch;
    final providers = _providers();
    setState(() => _editing = true);
    try {
      await Navigator.of(context).push<void>(
        FocusedPageRoute(
          builder: (_) => _GroupPropertiesPage(
            app: widget.app,
            group: group,
            storageEpoch: epoch,
            onEdit: local == null
                ? null
                : (editContext) => showLocalCustomDefinitionEditor(
                    editContext,
                    app: widget.app,
                    storageEpoch: local.epoch,
                    entry: local.entry,
                    definition: local.definition,
                    members: members,
                    providers: providers,
                  ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _editing = false);
    }
    if (_eligible) _controller.retry();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final epoch = widget.app.storageEpoch;
      final actual = _controller.data;
      final members = _members(actual);
      return LocalDefinitions(
        app: widget.app,
        sections: const {LocalYamlSection.strategyGroups},
        members: members,
        builder: (context, definitions) {
          final runtime = {
            for (final group in actual?.groups ?? <StrategyGroup>[])
              group.name: group,
          };
          final records = <Map<String, dynamic>>[
            for (final group in runtime.values)
              {
                'name': group.name,
                'type': group.rawType,
                'provenance': group.provenance?.toJson(),
              },
          ];
          final rows = actual?.matches(widget.app.state.core) == true
              ? DefinitionRows.merge(records, definitions.rows)
              : [...records, ...definitions.rows];
          return StrategiesPage(
            controller: _controller,
            active: _eligible,
            definitions: [
              for (final row in rows)
                StrategyDefinition(
                  runtime: row.containsKey('entryId')
                      ? null
                      : runtime[row['name']],
                  original: row,
                ),
            ],
            definitionActions: (context, row) =>
                definitions.actions(context, row.original),
            onOpenGroup: (group) =>
                _openProperties(group, definitions, members),
            onAdd: _eligible && !_editing && widget.app.overridesLoaded
                ? () => _add(epoch)
                : null,
          );
        },
      );
    },
  );
}

/// Details read captured runtime properties; edits still target the source definition.
class _GroupPropertiesPage extends StatefulWidget {
  const _GroupPropertiesPage({
    required this.app,
    required this.group,
    required this.storageEpoch,
    this.onEdit,
  });
  final AppController app;
  final StrategyDefinition group;
  final int storageEpoch;
  final Future<bool> Function(BuildContext)? onEdit;

  @override
  State<_GroupPropertiesPage> createState() => _GroupPropertiesPageState();
}

class _GroupPropertiesPageState extends State<_GroupPropertiesPage> {
  bool _editing = false;
  bool get _eligible =>
      mounted &&
      widget.app.foreground &&
      widget.storageEpoch == widget.app.storageEpoch &&
      AppTaskActivity.isActive(context) &&
      AppTaskActivity.routeIsActive(ModalRoute.of(context));

  Future<void> _edit() async {
    if (!_eligible || _editing || widget.onEdit == null) return;
    setState(() => _editing = true);
    final saved = await widget.onEdit!(context);
    if (!mounted) return;
    setState(() => _editing = false);
    if (saved && _eligible) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.app,
    builder: (context, _) {
      final strings = AppLocalizations.of(context);
      final group = widget.group;
      final runtime = group.runtime;
      final definition = group.original['definition'] as Map? ?? const {};
      final members = runtime == null
          ? (definition['proxies'] as List? ?? const [])
                .map((value) => value.toString())
                .toList()
          : runtime.members.map((member) => member.name).toList();
      return Scaffold(
        appBar: AppBar(title: Text(strings.strategyGroupDefinitionTitle)),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            key: const ValueKey('group-properties-content'),
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.all(20),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            StrategyIcon(
                              type: group.rawType,
                              source: group.icon,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                group.name,
                                key: const ValueKey('group-properties-name'),
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        Text(
                          strings.strategyGroupAttributesHeading,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          strings.strategyGroupFormType,
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                        SelectableText(group.typeLabel(strings)),
                        const SizedBox(height: 12),
                        Text(
                          strings.hiddenGroupAttribute,
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                        SelectableText(
                          group.hidden ? strings.proxyTrue : strings.proxyFalse,
                        ),
                        if (runtime != null && runtime.selectable) ...[
                          const SizedBox(height: 12),
                          SelectableText(
                            runtime.automatic && runtime.fixed.isNotEmpty
                                ? strings.strategyGroupFixedValue(runtime.fixed)
                                : runtime.now.isNotEmpty
                                ? strings.strategyGroupLoadedValue(runtime.now)
                                : strings.strategyGroupNotSelected,
                          ),
                        ],
                        if (group.icon.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          SelectableText(group.icon),
                        ],
                        const SizedBox(height: 20),
                        Text(
                          strings.strategyGroupFormMembers,
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        if (members.isEmpty)
                          Text(strings.strategyGroupNoMembers),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  sliver: SliverList.builder(
                    itemCount: members.length,
                    itemBuilder: (context, index) => Padding(
                      key: ValueKey(('group-property-member', members[index])),
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SelectableText(members[index]),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        bottomNavigationBar: widget.onEdit == null
            ? null
            : SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: FilledButton.icon(
                    key: const ValueKey('group-properties-edit'),
                    onPressed: _eligible && !_editing ? _edit : null,
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(strings.strategyGroupEditTitle),
                  ),
                ),
              ),
      );
    },
  );
}
