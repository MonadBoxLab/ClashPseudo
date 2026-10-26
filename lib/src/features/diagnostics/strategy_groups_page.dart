import 'package:flutter/material.dart';

import '../../app/app_theme.dart';

import '../../app/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../model/core_snapshot.dart';
import '../overrides/local_custom_editor.dart';
import '../overrides/local_yaml_edit.dart';
import '../overrides/override_entry.dart';
import '../strategies/strategies_page.dart';
import '../strategies/strategy_controller.dart';
import '../strategies/strategy_icon.dart';
import '../strategies/strategy_snapshot.dart';

class StrategyGroupsPage extends StatefulWidget {
  const StrategyGroupsPage({super.key, required this.app});
  final AppController app;

  @override
  State<StrategyGroupsPage> createState() => _StrategyGroupsPageState();
}

class _StrategyGroupsPageState extends State<StrategyGroupsPage> {
  late final StrategyController _controller;
  bool _editing = false;

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
    if (_editing) return;
    setState(() => _editing = true);
    try {
      await showLocalCustomForm(
        context,
        app: widget.app,
        section: LocalYamlSection.strategyGroups,
        storageEpoch: storageEpoch,
        members: _members(_controller.current ? _controller.data : null),
        providers: _providers(),
      );
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  /// Capture the direct original and require the same source identity when opening its
  /// form.
  ({OverrideEntry entry, LocalYamlDefinition definition})? _localDefinition(
    String name,
  ) {
    if (!widget.app.overridesLoaded) return null;
    final entries = widget.app.overrides
        .where((entry) => entry.role == OverrideRole.localCustom)
        .toList();
    if (entries.length != 1) return null;
    try {
      final editor = LocalYamlEdit(entries.single.body);
      final definition = editor.definitionNamed(
        LocalYamlSection.strategyGroups,
        name,
      );
      if (definition == null ||
          !guiStrategyGroupTypes.contains(
            editor.definitionValue(definition)['type'],
          )) {
        return null;
      }
      return (entry: entries.single, definition: definition);
    } on LocalYamlEditException {
      return null;
    }
  }

  /// Display contributors from the loaded composition. Editing authority separately
  /// follows the direct local definition, including when disabled or overridden.
  String _source(AppLocalizations strings, StrategyGroup group) {
    final provenance = group.provenance;
    if (provenance == null) {
      return group.name == 'GLOBAL'
          ? strings.strategyGroupSourceCore
          : strings.strategyGroupSourceUnknown;
    }
    final plugins = provenance.plugins.toList(growable: false);
    if (plugins.isEmpty) return strings.strategyGroupSourceConfiguration;
    if (plugins.length > 1) return strings.provenancePlugins(plugins.length);
    final source = plugins.single;
    final name = source.name!;
    return source.isLocalCustom && name != strings.localCustomTitle
        ? '$name · ${strings.localCustomTitle}'
        : name;
  }

  Future<void> _openProperties(
    StrategyGroup group,
    int storageEpoch,
    List<String> members,
  ) async {
    if (_editing) return;
    final local = _localDefinition(group.name);
    final core = _controller.current ? widget.app.state.core : null;
    final providers = _providers();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _GroupPropertiesPage(
          app: widget.app,
          core: core,
          group: group,
          source: (strings) => _source(strings, group),
          editable: local != null,
          onEdit: () => local == null
              ? Future.value(false)
              : showLocalCustomDefinitionEditor(
                  context,
                  app: widget.app,
                  storageEpoch: storageEpoch,
                  entry: local.entry,
                  definition: local.definition,
                  members: members,
                  providers: providers,
                ),
        ),
      ),
    );
    if (mounted) _controller.retry();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final epoch = widget.app.storageEpoch;
      final actual = _controller.current ? _controller.data : null;
      final members = _members(actual);
      return LocalDefinitions(
        app: widget.app,
        sections: const {LocalYamlSection.strategyGroups},
        members: members,
        loadedSource: actual == null ? null : widget.app.state.core,
        loadedContributors: [
          if (actual != null)
            for (final group in actual.groups)
              ...?group.provenance?.contributors,
        ],
        builder: (context, rows) => StrategiesPage(
          controller: _controller,
          active: true,
          onOpenGroup: (group) => _openProperties(group, epoch, members),
          onAdd: !_editing && widget.app.overridesLoaded
              ? () => _add(epoch)
              : null,
          localDefinitions: rows,
        ),
      );
    },
  );
}

/// Display actual runtime attributes; enable editing only through the writable original
/// direct definition.
class _GroupPropertiesPage extends StatefulWidget {
  const _GroupPropertiesPage({
    required this.app,
    required this.core,
    required this.group,
    required this.source,
    required this.editable,
    required this.onEdit,
  });

