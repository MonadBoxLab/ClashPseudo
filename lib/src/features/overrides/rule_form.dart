import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../l10n/messages.dart';
import '../configs/config_entry.dart';
import 'definition_form_body.dart';
import 'definition_form_fields.dart';

/// Raw rule tokens accepted by the selected mihomo parser.
const ruleFormTypes = [
  'DOMAIN',
  'DOMAIN-SUFFIX',
  'DOMAIN-KEYWORD',
  'DOMAIN-REGEX',
  'DOMAIN-WILDCARD',
  'GEOSITE',
  'GEOIP',
  'SRC-GEOIP',
  'IP-ASN',
  'SRC-IP-ASN',
  'IP-CIDR',
  'IP-CIDR6',
  'SRC-IP-CIDR',
  'IP-SUFFIX',
  'SRC-IP-SUFFIX',
  'SRC-PORT',
  'DST-PORT',
  'IN-PORT',
  'DSCP',
  'PROCESS-NAME',
  'PROCESS-PATH',
  'PROCESS-NAME-REGEX',
  'PROCESS-PATH-REGEX',
  'PROCESS-NAME-WILDCARD',
  'PROCESS-PATH-WILDCARD',
  'NETWORK',
  'UID',
  'IN-TYPE',
  'IN-USER',
  'IN-NAME',
  'REMATCH-NAME',
  'SUB-RULE',
  'AND',
  'OR',
  'NOT',
  'RULE-SET',
  'MATCH',
];
const _conditionTypes = {'AND', 'OR', 'NOT', 'SUB-RULE'};
const _regexTypes = {
  'DOMAIN-REGEX',
  'PROCESS-NAME-REGEX',
  'PROCESS-PATH-REGEX',
};
const _parameterTypes = {
  'GEOIP',
  'IP-ASN',
  'IP-CIDR',
  'IP-CIDR6',
  'IP-SUFFIX',
  'RULE-SET',
};
String _trimNative(String value) => value.replaceAll(RegExp(r'^ +| +$'), '');
bool _targetRepresentable(String value) =>
    !value.contains(',') && _trimNative(value) == value;
bool _payloadRepresentable(String type, String value) {
  if (_conditionTypes.contains(type)) {
    return true; // Native expressions, not a Dart expression language.
  }
  if (_regexTypes.contains(type)) {
    return value.split(',').map(_trimNative).join(',') == value;
  }
  return !value.contains(',') && _trimNative(value) == value;
}

/// Separates the fixed outer rule fields only. The payload (including commas
/// in native regex/condition expressions) stays opaque to the GUI.
({String type, String value, String target, bool src, bool noResolve})
ruleFormFields(String rule) {
  final first = rule.indexOf(',');
  if (first < 0) throw const FormatException('Rule has no target');
  final type = _trimNative(rule.substring(0, first));
  if (!ruleFormTypes.contains(type)) {
    throw const FormatException('Unsupported rule form type');
  }
  var rest = rule.substring(first + 1);
  var src = false;
  var noResolve = false;
  if (_parameterTypes.contains(type)) {
    while (true) {
      final comma = rest.lastIndexOf(',');
      if (comma < 0 || rest.substring(0, comma).lastIndexOf(',') < 0) break;
      final parameter = _trimNative(rest.substring(comma + 1));
      if (parameter == 'src' && !src) {
        src = true;
      } else if (parameter == 'no-resolve' && !noResolve) {
        noResolve = true;
      } else {
        break;
      }
      rest = rest.substring(0, comma);
    }
  }
  final last = type == 'MATCH' ? -1 : rest.lastIndexOf(',');
  if (type != 'MATCH' && last < 0) {
    throw const FormatException('Rule has no payload');
  }
  final value = type == 'MATCH' ? '' : _trimNative(rest.substring(0, last));
  final target = _trimNative(rest.substring(last + 1));
  if (!_targetRepresentable(target) ||
      target.isEmpty ||
      (type != 'MATCH' && !_payloadRepresentable(type, value))) {
    throw const FormatException('Rule cannot be represented without loss');
  }
  return (
    type: type,
    value: value,
    target: target,
    src: src,
    noResolve: noResolve,
  );
}

