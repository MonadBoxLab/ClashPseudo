part of 'local_custom_editor.dart';

typedef _Definitions = ({
  List<LocalYamlDefinition> rows,
  Map<LocalYamlSection, AppMessage> errors,
  Map<LocalYamlSection, List<String>> names,
});

_Definitions _parseDefinitions((String, Set<LocalYamlSection>) input) {
  final rows = <LocalYamlDefinition>[];
  final errors = <LocalYamlSection, AppMessage>{};
  final names = <LocalYamlSection, List<String>>{};
  try {
    final editor = LocalYamlEdit(input.$1);
    for (final section in LocalYamlSection.values) {
      if (section == LocalYamlSection.rules && !input.$2.contains(section)) {
        continue;
      }
      try {
        final definitions = editor.definitions(section);
        if (input.$2.contains(section)) rows.addAll(definitions);
        if (section != LocalYamlSection.rules) {
          names[section] = definitions.map((row) => row.value).toList();
        }
      } on LocalYamlEditException catch (error) {
        if (input.$2.contains(section)) {
          errors[section] = localYamlEditMessage(error.code);
        }
      }
    }
  } on LocalYamlEditException catch (error) {
    for (final section in input.$2) {
      errors[section] = localYamlEditMessage(error.code);
    }
  }
  return (rows: rows, errors: errors, names: names);
}

/// Manage direct definitions in their category's scroll view. Parse once per saved
/// source identity off the UI isolate.
class LocalDefinitions extends StatefulWidget {
  const LocalDefinitions({
    super.key,
    required this.app,
    required this.sections,
    required this.builder,
    this.query = '',
    this.loadedSource,
    this.loadedContributors = const [],
    this.members = const [],
    this.providers = const [],
    this.targets = const ['DIRECT', 'REJECT'],
    this.ruleProviders = const [],
    this.subRules = const [],
  });
  final Widget Function(BuildContext context, List<ReadingListItem> rows)
  builder;
  final AppController app;
  final Set<LocalYamlSection> sections;
  final String query;
  final CoreSnapshot? loadedSource;
  final List<SourceContribution> loadedContributors;
  final List<String> members;
  final List<String> providers;
  final List<String> targets;
  final List<String> ruleProviders;
  final List<String> subRules;

  @override
  State<LocalDefinitions> createState() => _LocalDefinitionsState();
}