  final AppController app;
  final CoreSnapshot? core;
  final StrategyGroup group;
  final String Function(AppLocalizations) source;
  final bool editable;
  final Future<bool> Function() onEdit;

  @override
  State<_GroupPropertiesPage> createState() => _GroupPropertiesPageState();
}

class _GroupPropertiesPageState extends State<_GroupPropertiesPage> {
  bool _editing = false;

  Future<void> _edit() async {
    if (_editing) return;
    setState(() => _editing = true);
    var saved = false;
    try {
      saved = await widget.onEdit();
    } finally {
      if (mounted) setState(() => _editing = false);
    }
    // The list below re-reads the applied composition; keeping this captured
    // snapshot on screen would present pre-save attributes as current.
    if (saved && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.app,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final currentSource =
        widget.core?.ready == true &&
        widget.core!.matchesIdentity(widget.app.state.core);
    final group = widget.group;
    final plugins =
        group.provenance?.plugins.toList(growable: false) ?? const [];
    final current = group.automatic
        ? group.fixed.isEmpty
              ? strings.strategyGroupNotSelected
              : strings.strategyGroupFixedValue(group.fixed)
        : group.selectable
        ? group.now.isEmpty
              ? strings.strategyGroupNotSelected
              : strings.strategyGroupLoadedValue(group.now)
        : null;
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          SelectableText(value),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(title: Text(strings.strategyGroupDefinitionTitle)),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          key: const ValueKey('group-properties-content'),
          constraints: const BoxConstraints(maxWidth: 840),
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          StrategyIcon(type: group.rawType, source: group.icon),
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
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: SingleChildScrollView(
                          key: const ValueKey('group-properties-runtime-state'),
                          scrollDirection: Axis.horizontal,
                          child: Text(
                            !currentSource
                                ? strings.coreSnapshotStale
                                : widget.core!.purpose == 'PREVIEW'
                                ? strings.runtimeConfigPreview
                                : strings.runtimeConfigLive,
                            softWrap: false,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.source(strings),
                        key: const ValueKey('group-properties-source'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        strings.strategyGroupRuntimePropertiesOnly,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (!widget.editable) ...[
                        const SizedBox(height: 12),
                        Text(
                          strings.strategyGroupSourceReadOnly,
                          key: const ValueKey('group-properties-readonly'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      Padding(
                        padding: const EdgeInsets.only(top: 20, bottom: 12),
                        child: Text(
                          strings.strategyGroupAttributesHeading,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      row(
                        strings.strategyGroupFormType,
                        group.typeLabel(strings),
                      ),
                      row(
                        strings.hiddenGroupAttribute,
                        group.hidden ? strings.proxyTrue : strings.proxyFalse,
                      ),
                      if (current != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: SelectableText(current),
                        ),
                      if (group.icon.isNotEmpty)
                        row(strings.strategyGroupInlineIcon, group.icon),
                      if (plugins.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 8),
                          child: Text(
                            strings.provenanceHeading,
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (plugins.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  sliver: SliverList.builder(
                    itemCount: plugins.length,
                    itemBuilder: (context, index) {
                      final plugin = plugins[index];
                      return Padding(
                        key: ValueKey(('group-contributor', plugin.id)),
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText('${index + 1}. ${plugin.name}'),
                            if (plugin.isLocalCustom)
                              Text(
                                strings.localCustomTitle,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        strings.strategyGroupFormMembers,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      if (group.members.isEmpty)
                        Text(
                          strings.strategyGroupNoMembers,
                          key: const ValueKey('group-properties-members'),
                        ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                sliver: SliverList.builder(
                  itemCount: group.members.length,
                  itemBuilder: (context, index) {
                    final member = group.members[index];
                    return Padding(
                      key: ValueKey(('group-property-member', member.name)),
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          StrategyIcon(type: member.type),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SelectableText(member.name),
                                Text(
                                  member.type,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: widget.editable
          ? SafeArea(
              top: false,
              child: Align(
                alignment: Alignment.bottomCenter,
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 840),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: FilledButton.icon(
                      key: const ValueKey('group-properties-edit'),
                      onPressed: _editing ? null : _edit,
                      icon: _editing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.edit_outlined),
                      style: FilledButton.styleFrom(
                        backgroundColor: HomePalette.of(context).editAction,
                        foregroundColor: Theme.of(context).colorScheme.surface,
                      ),
                      label: Text(strings.strategyGroupEditTitle),
                    ),
                  ),
                ),
              ),
            )
          : null,
    );
  }
}
