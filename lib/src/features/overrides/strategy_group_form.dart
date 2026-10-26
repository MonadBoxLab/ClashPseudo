import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../l10n/messages.dart';
import '../configs/config_entry.dart';
import 'definition_form_body.dart';
import 'definition_form_fields.dart';

/// Create or edit a direct local definition from its original field map, preserving
/// unknown fields and explicit false/0/empty values. References supply suggestions; the
/// caller owns storage identity and save/apply results.
class StrategyGroupFormPage extends StatefulWidget {
  const StrategyGroupFormPage({
    super.key,
    required this.onSave,
    this.members = const [],
    this.providers = const [],
    this.initialType = 'select',
    this.initialDefinition,
    this.notice,
    this.onSaveHandled,
  });
  final Future<void> Function(Map<String, Object?> definition) onSave;
  final List<String> members;
  final List<String> providers;
  final String initialType;

  /// Complete original direct definition, including unknown fields.
  final Map<String, Object?>? initialDefinition;
  final Widget? notice;

  /// Infallible local-reader notification; storage/ack ownership stays outside.
  final VoidCallback? onSaveHandled;

  @override
  State<StrategyGroupFormPage> createState() => _StrategyGroupFormPageState();
}

class _StrategyGroupFormPageState extends State<StrategyGroupFormPage> {
  final _form = GlobalKey<FormState>();
  bool _dirty = false;
  final _touched = <String>{};
  final _scroll = ScrollController();
  late Map<String, Object?> _original;
  late String _type;
  String? _loadBalanceStrategy;
  var _definition = <String, Object?>{};
  var _saving = false;
  var _unknownFailure = false;
  String? _unsupportedIdentity;
  AppMessage? _failure;

  bool get _editing => widget.initialDefinition != null;

  static Map<String, Object?> _copyMap(Map<String, Object?> value) => {
    for (final entry in value.entries) entry.key: _copyValue(entry.value),
  };

  static Object? _copyValue(Object? value) => switch (value) {
    Map() => _copyMap(Map<String, Object?>.from(value)),
    List() => <Object?>[for (final item in value) _copyValue(item)],
    _ => value,
  };

  static const _types = {
    'select': 'select',
    'url-test': 'url-test',
    'fallback': 'fallback',
    'load-balance': 'load-balance',
  };

  /// A direct value representable by this GUI with its original type.
  static bool _representable(String key, Object? value) => switch (key) {
    'proxies' ||
    'use' => value is List && value.every((item) => item is String),
    'lazy' ||
    'disable-udp' ||
    'include-all' ||
    'include-all-proxies' ||
    'include-all-providers' ||
    'hidden' => value is bool,
    'tolerance' ||
    'interval' ||
    'timeout' ||
    'max-failed-times' => value is int,
    _ => value is String,
  };

  @override
  void initState() {
    super.initState();
    _original = _copyMap(widget.initialDefinition ?? const {});
    final rawType = _original['type'];
    if (_editing) {
      if (!_types.containsKey(rawType)) {
        _unsupportedIdentity = 'type';
      } else if (_original['name'] != null && _original['name'] is! String) {
        _unsupportedIdentity = 'name';
      }
    }
    _type = rawType is String ? rawType : widget.initialType;
    final strategy = _original['strategy'];
    _loadBalanceStrategy = strategy is String ? strategy : null;
  }

  String? _stringValue(String key) {
    final value = _original[key];
    return value is String ? value : null;
  }

  List<String>? _stringListValue(String key) {
    final value = _original[key];
    return value is List && value.every((item) => item is String)
        ? value.cast<String>()
        : null;
  }

  bool? _boolValue(String key) {
    final value = _original[key];
    return value is bool ? value : null;
  }

  int? _intValue(String key) {
    final value = _original[key];
    return value is int ? value : null;
  }

  void _put(String key, Object? value, {bool active = true}) {
    // Preserve options belonging to other group types in the original field map.
    if (!active) return;
    if (value != null) {
      _definition[key] = value;
      return;
    }
    // Preserve an unrepresentable original while untouched; an explicit unset applies
    // the requested removal.
    final original = _original[key];
    if (!_touched.contains(key) &&
        _original.containsKey(key) &&
        !_representable(key, original)) {
      return;
    }
    _definition.remove(key);
  }

  /// Options that only one public group Option type consumes. Changing the
  /// type removes the previous type's options instead of carrying dead keys
  /// into the new definition; an unchanged type keeps every original field.
  static const _typeOptions = {
    'default-selected': 'select',
    'tolerance': 'url-test',
    'strategy': 'load-balance',
    'hash-key': 'load-balance',
  };

