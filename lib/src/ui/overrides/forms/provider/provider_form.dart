import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../model/messages.dart';
import '../../../../model/config_entry.dart';
import '../shared/form_body.dart';
import '../shared/form_interaction.dart';
import '../shared/editor.dart';
import '../shared/fields.dart';
import '../shared/save_bar.dart';
import '../proxy/proxy_form.dart';
import '../../../components/feedback/operation_feedback.dart'
    show showAppMessage, showLocalizedOperationMessage;

part 'name_replacements.dart';

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
    this.originalValueText,
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
  final String? Function(List<Object> path)? originalValueText;
  final Widget? notice;

  /// Infallible local-reader notification; storage/ack ownership stays outside.
  final VoidCallback? onSaveHandled;

  @override
  State<ProviderFormPage> createState() => _ProviderFormPageState();
}

class _ProxyDraft {
  _ProxyDraft(this.id, this.definition, {this.initialIndex});
  final int id;
  final int? initialIndex;
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
  ({Object result, bool Function() sourceCurrent})? _completed;
  String? _unknownFailureDetail;
  Object _saveIdentity = Object();
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

  bool _hasInitial(String key, [String scope = '']) {
    final parent = scope.isEmpty
        ? _original
        : _original[scope.replaceAll('/', '')];
    return parent is Map && parent.containsKey(key);
  }

