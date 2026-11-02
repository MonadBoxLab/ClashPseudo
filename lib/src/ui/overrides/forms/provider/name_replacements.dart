part of 'provider_form.dart';

class _NameReplacements extends StatefulWidget {
  const _NameReplacements({
    required this.enabled,
    required this.onSaved,
    this.initialValue,
    this.onChanged,
    this.preserveValue,
  });
  final bool enabled;
  final List? initialValue;
  final VoidCallback? onChanged;
  final ValueChanged<List<Map<String, Object?>>?> onSaved;
  final bool Function()? preserveValue;
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

  bool get _canInteract =>
      mounted && widget.enabled && DefinitionFormInteraction.canAct(context);

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
          if (!_present || widget.preserveValue?.call() == true) return null;
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
            if (!_canInteract || !_present) return;
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
              if (!_canInteract ||
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
                            if (!_canInteract || !_present) {
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
                    preserveValue: widget.preserveValue,
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
                          if (!_canInteract) return;
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
                            if (_canInteract &&
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
