import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/app_task.dart';
import '../../app/widgets/task_shortcuts.dart';

import '../../app/app_theme.dart';
import '../../app/widgets/choice_menu_button.dart';

import '../../l10n/app_localizations.dart';
import 'definition_form_body.dart';

const definitionInt64Max = 9223372036854775807;
const definitionInt64Min = -9223372036854775808;
// Fixed Go time.Duration consumers multiply seconds/milliseconds by nanoseconds.
const definitionMaxSeconds = 9223372036;
const definitionMaxMilliseconds = 9223372036854;
const _required = 'required';
const _invalid = 'invalid';
const _unset = '\u0000unset';

class DefinitionEditor extends StatefulWidget {
  const DefinitionEditor({
    super.key,
    required this.dirty,
    required this.saving,
    required this.onSave,
    required this.child,
  });

  final bool dirty;
  final bool saving;
  final VoidCallback onSave;
  final Widget child;

  @override
  State<DefinitionEditor> createState() => _DefinitionEditorState();
}

class _DefinitionEditorState extends State<DefinitionEditor> {
  AppController? _app;
  ModalRoute<dynamic>? _route;
  Future<bool>? _leaving;
  late final Future<bool> Function() _overviewLeave = _leave;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final owner = AppTaskScope.maybeOf(context)?.owner;
    final app = owner is AppController ? owner : null;
    final route = ModalRoute.of(context);
    if (identical(app, _app) && identical(route, _route)) return;
    if (_route case final previous?) {
      _app?.unregisterOverviewLeave(previous, _overviewLeave);
    }
    _app = app;
    _route = route;
    if (route != null) app?.registerOverviewLeave(route, _overviewLeave);
  }

  Future<bool> _leave() =>
      _leaving ??= _performLeave().whenComplete(() => _leaving = null);

  Future<bool> _performLeave() async {
    if (widget.saving || _app?.interactive == false) return false;
    final route = _route;
    if (route == null || !route.isCurrent) return false;
    final navigator = Navigator.of(context);
    if (route.willHandlePopInternally) {
      await navigator.maybePop<void>();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !route.isCurrent || route.willHandlePopInternally) {
        return false;
      }
    }
    if (widget.dirty) {
      FocusManager.instance.primaryFocus?.unfocus();
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) {
          final strings = AppLocalizations.of(context);
          return AlertDialog(
            scrollable: true,
            title: Text(strings.discardEditsTitle),
            content: Text(strings.discardEditsMessage),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(strings.continueEditing),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(strings.discard),
              ),
            ],
          );
        },
      );
      if (discard != true || !mounted || !route.isCurrent || widget.saving) {
        return false;
      }
    }
    if (!navigator.canPop()) return false;
    navigator.pop();
    return !route.isActive;
  }

  @override
  Widget build(BuildContext context) => TaskShortcuts(
    onSave: widget.saving ? null : widget.onSave,
    onEscape: widget.saving
        ? null
        : () {
            unawaited(Navigator.of(context).maybePop());
          },
    child: PopScope<void>(
      canPop: !widget.dirty && !widget.saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: widget.child,
    ),
  );

  @override
  void dispose() {
    if (_route case final route?) {
      _app?.unregisterOverviewLeave(route, _overviewLeave);
    }
    super.dispose();
  }
}

/// Standard SDK form-field composition.
Widget definitionHeading(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.only(top: 16, bottom: 12),
  child: Text(text, style: Theme.of(context).textTheme.titleSmall),
);

// AppBar otherwise clamps title scaling and defaults to a single ellipsized line.
Widget definitionToolbarTitle(
  BuildContext context,
  String title, {
  bool compact = false,
}) => MediaQuery(
  data: MediaQuery.of(context),
  child: Tooltip(
    message: title,
    excludeFromSemantics: true,
    child: Text(
      title,
      softWrap: !compact,
      maxLines: compact ? 1 : null,
      overflow: compact ? TextOverflow.ellipsis : TextOverflow.visible,
    ),
  ),
);

