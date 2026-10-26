import 'package:flutter/material.dart';

import '../../app/app_theme.dart';

import '../../l10n/app_localizations.dart';
import '../../l10n/messages.dart';
import '../configs/config_entry.dart';
import 'definition_form_body.dart';
import 'definition_form_fields.dart';
import 'proxy_form.dart';

/// Only lexical validation. The save/native boundary must additionally resolve
/// managed paths and reject protected-file and symlink conflicts before writes.
bool isManagedProviderRelativePath(String value) {
  if (value.isEmpty) return true; // HTTP's native URL-derived cache path.
  if (value.startsWith('/') ||
      value.contains('\\') ||
      RegExp(r'^[A-Za-z]:').hasMatch(value) ||
      value.contains('\u0000')) {
    return false;
  }
  final parts = value.split('/');
  return !parts.contains('..') && parts.last.isNotEmpty && parts.last != '.';
}

bool _httpUrl(String value) {
  if (value.isEmpty) return true;
  final uri = Uri.tryParse(value);
  return uri != null &&
      ['http', 'https'].contains(uri.scheme) &&
      uri.host.isNotEmpty &&
      !value.codeUnits.any((unit) => unit <= 32 || unit == 127);
}

Object? _copyDraft(Object? value) => switch (value) {
  Map value => <String, Object?>{
    for (final entry in value.entries)
      entry.key as String: _copyDraft(entry.value),
  },
  List value => value.map(_copyDraft).toList(),
  _ => value,
};

class ProviderFormPage extends StatefulWidget {
  const ProviderFormPage({
    super.key,
    required this.ruleProvider,
    required this.onSave,
    this.downloadProxies = const [],
    this.initialType = 'http',
    this.initialName,
    this.initialDefinition,
    this.notice,
    this.onSaveHandled,
  });
  final bool ruleProvider;
  final Future<void> Function(String name, Map<String, Object?> definition)
  onSave;
  final List<String> downloadProxies;
  final String initialType;
  final String? initialName;

  /// Complete original direct local fields.
  final Map<String, Object?>? initialDefinition;
  final Widget? notice;

  /// Infallible local-reader notification; storage/ack ownership stays outside.
  final VoidCallback? onSaveHandled;

  @override
  State<ProviderFormPage> createState() => _ProviderFormPageState();
}

class _ProxyDraft {
  _ProxyDraft(this.id, this.definition);
  final int id;
  Map<String, Object?> definition;
}

class _ProviderFormPageState extends State<ProviderFormPage> {
  final _form = GlobalKey<FormState>();
  bool _dirty = false;
  final _scroll = ScrollController();
  late final _original = Map<String, Object?>.from(
    _copyDraft(widget.initialDefinition ?? const <String, Object?>{}) as Map,
  );
  final _touched = <String>{};
  late String _type = _seed<String>('type') ?? widget.initialType;
  late String? _behavior = _seed<String>('behavior');
  var _name = '';
  var _definition = <String, Object?>{};
  var _health = <String, Object?>{};
  var _override = <String, Object?>{};
  final _payload = <_ProxyDraft>[];
  var _payloadPresent = false;
  var _payloadSequence = 0;
  var _saving = false;
  var _unknownFailure = false;
  AppMessage? _failure;

  var _payloadTouched = false;
  final _unsupportedFields = <String>{};
  bool get _unsupportedOriginal => _unsupportedFields.contains('type');

  static const _types = {'http': 'http', 'file': 'file', 'inline': 'inline'};
  static const _behaviors = {
    'domain': 'domain',
    'ipcidr': 'ipcidr',
    'classical': 'classical',
  };
  static const _formats = {'yaml': 'yaml', 'text': 'text', 'mrs': 'mrs'};
  static const _overrideBools = [
    'tfo',
    'mptcp',
    'udp',
    'udp-over-tcp',
    'skip-cert-verify',
  ];
  static const _overrideTexts = [
    'up',
    'down',
    'dialer-proxy',
    'name-cert-verify',
    'interface-name',
    'ip-version',
    'additional-prefix',
    'additional-suffix',
  ];

  void _check<T>(String key, [String scope = '']) {
    final value = _initial(key, scope);
    if (value != null && value is! T) _unsupportedFields.add('$scope$key');
  }