class _LocalDefinitionsState extends State<LocalDefinitions> {
  Object? _identity;
  OverrideEntry? _entry;
  int? _epoch;
  var _request = 0;
  var _loading = false;
  var _working = false;
  var _operationRunner = 0;
  _Definitions _definitions = (rows: [], errors: {}, names: {});
  AppMessage? _failure;
  AppMessage? _operationFailure;
  _LocalCustomSession? _deleteSession;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _deleteSession?.route = ModalRoute.of(context);
    _deleteSession?.syncOwner();
  }

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_changed);
    _load();
  }

  @override
  void didUpdateWidget(LocalDefinitions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app != widget.app) {
      oldWidget.app.removeListener(_changed);
      widget.app.addListener(_changed);
      _operationRunner++;
      _working = false;
      _deleteSession?.dispose();
      _deleteSession = null;
      _operationFailure = null;
      _identity = null;
    }
    _load();
  }

  void _changed() {
    if (!mounted) return;
    _load();
    setState(() {});
  }

  void _load() {
    final app = widget.app;
    final entries = app.overrides.where(
      (entry) => entry.role == OverrideRole.localCustom,
    );
    final entry = entries.length == 1 ? entries.single : null;
    final error =
        app.overrideErrorMessage ??
        (entries.length > 1 ? messages.temporaryOverridesUnreadable : null);
    final identity = (
      entry?.id,
      entry?.revision,
      entry?.body,
      app.storageEpoch,
      error,
      app.overridesLoaded,
      Set<LocalYamlSection>.unmodifiable(widget.sections).join(','),
    );
    if (_identity == identity) {
      if (_entry?.id == entry?.id &&
          _entry?.revision == entry?.revision &&
          _entry?.body == entry?.body) {
        _entry = entry;
      }
      return;
    }
    _identity = identity;
    if (_epoch != null && _epoch != app.storageEpoch) {
      _operationRunner++;
      _working = false;
      _deleteSession?.dispose();
      _deleteSession = null;
      _operationFailure = null;
    }
    final request = ++_request;
    _failure = error;
    if (!app.overridesLoaded || error != null) {
      _loading = false;
      return;
    }
    if (entry == null) {
      _entry = null;
      _epoch = app.storageEpoch;
      _definitions = (rows: [], errors: {}, names: {});
      _loading = false;
      return;
    }
    _loading = true;
    final epoch = app.storageEpoch;
    compute(_parseDefinitions, (
      entry.body,
      Set<LocalYamlSection>.of(widget.sections),
    )).then(
      (definitions) {
        if (!mounted || request != _request) return;
        setState(() {
          _entry = widget.app.overrides.firstWhere(
            (current) =>
                current.id == entry.id &&
                current.revision == entry.revision &&
                current.body == entry.body,
            orElse: () => entry,
          );
          _epoch = epoch;
          _definitions = definitions;
          _loading = false;
        });
      },
      onError: (Object error, StackTrace stack) {
        if (!mounted || request != _request) return;
        setState(() {
          _loading = false;
          _failure = messages.localYamlInvalid;
        });
      },
    );
  }

  bool get _writable {
    final app = widget.app;
    return !_working &&
        _deleteSession?._uncertain != true &&
        !_loading &&
        _failure == null &&
        app.canEdit &&
        app.overridesLoaded &&
        _epoch == app.storageEpoch &&
        _epoch == app.state.storageEpoch &&
        app.overrides.any(
          (entry) =>
              entry.id == _entry?.id &&
              entry.revision == _entry?.revision &&
              entry.body == _entry?.body,
        );
  }

  Future<void> _operate(
    LocalYamlDefinition definition,
    OverrideEntry entry,
    int epoch, {
    bool remove = false,
  }) async {
    if (!_writable ||
        !widget.app.foreground ||
        ModalRoute.of(context)?.isCurrent == false ||
        _epoch != epoch ||
        _entry?.id != entry.id ||
        _entry?.revision != entry.revision ||
        _entry?.body != entry.body) {
      return;
    }
    final run = ++_operationRunner;
    setState(() {
      _working = true;
      _operationFailure = null;
    });
    try {
      if (remove) {
        _deleteSession?.dispose();
        final session = _capture(context, widget.app, epoch, null);
        if (session == null) return;
        _deleteSession = session;
        session.route = ModalRoute.of(context);
        final confirmed = await _confirmLocalDefinitionRemoval(
          context,
          definition,
        );
        if (!confirmed || !mounted) {
          session.dispose();
          if (identical(_deleteSession, session)) _deleteSession = null;
          return;
        }
        await _deleteResult(session, () => session.remove(definition, entry));
      } else {
        _deleteSession?.dispose();
        _deleteSession = null;
        _operationFailure = null;
        final app = widget.app;
        final source = app.state.core;
        final members = <String>{
          ...widget.members,
          ...?_definitions.names[LocalYamlSection.proxies],
          ...?_definitions.names[LocalYamlSection.strategyGroups],
        };
        final targets = <String>{...widget.targets};
        if (definition.section != LocalYamlSection.proxies && source.ready) {
          try {
            final actual = await app.platform
                .strategies(source.generation)
                .timeout(const Duration(seconds: 8));
            if (!mounted || run != _operationRunner) return;
            if (!source.matchesIdentity(app.state.core) ||
                !actual.matches(source)) {
              showAppMessage(context, messages.strategyContextChangedRetry);
              return;
            }
            for (final group in actual.groups) {
              targets.add(group.name);
              members.add(group.name);
              members.addAll(group.members.map((member) => member.name));
            }
          } catch (_) {
            // Keep independent saved definitions and typed input available while
            // runtime suggestions are unavailable.
          }
        }
        if (!mounted || run != _operationRunner) return;
        if (source.ready && !source.matchesIdentity(app.state.core)) {
          showAppMessage(context, messages.strategyContextChangedRetry);
          return;
        }
        await showLocalCustomDefinitionEditor(
          context,
          app: app,
          storageEpoch: epoch,
          entry: entry,
          definition: definition,
          members: members.toList(),
          providers: <String>{
            ...widget.providers,
            ...?_definitions.names[LocalYamlSection.proxyProviders],
          }.toList(),
          targets: targets.toList(),
          ruleProviders: <String>{
            ...widget.ruleProviders,
            ...?_definitions.names[LocalYamlSection.ruleProviders],
          }.toList(),
          subRules: widget.subRules,
        );
      }
    } finally {
      if (mounted && run == _operationRunner) setState(() => _working = false);
    }
  }

  Future<void> _deleteResult(
    _LocalCustomSession session,
    Future<void> Function() operation,
  ) async {
    AppMessage? failure;
    try {
      await operation();
    } on ConfigFailure catch (error) {
      failure = error.message;
    } catch (_) {
      failure = messages.operationNotCompletedRetry;
    }
    if (!mounted || !identical(_deleteSession, session)) return;
    final ownsFeedback =
        !session._relinquished &&
        session._storageCurrent &&
        !session.expired &&
        widget.app.foreground &&
        ModalRoute.of(context)?.isCurrent == true;
    setState(() {
      _operationFailure = failure;
      _working = false;
    });
    session.acknowledge();
    if (failure != null && ownsFeedback) {
      await showAppMessage(context, failure);
    }
    if (!session._retryApply && !session._uncertain) {
      session.dispose();
      if (identical(_deleteSession, session)) _deleteSession = null;
    }
  }

  bool get _canRetryDeletion {
    final session = _deleteSession;
    return !_working &&
        session != null &&
        session._retryApply &&
        !session._uncertain &&
        !session.expired &&
        widget.app.foreground &&
        widget.app.canEdit &&
        ModalRoute.of(context)?.isCurrent == true;
  }

  Future<void> _retryDeletion() async {
    if (!_canRetryDeletion) return;
    final session = _deleteSession!;
    final run = ++_operationRunner;
    setState(() => _working = true);
    try {
      await _deleteResult(session, session.retry);
    } finally {
      if (mounted && run == _operationRunner) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final error =
        _operationFailure ?? _failure ?? _definitions.errors.values.firstOrNull;
    final query = widget.query.trim().toLowerCase();
    final rows = query.isEmpty
        ? _definitions.rows
        : _definitions.rows
              .where((row) => row.value.toLowerCase().contains(query))
              .toList();
    final entry = _entry;
    final epoch = _epoch;
    if (_entry == null && !_loading && error == null) {
      return widget.builder(context, const []);
    }
    final label = _loading || _working
        ? strings.coreReadLoading
        : error != null
        ? strings.operationFailed
        : _entry?.enabled == false
        ? strings.localCustomDisabled
        : rows.isEmpty
        ? strings.localCustomDefinitionsEmpty
        : strings.localCustomNotice;
    final occurrences = <(LocalYamlSection, String), int>{};
    final ids = <Object>[
      for (final row in rows)
        (
          entry?.id,
          epoch,
          row.section,
          row.value,
          occurrences.update(
            (row.section, row.value),
            (value) => value + 1,
            ifAbsent: () => 0,
          ),
        ),
    ];
    Widget item(BuildContext context, int index) {
      if (index == 0) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final style = Theme.of(context).textTheme.bodyMedium!;
            final width = (constraints.maxWidth - 144).clamp(
              0.0,
              double.infinity,
            );
            var height = 0.0;
            for (final message in [
              strings.coreReadLoading,
              strings.operationFailed,
              strings.localCustomDisabled,
              strings.localCustomDefinitionsEmpty,
              strings.localCustomNotice,
            ]) {
              final painter = TextPainter(
                text: TextSpan(text: message, style: style),
                textDirection: Directionality.of(context),
                textScaler: MediaQuery.textScalerOf(context),
                maxLines: 2,
                ellipsis: '…',
              )..layout(maxWidth: width);
              if (painter.height > height) height = painter.height;
              painter.dispose();
            }
            return ListTile(
              key: const ValueKey('local-definitions-header'),
              title: Text(strings.localCustomTitle),
              subtitle: SizedBox(
                height: height,
                child: Tooltip(
                  message: label,
                  child: Text(
                    label,
                    style: style,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              trailing: SizedBox(
                width: 96,
                height: 48,
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 48,
                      child: error == null
                          ? null
                          : IconButton(
                              tooltip: strings.viewConfigError,
                              color: Theme.of(context).colorScheme.error,
                              icon: const Icon(Icons.error_outline),
                              onPressed: () => showAppMessage(context, error),
                            ),
                    ),
                    SizedBox.square(
                      dimension: 48,
                      child: _loading
                          ? const Center(
                              child: SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : _working
                          ? Icon(
                              Icons.hourglass_empty,
                              size: 20,
                              color: HomePalette.of(context).syncAction,
                            )
                          : _deleteSession?._retryApply == true
                          ? IconButton(
                              tooltip: strings.retry,
                              color: HomePalette.of(context).syncAction,
                              icon: const Icon(Icons.refresh),
                              onPressed: _canRetryDeletion
                                  ? _retryDeletion
                                  : null,
                            )
                          : null,
                    ),
                  ],
                ),
              ),
            );
          },
        );
      }
      final row = rows[index - 1];
      final path =
          '/${row.path.map((part) => part.toString().replaceAll('~', '~0').replaceAll('/', '~1')).join('/')}';
      final loaded =
          widget.loadedSource?.ready == true &&
          widget.loadedSource!.matchesIdentity(widget.app.state.core) &&
          widget.loadedContributors.any(
            (source) =>
                source.isLocalCustom &&
                source.id == entry?.id &&
                source.revision == entry?.revision &&
                source.path == path,
          );
      final category = switch (row.section) {
        LocalYamlSection.proxies => strings.proxyNodes,
        LocalYamlSection.strategyGroups => strings.strategyGroups,
        LocalYamlSection.proxyProviders => strings.resourceProxyProvider,
        LocalYamlSection.ruleProviders => strings.resourceRuleProvider,
        LocalYamlSection.rules => strings.rules,
      };
      final status = _entry?.enabled == false
          ? strings.localOriginalDisabled
          : loaded
          ? strings.localOriginalContributes
          : strings.localOriginalUnconfirmed;
      return ListTile(
        key: ValueKey(ids[index - 1]),
        title: Tooltip(
          message: row.value,
          child: Text(
            row.value.isEmpty ? '""' : row.value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        subtitle: LayoutBuilder(
          builder: (context, constraints) {
            final style = Theme.of(context).textTheme.bodyMedium!;
            var height = 0.0;
            for (final state in [
              strings.localOriginalDisabled,
              strings.localOriginalContributes,
              strings.localOriginalUnconfirmed,
            ]) {
              final painter = TextPainter(
                text: TextSpan(
                  text: '${strings.localSavedOriginal} · $category · $state',
                  style: style,
                ),
                textDirection: Directionality.of(context),
                textScaler: MediaQuery.textScalerOf(context),
                maxLines: 2,
                ellipsis: '…',
              )..layout(maxWidth: constraints.maxWidth);
              if (painter.height > height) height = painter.height;
              painter.dispose();
            }
            final label = '${strings.localSavedOriginal} · $category · $status';
            return SizedBox(
              height: height,
              child: Tooltip(
                message: label,
                child: Text(
                  label,
                  style: style,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            );
          },
        ),
        onTap: _writable ? () => _operate(row, entry!, epoch!) : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: strings.editLocalDefinition,
              color: HomePalette.of(context).editAction,
              icon: const Icon(Icons.edit_outlined),
              onPressed: _writable ? () => _operate(row, entry!, epoch!) : null,
            ),
            IconButton(
              tooltip: strings.delete,
              color: Theme.of(context).colorScheme.error,
              icon: const Icon(Icons.delete_outline),
              onPressed: _writable
                  ? () => _operate(row, entry!, epoch!, remove: true)
                  : null,
            ),
          ],
        ),
      );
    }

    Widget readable(BuildContext context, int index) => Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: Semantics(container: true, child: item(context, index)),
      ),
    );
    return widget.builder(context, [
      ReadingListItem(
        id: ('local-header', entry?.id, epoch),
        builder: (context) => readable(context, 0),
      ),
      for (var i = 0; i < rows.length; i++)
        ReadingListItem(
          id: ids[i],
          builder: (context) => readable(context, i + 1),
        ),
    ]);
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(FlagProperty('parsing', value: _loading, ifTrue: 'parsing'));
  }

  @override
  void dispose() {
    _request++;
    _operationRunner++;
    _deleteSession?.dispose();
    widget.app.removeListener(_changed);
    super.dispose();
  }
}