class RuleFormPage extends StatefulWidget {
  const RuleFormPage({
    super.key,
    required this.onSave,
    required this.targets,
    this.ruleProviders = const [],
    this.subRules = const [],
    this.initialType = 'DOMAIN',
    this.initialRule,
    this.initialValue,
    this.initialTarget,
    this.restrictTargets = false,
    this.notice,
    this.onSaveHandled,
  });
  final Future<void> Function(String rule) onSave;
  final List<String> targets;
  final List<String> ruleProviders;
  final List<String> subRules;
  final String initialType;
  final String? initialRule;
  final String? initialValue;
  final String? initialTarget;

  /// Connection-assisted creation permits only caller-supplied current targets.
  /// The callback still rechecks the actual source/context identity before save.
  final bool restrictTargets;
  final Widget? notice;

  /// Infallible local-reader notification; storage/ack ownership stays outside.
  final VoidCallback? onSaveHandled;

  @override
  State<RuleFormPage> createState() => _RuleFormPageState();
}

class _RuleFormPageState extends State<RuleFormPage> {
  final _form = GlobalKey<FormState>();
  bool _dirty = false;
  final _scroll = ScrollController();
  late final _original = widget.initialRule == null
      ? null
      : ruleFormFields(widget.initialRule!);
  late String _type = _initialType;
  String get _initialType => _original?.type ?? widget.initialType;
  String? get _initialValue => _original?.value ?? widget.initialValue;
  String? get _initialTarget => _original?.target ?? widget.initialTarget;
  var _target = '';
  var _value = '';
  late bool _src = _original?.src ?? false;
  late bool _noResolve = _original?.noResolve ?? false;
  var _saving = false;
  var _unknownFailure = false;
  AppMessage? _failure;