  @override
  void initState() {
    super.initState();
    final payload = _original['payload'];
    if (widget.initialDefinition != null) {
      final type = _original['type'];
      if (!_types.containsKey(type)) _unsupportedFields.add('type');
      for (final key in ['url', 'proxy', 'path']) {
        _check<String>(key);
      }
      _check<int>('size-limit');
      _check<int>('interval');
      if (_original['header'] != null && _headers == null) {
        _unsupportedFields.add('header');
      }
      if (widget.ruleProvider) _check<String>('path-in-bundle');
      if (widget.ruleProvider) {
        _check<String>('behavior');
        _check<String>('format');
        for (final (key, options) in [
          ('behavior', _behaviors.keys),
          ('format', _formats.keys),
        ]) {
          final value = _original[key];
          if (value is String && !options.contains(value)) {
            _unsupportedFields.add(key);
          }
        }
      } else {
        for (final key in [
          'filter',
          'exclude-filter',
          'exclude-type',
          'dialer-proxy',
          'age-secret-key',
        ]) {
          _check<String>(key);
        }
        for (final scope in ['health-check', 'override']) {
          _check<Map>(scope);
        }
        for (final key in ['enable', 'lazy']) {
          _check<bool>(key, 'health-check/');
        }
        for (final key in ['url', 'expected-status']) {
          _check<String>(key, 'health-check/');
        }
        for (final key in ['interval', 'timeout']) {
          _check<int>(key, 'health-check/');
        }
        for (final key in _overrideBools) {
          _check<bool>(key, 'override/');
        }
        for (final key in _overrideTexts) {
          _check<String>(key, 'override/');
        }
        _check<int>('routing-mark', 'override/');
        final expressions = _initial('override-expr', 'override/');
        if (expressions != null &&
            _strings('override-expr', 'override/') == null) {
          _unsupportedFields.add('override/override-expr');
        }
        final replacements = _initial('proxy-name', 'override/');
        if (replacements != null &&
            (replacements is! List ||
                !replacements.every(
                  (row) =>
                      row is Map &&
                      [
                        'pattern',
                        'target',
                      ].every((key) => row[key] == null || row[key] is String),
                ))) {
          _unsupportedFields.add('override/proxy-name');
        }
      }
      if (payload != null &&
          (payload is! List ||
              !payload.every(
                (row) => widget.ruleProvider
                    ? row is String
                    : row is Map<String, Object?> &&
                          row['name'] is String &&
                          row['type'] is String,
              ))) {
        _unsupportedFields.add('payload');
      }
    }
    if (_unsupportedOriginal) return;
    if (!widget.ruleProvider &&
        payload is List &&
        payload.every((row) => row is Map<String, Object?>)) {
      _payloadPresent = true;
      for (final row in payload) {
        _payload.add(
          _ProxyDraft(
            _payloadSequence++,
            Map<String, Object?>.from(_copyDraft(row) as Map),
          ),
        );
      }
    }
  }

  Map<String, Object?> _originalMap(String scope) {
    final value = _original[scope];
    return value is Map
        ? Map<String, Object?>.from(_copyDraft(value) as Map)
        : <String, Object?>{};
  }

  Object? _initial(String key, [String scope = '']) {
    if (scope.isEmpty) return _original[key];
    final parent = _original[scope.replaceAll('/', '')];
    return parent is Map ? parent[key] : null;
  }

  T? _seed<T>(String key, [String scope = '']) {
    final value = _initial(key, scope);
    return value is T ? value : null;
  }

  List<String>? _strings(String key, [String scope = '']) {
    final value = _initial(key, scope);
    return value is List && value.every((item) => item is String)
        ? value.cast<String>()
        : null;
  }

  Map<String, List<String>>? get _headers {
    final value = _original['header'];
    if (value is! Map ||
        !value.entries.every(
          (entry) =>
              entry.key is String &&
              entry.value is List &&
              (entry.value as List).every((item) => item is String),
        )) {
      return null;
    }
    return {
      for (final entry in value.entries)
        entry.key as String: (entry.value as List).cast<String>(),
    };
  }

  void _put(
    Map<String, Object?> into,
    String key,
    Object? value, {
    String scope = '',
    bool active = true,
  }) {
    if (!active) return;
    final original = scope.isEmpty
        ? _original
        : _original[scope.replaceAll('/', '')];
    if (original is Map &&
        original.containsKey(key) &&
        !_touched.contains('$scope$key')) {
      return;
    }
    if (value == null) {
      into.remove(key);
    } else {
      into[key] = value;
    }
  }