  Future<void> _save() async {
    if (!mounted || _saving || _unsupportedIdentity != null) return;
    if (!DefinitionFormBody.validate(_form)) return;
    _definition = _copyMap(_original);
    final previousType = _original['type'];
    if (previousType is String && previousType != _type) {
      for (final option in _typeOptions.entries) {
        if (option.value == previousType) _definition.remove(option.key);
      }
    }
    _definition['type'] = _type;
    for (final key in _touched) {
      if (!_representable(key, _original[key])) _definition.remove(key);
    }
    _form.currentState!.save();
    final definition = Map<String, Object?>.unmodifiable(_definition);
    setState(() {
      _saving = true;
      _failure = null;
      _unknownFailure = false;
    });
    var completed = false;
    try {
      await widget.onSave(definition);
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
      // A successfully completed route stays locked throughout its exit.
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

  Widget _originalField(String key, Widget child) {
    final value = _original[key];
    if (value == null || _representable(key, value) || _touched.contains(key)) {
      return child;
    }
    return DefinitionOriginalField(
      key: ValueKey('definition-original:group/$key'),
      id: 'group/$key',
      label: key,
      enabled: !_saving,
      onUnset: () {
        if (!mounted || _saving) return;
        setState(() {
          _dirty = true;
          _touched.add(key);
        });
      },
    );
  }

  Widget _text(String key, {List<String>? suggestions}) => _originalField(
    key,
    DefinitionTextField(
      id: 'group/$key',
      label: key,
      initialValue: _stringValue(key),
      nullable: true,
      enabled: !_saving,
      suggestions: suggestions,
      onSaved: (value) => _put(key, value),
      onInteracted: () => _touched.add(key),
    ),
  );
  Widget _bool(String key) => _originalField(
    key,
    DefinitionBoolField(
      id: 'group/$key',
      label: key,
      initialValue: _boolValue(key),
      enabled: !_saving,
      onSaved: (value) => _put(key, value),
      onInteracted: () => _touched.add(key),
    ),
  );
  Widget _number(
    String key, {
    String? unit,
    int max = definitionInt64Max,
    bool active = true,
  }) => _originalField(
    key,
    DefinitionNumberField(
      id: 'group/$key',
      label: key,
      initialValue: _intValue(key),
      enabled: !_saving,
      active: active,
      unit: unit,
      max: max,
      onSaved: (value) => _put(key, value, active: active),
      onInteracted: () => _touched.add(key),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final title = _editing
        ? strings.strategyGroupEditTitle
        : strings.strategyGroupFormTitle;
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = definitionEditorLayout(
          context,
          title,
          constraints.biggest,
          footerHeight: _unsupportedIdentity == null ? null : 0,
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
                child: _unsupportedIdentity != null
                    ? SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (widget.notice != null) widget.notice!,
                            SelectableText(strings.localYamlUnsupportedEdit),
                            const SizedBox(height: 12),
                            SelectableText(_unsupportedIdentity!),
                          ],
                        ),
                      )
                    : Column(
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
                                      id: 'group/type',
                                      label: strings.strategyGroupFormType,
                                      options: _types,
                                      initialValue: _type,
                                      optional: false,
                                      enabled: !_saving,
                                      onChanged: (value) =>
                                          setState(() => _type = value!),
                                    ),
                                    _originalField(
                                      'name',
                                      DefinitionTextField(
                                        id: 'group/name',
                                        label: strings.definitionFormName,
                                        initialValue: _stringValue('name'),
                                        required: true,
                                        enabled: !_saving,
                                        onSaved: (value) => _put('name', value),
                                      ),
                                    ),
                                  ],
                                ),
                                DefinitionFormChapter(
                                  id: 'members',
                                  title: strings.strategyGroupFormMembers,
                                  children: [
                                    _originalField(
                                      'proxies',
                                      DefinitionStringListField(
                                        id: 'group/proxies',
                                        label: strings.strategyGroupFormMembers,
                                        initialValue: _stringListValue(
                                          'proxies',
                                        ),
                                        suggestions: widget.members,
                                        enabled: !_saving,
                                        onSaved: (value) =>
                                            _put('proxies', value),
                                        onChanged: (_) =>
                                            _touched.add('proxies'),
                                      ),
                                    ),
                                    _originalField(
                                      'use',
                                      DefinitionStringListField(
                                        id: 'group/use',
                                        label:
                                            strings.strategyGroupFormProviders,
                                        initialValue: _stringListValue('use'),
                                        suggestions: widget.providers,
                                        enabled: !_saving,
                                        onSaved: (value) => _put('use', value),
                                        onChanged: (_) => _touched.add('use'),
                                      ),
                                    ),
                                  ],
                                ),
                                DefinitionFormChapter(
                                  id: 'protocol',
                                  title: strings.proxyFormProtocol,
                                  secondary: true,
                                  children: [
                                    Visibility(
                                      visible: _type == 'select',
                                      maintainState: true,
                                      child: _originalField(
                                        'default-selected',
                                        DefinitionTextField(
                                          id: 'group/default-selected',
                                          label: 'default-selected',
                                          initialValue: _stringValue(
                                            'default-selected',
                                          ),
                                          nullable: true,
                                          active: _type == 'select',
                                          enabled: !_saving,
                                          suggestions: widget.members,
                                          onInteracted: () =>
                                              _touched.add('default-selected'),
                                          onSaved: (value) => _put(
                                            'default-selected',
                                            value,
                                            active: _type == 'select',
                                          ),
                                        ),
                                      ),
                                    ),
                                    Visibility(
                                      visible: _type == 'url-test',
                                      maintainState: true,
                                      child: _number(
                                        'tolerance',
                                        unit: strings.proxyUnitMilliseconds,
                                        max: 65535,
                                        active: _type == 'url-test',
                                      ),
                                    ),
                                    Visibility(
                                      visible: _type == 'load-balance',
                                      maintainState: true,
                                      child: Column(
                                        children: [
                                          _originalField(
                                            'strategy',
                                            DefinitionChoiceField(
                                              id: 'group/strategy',
                                              label: 'strategy',
                                              initialValue: _stringValue(
                                                'strategy',
                                              ),
                                              active: _type == 'load-balance',
                                              enabled: !_saving,
                                              options: const {
                                                'consistent-hashing':
                                                    'consistent-hashing',
                                                'round-robin': 'round-robin',
                                                'sticky-sessions':
                                                    'sticky-sessions',
                                              },
                                              onChanged: (value) {
                                                _touched.add('strategy');
                                                setState(
                                                  () => _loadBalanceStrategy =
                                                      value,
                                                );
                                              },
                                              onSaved: (value) => _put(
                                                'strategy',
                                                value,
                                                active: _type == 'load-balance',
                                              ),
                                            ),
                                          ),
                                          _originalField(
                                            'hash-key',
                                            DefinitionChoiceField(
                                              id: 'group/hash-key',
                                              label: 'hash-key',
                                              initialValue: _stringValue(
                                                'hash-key',
                                              ),
                                              active: _type == 'load-balance',
                                              enabled: !_saving,
                                              options: const {
                                                '': '""',
                                                'in-user': 'in-user',
                                              },
                                              onChanged: (_) =>
                                                  _touched.add('hash-key'),
                                              isValid: (value) =>
                                                  _loadBalanceStrategy !=
                                                      'round-robin' ||
                                                  value.isEmpty,
                                              invalidMessage: strings
                                                  .strategyGroupHashKeyInvalid,
                                              onSaved: (value) => _put(
                                                'hash-key',
                                                value,
                                                active: _type == 'load-balance',
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                DefinitionFormChapter(
                                  id: 'advanced',
                                  title: strings.proxyFormAdvanced,
                                  secondary: true,
                                  initiallyExpanded: false,
                                  children: [
                                    _text('url'),
                                    _number(
                                      'interval',
                                      unit: strings.proxyUnitSeconds,
                                      max: definitionMaxSeconds,
                                    ),
                                    _number(
                                      'timeout',
                                      unit: strings.proxyUnitMilliseconds,
                                      max: definitionMaxMilliseconds,
                                    ),
                                    _number('max-failed-times'),
                                    _text(
                                      'empty-fallback',
                                      suggestions: widget.members,
                                    ),
                                    _bool('lazy'),
                                    _bool('disable-udp'),
                                    _text('filter'),
                                    _text('exclude-filter'),
                                    _text('exclude-type'),
                                    _text('expected-status'),
                                    _bool('include-all'),
                                    _bool('include-all-proxies'),
                                    _bool('include-all-providers'),
                                    _bool('hidden'),
                                    _text('icon'),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          DefinitionSaveBar(
                            id: 'group',
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
