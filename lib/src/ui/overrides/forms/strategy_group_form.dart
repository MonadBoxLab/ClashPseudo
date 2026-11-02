import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../model/messages.dart';
import '../../../model/config_entry.dart';
import 'shared/form_body.dart';
import 'shared/form_interaction.dart';
import 'shared/editor.dart';
import 'shared/fields.dart';
import 'shared/save_bar.dart';
import '../../components/feedback/operation_feedback.dart'
    show showAppMessage, showLocalizedOperationMessage;

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
    this.originalValueText,
    this.notice,
    this.onSaveHandled,
  });
  final Future<void> Function(Map<String, Object?> definition) onSave;
  final List<String> members;
  final List<String> providers;
  final String initialType;

  /// Complete original direct definition, including unknown fields.
  final Map<String, Object?>? initialDefinition;
  final String? Function(List<Object> path)? originalValueText;
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
  ({Object result, bool Function() sourceCurrent})? _completed;
  String? _unknownFailureDetail;
  Object _saveIdentity = Object();
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

  bool _preserve(String key) =>
      _original.containsKey(key) && !_touched.contains(key);

  void _put(String key, Object? value, {bool active = true}) {
    // Preserve options belonging to other group types in the original field map.
    if (!active || _preserve(key)) {
      return;
    }
    if (value != null) {
      _definition[key] = value;
    } else {
      _definition.remove(key);
    }
  }

  Future<void> _save() async {
    if (!mounted ||
        _saving ||
        _unsupportedIdentity != null ||
        !DefinitionFormInteraction.canAct(context)) {
      return;
    }
    if (!DefinitionFormBody.validate(_form)) return;
    _definition = _copyMap(_original);
    // Selecting a type only edits its discriminator. Inactive controls cannot
    // authorize deletion of their original options (for example tolerance).
    _definition['type'] = _type;
    _form.currentState!.save();
    final definition = Map<String, Object?>.unmodifiable(_definition);
    final sourceCurrent = captureDefinitionSaveSource(context);
    setState(() {
      _saveIdentity = Object();
      _saving = true;
      _failure = null;
      _unknownFailureDetail = null;
    });
    final ownRoute = ModalRoute.of(context);
    final onSaveHandled = widget.onSaveHandled;
    var completed = false;
    try {
      await widget.onSave(definition);
      completed = true;
      if (mounted &&
          ownRoute?.isActive == true &&
          ownRoute?.animation?.status != AnimationStatus.reverse) {
        setState(
          () => _completed = (result: definition, sourceCurrent: sourceCurrent),
        );
        onSaveHandled?.call();
        await definitionSaved(
          context,
          definition,
          isSourceCurrent: sourceCurrent,
        );
      }
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
      // A successfully completed route stays locked throughout its exit.
      if (mounted &&
          !completed &&
          ownRoute?.isActive == true &&
          ownRoute?.animation?.status != AnimationStatus.reverse) {
        setState(() => _saving = false);
      }
    }
    if (mounted && !completed) {
      await _presentFailure(sourceCurrent, onSaveHandled);
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
      );
    }
    return showLocalizedOperationMessage(
      context,
      (strings) => strings.proxySaveFailed,
      technicalDetail: (_) => detail,
      title: (strings) => strings.errorDetails,
      isCurrent: current,
      isCurrentWithPopup: (_) => current(),
    );
  }

  Widget _originalField(String key, Widget child) {
    final value = _original[key];
    if (!_original.containsKey(key) ||
        _representable(key, value) ||
        _touched.contains(key)) {
      return child;
    }
    return DefinitionOriginalField(
      key: ValueKey('definition-original:group/$key'),
      id: 'group/$key',
      label: key,
      originalValue: value,
      originalText: widget.originalValueText?.call([key]),
      identity: _original,
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
      preserveValue: () => _preserve(key),
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
      preserveValue: () => _preserve(key),
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
                                        preserveValue: () => _preserve('name'),
                                        id: 'group/name',
                                        label: strings.definitionFormName,
                                        initialValue: _stringValue('name'),
                                        required: true,
                                        enabled: !_saving,
                                        onSaved: (value) => _put('name', value),
                                        onInteracted: () =>
                                            _touched.add('name'),
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
                                        preserveValue: () =>
                                            _preserve('proxies'),
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
                                        preserveValue: () => _preserve('use'),
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
                                    DefinitionFormVisibility(
                                      visible: _type == 'select',
                                      maintainState: true,
                                      child: _originalField(
                                        'default-selected',
                                        DefinitionTextField(
                                          preserveValue: () =>
                                              _preserve('default-selected'),
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
                                    DefinitionFormVisibility(
                                      visible: _type == 'url-test',
                                      maintainState: true,
                                      child: _number(
                                        'tolerance',
                                        unit: strings.proxyUnitMilliseconds,
                                        max: 65535,
                                        active: _type == 'url-test',
                                      ),
                                    ),
                                    DefinitionFormVisibility(
                                      visible: _type == 'load-balance',
                                      maintainState: true,
                                      child: Column(
                                        children: [
                                          _originalField(
                                            'strategy',
                                            DefinitionChoiceField(
                                              preserveValue: () =>
                                                  _preserve('strategy'),
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
                                              preserveValue: () =>
                                                  _preserve('hash-key'),
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