  Future<void> _save() async {
    if (!mounted ||
        _saving ||
        _unsupportedOriginal ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    if (!DefinitionFormBody.validate(_form)) return;
    _definition = Map<String, Object?>.from(_copyDraft(_original) as Map);
    if (_original['type'] != _type) {
      if (_type != 'http') {
        for (final key in ['url', 'header', 'proxy', 'size-limit']) {
          _definition.remove(key);
        }
      }
      if (_type == 'inline') {
        for (final key in ['path', 'interval', 'path-in-bundle']) {
          _definition.remove(key);
        }
      }
    }
    _definition['type'] = _type;
    _health = _originalMap('health-check');
    _override = _originalMap('override');
    _form.currentState!.save();
    for (final (key, value) in [
      ('health-check', _health),
      ('override', _override),
    ]) {
      if (value.isNotEmpty) {
        _definition[key] = Map<String, Object?>.unmodifiable(value);
      } else if (_touched.any((field) => field.startsWith('$key/'))) {
        _definition.remove(key);
      }
    }
    if (!widget.ruleProvider &&
        (_payloadTouched || !_original.containsKey('payload'))) {
      if (_payloadPresent) {
        _definition['payload'] = [
          for (final row in _payload) _copyDraft(row.definition),
        ];
      } else {
        _definition.remove('payload');
      }
    }
    final definition = Map<String, Object?>.unmodifiable(_definition);
    setState(() {
      _saving = true;
      _failure = null;
      _unknownFailure = false;
    });
    var completed = false;
    try {
      await widget.onSave(_name, definition);
      completed = true;
      if (mounted) {
        widget.onSaveHandled?.call();
        await definitionSaved(context, definition);
      }
    } on ConfigFailure catch (failure) {
      if (mounted) {
        setState(() => _failure = failure.message);
        widget.onSaveHandled?.call();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _unknownFailure = true);
        widget.onSaveHandled?.call();
      }
    } finally {
      if (mounted && !completed) setState(() => _saving = false);
    }
  }