  void _check<T>(String key, [String scope = '']) {
    if (_hasInitial(key, scope) && _initial(key, scope) is! T) {
      _unsupportedFields.add('$scope$key');
    }
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
      if (_original.containsKey('header') && _headers == null) {
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
        if (_hasInitial('override-expr', 'override/') &&
            _strings('override-expr', 'override/') == null) {
          _unsupportedFields.add('override/override-expr');
        }
        final replacements = _initial('proxy-name', 'override/');
        if (_hasInitial('proxy-name', 'override/') &&
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
      if (_original.containsKey('payload') &&
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
      for (final (index, row) in payload.indexed) {
        _payload.add(
          _ProxyDraft(
            _payloadSequence++,
            Map<String, Object?>.from(_copyDraft(row) as Map),
            initialIndex: index,
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

  bool _preserve(String key, [String scope = '']) =>
      _hasInitial(key, scope) && !_touched.contains('$scope$key');

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
        !DefinitionFormInteraction.canAct(context)) {
      return;
    }
    if (!DefinitionFormBody.validate(_form)) return;
    _definition = Map<String, Object?>.from(_copyDraft(_original) as Map);
    // Switching source kind must not delete fields the user did not edit.
    // Hidden source controls keep their draft and do not participate in save.
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
    final sourceCurrent = captureDefinitionSaveSource(context);
    final ownRoute = ModalRoute.of(context);
    final onSaveHandled = widget.onSaveHandled;
    setState(() {
      _saveIdentity = Object();
      _saving = true;
      _failure = null;
      _unknownFailureDetail = null;
    });
    var completed = false;
    try {
      await widget.onSave(_name, definition);
      completed = true;
    } on ConfigFailure catch (failure) {
      if (mounted &&
          ownRoute?.isActive == true &&
          ownRoute?.animation?.status != AnimationStatus.reverse) {
        setState(() => _failure = failure.message);
      }
    } catch (failure) {
      if (mounted &&
          ownRoute?.isActive == true &&
          ownRoute?.animation?.status != AnimationStatus.reverse) {
        setState(() {
          _unknownFailureDetail = failure.toString();
        });
      }
    } finally {
      if (mounted &&
          !completed &&
          ownRoute?.isActive == true &&
          ownRoute?.animation?.status != AnimationStatus.reverse) {
        setState(() => _saving = false);
      }
    }
    if (!mounted ||
        ownRoute?.isActive != true ||
        ownRoute?.animation?.status == AnimationStatus.reverse) {
      return;
    }
    if (completed) {
      setState(
        () => _completed = (result: definition, sourceCurrent: sourceCurrent),
      );
    }
    if (completed) {
      onSaveHandled?.call();
    } else {
      await _presentFailure(sourceCurrent, onSaveHandled);
    }
    if (mounted && completed && ownRoute?.isActive == true) {
      await definitionSaved(
        context,
        definition,
        isSourceCurrent: sourceCurrent,
      );
    }
  }

  Future<void> _presentFailure(
    bool Function() sourceCurrent,
    VoidCallback? onPresented,
  ) async {
    final identity = _saveIdentity;
    final failure = _failure;
    final detail = _unknownFailureDetail;
    await showDefinitionSaveFailure(
      context,
      failure: failure,
      detail: detail,
      isCurrent: () =>
          mounted &&
          !_saving &&
          _completed == null &&
          sourceCurrent() &&
          identical(_saveIdentity, identity) &&
          identical(_failure, failure) &&
          _unknownFailureDetail == detail,
      onDetails: _details,
      onRetry: _save,
      onPresented: onPresented,
    );
  }

  Future<void> _details() {
    if (!mounted ||
        _saving ||
        _completed != null ||
        !DefinitionFormInteraction.canAct(context)) {
      return Future.value();
    }
    final identity = _saveIdentity;
    final failure = _failure;
    final detail = _unknownFailureDetail;
    bool current() =>
        mounted &&
        !_saving &&
        _completed == null &&
        identical(_saveIdentity, identity) &&
        identical(_failure, failure) &&
        _unknownFailureDetail == detail;
    if (failure != null) {
      return showAppMessage(
        context,
        failure,
        title: (strings) => strings.errorDetails,
        isCurrent: current,
        isCurrentWithPopup: (_) => current(),
        onRetry: _save,
      );
    }
    return showLocalizedOperationMessage(
      context,
      (strings) => strings.proxySaveFailed,
      technicalDetail: (_) => detail,
      title: (strings) => strings.errorDetails,
      isCurrent: current,
      isCurrentWithPopup: (_) => current(),
      onRetry: _save,
    );
  }

  Widget _originalField(String path, Widget child) =>
      _unsupportedFields.contains(path)
      ? DefinitionOriginalField(
          key: ValueKey('definition-original:provider/$path'),
          id: 'provider/$path',
          label: path,
          originalValue: path.contains('/')
              ? _initial(path.split('/').last, '${path.split('/').first}/')
              : _original[path],
          originalText: widget.originalValueText?.call(path.split('/')),
          identity: _original,
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
      preserveValue: () => _preserve(key, scope),
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
      preserveValue: () => _preserve(key, scope),
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
    if (_saving ||
        !DefinitionFormInteraction.canAct(context) ||
        editing != null && (!_payloadPresent || !_payload.contains(editing))) {
      return;
    }
    final ownRoute = ModalRoute.of(context)!;
    FocusManager.instance.primaryFocus?.unfocus();
    await Navigator.of(context).push<Map<String, Object?>>(
      MaterialPageRoute(
        builder: (_) => ProxyFormPage(
          initialDefinition: editing == null
              ? null
              : _copyDraft(editing.definition) as Map<String, Object?>,
          originalValueText: editing?.initialIndex == null
              ? null
              : (path) => widget.originalValueText?.call([
                  'payload',
                  editing!.initialIndex!,
                  ...path,
                ]),
          onSave: (definition) async {
            if (!mounted ||
                !ownRoute.isActive ||
                ownRoute.animation?.status == AnimationStatus.reverse ||
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
      bool canAct() =>
          mounted && !_saving && DefinitionFormInteraction.canAct(context);
      void move(_ProxyDraft row, int direction) {
        if (!canAct() || !_payloadPresent) return;
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
                        if (!canAct() ||
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
                      ? () {
                          if (canAct()) _proxy(row);
                        }
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
                      : (value) {
                          if (!canAct()) return;
                          setState(() {
                            _payloadPresent = value;
                            _dirty = true;
                            _payloadTouched = true;
                          });
                        },
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
              onPressed: _saving
                  ? null
                  : () {
                      if (canAct()) _proxy();
                    },
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
          completedResult: _completed?.result,
          isCompletedSourceCurrent: _completed?.sourceCurrent,
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
                                    preserveValue: () =>
                                        _preserve('behavior', ''),
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
                                    preserveValue: () =>
                                        _preserve('format', ''),
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
                              DefinitionFormVisibility(
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
                              DefinitionFormVisibility(
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
                              DefinitionFormVisibility(
                                visible: http,
                                maintainState: true,
                                child: _text(
                                  'proxy',
                                  label: strings.providerFormDownloadProxy,
                                  active: http,
                                  suggestions: widget.downloadProxies,
                                ),
                              ),
                              DefinitionFormVisibility(
                                visible: external,
                                maintainState: true,
                                child: _number(
                                  'interval',
                                  active: external,
                                  unit: strings.proxyUnitSeconds,
                                  max: definitionMaxSeconds,
                                ),
                              ),
                              DefinitionFormVisibility(
                                visible: http,
                                maintainState: true,
                                child: _number(
                                  'size-limit',
                                  active: http,
                                  unit: strings.proxyUnitBytes,
                                ),
                              ),
                              DefinitionFormVisibility(
                                visible: http,
                                maintainState: true,
                                child: _originalField(
                                  'header',
                                  DefinitionHeadersField(
                                    preserveValue: () =>
                                        _preserve('header', ''),
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
                                DefinitionFormVisibility(
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
                                    preserveValue: () =>
                                        _preserve('proxy-name', 'override/'),
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
                                    preserveValue: () =>
                                        _preserve('override-expr', 'override/'),
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
                                        preserveValue: () =>
                                            _preserve('payload', ''),
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
                      completed: _completed != null,
                      onSave: _save,
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
