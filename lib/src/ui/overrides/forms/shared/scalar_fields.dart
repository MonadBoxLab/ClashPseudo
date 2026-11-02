part of 'fields.dart';

const _noOriginalValue = Object();

class DefinitionOriginalField extends StatelessWidget {
  const DefinitionOriginalField({
    super.key,
    required this.id,
    required this.label,
    this.enabled = true,
    this.onUnset,
    this.originalValue = _noOriginalValue,
    this.originalText,
    this.identity,
  });

  final String id;
  final String label;
  final bool enabled;
  final VoidCallback? onUnset;

  /// Parsed value for a read-only model view, not reconstructed YAML source.
  /// The sentinel distinguishes an absent argument from an explicit null value.
  final Object? originalValue;

  /// Only a captured source span may be supplied here, including its original
  /// quoting and line endings. Never substitute normalized YAML serialization.
  final String? originalText;
  final Object? identity;

  String get _valueText {
    try {
      return const JsonEncoder.withIndent('  ').convert(originalValue);
    } on JsonUnsupportedObjectError {
      return originalValue.toString();
    }
  }

  bool _ownsOriginal(BuildContext context, ModalRoute<dynamic>? popup) {
    if (!context.mounted || ModalRoute.of(context)?.isActive == false) {
      return false;
    }
    final current = context.widget;
    return current is DefinitionOriginalField &&
        current.id == id &&
        current.originalText == originalText &&
        current.identity == identity &&
        current.enabled &&
        DefinitionFormInteraction.canAct(context, ownedPopup: popup);
  }

  Future<void> _showOriginal(BuildContext context) => showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(label, style: Theme.of(context).textTheme.titleLarge),
            ),
            Flexible(
              child: OriginalTextView(
                text: originalText!,
                identity: (identity, id, originalText),
                isCurrent: () =>
                    _ownsOriginal(context, ModalRoute.of(dialogContext)),
                isCurrentWithPopup: (popup) => _ownsOriginal(context, popup),
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(AppLocalizations.of(dialogContext).close),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  double _labelTopSpace(BuildContext context) {
    final theme = Theme.of(context);
    final states = {if (!enabled) WidgetState.disabled};
    final decoration = theme.inputDecorationTheme;
    final style = theme.textTheme.titleMedium!
        .merge(WidgetStateProperty.resolveAs(decoration.labelStyle, states))
        .merge(
          WidgetStateProperty.resolveAs(decoration.floatingLabelStyle, states),
        )
        .copyWith(height: 1);
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final height = painter.height;
    painter.dispose();
    // An outlined label paints above its border. Reserve that space in this
    // field, inside the chapter/visibility clips, at the actual text scale.
    return math.max(8, height / 2 + 2);
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(top: _labelTopSpace(context), bottom: 12),
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
            if (!identical(originalValue, _noOriginalValue)) ...[
              const SizedBox(height: 6),
              SelectableText(_valueText),
            ],
            if (originalText != null)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: ValueKey('definition-view-original:$id'),
                  onPressed: enabled
                      ? () {
                          if (DefinitionFormInteraction.canAct(context)) {
                            unawaited(_showOriginal(context));
                          }
                        }
                      : null,
                  icon: const Icon(Icons.code),
                  label: Text(strings.viewBody),
                ),
              ),
            if (onUnset != null)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: ValueKey('definition-unset-original:$id'),
                  onPressed: enabled
                      ? () {
                          if (DefinitionFormInteraction.canAct(context)) {
                            onUnset?.call();
                          }
                        }
                      : null,
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
    this.preserveValue,
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
  final bool Function()? preserveValue;
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
        if (!widget.active ||
            !_included ||
            widget.preserveValue?.call() == true) {
          return null;
        }
        final value = raw ?? '';
        if (widget.required &&
            (widget.trimRequired ? value.trim() : value).isEmpty) {
          return strings.proxyRequired;
        }
        if (value.isEmpty && !widget.required && !widget.nullable) return null;
        return widget.isValid?.call(value) == false
            ? widget.invalidMessage ?? strings.localYamlInvalidStructure
            : null;
      },
      onSaved: (value) {
        if (widget.preserveValue?.call() == true) return;
        widget.onSaved?.call(
          widget.active &&
                  _included &&
                  (widget.nullable || (value?.isNotEmpty ?? false))
              ? value ?? ''
              : null,
        );
      },
      builder: (field) {
        final editable = widget.active && widget.enabled && _included;
        void change(String value) {
          if (!mounted ||
              !widget.active ||
              !widget.enabled ||
              !DefinitionFormInteraction.canAct(context)) {
            return;
          }
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
                                if (!mounted ||
                                    !widget.active ||
                                    !widget.enabled ||
                                    !DefinitionFormInteraction.canAct(
                                      context,
                                    )) {
                                  return;
                                }
                                setState(() => _present = value);
                                widget.onInteracted?.call();
                              }
                            : null,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              DefinitionFieldValidation(
                hasError: widget.active && _included && field.hasError,
                message: field.errorText,
                child: TextField(
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
                                ? () {
                                    if (mounted &&
                                        widget.active &&
                                        widget.enabled &&
                                        _included &&
                                        DefinitionFormInteraction.canAct(
                                          context,
                                        )) {
                                      setState(() => _revealed = !_revealed);
                                    }
                                  }
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
                                if (!mounted ||
                                    !widget.active ||
                                    !widget.enabled ||
                                    !_included ||
                                    !DefinitionFormInteraction.canAct(
                                      context,
                                    )) {
                                  return;
                                }
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
              ),
              if (widget.hint != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    widget.hint!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
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
    this.preserveValue,
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
  final bool Function()? preserveValue;
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
    preserveValue: preserveValue,
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
    this.preserveValue,
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
  final bool Function()? preserveValue;
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
        if (!active || preserveValue?.call() == true) return null;
        if (value == null) return optional ? null : strings.proxyRequired;
        return isValid?.call(value) == false
            ? invalidMessage ?? strings.localYamlInvalidStructure
            : null;
      },
      onSaved: (value) {
        if (preserveValue?.call() != true) onSaved?.call(active ? value : null);
      },
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
              DefinitionFieldValidation(
                hasError: active && field.hasError,
                message: field.errorText,
                child: ChoiceMenuButton<String>(
                  key: ValueKey('definition-menu:$id'),
                  enabled: active && enabled,
                  semanticsLabel: label,
                  semanticsValue: selected,
                  value: field.value ?? _unset,
                  options: {
                    if (optional) _unset: strings.proxyUnset,
                    ...options,
                  },
                  onOpened: () => FocusManager.instance.primaryFocus?.unfocus(),
                  onSelected: (raw) {
                    if (!field.mounted ||
                        !active ||
                        !enabled ||
                        !DefinitionFormInteraction.canAct(field.context)) {
                      return;
                    }
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
              ),
              if (hint != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    hint!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
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