  Future<void> _details() => showDialog<void>(
    context: context,
    builder: (context) {
      final strings = AppLocalizations.of(context);
      return AlertDialog(
        scrollable: true,
        title: Text(strings.viewConfigError),
        content: SelectableText(
          _failure?.resolve(strings) ?? strings.proxySaveFailed,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(strings.close),
          ),
        ],
      );
    },
  );

  Widget _originalField(String path, Widget child) =>
      _unsupportedFields.contains(path)
      ? DefinitionOriginalField(
          key: ValueKey('definition-original:provider/$path'),
          id: 'provider/$path',
          label: path,
        )
      : child;

  List<Widget> _scopeFields(String scope, List<Widget> children) =>
      _unsupportedFields.contains(scope)
      ? [_originalField(scope, const SizedBox.shrink())]
      : children;

  Widget _text(
    String key, {
    String? label,
    bool active = true,
    bool required = false,
    bool nullable = true,
    bool secret = false,
    String? hint,
    List<String>? suggestions,
    bool Function(String)? valid,
    String? invalid,
    String scope = '',
    Map<String, Object?> Function()? into,
  }) => _originalField(
    '$scope$key',
    DefinitionTextField(
      id: 'provider/$scope$key',
      label: label ?? key,
      initialValue: _seed<String>(key, scope),
      onInteracted: () => _touched.add('$scope$key'),
      active: active,
      enabled: !_saving,
      required: required,
      nullable: nullable,
      secret: secret,
      hint: hint,
      suggestions: suggestions,
      isValid: valid,
      invalidMessage: invalid,
      onSaved: (value) => _put(
        into?.call() ?? _definition,
        key,
        value,
        active: active,
        scope: scope,
      ),
    ),
  );
  Widget _bool(
    String key, {
    String scope = '',
    required Map<String, Object?> Function() into,
  }) => _originalField(
    '$scope$key',
    DefinitionBoolField(
      id: 'provider/$scope$key',
      label: key,
      initialValue: _seed<bool>(key, scope),
      onInteracted: () => _touched.add('$scope$key'),
      enabled: !_saving,
      onSaved: (value) => _put(into(), key, value, scope: scope),
    ),
  );
  Widget _number(
    String key, {
    String scope = '',
    bool active = true,
    String? unit,
    int min = 0,
    int max = definitionInt64Max,
    Map<String, Object?> Function()? into,
  }) => _originalField(
    '$scope$key',
    DefinitionNumberField(
      id: 'provider/$scope$key',
      label: key,
      initialValue: _seed<int>(key, scope),
      onInteracted: () => _touched.add('$scope$key'),
      enabled: !_saving,
      active: active,
      unit: unit,
      min: min,
      max: max,
      onSaved: (value) => _put(
        into?.call() ?? _definition,
        key,
        value,
        scope: scope,
        active: active,
      ),
    ),
  );

  Future<void> _proxy([_ProxyDraft? editing]) async {
    if (_saving) return;
    FocusManager.instance.primaryFocus?.unfocus();
    await Navigator.of(context).push<Map<String, Object?>>(
      MaterialPageRoute(
        builder: (_) => ProxyFormPage(
          initialDefinition: editing == null
              ? null
              : _copyDraft(editing.definition) as Map<String, Object?>,
          onSave: (definition) async {
            if (!mounted ||
                _saving ||
                (editing != null && !_payload.contains(editing))) {
              throw ProxyFormSaveException(messages.storageContextChanged);
            }
            if (_payload.any(
              (row) =>
                  !identical(row, editing) &&
                  row.definition['name'] == definition['name'],
            )) {
              throw ProxyFormSaveException(messages.localYamlDuplicateName);
            }
            final copy = _copyDraft(definition) as Map<String, Object?>;
            setState(() {
              _dirty = true;
              _payloadTouched = true;
              _payloadPresent = true;
              if (editing == null) {
                _payload.add(_ProxyDraft(_payloadSequence++, copy));
              } else {
                editing.definition = copy;
              }
            });
          },
        ),
      ),
    );
  }

  Widget _proxyPayload(String label) => Builder(
    builder: (context) {
      final strings = AppLocalizations.of(context);
      final indices = {
        for (final (index, row) in _payload.indexed)
          ValueKey('provider-proxy:${row.id}'): index,
      };
      void move(_ProxyDraft row, int direction) {
        if (!mounted || _saving || !_payloadPresent) return;
        final from = _payload.indexOf(row);
        final to = from + direction;
        if (from < 0 || to < 0 || to >= _payload.length) return;
        setState(() {
          _payload.removeAt(from);
          _payload.insert(to, row);
          _dirty = true;
          _payloadTouched = true;
        });
      }

      Widget item(int index, {bool prototype = false}) {
        final row = _payload[index];
        final id = prototype ? 'prototype' : '${row.id}';
        final name = row.definition['name'] as String;
        final type = row.definition['type'] as String;
        return Padding(
          key: prototype ? null : ValueKey('provider-proxy:${row.id}'),
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DefinitionRowActions(
                id: 'provider/payload/$id',
                label: label,
                index: index,
                onUp: !prototype && !_saving && _payloadPresent && index > 0
                    ? () => move(row, -1)
                    : null,
                onDown:
                    !prototype &&
                        !_saving &&
                        _payloadPresent &&
                        index + 1 < _payload.length
                    ? () => move(row, 1)
                    : null,
                onRemove: !prototype && !_saving && _payloadPresent
                    ? () {
                        if (!mounted ||
                            _saving ||
                            !_payloadPresent ||
                            !_payload.contains(row)) {
                          return;
                        }
                        setState(() {
                          _payload.remove(row);
                          _dirty = true;
                          _payloadTouched = true;
                        });
                      }
                    : null,
              ),
              Tooltip(
                message: name,
                child: Text(
                  prototype ? '$name\n$name' : name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Tooltip(
                message: type,
                child: Text(
                  type,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (!prototype) const Spacer(),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: prototype
                      ? null
                      : ValueKey('provider-edit-proxy:${row.id}'),
                  onPressed: !prototype && !_saving && _payloadPresent
                      ? () => _proxy(row)
                      : null,
                  style: TextButton.styleFrom(
                    iconColor: HomePalette.of(context).editAction,
                  ),
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(strings.providerFormEditProxy),
                ),
              ),
            ],
          ),
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Semantics(
                label: '${strings.proxyOptional}: $label',
                child: Switch(
                  key: const ValueKey('definition-presence:provider/payload'),
                  value: _payloadPresent,
                  onChanged: _saving
                      ? null
                      : (value) => setState(() {
                          _payloadPresent = value;
                          _dirty = true;
                          _payloadTouched = true;
                        }),
                ),
              ),
            ],
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: DefinitionFormBody.collectionHeightOf(context),
            ),
            child: ListView.builder(
              key: const ValueKey('provider-payload-list'),
              padding: EdgeInsets.zero,
              primary: false,
              shrinkWrap: true,
              // Measure the largest index and two name lines once, then use fixed row
              // metrics for distant jumps.
              prototypeItem: _payload.isEmpty
                  ? null
                  : item(_payload.length - 1, prototype: true),
              itemCount: _payload.length,
              findChildIndexCallback: (key) => indices[key],
              itemBuilder: (context, index) => item(index),
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('provider-add-proxy'),
              onPressed: _saving ? null : _proxy,
              style: TextButton.styleFrom(
                iconColor: HomePalette.of(context).editAction,
              ),
              icon: const Icon(Icons.add),
              label: Text(strings.providerFormAddProxy),
            ),
          ),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final title = widget.initialDefinition != null
        ? strings.editLocalDefinition
        : widget.ruleProvider
        ? strings.providerRuleFormTitle
        : strings.providerProxyFormTitle;
    if (_unsupportedOriginal) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final layout = definitionEditorLayout(
            context,
            title,
            constraints.biggest,
            footerHeight: 0,
          );
          return Scaffold(
            appBar: AppBar(
              title: definitionToolbarTitle(
                context,
                title,
                compact: layout.compact,
              ),
              toolbarHeight: layout.toolbarHeight,
            ),
            body: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                key: const ValueKey('definition-content'),
                constraints: const BoxConstraints(maxWidth: 840),
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.notice != null) widget.notice!,
                      SelectableText(strings.localYamlUnsupportedEdit),
                      const SizedBox(height: 12),
                      SelectableText(_unsupportedFields.join(', ')),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
    }
    final external = _type != 'inline';
    final http = _type == 'http';
    final payloadLabel = external
        ? strings.providerFormFallbackPayload
        : strings.providerFormPayload;
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = definitionEditorLayout(
          context,
          title,
          constraints.biggest,
        );
        return DefinitionEditor(
          dirty: _dirty,
          saving: _saving,
          onSave: _save,
          child: Scaffold(
            appBar: AppBar(
              title: definitionToolbarTitle(
                context,
                title,
                compact: layout.compact,
              ),
              toolbarHeight: layout.toolbarHeight,
            ),
            body: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                key: const ValueKey('definition-content'),
                constraints: BoxConstraints(
                  maxWidth: DefinitionFormBody.widthOf(context),
                ),
                child: Column(
                  children: [
                    Expanded(
                      child: DefinitionFormBody(
                        form: _form,
                        controller: _scroll,
                        header: widget.notice,
                        onChanged: () {
                          if (!_dirty) setState(() => _dirty = true);
                        },
                        chapters: [
                          DefinitionFormChapter(
                            id: 'basic',
                            title: strings.proxyFormBasic,
                            children: [
                              DefinitionChoiceField(
                                id: 'provider/type',
                                label: strings.providerFormType,
                                options: _types,
                                initialValue: _type,
                                optional: false,
                                enabled: !_saving,
                                onChanged: (value) =>
                                    setState(() => _type = value!),
                              ),
                              DefinitionTextField(
                                id: 'provider/name',
                                label: strings.definitionFormName,
                                initialValue: widget.initialName,
                                required: true,
                                enabled: !_saving,
                                onSaved: (value) => _name = value!,
                              ),
                              if (widget.ruleProvider) ...[
                                _originalField(
                                  'behavior',
                                  DefinitionChoiceField(
                                    id: 'provider/behavior',
                                    label: 'behavior',
                                    initialValue: _seed<String>('behavior'),
                                    optional: false,
                                    enabled: !_saving,
                                    options: _behaviors,
                                    onChanged: (value) => setState(() {
                                      _touched.add('behavior');
                                      _behavior = value;
                                    }),
                                    onSaved: (value) =>
                                        _put(_definition, 'behavior', value),
                                  ),
                                ),
                                _originalField(
                                  'format',
                                  DefinitionChoiceField(
                                    id: 'provider/format',
                                    label: 'format',
                                    initialValue: _seed<String>('format'),
                                    onChanged: (_) => _touched.add('format'),
                                    hint: strings.providerFormFormatHint,
                                    enabled: !_saving,
                                    options: _formats,
                                    isValid: (value) =>
                                        value != 'mrs' ||
                                        _behavior != 'classical',
                                    invalidMessage:
                                        strings.providerFormMRSClassical,
                                    onSaved: (value) =>
                                        _put(_definition, 'format', value),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          DefinitionFormChapter(
                            id: 'source',
                            title: strings.providerFormSource,
                            secondary: widget.ruleProvider,
                            visible: external,
                            children: [
                              Visibility(
                                visible: http,
                                maintainState: true,
                                child: _text(
                                  'url',
                                  label: 'URL',
                                  required: true,
                                  nullable: false,
                                  active: http,
                                  valid: _httpUrl,
                                  invalid: strings.providerFormInvalidUrl,
                                ),
                              ),
                              Visibility(
                                visible: external,
                                maintainState: true,
                                child: _text(
                                  'path',
                                  required: _type == 'file',
                                  nullable: _type != 'file',
                                  active: external,
                                  hint: strings.providerFormPathHint,
                                  valid: isManagedProviderRelativePath,
                                  invalid: strings.providerFormInvalidPath,
                                ),
                              ),
                              Visibility(
                                visible: http,
                                maintainState: true,
                                child: _text(
                                  'proxy',
                                  label: strings.providerFormDownloadProxy,
                                  active: http,
                                  suggestions: widget.downloadProxies,
                                ),
                              ),
                              Visibility(
                                visible: external,
                                maintainState: true,
                                child: _number(
                                  'interval',
                                  active: external,
                                  unit: strings.proxyUnitSeconds,
                                  max: definitionMaxSeconds,
                                ),
                              ),
                              Visibility(
                                visible: http,
                                maintainState: true,
                                child: _number(
                                  'size-limit',
                                  active: http,
                                  unit: strings.proxyUnitBytes,
                                ),
                              ),
                              Visibility(
                                visible: http,
                                maintainState: true,
                                child: _originalField(
                                  'header',
                                  DefinitionHeadersField(
                                    id: 'provider/header',
                                    label: strings.providerFormHeaders,
                                    initialValue: _headers,
                                    onChanged: (_) => _touched.add('header'),
                                    active: http,
                                    enabled: !_saving,
                                    onSaved: (value) => _put(
                                      _definition,
                                      'header',
                                      value,
                                      active: http,
                                    ),
                                  ),
                                ),
                              ),
                              if (widget.ruleProvider)
                                Visibility(
                                  visible: external,
                                  maintainState: true,
                                  child: _text(
                                    'path-in-bundle',
                                    active: external,
                                  ),
                                ),
                            ],
                          ),
                          if (!widget.ruleProvider) ...[
                            DefinitionFormChapter(
                              id: 'advanced',
                              title: strings.proxyFormAdvanced,
                              secondary: true,
                              children: [
                                _text('filter'),
                                _text('exclude-filter'),
                                _text('exclude-type'),
                                _text(
                                  'dialer-proxy',
                                  suggestions: widget.downloadProxies,
                                ),
                                _text('age-secret-key', secret: true),
                              ],
                            ),
                            DefinitionFormChapter(
                              id: 'health-check',
                              title: strings.providerFormHealthCheck,
                              secondary: true,
                              children: _scopeFields('health-check', [
                                _bool(
                                  'enable',
                                  scope: 'health-check/',
                                  into: () => _health,
                                ),
                                _text(
                                  'url',
                                  scope: 'health-check/',
                                  valid: _httpUrl,
                                  invalid: strings.providerFormInvalidUrl,
                                  into: () => _health,
                                ),
                                _number(
                                  'interval',
                                  scope: 'health-check/',
                                  unit: strings.proxyUnitSeconds,
                                  max: definitionMaxSeconds,
                                  into: () => _health,
                                ),
                                _number(
                                  'timeout',
                                  scope: 'health-check/',
                                  unit: strings.proxyUnitMilliseconds,
                                  max: definitionMaxMilliseconds,
                                  into: () => _health,
                                ),
                                _bool(
                                  'lazy',
                                  scope: 'health-check/',
                                  into: () => _health,
                                ),
                                _text(
                                  'expected-status',
                                  scope: 'health-check/',
                                  into: () => _health,
                                ),
                              ]),
                            ),
                            DefinitionFormChapter(
                              id: 'override',
                              title: strings.providerFormOverride,
                              secondary: true,
                              initiallyExpanded: false,
                              children: _scopeFields('override', [
                                Text(
                                  strings.providerFormAndroidIgnored,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                for (final key in _overrideBools)
                                  _bool(
                                    key,
                                    scope: 'override/',
                                    into: () => _override,
                                  ),
                                for (final key in _overrideTexts)
                                  _text(
                                    key,
                                    scope: 'override/',
                                    into: () => _override,
                                    suggestions: key == 'dialer-proxy'
                                        ? widget.downloadProxies
                                        : key == 'ip-version'
                                        ? const [
                                            'dual',
                                            'ipv4',
                                            'ipv6',
                                            'ipv4-prefer',
                                            'ipv6-prefer',
                                          ]
                                        : const [],
                                  ),
                                _number(
                                  'routing-mark',
                                  scope: 'override/',
                                  min: definitionInt64Min,
                                  into: () => _override,
                                ),
                                _originalField(
                                  'override/proxy-name',
                                  _NameReplacements(
                                    enabled: !_saving,
                                    initialValue: _seed<List>(
                                      'proxy-name',
                                      'override/',
                                    ),
                                    onChanged: () =>
                                        _touched.add('override/proxy-name'),
                                    onSaved: (value) => _put(
                                      _override,
                                      'proxy-name',
                                      value,
                                      scope: 'override/',
                                    ),
                                  ),
                                ),
                                _originalField(
                                  'override/override-expr',
                                  DefinitionStringListField(
                                    id: 'provider/override/override-expr',
                                    label: strings.providerFormExpressions,
                                    initialValue: _strings(
                                      'override-expr',
                                      'override/',
                                    ),
                                    onChanged: (_) =>
                                        _touched.add('override/override-expr'),
                                    enabled: !_saving,
                                    multiline: true,
                                    onSaved: (value) => _put(
                                      _override,
                                      'override-expr',
                                      value,
                                      scope: 'override/',
                                    ),
                                  ),
                                ),
                              ]),
                            ),
                          ],
                          DefinitionFormChapter(
                            id: 'payload',
                            title: payloadLabel,
                            fullWidth: true,
                            children: [
                              _originalField(
                                'payload',
                                widget.ruleProvider
                                    ? DefinitionStringListField(
                                        id: 'provider/payload',
                                        label: payloadLabel,
                                        initialValue: _strings('payload'),
                                        onChanged: (_) =>
                                            _touched.add('payload'),
                                        enabled: !_saving,
                                        onSaved: (value) =>
                                            _put(_definition, 'payload', value),
                                      )
                                    : _proxyPayload(payloadLabel),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    DefinitionSaveBar(
                      id: 'provider',
                      compact: layout.compact,
                      saving: _saving,
                      failed: _failure != null || _unknownFailure,
                      onSave: _save,
                      onDetails: _details,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }
}

class _NameReplacements extends StatefulWidget {
  const _NameReplacements({
    required this.enabled,
    required this.onSaved,
    this.initialValue,
    this.onChanged,
  });
  final bool enabled;
  final List? initialValue;
  final VoidCallback? onChanged;
  final ValueChanged<List<Map<String, Object?>>?> onSaved;
  @override
  State<_NameReplacements> createState() => _NameReplacementsState();
}

class _NameReplacementsState extends State<_NameReplacements> {
  int? _errorId;
  final _scroll = ScrollController();
  late bool _present = widget.initialValue != null;
  var _sequence = 0;
  late final _rows = <({int id, Map<String, Object?> data})>[
    for (final value in widget.initialValue ?? const [])
      if (value is Map<String, Object?>) (id: _sequence++, data: Map.of(value)),
  ];

  Future<BuildContext?> _revealError() async {
    final index = _rows.indexWhere((row) => row.id == _errorId);
    if (!mounted ||
        !widget.enabled ||
        !_present ||
        index < 0 ||
        _rows[index].data['pattern'] is String &&
            (_rows[index].data['pattern'] as String).isNotEmpty) {
      return null;
    }
    return DefinitionFormBody.revealListRow(
      context: context,
      controller: _scroll,
      index: index,
      count: _rows.length,
      rowKey: ValueKey('provider-replacement:${_rows[index].id}'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final label = strings.providerFormProxyNames;
    return DefinitionValidationTarget(
      reveal: _revealError,
      child: FormField<List<Map<String, Object?>>>(
        validator: (_) {
          _errorId = null;
          if (!_present) return null;
          for (final row in _rows) {
            if (row.data['pattern'] is! String ||
                (row.data['pattern'] as String).isEmpty) {
              _errorId = row.id;
              return strings.proxyRequired;
            }
          }
          return null;
        },
        onSaved: (_) => widget.onSaved(
          _present
              ? [for (final row in _rows) Map<String, Object?>.of(row.data)]
              : null,
        ),
        builder: (field) {
          void changed() {
            widget.onChanged?.call();
            field.didChange(
              _present
                  ? [for (final row in _rows) Map<String, Object?>.of(row.data)]
                  : null,
            );
          }

          void move(int id, int direction) {
            if (!mounted || !widget.enabled || !_present) return;
            final from = _rows.indexWhere((row) => row.id == id);
            final to = from + direction;
            if (from < 0 || to < 0 || to >= _rows.length) return;
            setState(() {
              final row = _rows.removeAt(from);
              _rows.insert(to, row);
              changed();
            });
          }

          Widget item(int index, {bool prototype = false}) {
            final row = _rows[index];
            final id = prototype ? 'prototype' : '${row.id}';
            final editable = !prototype && widget.enabled && _present;
            void change(String key, String value) {
              if (!mounted ||
                  !widget.enabled ||
                  !_present ||
                  !_rows.any((item) => item.id == row.id)) {
                return;
              }
              row.data[key] = value;
              changed();
            }

            return Padding(
              key: prototype
                  ? null
                  : ValueKey('provider-replacement:${row.id}'),
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DefinitionRowActions(
                    id: 'provider/override/proxy-name/$id',
                    label: label,
                    index: index,
                    onUp: editable && index > 0 ? () => move(row.id, -1) : null,
                    onDown: editable && index + 1 < _rows.length
                        ? () => move(row.id, 1)
                        : null,
                    onRemove: editable
                        ? () {
                            if (!mounted || !widget.enabled || !_present) {
                              return;
                            }
                            final at = _rows.indexWhere(
                              (item) => item.id == row.id,
                            );
                            if (at < 0) return;
                            setState(() {
                              _rows.removeAt(at);
                              changed();
                            });
                          }
                        : null,
                  ),
                  DefinitionTextField(
                    id: 'provider/override/proxy-name/$id/pattern',
                    label: strings.providerFormPattern,
                    initialValue: prototype
                        ? ''
                        : row.data['pattern'] as String?,
                    required: true,
                    trimRequired: false,
                    active: !prototype && _present,
                    enabled: !prototype && widget.enabled,
                    onChanged: prototype
                        ? null
                        : (value) => change('pattern', value),
                  ),
                  DefinitionTextField(
                    id: 'provider/override/proxy-name/$id/target',
                    label: strings.providerFormReplacement,
                    initialValue: prototype
                        ? ''
                        : row.data['target'] as String?,
                    active: !prototype && _present,
                    enabled: !prototype && widget.enabled,
                    onChanged: prototype
                        ? null
                        : (value) => change('target', value),
                  ),
                ],
              ),
            );
          }

          final indices = {
            for (final (index, row) in _rows.indexed)
              ValueKey('provider-replacement:${row.id}'): index,
          };
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  Semantics(
                    label: '${strings.proxyOptional}: $label',
                    child: Switch(
                      key: const ValueKey(
                        'definition-presence:provider/override/proxy-name',
                      ),
                      value: _present,
                      onChanged: widget.enabled
                          ? (value) => setState(() {
                              _present = value;
                              changed();
                            })
                          : null,
                    ),
                  ),
                ],
              ),
              if (_rows.isNotEmpty)
                Visibility(
                  maintainState: true,
                  maintainAnimation: true,
                  maintainSize: true,
                  visible: _present && field.hasError,
                  child: Text(
                    strings.proxyRequired,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: DefinitionFormBody.collectionHeightOf(context),
                ),
                child: ListView.builder(
                  key: const ValueKey('provider-replacement-list'),
                  controller: _scroll,
                  padding: EdgeInsets.zero,
                  primary: false,
                  shrinkWrap: true,
                  prototypeItem: _rows.isEmpty
                      ? null
                      : ExcludeFocus(
                          child: ExcludeSemantics(
                            child: item(_rows.length - 1, prototype: true),
                          ),
                        ),
                  itemCount: _rows.length,
                  findChildIndexCallback: (key) => indices[key],
                  itemBuilder: (context, index) => item(index),
                ),
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey(
                    'definition-add:provider/override/proxy-name',
                  ),
                  onPressed: widget.enabled
                      ? () {
                          final id = _sequence++;
                          setState(() {
                            _present = true;
                            _rows.add((
                              id: id,
                              data: {'pattern': '', 'target': ''},
                            ));
                            changed();
                          });
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted &&
                                widget.enabled &&
                                _present &&
                                _rows.lastOrNull?.id == id &&
                                _scroll.hasClients) {
                              _scroll.jumpTo(_scroll.position.maxScrollExtent);
                            }
                          });
                        }
                      : null,
                  style: TextButton.styleFrom(
                    iconColor: HomePalette.of(context).editAction,
                  ),
                  icon: const Icon(Icons.add),
                  label: Text(strings.proxyAddItem(label)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }
}