/// Reserve title space according to actual width and text scale.
double definitionToolbarHeight(
  BuildContext context,
  String title,
  double width,
) {
  final theme = Theme.of(context);
  final painter = TextPainter(
    text: TextSpan(
      text: title,
      style: theme.appBarTheme.titleTextStyle ?? theme.textTheme.titleLarge,
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout(maxWidth: math.max(1, width - 88));
  final height = math.max(kToolbarHeight, painter.height + 16);
  painter.dispose();
  return height;
}

({double toolbarHeight, bool compact}) definitionEditorLayout(
  BuildContext context,
  String title,
  Size bounds, {
  double? footerHeight,
}) {
  final toolbar = definitionToolbarHeight(context, title, bounds.width);
  final available =
      bounds.height -
      MediaQuery.paddingOf(context).vertical -
      MediaQuery.viewInsetsOf(context).vertical;
  final compact =
      available -
          toolbar -
          (footerHeight ??
              DefinitionSaveBar.normalHeight(context, bounds.width)) <
      WorkspaceLayout.minimumBodyHeight;
  return (toolbarHeight: compact ? kToolbarHeight : toolbar, compact: compact);
}

/// Remove only this form's captured route.
Future<void> definitionSaved(BuildContext context, Object result) async {
  final route = ModalRoute.of(context);
  final owner = AppTaskScope.maybeOf(context)?.owner;
  if (owner is AppController && !await owner.waitUntilInteractive()) return;
  if (!context.mounted || route == null || !route.isActive) return;
  final navigator = Navigator.of(context);
  if (route.isCurrent) {
    navigator.pop(result);
  } else {
    navigator.removeRoute(route, result);
  }
}

Widget _errorSlot(
  BuildContext context,
  String? code,
  String? invalid, {
  required bool required,
}) {
  final strings = AppLocalizations.of(context);
  final messages = {
    if (required) _required: strings.proxyRequired,
    _invalid: ?invalid,
  };
  if (messages.isEmpty) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Stack(
      alignment: AlignmentDirectional.topStart,
      children: [
        for (final entry in messages.entries)
          Visibility(
            maintainState: true,
            maintainAnimation: true,
            maintainSize: true,
            visible: code == entry.key,
            child: Text(
              entry.value,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    ),
  );
}

class DefinitionOriginalField extends StatelessWidget {
  const DefinitionOriginalField({
    super.key,
    required this.id,
    required this.label,
    this.enabled = true,
    this.onUnset,
  });

  final String id;
  final String label;
  final bool enabled;
  final VoidCallback? onUnset;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableText(id),
            const SizedBox(height: 6),
            SelectableText(strings.localYamlUnsupportedField),
            if (onUnset != null)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: ValueKey('definition-unset-original:$id'),
                  onPressed: enabled ? onUnset : null,
                  style: TextButton.styleFrom(
                    iconColor: Theme.of(context).colorScheme.error,
                  ),
                  icon: const Icon(Icons.remove_circle_outline),
                  label: Text(strings.definitionFormUnsetField),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class DefinitionTextField extends StatefulWidget {
  const DefinitionTextField({
    super.key,
    required this.id,
    required this.label,
    this.initialValue,
    this.onSaved,
    this.onChanged,
    this.onInteracted,
    this.isValid,
    this.invalidMessage,
    this.required = false,
    this.trimRequired = true,
    this.active = true,
    this.enabled = true,
    this.nullable = false,
    this.readOnly = false,
    this.secret = false,
    this.multiline = false,
    this.numeric = false,
    this.signed = false,
    this.unit,
    this.hint,
    this.suggestions,
  });
  final String id;
  final String label;
  final String? initialValue;
  final ValueChanged<String?>? onSaved;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onInteracted;
  final bool Function(String)? isValid;
  final String? invalidMessage;
  final bool required;
  final bool trimRequired;
  final bool active;
  final bool enabled;
  final bool nullable;
  final bool readOnly;
  final bool secret;
  final bool multiline;
  final bool numeric;
  final bool signed;
  final String? unit;
  final String? hint;
  final List<String>? suggestions;

  @override
  State<DefinitionTextField> createState() => _DefinitionTextFieldState();
}

class _DefinitionTextFieldState extends State<DefinitionTextField> {
  late final _controller = TextEditingController(
    text: widget.initialValue ?? '',
  );
  late bool _present = !widget.nullable || widget.initialValue != null;
  bool _revealed = false;
  bool get _included => !widget.nullable || _present;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return FormField<String>(
      initialValue: widget.initialValue ?? '',
      validator: (raw) {
        if (!widget.active || !_included) return null;
        final value = raw ?? '';
        if (widget.required &&
            (widget.trimRequired ? value.trim() : value).isEmpty) {
          return _required;
        }
        if (value.isEmpty && !widget.required && !widget.nullable) return null;
        return widget.isValid?.call(value) == false ? _invalid : null;
      },
      onSaved: (value) => widget.onSaved?.call(
        widget.active &&
                _included &&
                (widget.nullable || (value?.isNotEmpty ?? false))
            ? value ?? ''
            : null,
      ),
      builder: (field) {
        final editable = widget.active && widget.enabled && _included;
        void change(String value) {
          field.didChange(value);
          widget.onInteracted?.call();
          widget.onChanged?.call(value);
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.label,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  if (widget.nullable)
                    Semantics(
                      label: '${strings.proxyOptional}: ${widget.label}',
                      child: Switch(
                        key: ValueKey('definition-presence:${widget.id}'),
                        value: _present,
                        onChanged: widget.active && widget.enabled
                            ? (value) {
                                setState(() => _present = value);
                                widget.onInteracted?.call();
                              }
                            : null,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              TextField(
                key: ValueKey('definition-input:${widget.id}'),
                controller: _controller,
                enabled: editable,
                readOnly: widget.readOnly,
                autocorrect: false,
                enableSuggestions: false,
                obscureText: widget.secret && !widget.multiline && !_revealed,
                minLines: widget.multiline ? 3 : 1,
                maxLines: widget.multiline ? 3 : 1,
                keyboardType: widget.numeric
                    ? TextInputType.numberWithOptions(signed: widget.signed)
                    : widget.multiline
                    ? TextInputType.multiline
                    : TextInputType.text,
                onChanged: change,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  suffixText: widget.unit,
                  suffixIcon: widget.secret && !widget.multiline
                      ? IconButton(
                          tooltip: _revealed
                              ? strings.proxyHideSecret
                              : strings.proxyShowSecret,
                          onPressed: editable
                              ? () => setState(() => _revealed = !_revealed)
                              : null,
                          color: HomePalette.of(context).moreAction,
                          icon: Icon(
                            _revealed
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                        )
                      : widget.suggestions != null
                      ? Semantics(
                          container: true,
                          explicitChildNodes: true,
                          child: ChoiceMenuButton<String>(
                            key: ValueKey(
                              'definition-suggestions:${widget.id}',
                            ),
                            enabled: editable,
                            options: {
                              for (final value in widget.suggestions!)
                                value: value,
                            },
                            tooltip: strings.definitionFormSuggestions,
                            onSelected: (value) {
                              _controller.value = TextEditingValue(
                                text: value,
                                selection: TextSelection.collapsed(
                                  offset: value.length,
                                ),
                              );
                              change(value);
                            },
                            iconColor: HomePalette.of(context).moreAction,
                          ),
                        )
                      : null,
                ),
              ),
              if (widget.hint != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    widget.hint!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              _errorSlot(
                context,
                widget.active && _included ? field.errorText : null,
                widget.invalidMessage,
                required: widget.required,
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class DefinitionNumberField extends StatelessWidget {
  const DefinitionNumberField({
    super.key,
    required this.id,
    required this.label,
    required this.onSaved,
    this.onInteracted,
    this.initialValue,
    this.min = 0,
    this.max = definitionInt64Max,
    this.required = false,
    this.active = true,
    this.enabled = true,
    this.unit,
  });
  final String id;
  final String label;
  final ValueChanged<int?> onSaved;
  final VoidCallback? onInteracted;
  final int? initialValue;
  final int min;
  final int max;
  final bool required;
  final bool active;
  final bool enabled;
  final String? unit;

  int? _parse(String input) {
    final text = input.trim();
    if (!RegExp(r'^[+-]?[0-9]+$').hasMatch(text)) return null;
    final value = int.tryParse(text);
    return value == null || value < min || value > max ? null : value;
  }

  @override
  Widget build(BuildContext context) => DefinitionTextField(
    id: id,
    label: label,
    initialValue: initialValue?.toString(),
    numeric: true,
    signed: min < 0,
    unit: unit,
    active: active,
    enabled: enabled,
    required: required,
    isValid: (value) => _parse(value) != null,
    invalidMessage: AppLocalizations.of(context).proxyInvalidInteger,
    onSaved: (value) => onSaved(value == null ? null : _parse(value)),
    onInteracted: onInteracted,
  );
}

Widget _choiceLabel(Set<String> labels, String selected) => LayoutBuilder(
  builder: (context, constraints) {
    final style = DefaultTextStyle.of(context).style;
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    );
    painter.text = TextSpan(text: 'M\nM', style: style);
    painter.layout(maxWidth: constraints.maxWidth);
    final twoLines = painter.height;
    var height = 0.0;
    for (final label in labels) {
      painter.text = TextSpan(text: label, style: style);
      painter.layout(maxWidth: constraints.maxWidth);
      height = math.max(height, painter.height);
    }
    painter.dispose();
    // Use bounded, scrollable content with wrapping at the current text scale.
    return SizedBox(
      height: math.min(twoLines, height),
      child: SingleChildScrollView(
        key: ValueKey(selected),
        primary: false,
        child: Text(selected),
      ),
    );
  },
);

class DefinitionChoiceField extends StatelessWidget {
  const DefinitionChoiceField({
    super.key,
    required this.id,
    required this.label,
    required this.options,
    this.initialValue,
    this.optional = true,
    this.active = true,
    this.enabled = true,
    this.onSaved,
    this.onChanged,
    this.isValid,
    this.invalidMessage,
    this.hint,
  });
  final String id;
  final String label;
  final Map<String, String> options;
  final String? initialValue;
  final bool optional;
  final bool active;
  final bool enabled;
  final ValueChanged<String?>? onSaved;
  final ValueChanged<String?>? onChanged;
  final bool Function(String)? isValid;
  final String? invalidMessage;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return FormField<String>(
      key: ValueKey('definition-choice:$id'),
      initialValue: initialValue,
      validator: (value) {
        if (!active) return null;
        if (value == null) return optional ? null : _required;
        return isValid?.call(value) == false ? _invalid : null;
      },
      onSaved: (value) => onSaved?.call(active ? value : null),
      builder: (field) {
        final selected = field.value == null
            ? strings.proxyUnset
            : options[field.value] ?? field.value!;
        final labels = {strings.proxyUnset, ...options.values, selected};
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ExcludeSemantics(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              const SizedBox(height: 6),
              ChoiceMenuButton<String>(
                key: ValueKey('definition-menu:$id'),
                enabled: active && enabled,
                semanticsLabel: label,
                semanticsValue: selected,
                value: field.value ?? _unset,
                options: {if (optional) _unset: strings.proxyUnset, ...options},
                onOpened: () => FocusManager.instance.primaryFocus?.unfocus(),
                onSelected: (raw) {
                  final value = raw == _unset ? null : raw;
                  field.didChange(value);
                  onChanged?.call(value);
                },
                child: InputDecorator(
                  isEmpty: false,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    enabled: active && enabled,
                  ),
                  child: Row(
                    children: [
                      Expanded(child: _choiceLabel(labels, selected)),
                      const SizedBox(width: 12),
                      const Icon(Icons.arrow_drop_down),
                    ],
                  ),
                ),
              ),
              if (hint != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    hint!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              _errorSlot(
                context,
                active ? field.errorText : null,
                invalidMessage,
                required: !optional,
              ),
            ],
          ),
        );
      },
    );
  }
}

class DefinitionBoolField extends StatelessWidget {
  const DefinitionBoolField({
    super.key,
    required this.id,
    required this.label,
    required this.onSaved,
    this.onInteracted,
    this.initialValue,
    this.active = true,
    this.enabled = true,
    this.hint,
  });
  final String id;
  final String label;
  final ValueChanged<bool?> onSaved;
  final VoidCallback? onInteracted;
  final bool? initialValue;
  final bool active;
  final bool enabled;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return DefinitionChoiceField(
      id: id,
      label: label,
      active: active,
      enabled: enabled,
      hint: hint,
      initialValue: initialValue?.toString(),
      options: {'true': strings.proxyTrue, 'false': strings.proxyFalse},
      onSaved: (value) => onSaved(value == null ? null : value == 'true'),
      onChanged: (_) => onInteracted?.call(),
    );
  }
}

class DefinitionRowActions extends StatelessWidget {
  const DefinitionRowActions({
    super.key,
    required this.id,
    required this.label,
    required this.index,
    this.onUp,
    this.onDown,
    this.onRemove,
  });
  final String id;
  final String label;
  final int index;
  final VoidCallback? onUp;
  final VoidCallback? onDown;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Row(
      children: [
        Expanded(
          child: Tooltip(
            message: '#${index + 1}',
            excludeFromSemantics: true,
            child: Text(
              '#${index + 1}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ),
        IconButton(
          key: ValueKey('definition-up:$id'),
          tooltip: strings.definitionFormMoveUp,
          onPressed: onUp,
          color: HomePalette.of(context).editAction,
          icon: const Icon(Icons.arrow_upward),
        ),
        IconButton(
          key: ValueKey('definition-down:$id'),
          tooltip: strings.definitionFormMoveDown,
          onPressed: onDown,
          color: HomePalette.of(context).editAction,
          icon: const Icon(Icons.arrow_downward),
        ),
        IconButton(
          key: ValueKey('definition-remove:$id'),
          tooltip: strings.proxyRemoveItem(label, index + 1),
          onPressed: onRemove,
          color: Theme.of(context).colorScheme.error,
          icon: const Icon(Icons.remove_circle_outline),
        ),
      ],
    );
  }
}

class DefinitionStringListField extends StatefulWidget {
  const DefinitionStringListField({
    super.key,
    required this.id,
    required this.label,
    required this.onSaved,
    this.initialValue,
    this.onChanged,
    this.optional = true,
    this.active = true,
    this.enabled = true,
    this.multiline = false,
    this.allowEmptyItems = false,
    this.suggestions,
    this.isValidItem,
    this.invalidMessage,
    this.numeric = false,
    this.signed = true,
    this.unit,
  });
  final String id;
  final String label;
  final List<String>? initialValue;
  final ValueChanged<List<String>?> onSaved;
  final ValueChanged<List<String>?>? onChanged;
  final bool optional;
  final bool active;
  final bool enabled;
  final bool multiline;
  final bool allowEmptyItems;
  final List<String>? suggestions;
  final bool Function(String)? isValidItem;
  final String? invalidMessage;
  final bool numeric;
  final bool signed;
  final String? unit;

  @override
  State<DefinitionStringListField> createState() =>
      _DefinitionStringListFieldState();
}

class _DefinitionStringListFieldState extends State<DefinitionStringListField> {
  int? _errorId;
  final _scroll = ScrollController();
  var _sequence = 0;
  late bool _present = !widget.optional || widget.initialValue != null;
  late final _rows = <({int id, String text})>[
    for (final value in widget.initialValue ?? const <String>[])
      (id: _sequence++, text: value),
  ];
  bool get _included => !widget.optional || _present;
  bool get _canInteract =>
      mounted &&
      widget.active &&
      widget.enabled &&
      ModalRoute.of(context)?.isCurrent != false;
  List<String>? get _value =>
      _included ? List.unmodifiable(_rows.map((row) => row.text)) : null;

  String? _rowError(({int id, String text}) row) {
    if (!widget.allowEmptyItems && row.text.isEmpty) return _required;
    return widget.isValidItem?.call(row.text) == false ? _invalid : null;
  }

  Future<BuildContext?> _revealError() async {
    final index = _rows.indexWhere((row) => row.id == _errorId);
    if (!_canInteract ||
        !_included ||
        index < 0 ||
        _rowError(_rows[index]) == null) {
      return null;
    }
    return DefinitionFormBody.revealListRow(
      context: context,
      controller: _scroll,
      index: index,
      count: _rows.length,
      rowKey: ValueKey('definition-row:${widget.id}/${_rows[index].id}'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return DefinitionValidationTarget(
      reveal: _revealError,
      child: FormField<List<String>>(
        initialValue: widget.initialValue,
        validator: (_) {
          _errorId = null;
          if (!widget.active || !_included) return null;
          for (final row in _rows) {
            final error = _rowError(row);
            if (error != null) {
              _errorId = row.id;
              return error;
            }
          }
          return null;
        },
        onSaved: (_) => widget.onSaved(widget.active ? _value : null),
        builder: (field) {
          final editable = widget.active && widget.enabled && _included;
          void changed() {
            field.didChange(_value);
            widget.onChanged?.call(_value);
          }

          void move(int id, int direction) {
            if (!_canInteract || !_included) {
              return;
            }
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
            return Padding(
              key: prototype
                  ? null
                  : ValueKey('definition-row:${widget.id}/${row.id}'),
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                children: [
                  DefinitionRowActions(
                    id: '${widget.id}/$id',
                    label: widget.label,
                    index: index,
                    onUp: !prototype && editable && index > 0
                        ? () => move(row.id, -1)
                        : null,
                    onDown: !prototype && editable && index + 1 < _rows.length
                        ? () => move(row.id, 1)
                        : null,
                    onRemove: !prototype && editable
                        ? () {
                            if (!_canInteract || !_included) {
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
                    id: '${widget.id}/$id',
                    label: widget.label,
                    initialValue: prototype ? '' : row.text,
                    active: !prototype && widget.active && _included,
                    enabled: !prototype && widget.enabled,
                    required: !widget.allowEmptyItems,
                    trimRequired: false,
                    multiline: widget.multiline,
                    suggestions: widget.suggestions,
                    isValid: widget.isValidItem,
                    invalidMessage: widget.invalidMessage,
                    numeric: widget.numeric,
                    signed: widget.signed,
                    unit: widget.unit,
                    onChanged: prototype
                        ? null
                        : (value) {
                            if (!_canInteract || !_included) {
                              return;
                            }
                            final at = _rows.indexWhere(
                              (item) => item.id == row.id,
                            );
                            if (at < 0) return;
                            _rows[at] = (id: row.id, text: value);
                            changed();
                          },
                  ),
                ],
              ),
            );
          }

          final indices = {
            for (final (index, row) in _rows.indexed)
              ValueKey('definition-row:${widget.id}/${row.id}'): index,
          };
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.label,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  if (widget.optional)
                    Semantics(
                      label: '${strings.proxyOptional}: ${widget.label}',
                      child: Switch(
                        key: ValueKey('definition-presence:${widget.id}'),
                        value: _present,
                        onChanged: widget.active && widget.enabled
                            ? (value) {
                                if (!_canInteract) return;
                                setState(() {
                                  _present = value;
                                  changed();
                                });
                              }
                            : null,
                      ),
                    ),
                ],
              ),
              _errorSlot(
                context,
                widget.active && _included ? field.errorText : null,
                widget.invalidMessage,
                required: !widget.allowEmptyItems,
              ),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: DefinitionFormBody.collectionHeightOf(context),
                ),
                child: ListView.builder(
                  key: ValueKey('definition-list:${widget.id}'),
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
                  key: ValueKey('definition-add:${widget.id}'),
                  onPressed: widget.active && widget.enabled
                      ? () {
                          if (!_canInteract) return;
                          final id = _sequence++;
                          setState(() {
                            _present = true;
                            _rows.add((id: id, text: ''));
                            changed();
                          });
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (_canInteract &&
                                _included &&
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
                  label: Text(strings.proxyAddItem(widget.label)),
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

class DefinitionHeadersField extends StatefulWidget {
  const DefinitionHeadersField({
    super.key,
    required this.id,
    required this.label,
    required this.onSaved,
    this.initialValue,
    this.onChanged,
    this.active = true,
    this.enabled = true,
    this.scalarValues = false,
  });
  final String id;
  final String label;
  final ValueChanged<Map<String, List<String>>?> onSaved;
  final Map<String, List<String>>? initialValue;
  final ValueChanged<Map<String, List<String>>?>? onChanged;
  final bool active;
  final bool enabled;
  final bool scalarValues;

  @override
  State<DefinitionHeadersField> createState() => _DefinitionHeadersFieldState();
}

class _HeaderRow {
  _HeaderRow(this.id);
  final int id;
  String name = '';
  List<String> values = const [];
}

class _DefinitionHeadersFieldState extends State<DefinitionHeadersField> {
  int? _errorId;
  final _scroll = ScrollController();
  var _sequence = 0;
  var _editing = false;
  late bool _present = widget.initialValue != null;
  late final _rows = <_HeaderRow>[
    for (final entry
        in widget.initialValue?.entries ??
            const Iterable<MapEntry<String, List<String>>>.empty())
      _HeaderRow(_sequence++)
        ..name = entry.key
        ..values = List.of(entry.value),
  ];
  bool get _included => _present;
  bool get _canInteract =>
      mounted &&
      widget.active &&
      widget.enabled &&
      !_editing &&
      ModalRoute.of(context)?.isCurrent != false;
  Map<String, List<String>>? get _value => !_present
      ? null
      : Map.unmodifiable({
          for (final row in _rows)
            row.name: List<String>.unmodifiable(row.values),
        });

  ({int id, String error})? get _firstError {
    if (!widget.active || !_included) return null;
    final names = <String>{};
    for (final row in _rows) {
      if (row.name.trim().isEmpty) return (id: row.id, error: _required);
      if (!names.add(row.name)) return (id: row.id, error: _invalid);
    }
    return null;
  }

  Future<BuildContext?> _revealError() async {
    final index = _rows.indexWhere((row) => row.id == _errorId);
    if (!_canInteract ||
        !_included ||
        index < 0 ||
        _firstError?.id != _errorId) {
      return null;
    }
    return DefinitionFormBody.revealListRow(
      context: context,
      controller: _scroll,
      index: index,
      count: _rows.length,
      rowKey: ValueKey('definition-header:${widget.id}/${_rows[index].id}'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return DefinitionValidationTarget(
      reveal: _revealError,
      child: FormField<Map<String, List<String>>>(
        initialValue: _value,
        validator: (_) {
          final error = _firstError;
          _errorId = error?.id;
          return error?.error;
        },
        onSaved: (_) => widget.onSaved(widget.active ? _value : null),
        builder: (field) {
          final editable = widget.active && widget.enabled && !_editing;
          void changed() {
            field.didChange(_value);
            widget.onChanged?.call(_value);
          }

          Future<void> edit(int? id) async {
            if (!mounted ||
                !widget.active ||
                !widget.enabled ||
                _editing ||
                ModalRoute.of(context)?.isCurrent != true) {
              return;
            }
            final row = id == null
                ? null
                : _rows.where((row) => row.id == id).firstOrNull;
            if (id != null && (!_included || row == null)) return;
            FocusManager.instance.primaryFocus?.unfocus();
            setState(() => _editing = true);
            try {
              final result = await Navigator.of(context)
                  .push<(String, List<String>)>(
                    MaterialPageRoute(
                      builder: (_) => _HeaderEditorPage(
                        id: '${widget.id}/${row?.id ?? _sequence}',
                        label: widget.label,
                        name: row?.name ?? '',
                        values: List.of(row?.values ?? const []),
                        scalarValues: widget.scalarValues,
                        otherNames: {
                          for (final other in _rows)
                            if (other.id != id) other.name,
                        },
                      ),
                    ),
                  );
              if (!mounted ||
                  result == null ||
                  !widget.active ||
                  !widget.enabled) {
                return;
              }
              if (id != null &&
                  (!_included || !_rows.any((row) => row.id == id))) {
                return;
              }
              final target = row ?? _HeaderRow(_sequence++);
              setState(() {
                target.name = result.$1;
                target.values = List.of(result.$2);
                if (row == null) {
                  _present = true;
                  _rows.add(target);
                }
                changed();
              });
              if (row == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted &&
                      widget.active &&
                      widget.enabled &&
                      _included &&
                      !_editing &&
                      _rows.lastOrNull?.id == target.id &&
                      _scroll.hasClients) {
                    _scroll.jumpTo(_scroll.position.maxScrollExtent);
                  }
                });
              }
            } finally {
              if (mounted) setState(() => _editing = false);
            }
          }

          Widget item(int index, {bool prototype = false}) {
            final row = _rows[index];
            final canEdit = !prototype && editable && _included;
            return ListTile(
              key: prototype
                  ? null
                  : ValueKey('definition-header:${widget.id}/${row.id}'),
              contentPadding: EdgeInsets.zero,
              title: Tooltip(
                message: row.name,
                excludeFromSemantics: true,
                child: Text(
                  row.name.isEmpty ? '""' : row.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              subtitle: Text(
                strings.definitionFormValueCount(row.values.length),
                maxLines: 1,
              ),
              onTap: canEdit ? () => edit(row.id) : null,
              trailing: SizedBox(
                width: 96,
                child: Row(
                  children: [
                    IconButton(
                      key: prototype
                          ? null
                          : ValueKey('definition-edit:${widget.id}/${row.id}'),
                      tooltip: strings.definitionFormEditItem(
                        widget.label,
                        index + 1,
                      ),
                      onPressed: canEdit ? () => edit(row.id) : null,
                      color: HomePalette.of(context).editAction,
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      key: prototype
                          ? null
                          : ValueKey(
                              'definition-remove:${widget.id}/${row.id}',
                            ),
                      tooltip: strings.proxyRemoveItem(widget.label, index + 1),
                      onPressed: canEdit
                          ? () {
                              if (!_canInteract || !_included) {
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
                      color: Theme.of(context).colorScheme.error,
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                  ],
                ),
              ),
            );
          }

          final indices = {
            for (final (index, row) in _rows.indexed)
              ValueKey('definition-header:${widget.id}/${row.id}'): index,
          };
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.label,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  Semantics(
                    label: '${strings.proxyOptional}: ${widget.label}',
                    child: Switch(
                      key: ValueKey('definition-presence:${widget.id}'),
                      value: _present,
                      onChanged: editable
                          ? (value) {
                              if (!_canInteract) return;
                              setState(() {
                                _present = value;
                                changed();
                              });
                            }
                          : null,
                    ),
                  ),
                ],
              ),
              if (_rows.isNotEmpty)
                _errorSlot(
                  context,
                  _included ? field.errorText : null,
                  strings.proxyDuplicateKey,
                  required: true,
                ),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: DefinitionFormBody.collectionHeightOf(context),
                ),
                child: ListView.builder(
                  key: ValueKey('definition-header-list:${widget.id}'),
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
                  key: ValueKey('definition-add:${widget.id}'),
                  onPressed: editable ? () => edit(null) : null,
                  style: TextButton.styleFrom(
                    iconColor: HomePalette.of(context).editAction,
                  ),
                  icon: const Icon(Icons.add),
                  label: Text(strings.proxyAddItem(widget.label)),
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

class _HeaderEditorPage extends StatefulWidget {
  const _HeaderEditorPage({
    required this.id,
    required this.label,
    required this.name,
    required this.values,
    required this.scalarValues,
    required this.otherNames,
  });
  final String id;
  final String label;
  final String name;
  final List<String> values;
  final bool scalarValues;
  final Set<String> otherNames;

  @override
  State<_HeaderEditorPage> createState() => _HeaderEditorPageState();
}

class _HeaderEditorPageState extends State<_HeaderEditorPage> {
  final _form = GlobalKey<FormState>();
  final _scroll = ScrollController();
  var _dirty = false;
  late String _name = widget.name;
  late List<String> _values = List.of(widget.values);
  var _committed = false;

  void _save() {
    if (!mounted ||
        _committed ||
        ModalRoute.of(context)?.isCurrent != true ||
        !DefinitionFormBody.validate(_form)) {
      return;
    }
    _form.currentState!.save();
    _committed = true;
    Navigator.of(context).pop((_name, List<String>.unmodifiable(_values)));
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final strings = AppLocalizations.of(context);
      const padding = EdgeInsets.fromLTRB(20, 12, 20, 12);
      final layout = definitionEditorLayout(
        context,
        widget.label,
        constraints.biggest,
        footerHeight:
            1 + padding.vertical + DefinitionSaveBar.buttonHeight(context),
      );
      return DefinitionEditor(
        dirty: _dirty,
        saving: _committed,
        onSave: _save,
        child: Scaffold(
          appBar: AppBar(
            title: definitionToolbarTitle(
              context,
              widget.label,
              compact: layout.compact,
            ),
            toolbarHeight: layout.toolbarHeight,
          ),
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: DefinitionFormBody(
                      form: _form,
                      controller: _scroll,
                      onChanged: () {
                        if (!_dirty) setState(() => _dirty = true);
                      },
                      chapters: [
                        DefinitionFormChapter(
                          id: 'header',
                          title: widget.label,
                          children: [
                            DefinitionTextField(
                              id: '${widget.id}/key',
                              label: strings.proxyMapKey,
                              initialValue: widget.name,
                              required: true,
                              isValid: (value) =>
                                  !widget.otherNames.contains(value),
                              invalidMessage: strings.proxyDuplicateKey,
                              onSaved: (value) => _name = value!,
                            ),
                            if (widget.scalarValues)
                              DefinitionTextField(
                                id: '${widget.id}/value',
                                label: strings.proxyMapValue,
                                initialValue: widget.values.firstOrNull ?? '',
                                onSaved: (value) => _values = [value ?? ''],
                              )
                            else
                              DefinitionStringListField(
                                id: '${widget.id}/values',
                                label: strings.proxyMapValue,
                                initialValue: widget.values,
                                optional: false,
                                allowEmptyItems: true,
                                onSaved: (value) => _values = List.of(value!),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: padding,
                      child: FilledButton(
                        key: ValueKey('definition-save-header:${widget.id}'),
                        style: DefinitionSaveBar.buttonStyle(context),
                        onPressed: _save,
                        child: Text(
                          strings.save,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }
}

class DefinitionSaveBar extends StatelessWidget {
  const DefinitionSaveBar({
    super.key,
    required this.id,
    required this.saving,
    required this.failed,
    required this.onSave,
    required this.onDetails,
    this.compact = false,
    this.saveKey,
    this.detailsKey,
  });
  final String id;
  final bool saving;
  final bool failed;
  final bool compact;
  final Key? saveKey;
  final Key? detailsKey;
  final VoidCallback onSave;
  final VoidCallback onDetails;

  static const _padding = EdgeInsets.fromLTRB(20, 8, 20, 12);
  static const _buttonPadding = EdgeInsets.symmetric(
    horizontal: 24,
    vertical: 12,
  );

  static double _height(
    BuildContext context,
    String text,
    TextStyle? style,
    double width,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: math.max(1, width));
    final height = painter.height;
    painter.dispose();
    return height;
  }

  static double normalHeight(BuildContext context, double width) {
    final strings = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final content =
        math.min(width, DefinitionFormBody.widthOf(context, wide: false)) -
        _padding.horizontal;
    final feedback = math.max(
      kMinInteractiveDimension,
      _height(
        context,
        strings.operationFailed,
        theme.textTheme.bodySmall,
        content - kMinInteractiveDimension,
      ),
    );
    return _padding.vertical + feedback + buttonHeight(context);
  }

  static double buttonHeight(BuildContext context) => math.max(
    kMinInteractiveDimension,
    _height(
          context,
          AppLocalizations.of(context).save,
          Theme.of(context).textTheme.labelLarge,
          double.infinity,
        ) +
        _buttonPadding.vertical,
  );

  static ButtonStyle buttonStyle(
    BuildContext context, {
    bool compact = false,
  }) => FilledButton.styleFrom(
    textStyle: Theme.of(context).textTheme.labelLarge,
    minimumSize: const Size(64, kMinInteractiveDimension),
    visualDensity: VisualDensity.standard,
    tapTargetSize: MaterialTapTargetSize.padded,
    padding: compact
        ? const EdgeInsets.symmetric(horizontal: 16, vertical: 12)
        : _buttonPadding,
  );

  Widget _details(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Visibility(
      maintainState: true,
      maintainAnimation: true,
      maintainSize: true,
      visible: failed,
      child: Semantics(
        liveRegion: failed,
        label: compact && failed ? strings.operationFailed : null,
        child: SizedBox.square(
          dimension: kMinInteractiveDimension,
          child: IconButton(
            key: detailsKey ?? ValueKey('definition-details:$id'),
            tooltip: strings.viewConfigError,
            onPressed: failed ? onDetails : null,
            icon: Icon(
              Icons.info_outline,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      ),
    );
  }

  Widget _save(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final progress = SizedBox.square(
      dimension: 16,
      child: saving ? const CircularProgressIndicator(strokeWidth: 2) : null,
    );
    final style = buttonStyle(context, compact: compact);
    final key = saveKey ?? ValueKey('definition-save:$id');
    return Tooltip(
      message: strings.save,
      excludeFromSemantics: true,
      child: FilledButton(
        key: key,
        style: style,
        onPressed: saving ? null : onSave,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            progress,
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                strings.save,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!compact) const SizedBox(width: 24),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Align(
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: DefinitionFormBody.widthOf(context, wide: false),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: _padding,
            child: Flex(
              direction: compact ? Axis.horizontal : Axis.vertical,
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: compact
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: compact ? kMinInteractiveDimension : null,
                  child: Row(
                    children: [
                      if (!compact)
                        Expanded(
                          child: Visibility(
                            maintainState: true,
                            maintainAnimation: true,
                            maintainSize: true,
                            visible: failed,
                            child: Semantics(
                              liveRegion: failed,
                              child: Text(
                                strings.operationFailed,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error,
                                    ),
                              ),
                            ),
                          ),
                        ),
                      _details(context),
                    ],
                  ),
                ),
                SizedBox(width: compact ? 8 : 0),
                Flexible(flex: compact ? 1 : 0, child: _save(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
