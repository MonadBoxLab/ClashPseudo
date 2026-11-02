part of 'local_custom_editor.dart';

int _nextDefinitionSnapshot = 0;

typedef _Definitions = ({
  List<LocalYamlDefinition> rows,
  Map<LocalYamlSection, AppMessage> errors,
  Map<LocalYamlSection, List<String>> names,
  Map<String, Map<String, dynamic>> values,
});

_Definitions _parseDefinitions((String, Set<LocalYamlSection>) input) {
  final rows = <LocalYamlDefinition>[];
  final errors = <LocalYamlSection, AppMessage>{};
  final names = <LocalYamlSection, List<String>>{};
  final values = <String, Map<String, dynamic>>{};
  try {
    final editor = LocalYamlEdit(input.$1);
    for (final section in LocalYamlSection.values) {
      if (section == LocalYamlSection.rules && !input.$2.contains(section)) {
        continue;
      }
      try {
        final definitions = editor.definitions(section);
        if (input.$2.contains(section)) {
          rows.addAll(definitions);
          for (final definition in definitions) {
            if (section == LocalYamlSection.rules) {
              try {
                final fields = ruleFormFields(definition.value);
                values[_definitionPath(definition)] = {
                  'type': fields.type,
                  'payload': fields.value,
                  'target': fields.target,
                  'definition': definition.value,
                };
              } on FormatException {
                values[_definitionPath(definition)] = {
                  'type': '',
                  'payload': definition.value,
                  'target': '',
                  'definition': definition.value,
                };
              }
            } else {
              final value = editor.definitionValue(definition);
              values[_definitionPath(definition)] = {
                'name': definition.value,
                'type': value['type'] ?? '',
                'definition': value,
                if (section == LocalYamlSection.proxyProviders)
                  'kind': 'proxyProvider',
                if (section == LocalYamlSection.ruleProviders)
                  'kind': 'ruleProvider',
                if (section == LocalYamlSection.proxyProviders ||
                    section == LocalYamlSection.ruleProviders)
                  'source': value['url'] ?? value['path'] ?? '',
              };
            }
          }
        }
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
  return (rows: rows, errors: errors, names: names, values: values);
}

String _definitionPath(LocalYamlDefinition definition) =>
    '/${definition.path.map((part) => part.toString().replaceAll('~', '~0').replaceAll('/', '~1')).join('/')}';

/// 捕获同一份原文及编辑目标，不生成独立的本地列表。
class LocalDefinitionCollection {
  const LocalDefinitionCollection({
    this.identity = '',
    this.rows = const [],
    this.edit,
    this.remove,
    this.target,
    this.retry,
  });
  final ({OverrideEntry entry, LocalYamlDefinition definition, int epoch})?
  Function(String identity)?
  target;
  final Future<void> Function()? retry;
  final String identity;
  final List<Map<String, dynamic>> rows;
  final Future<void> Function(String identity)? edit;
  final Future<void> Function(String identity)? remove;

  /// 阅读锚点与编辑目标分开，revision 改变后仍可保留同一条目。
  String? readingIdentity(Map<String, dynamic> row) =>
      row.containsKey('entryId') ? row['readingDefinition'] as String? : null;

  Widget? actions(BuildContext context, Map<String, dynamic> row) {
    final id = row['localDefinition'];
    if (id is! String || !rows.any((row) => row['localDefinition'] == id)) {
      return null;
    }
    final strings = AppLocalizations.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: strings.editLocalDefinition,
          color: HomePalette.of(context).editAction,
          icon: const Icon(Icons.edit_outlined),
          onPressed: edit == null ? null : () => edit!(id),
        ),
        IconButton(
          tooltip: strings.delete,
          color: Theme.of(context).colorScheme.error,
          icon: const Icon(Icons.delete_outline),
          onPressed: remove == null ? null : () => remove!(id),
        ),
      ],
    );
  }
}

/// 原文解析在 UI isolate 之外执行，保留现有保存 session。
class LocalDefinitions extends StatefulWidget {
  const LocalDefinitions({
    super.key,
    required this.app,
    required this.sections,
    required this.builder,
    this.members = const [],
    this.providers = const [],
    this.targets = const ['DIRECT', 'REJECT'],
    this.ruleProviders = const [],
    this.subRules = const [],
  });
  final Widget Function(
    BuildContext context,
    LocalDefinitionCollection definitions,
  )
  builder;
  final AppController app;
  final Set<LocalYamlSection> sections;
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
  Object? _parsedIdentity;
  String _snapshotIdentity = '';
  OverrideEntry? _entry;
  int? _epoch;
  var _request = 0;
  var _loading = false;
  var _working = false;
  var _operationRunner = 0;
  _Definitions _definitions = (rows: [], errors: {}, names: {}, values: {});
  AppMessage? _failure;
  _LocalCustomSession? _deleteSession;
  Object _uiAuthority = Object();

