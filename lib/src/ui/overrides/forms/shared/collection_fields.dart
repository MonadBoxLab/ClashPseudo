part of 'fields.dart';

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
          onPressed: onUp == null
              ? null
              : () {
                  if (DefinitionFormInteraction.canAct(context)) onUp?.call();
                },
          color: HomePalette.of(context).editAction,
          icon: const Icon(Icons.arrow_upward),
        ),
        IconButton(
          key: ValueKey('definition-down:$id'),
          tooltip: strings.definitionFormMoveDown,
          onPressed: onDown == null
              ? null
              : () {
                  if (DefinitionFormInteraction.canAct(context)) onDown?.call();
                },
          color: HomePalette.of(context).editAction,
          icon: const Icon(Icons.arrow_downward),
        ),
        IconButton(
          key: ValueKey('definition-remove:$id'),
          tooltip: strings.proxyRemoveItem(label, index + 1),
          onPressed: onRemove == null
              ? null
              : () {
                  if (DefinitionFormInteraction.canAct(context)) {
                    onRemove?.call();
                  }
                },
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
    this.preserveValue,
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
  final bool Function()? preserveValue;
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
      DefinitionFormInteraction.canAct(context);
  List<String>? get _value =>
      _included ? List.unmodifiable(_rows.map((row) => row.text)) : null;

  String? _rowError(({int id, String text}) row) {
    final strings = AppLocalizations.of(context);
    if (!widget.allowEmptyItems && row.text.isEmpty) {
      return strings.proxyRequired;
    }
    return widget.isValidItem?.call(row.text) == false
        ? widget.invalidMessage ?? strings.localYamlInvalidStructure
        : null;
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
          if (!widget.active ||
              !_included ||
              widget.preserveValue?.call() == true) {
            return null;
          }
          for (final row in _rows) {
            final error = _rowError(row);
            if (error != null) {
              _errorId = row.id;
              return error;
            }
          }
          return null;
        },
        onSaved: (_) {
          if (widget.preserveValue?.call() != true) {
            widget.onSaved(widget.active ? _value : null);
          }
        },
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
    this.preserveValue,
    this.scalarValues = false,
  });
  final String id;
  final String label;
  final ValueChanged<Map<String, List<String>>?> onSaved;
  final Map<String, List<String>>? initialValue;
  final ValueChanged<Map<String, List<String>>?>? onChanged;
  final bool active;
  final bool enabled;
  final bool Function()? preserveValue;
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
      DefinitionFormInteraction.canAct(context);
  Map<String, List<String>>? get _value => !_present
      ? null
      : Map.unmodifiable({
          for (final row in _rows)
            row.name: List<String>.unmodifiable(row.values),
        });

  ({int id, String error})? get _firstError {
    if (!widget.active || !_included || widget.preserveValue?.call() == true) {
      return null;
    }
    final names = <String>{};
    for (final row in _rows) {
      if (row.name.trim().isEmpty) {
        return (id: row.id, error: AppLocalizations.of(context).proxyRequired);
      }
      if (!names.add(row.name)) {
        return (
          id: row.id,
          error: AppLocalizations.of(context).proxyDuplicateKey,
        );
      }
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
        onSaved: (_) {
          if (widget.preserveValue?.call() != true) {
            widget.onSaved(widget.active ? _value : null);
          }
        },
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
                !DefinitionFormInteraction.canAct(context)) {
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
                  !widget.enabled ||
                  !DefinitionFormInteraction.canAct(this.context)) {
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
        !DefinitionFormInteraction.canAct(context) ||
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