  Future<void> _save() async {
    if (!mounted || _saving || ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    if (!DefinitionFormBody.validate(_form)) return;
    _form.currentState!.save();
    final parts = <String>[
      _type,
      if (_type != 'MATCH') _value,
      _target,
      if (_parameterTypes.contains(_type)) ...[
        if (_src) 'src',
        if (_noResolve) 'no-resolve',
      ],
    ];
    final original = _original;
    final canonical = original == null
        ? null
        : [
            original.type,
            if (original.type != 'MATCH') original.value,
            original.target,
            if (original.src) 'src',
            if (original.noResolve) 'no-resolve',
          ].join(',');
    final updated = parts.join(',');
    final rule = updated == canonical ? widget.initialRule! : updated;
    setState(() {
      _saving = true;
      _failure = null;
      _unknownFailure = false;
    });
    var completed = false;
    try {
      await widget.onSave(rule);
      completed = true;
      if (mounted) {
        widget.onSaveHandled?.call();
        await definitionSaved(context, rule);
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

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final title = widget.initialRule == null
        ? strings.ruleFormTitle
        : strings.editLocalDefinition;
    final subRule = _type == 'SUB-RULE';
    final condition = _conditionTypes.contains(_type);
    final provider = _type == 'RULE-SET';
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
                constraints: const BoxConstraints(maxWidth: 840),
                child: Column(
                  children: [
                    Expanded(
                      child: DefinitionFormBody(
                        form: _form,
                        controller: _scroll,
                        onChanged: () {
                          if (!_dirty) setState(() => _dirty = true);
                        },
                        children: [
                          if (widget.notice != null) widget.notice!,
                          DefinitionChoiceField(
                            id: 'rule/type',
                            label: strings.ruleFormType,
                            options: {
                              for (final type in ruleFormTypes) type: type,
                            },
                            initialValue: _type,
                            optional: false,
                            enabled: !_saving,
                            onChanged: (value) =>
                                setState(() => _type = value!),
                          ),
                          // Keep the outbound anchor before type-specific payload controls.
                          Visibility(
                            visible: !subRule,
                            maintainState: true,
                            child: DefinitionTextField(
                              id: 'rule/target',
                              label: strings.ruleFormTarget,
                              initialValue: _initialType == 'SUB-RULE'
                                  ? null
                                  : _initialTarget,
                              required: true,
                              active: !subRule,
                              enabled: !_saving,
                              readOnly: widget.restrictTargets,
                              suggestions: widget.targets,
                              isValid: (value) =>
                                  _targetRepresentable(value) &&
                                  (!widget.restrictTargets ||
                                      widget.targets.contains(value)),
                              invalidMessage: widget.restrictTargets
                                  ? strings.connectionRuleUnavailable
                                  : strings.ruleFormUnrepresentable,
                              hint: strings.ruleFormTargetHint,
                              onSaved: (value) {
                                if (value != null) _target = value;
                              },
                            ),
                          ),
                          Visibility(
                            visible: subRule,
                            maintainState: true,
                            child: DefinitionTextField(
                              id: 'rule/sub-rule',
                              label: strings.ruleFormSubRule,
                              initialValue: _initialType == 'SUB-RULE'
                                  ? _initialTarget
                                  : null,
                              required: true,
                              active: subRule,
                              enabled: !_saving,
                              suggestions: widget.subRules,
                              isValid: _targetRepresentable,
                              invalidMessage: strings.ruleFormUnrepresentable,
                              hint: strings.ruleFormTargetHint,
                              onSaved: (value) {
                                if (value != null) _target = value;
                              },
                            ),
                          ),
                          Visibility(
                            visible:
                                _type != 'MATCH' && !condition && !provider,
                            maintainState: true,
                            child: DefinitionTextField(
                              id: 'rule/value',
                              label: strings.ruleFormMatch,
                              initialValue:
                                  !_conditionTypes.contains(_initialType) &&
                                      _initialType != 'RULE-SET' &&
                                      _initialType != 'MATCH'
                                  ? _initialValue
                                  : null,
                              required: true,
                              active:
                                  _type != 'MATCH' && !condition && !provider,
                              enabled: !_saving,
                              isValid: (value) =>
                                  _payloadRepresentable(_type, value),
                              invalidMessage: strings.ruleFormUnrepresentable,
                              onSaved: (value) {
                                if (value != null) _value = value;
                              },
                            ),
                          ),
                          Visibility(
                            visible: provider,
                            maintainState: true,
                            child: DefinitionTextField(
                              id: 'rule/provider',
                              label: strings.ruleFormProvider,
                              initialValue: _initialType == 'RULE-SET'
                                  ? _initialValue
                                  : null,
                              required: true,
                              active: provider,
                              enabled: !_saving,
                              suggestions: widget.ruleProviders,
                              isValid: (value) =>
                                  _payloadRepresentable('RULE-SET', value),
                              invalidMessage: strings.ruleFormUnrepresentable,
                              onSaved: (value) {
                                if (value != null) _value = value;
                              },
                            ),
                          ),
                          Visibility(
                            visible: condition,
                            maintainState: true,
                            child: DefinitionTextField(
                              id: 'rule/condition',
                              label: strings.ruleFormCondition,
                              initialValue:
                                  _conditionTypes.contains(_initialType)
                                  ? _initialValue
                                  : null,
                              required: true,
                              active: condition,
                              enabled: !_saving,
                              multiline: true,
                              onSaved: (value) {
                                if (value != null) _value = value;
                              },
                            ),
                          ),
                          Visibility(
                            visible: _parameterTypes.contains(_type),
                            maintainState: true,
                            child: Column(
                              children: [
                                CheckboxListTile(
                                  key: const ValueKey('rule-src'),
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('src'),
                                  value: _src,
                                  onChanged: _saving
                                      ? null
                                      : (value) => setState(() {
                                          _dirty = true;
                                          _src = value!;
                                        }),
                                ),
                                CheckboxListTile(
                                  key: const ValueKey('rule-no-resolve'),
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('no-resolve'),
                                  value: _noResolve,
                                  onChanged: _saving
                                      ? null
                                      : (value) => setState(() {
                                          _dirty = true;
                                          _noResolve = value!;
                                        }),
                                ),
                                Text(
                                  strings.ruleFormSrcHint,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          if (_type.startsWith('PROCESS-') || _type == 'UID')
                            Text(
                              strings.ruleFormIdentityNotice,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                    DefinitionSaveBar(
                      id: 'rule',
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