  bool _eligible({ModalRoute<dynamic>? ownedPopup}) =>
      mounted &&
      widget.app.foreground &&
      AppTaskActivity.isActive(context, ownedPopup: ownedPopup) &&
      AppTaskActivity.routeIsActive(
        ModalRoute.of(context),
        ownedPopup: ownedPopup,
      );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_eligible()) _uiAuthority = Object();
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

      _identity = null;
      _parsedIdentity = null;
    }
    _load();
  }

  void _changed() {
    if (!mounted) return;
    if (!_eligible()) _uiAuthority = Object();
    _load();
    _reportReadFailure();
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
    }
    final request = ++_request;
    _failure = error;
    if (!app.overridesLoaded || error != null) {
      _loading = false;
      _reportReadFailure();
      return;
    }
    final definitionIdentity = (
      entry?.id,
      entry?.revision,
      entry?.body,
      app.storageEpoch,
      widget.sections.join(','),
    );
    if (_parsedIdentity == definitionIdentity) {
      _entry = entry;
      _epoch = app.storageEpoch;
      _loading = false;
      return;
    }
    if (entry == null) {
      _parsedIdentity = definitionIdentity;
      _snapshotIdentity = '${++_nextDefinitionSnapshot}';
      _entry = null;
      _epoch = app.storageEpoch;
      _definitions = (rows: [], errors: {}, names: {}, values: {});
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
          _parsedIdentity = definitionIdentity;
          _snapshotIdentity = '${++_nextDefinitionSnapshot}';
          _definitions = definitions;
          _loading = false;
        });
        _reportReadFailure();
      },
      onError: (Object error, StackTrace stack) {
        if (!mounted || request != _request) return;
        setState(() {
          _loading = false;
          _failure = messages.localYamlInvalid.withDetail(error);
        });
        _reportReadFailure();
      },
    );
  }

  bool get _writable {
    final app = widget.app;
    return _eligible() &&
        !_working &&
        _deleteSession?._uncertain != true &&
        !_loading &&
        _failure == null &&
        app.canEditOverrides &&
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
    final authority = _uiAuthority;
    bool current() =>
        _eligible() &&
        identical(authority, _uiAuthority) &&
        run == _operationRunner;
    setState(() {
      _working = true;
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
          widget.app,
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
                .strategies(source)
                .timeout(const Duration(seconds: 8));
            if (!mounted || !current()) return;
            if (!source.matchesIdentity(app.state.core) ||
                !actual.matches(source)) {
              _showFailure(messages.strategyContextChangedRetry);
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
        if (!mounted || !current()) return;
        if (source.ready && !source.matchesIdentity(app.state.core)) {
          _showFailure(messages.strategyContextChangedRetry);
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

  Future<void> _showFailure(
    AppMessage message, {
    VoidCallback? onPresented,
  }) async {
    final identity = _identity;
    await showAppNotice(
      context,
      message,
      isCurrent: () => _eligible() && identity == _identity,
      isCurrentWithPopup: (popup) =>
          _eligible(ownedPopup: popup) && identity == _identity,
      eligibilityChanges: widget.app,
      onRetry: _canRetryDeletion ? _retryDeletion : null,
      onPresented: onPresented,
    );
  }

  bool _readNoticed = false;
  Object? _readSource;
  void _reportReadFailure() {
    if (_working || _deleteSession?._uncertain == true) return;
    final source = (_entry?.id, _entry?.revision, _entry?.body, _epoch);
    if (_readSource != source) {
      _readSource = source;
      _readNoticed = false;
    }
    final error = _failure ?? _definitions.errors.values.firstOrNull;
    if (error == null) {
      if (!_loading) _readNoticed = false;
      return;
    }
    if (_readNoticed) return;
    _readNoticed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_eligible() && _readSource == source) _showFailure(error);
    });
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
    } catch (error) {
      failure = messages.operationNotCompletedRetry.withDetail(error);
    }
    if (!mounted || !identical(_deleteSession, session)) return;
    final ownsFeedback =
        !session._relinquished &&
        session._storageCurrent &&
        !session.expired &&
        _eligible();
    setState(() {
      _working = false;
    });
    if (failure != null && ownsFeedback) {
      await _showFailure(failure, onPresented: session.acknowledge);
    } else if (failure == null) {
      session.acknowledge();
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
        widget.app.canEditOverrides &&
        _eligible();
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
    final entry = _entry;
    final epoch = _epoch;
    final valid = entry != null && epoch != null;
    final identity = epoch == null ? '' : _snapshotIdentity;
    final definitions = <String, LocalYamlDefinition>{};
    final occurrences = <(LocalYamlSection, String), int>{};
    final rows = <Map<String, dynamic>>[];
    if (valid) {
      for (final definition in _definitions.rows) {
        final path = _definitionPath(definition);
        final id = '$identity$path';
        definitions[id] = definition;
        final key = (definition.section, definition.value);
        final occurrence = occurrences[key] ?? 0;
        occurrences[key] = occurrence + 1;
        final readingIdentity = jsonEncode([
          'local',
          entry.id,
          definition.section.name,
          definition.value,
          occurrence,
        ]);
        rows.add(
          Map.unmodifiable({
            ...?_definitions.values[path],
            'localDefinition': id,
            'readingDefinition': readingIdentity,
            'entryId': entry.id,
            'revision': entry.revision,
            'definitionPath': path,
          }),
        );
      }
    }
    return widget.builder(
      context,
      LocalDefinitionCollection(
        identity: identity,
        retry: _canRetryDeletion ? _retryDeletion : null,
        rows: List.unmodifiable(rows),
        target: (id) {
          final definition = definitions[id];
          return definition == null || !valid
              ? null
              : (entry: entry, definition: definition, epoch: epoch);
        },
        edit: !_writable
            ? null
            : (id) async {
                final definition = definitions[id];
                if (definition != null) {
                  await _operate(definition, entry!, epoch!);
                }
              },
        remove: !_writable
            ? null
            : (id) async {
                final definition = definitions[id];
                if (definition != null) {
                  await _operate(definition, entry!, epoch!, remove: true);
                }
              },
      ),
    );
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
