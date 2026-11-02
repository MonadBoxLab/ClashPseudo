part of 'proxy_form.dart';

// Bindings for the explicitly composed widgets in proxy_form.dart.
typedef _Scope = ({
  Map<String, Object?> data,
  List<Object> path,
  String identity,
  List<Object>? initialPath,
  bool active,
});

typedef _RecordFields = List<Widget> Function(
  _ProxyFormPageState owner,
  _Scope scope,
);

enum _OptionalBool { unset, off, on }

class _CollectionDraft {
  bool enabled = false;
  bool editing = false;
  bool expanded = false;
  String? errorId;
  final rows = <_EntryDraft>[];
}

class _EntryDraft {
  _EntryDraft(this.id, {this.initialPath});
  final String id;
  final List<Object>? initialPath;
  Map<String, Object?>? definition;
}

Map<String, Object?> _copyProxyDraft(Map<String, Object?> source) {
  final active = Set<Object>.identity();
  Object? copy(Object? value, int depth) {
    if (depth > 64) throw ArgumentError('GUI proxy draft is too deep');
    if (value == null || value is String || value is bool || value is num) {
      return value;
    }
    if (value is! Map && value is! List) {
      throw ArgumentError('Invalid GUI proxy draft value');
    }
    if (!active.add(value)) throw ArgumentError('Cyclic GUI proxy draft');
    final Object result;
    if (value is Map) {
      final map = <String, Object?>{};
      for (final entry in value.entries) {
        if (entry.key is! String) {
          throw ArgumentError('Invalid GUI proxy draft key');
        }
        map[entry.key as String] = copy(entry.value, depth + 1);
      }
      result = map;
    } else {
      result = [for (final child in value as List) copy(child, depth + 1)];
    }
    active.remove(value);
    return result;
  }

  return copy(source, 0) as Map<String, Object?>;
}

const _minInt = -9223372036854775808;
const _maxInt = 9223372036854775807;
final _maxUint64 = BigInt.parse('18446744073709551615');

Object _parseFormInteger(
  String text, {
  int min = _minInt,
  int max = _maxInt,
  bool unsigned64 = false,
}) {
  if (!RegExp(r'^[+-]?[0-9]+$').hasMatch(text)) {
    throw const FormatException('Invalid integer');
  }
  final value = BigInt.tryParse(text);
  final lower = unsigned64 ? BigInt.zero : BigInt.from(min);
  final upper = unsigned64 ? _maxUint64 : BigInt.from(max);
  if (value == null || value < lower || value > upper) {
    throw const FormatException('Invalid integer');
  }
  // Declared uint64 options use exact decimal-string input above signed64.
  return value > BigInt.from(_maxInt) ? value.toString() : value.toInt();
}

extension _ProxyFormFields on _ProxyFormPageState {
  void _register(_Scope scope, String key) {
    if (scope.path.isEmpty) {
      _typeFields.putIfAbsent(_type.raw, () => <String>{}).add(key);
    }
  }

  _Scope _effective(_Scope s, String key) {
    _register(s, key);
    return s.path.isEmpty &&
            widget._recordFields == null &&
            _ProxyFormPageState._commonKeys.contains(key)
        ? (
            data: _common,
            path: s.path,
            identity: 'common',
            initialPath: const <Object>[],
            active: s.active,
          )
        : s;
  }

  bool _changedField(String identity) => _touched.any(
    (field) => field == identity || field.startsWith('$identity/'),
  );

  bool _hasOriginal(_Scope scope, String key) {
    final parent = _initialAt(scope.initialPath);
    return scope.initialPath != null &&
        parent is Map &&
        parent.containsKey(key);
  }

  bool _preserveField(_Scope scope, String key) =>
      _hasOriginal(_effective(scope, key), key) &&
      !_changedField(_fieldId(scope, key));

  void _saveField(_Scope scope, String key, Object? value) {
    if (!scope.active || _preserveField(scope, key)) return;
    final path = [...scope.path, key];
    if (value == null) {
      _removeField(path);
    } else {
      _put(path, value);
    }
  }

  void _removeField(List<Object> path) {
    Object? current = _definition;
    for (final key in path.take(path.length - 1)) {
      current = current is Map
          ? current[key]
          : current is List && key is int && key < current.length
          ? current[key]
          : null;
    }
    final key = path.last;
    if (current is Map) current.remove(key);
  }

  Object? _initialAt(List<Object>? path) {
    if (path == null) return null;
    Object? value = _initialDefinition;
    for (final key in path) {
      if (value is Map<String, Object?> && key is String) {
        value = value[key];
      } else if (value is List &&
          key is int &&
          key >= 0 &&
          key < value.length) {
        value = value[key];
      } else {
        return null;
      }
    }
    return value;
  }

  Object? _native(_Scope s, String key) =>
      _initialAt(s.initialPath == null ? null : [...s.initialPath!, key]);

  Object? _read(_Scope s, String key) {
    final effective = _effective(s, key);
    return effective.data.containsKey(key)
        ? effective.data[key]
        : _native(effective, key);
  }

  String _readString(_Scope s, String key) {
    final value = _read(s, key);
    return value is String ? value : '';
  }

  Widget? _originalField(
    _Scope scope,
    String key,
    bool Function(Object) representable,
  ) => _unsupportedValue(
    scope,
    key,
    _native(_effective(scope, key), key),
    representable,
  );

  Widget? _unsupportedValue(
    _Scope scope,
    String key,
    Object? value,
    bool Function(Object) representable,
  ) {
    if (!_hasOriginal(_effective(scope, key), key) ||
        value != null && representable(value)) {
      return null;
    }
    return DefinitionOriginalField(
      key: ValueKey('proxy-original-field:${_fieldId(scope, key)}'),
      id: _fieldId(scope, key),
      label: _label(scope, key),
      originalValue: value,
      originalText: widget.originalValueText?.call([...scope.path, key]),
      identity: _initialDefinition,
    );
  }

  String _fieldId(_Scope s, String key) =>
      '${_effective(s, key).identity}/$key';

  String _label(_Scope s, String key) => s.path.isEmpty
      ? switch (key) {
          'name' => _strings.proxyName,
          'server' => _strings.proxyServer,
          'port' => _strings.portLabel('').trim(),
          'username' => _strings.proxyUsername,
          'password' => _strings.proxyPassword,
          _ => key,
        }
      : key;

  Widget _text(
    _Scope scope,
    String key, {
    bool required = false,
    bool secret = false,
    bool multiline = false,
    bool nullable = false,
    String? label,
    String? unit,
    String? hint,
    String? Function(String)? extraValidate,
  }) {
    final s = _effective(scope, key);
    final original = _originalField(scope, key, (value) => value is String);
    if (original != null) return original;
    final identity = _fieldId(scope, key);
    s.data.putIfAbsent(
      key,
      () => _native(s, key) is String ? _native(s, key) as String : '',
    );
    if (nullable) {
      s.data.putIfAbsent('$key#present', () => _native(s, key) != null);
    }
    Widget input(bool present, Widget? presence) => _ScalarInput(
      key: ValueKey('proxy-field:$identity'),
      label: label ?? _label(scope, key),
      initial: s.data[key] as String? ?? '',
      enabled: s.active && present,
      secret: secret,
      multiline: multiline,
      unit: unit,
      hint: hint,
      labelTrailing: presence,
      onChanged: (value) {
        s.data[key] = value;
        _touched.add(_fieldId(scope, key));
      },
      validate: (value) {
        if (!s.active || !present || _preserveField(scope, key)) return null;
        if (required && value.trim().isEmpty) return _strings.proxyRequired;
        return extraValidate?.call(value);
      },
      onSaved: (value) {
        if (s.active) {
          _saveField(
            scope,
            key,
            present && (nullable || value.isNotEmpty) ? value : null,
          );
        }
      },
    );
    if (!nullable) return input(true, null);
    return FormField<bool>(
      key: ValueKey('proxy-presence:$identity'),
      initialValue: s.data['$key#present'] == true,
      builder: (field) => input(
        field.value == true,
        Switch(
          key: ValueKey('proxy-enable:$identity'),
          value: field.value == true,
          onChanged: s.active
              ? (value) {
                  if (!field.mounted ||
                      !s.active ||
                      !DefinitionFormInteraction.canAct(field.context)) {
                    return;
                  }
                  s.data['$key#present'] = value;
                  _touched.add(_fieldId(scope, key));
                  field.didChange(value);
                }
              : null,
        ),
      ),
    );
  }

  List<Widget> _texts(_Scope s, List<String> keys) => [
    for (final key in keys) _text(s, key),
  ];

  Widget _number(
    _Scope scope,
    String key, {
    bool required = false,
    int min = _minInt,
    int max = _maxInt,
    bool unsigned64 = false,
    String? unit,
    String? hint,
    String? label,
    String? Function(String)? extraValidate,
  }) {
    final s = _effective(scope, key);
    final original = _originalField(
      scope,
      key,
      (value) => value is int || value is String,
    );
    if (original != null) return original;
    s.data.putIfAbsent(key, () => _native(s, key)?.toString() ?? '');
    return _ScalarInput(
      key: ValueKey('proxy-field:${_fieldId(scope, key)}'),
      label: label ?? _label(scope, key),
      initial: s.data[key] as String? ?? '',
      enabled: s.active,
      numeric: true,
      signed: !unsigned64 && min < 0,
      unit: unit,
      hint: hint,
      onChanged: (value) {
        s.data[key] = value;
        _touched.add(_fieldId(scope, key));
      },
      validate: (value) {
        if (!s.active || _preserveField(scope, key)) return null;
        return _integerError(
              value,
              key,
              required: required,
              min: min,
              max: max,
              unsigned64: unsigned64,
            ) ??
            (value.isNotEmpty ? extraValidate?.call(value) : null);
      },
      onSaved: (value) {
        if (s.active && !_preserveField(scope, key)) {
          _saveField(
            scope,
            key,
            value.isEmpty
                ? null
                : _parseFormInteger(
                    value,
                    min: min,
                    max: max,
                    unsigned64: unsigned64,
                  ),
          );
        }
      },
    );
  }

  List<Widget> _numbers(
    _Scope s,
    List<String> keys, {
    int min = _minInt,
    int max = _maxInt,
    bool unsigned64 = false,
    String? unit,
  }) => [
    for (final key in keys)
      _number(s, key, min: min, max: max, unsigned64: unsigned64, unit: unit),
  ];

  Widget _bool(_Scope scope, String key, {String? hint}) {
    final s = _effective(scope, key);
    final original = _originalField(scope, key, (value) => value is bool);
    if (original != null) return original;
    s.data.putIfAbsent(
      key,
      () => switch (_native(s, key)) {
        true => _OptionalBool.on,
        false => _OptionalBool.off,
        _ => _OptionalBool.unset,
      },
    );
    return FormField<_OptionalBool>(
      key: ValueKey('proxy-bool:${_fieldId(scope, key)}'),
      initialValue: s.data[key] as _OptionalBool? ?? _OptionalBool.unset,
      onSaved: (value) {
        if (s.active) {
          _saveField(
            scope,
            key,
            value == null || value == _OptionalBool.unset
                ? null
                : value == _OptionalBool.on,
          );
        }
      },
      builder: (field) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _label(scope, key),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 6),
            ChoiceMenuButton<_OptionalBool>(
              key: ValueKey('proxy-choice:${_fieldId(scope, key)}'),
              enabled: s.active,
              value: field.value,
              options: {
                _OptionalBool.unset: _strings.proxyUnset,
                _OptionalBool.off: _strings.proxyFalse,
                _OptionalBool.on: _strings.proxyTrue,
              },
              onSelected: (value) {
                if (!field.mounted ||
                    !s.active ||
                    !DefinitionFormInteraction.canAct(field.context)) {
                  return;
                }
                s.data[key] = value;
                _touched.add(_fieldId(scope, key));
                field.didChange(value);
              },
              child: InputDecorator(
                decoration: InputDecoration(
                  enabled: s.active,
                  border: const OutlineInputBorder(),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _selectionLabel(
                        {
                          _strings.proxyUnset,
                          _strings.proxyFalse,
                          _strings.proxyTrue,
                        },
                        switch (field.value ?? _OptionalBool.unset) {
                          _OptionalBool.unset => _strings.proxyUnset,
                          _OptionalBool.off => _strings.proxyFalse,
                          _OptionalBool.on => _strings.proxyTrue,
                        },
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
            ),
            if (hint != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(hint, style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _bools(_Scope s, List<String> keys) => [
    for (final key in keys) _bool(s, key),
  ];

  Widget _choice(
    _Scope scope,
    String key,
    List<String> values, {
    bool required = false,
    bool refresh = false,
  }) {
    final s = _effective(scope, key);
    final original = _originalField(scope, key, (value) => value is String);
    if (original != null) return original;
    s.data.putIfAbsent(
      key,
      () => _native(s, key) is String ? _native(s, key) as String : '',
    );
    return FormField<String>(
      key: ValueKey('proxy-select:${_fieldId(scope, key)}'),
      initialValue: s.data[key] as String? ?? '',
      validator: (value) =>
          s.active &&
              !_preserveField(scope, key) &&
              required &&
              (value == null || value.isEmpty)
          ? _strings.proxyRequired
          : null,
      onSaved: (value) {
        if (s.active) {
          _saveField(scope, key, value == null || value.isEmpty ? null : value);
        }
      },
      builder: (field) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _label(scope, key),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 6),
            DefinitionFieldValidation(
              hasError: field.hasError,
              message: field.errorText,
              child: ChoiceMenuButton<String>(
                key: ValueKey('proxy-choice:${_fieldId(scope, key)}'),
                enabled: s.active,
                value: field.value,
                options: {
                  '': _strings.proxyUnset,
                  for (final value in values) value: value,
                },
                onSelected: (value) {
                  if (!field.mounted ||
                      !s.active ||
                      !DefinitionFormInteraction.canAct(field.context)) {
                    return;
                  }
                  s.data[key] = value;
                  _touched.add(_fieldId(scope, key));
                  field.didChange(value);
                  if (refresh) _refreshFields();
                },
                child: InputDecorator(
                  decoration: InputDecoration(
                    enabled: s.active,
                    border: const OutlineInputBorder(),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _selectionLabel(
                          {_strings.proxyUnset, ...values},
                          field.value?.isNotEmpty == true
                              ? field.value!
                              : _strings.proxyUnset,
                        ),
                      ),
                      const Icon(Icons.arrow_drop_down),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  _Scope _child(_Scope parent, String key, {String? draftKey, bool? active}) {
    _register(parent, key);
    final data = parent.data.putIfAbsent(
      draftKey ?? key,
      () => <String, Object?>{},
    ) as Map<String, Object?>;
    return (
      data: data,
      path: [...parent.path, key],
      identity: '${parent.identity}/${draftKey ?? key}',
      // A plugin selection changes the discriminator, not the original map.
      // Keep same-named and unknown options available in every branch draft.
      initialPath: parent.initialPath == null
          ? null
          : [...parent.initialPath!, key],
      active: active ?? parent.active,
    );
  }

  Widget _object(
    _Scope parent,
    String key,
    List<Widget> Function(_Scope) children, {
    bool initiallyExpanded = false,
    String? draftKey,
  }) {
    final child = _child(parent, key, draftKey: draftKey);
    final original = _unsupportedValue(
      parent,
      key,
      _initialAt(child.initialPath),
      (value) => value is Map<String, Object?>,
    );
    if (original != null) return original;
    child.data.putIfAbsent(
      '#enabled',
      () => _initialAt(child.initialPath) is Map,
    );
    return FormField<bool>(
      key: ValueKey('proxy-object:${child.identity}'),
      initialValue: child.data['#enabled'] == true,
      onSaved: (enabled) {
        if (!parent.active) return;
        if (_hasOriginal(parent, key) && !_changedField(child.identity)) return;
        if (enabled == true) {
          _ensure([...parent.path, key], <String, Object?>{});
        } else {
          _removeField([...parent.path, key]);
        }
      },
      builder: (field) {
        final scoped = (
          data: child.data,
          path: child.path,
          identity: child.identity,
          initialPath: child.initialPath,
          active: parent.active && field.value == true,
        );
        return DefinitionFormExpansion(
          key: ValueKey('proxy-group:${child.identity}'),
          onExpansionChanged: (expanded) {
            if (!expanded && field.mounted) {
              DefinitionFormBody.unfocusWithin(field.context);
            }
          },
          maintainState: true,
          initiallyExpanded: initiallyExpanded,
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsetsDirectional.only(start: 12, top: 8),
          leading: Semantics(
            label: key,
            child: Switch(
              key: ValueKey('proxy-enable:${child.identity}'),
              value: field.value == true,
              onChanged: parent.active
                  ? (value) {
                      if (!field.mounted ||
                          !parent.active ||
                          !DefinitionFormInteraction.canAct(field.context)) {
                        return;
                      }
                      child.data['#enabled'] = value;
                      _touched.add(child.identity);
                      field.didChange(value);
                    }
                  : null,
            ),
          ),
          title: Text(key),
          children: [
            DefinitionFormInteraction(
              active: scoped.active,
              isActiveNow: () =>
                  field.mounted && parent.active && field.value == true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children(scoped),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _list(
    _Scope scope,
    String key, {
    bool numeric = false,
    int min = _minInt,
    int max = _maxInt,
    String? unit,
  }) {
    final s = _effective(scope, key);
    final original = _originalField(
      scope,
      key,
      (value) =>
          value is List &&
          value.every((item) => item is String || numeric && item is int),
    );
    if (original != null) return original;
    final source = _read(s, key);
    final identity = _fieldId(scope, key);
    return DefinitionStringListField(
      preserveValue: () => _preserveField(scope, key),
      key: ValueKey('proxy-list:$identity'),
      id: identity,
      label: _label(scope, key),
      initialValue: source is List
          ? [for (final item in source) '$item']
          : null,
      active: s.active,
      enabled: s.active,
      allowEmptyItems: !numeric,
      numeric: numeric,
      signed: min < 0,
      unit: unit,
      isValidItem: numeric
          ? (value) =>
                _preserveField(scope, key) ||
                _integerError(value, 'value', min: min, max: max) == null
          : null,
      invalidMessage: numeric
          ? max == 255 && min == 0
                ? _strings.proxyInvalidByte
                : _strings.proxyInvalidInteger
          : null,
      onChanged: (value) {
        s.data[key] = value;
        _touched.add(identity);
      },
      onSaved: (value) => _saveField(
        scope,
        key,
        value == null || _preserveField(scope, key)
            ? null
            : [
                for (final item in value)
                  if (numeric)
                    _parseFormInteger(item, min: min, max: max)
                  else
                    item,
              ],
      ),
    );
  }

  Widget _mapping(_Scope scope, String key, {bool listValues = false}) {
    final s = _effective(scope, key);
    final original = _originalField(
      scope,
      key,
      (value) =>
          value is Map<String, Object?> &&
          value.values.every(
            (item) => listValues
                ? item is List && item.every((value) => value is String)
                : item is String,
          ),
    );
    if (original != null) return original;
    final source = _read(s, key);
    // GUI drafts use lists even when the native mapping has scalar values.
    final hasDraft = s.data.containsKey(key);
    final identity = _fieldId(scope, key);
    return DefinitionHeadersField(
      preserveValue: () => _preserveField(scope, key),
      key: ValueKey('proxy-mapping:$identity'),
      id: identity,
      label: _label(scope, key),
      initialValue: source is Map<String, Object?>
          ? {
              for (final entry in source.entries)
                entry.key: listValues || hasDraft
                    ? (entry.value as List).cast<String>()
                    : [entry.value as String],
            }
          : null,
      active: s.active,
      enabled: s.active,
      scalarValues: !listValues,
      onChanged: (value) {
        s.data[key] = value;
        _touched.add(identity);
      },
      onSaved: (value) => _saveField(
        scope,
        key,
        value == null
            ? null
            : {
                for (final entry in value.entries)
                  entry.key: listValues ? entry.value : entry.value.single,
              },
      ),
    );
  }

  String? _integerError(
    Object? value,
    String key, {
    bool required = false,
    int min = _minInt,
    int max = _maxInt,
    bool unsigned64 = false,
  }) {
    if (value == null || value == '') {
      return required ? _strings.proxyRequired : null;
    }
    // Other original shapes are shown read-only and preserved by the field.
    if (value is! String && value is! int) return null;
    try {
      _parseFormInteger('$value', min: min, max: max, unsigned64: unsigned64);
      return null;
    } on FormatException {
      return max == 255 && min == 0
          ? _strings.proxyInvalidByte
          : max == 65535 && min == 0 && key.contains('port')
          ? _strings.proxyInvalidPort
          : _strings.proxyInvalidInteger;
    }
  }

  String? _requiredRecordText(Object? value) =>
      value == null || value is String && value.isEmpty
      ? _strings.proxyRequired
      : null;

  String? _wireguardPeerError(Map<String, Object?> row) {
    final port = _integerError(row['port'], 'port', min: 0, max: 65535);
    if (port != null) return port;
    final reserved = row['reserved'];
    if (reserved is List &&
        reserved.every((value) => value is String || value is int)) {
      for (final value in reserved) {
        final error = _integerError(
          value,
          'value',
          required: true,
          min: 0,
          max: 255,
        );
        if (error != null) return error;
      }
    }
    return null;
  }

  String? _nextStepError(Map<String, Object?> row) =>
      _integerError(
        row['weight'],
        'weight',
        min: -2147483648,
        max: 2147483647,
      ) ??
      _integerError(row['goto-location'], 'goto-location');

  String? _timeSpecPairError(String baseText, String multiplierText) {
    final base = baseText.isEmpty ? BigInt.zero : BigInt.tryParse(baseText);
    final multiplier = multiplierText.isEmpty
        ? BigInt.zero
        : BigInt.tryParse(multiplierText);
    if (base == null || multiplier == null) return null;
    final maximum =
        base +
        (multiplier > BigInt.zero ? multiplier - BigInt.one : BigInt.zero);
    return maximum > BigInt.from(_maxInt) ? _strings.proxyInvalidInteger : null;
  }

  String? _trafficStepError(Map<String, Object?> row) {
    final next = row['next-step'];
    if (next is List && next.every((value) => value is Map<String, Object?>)) {
      for (final value in next.cast<Map<String, Object?>>()) {
        final error = _nextStepError(value);
        if (error != null) return error;
      }
    }
    final wait = row['wait-time'];
    if (wait is Map<String, Object?>) {
      final base = wait['base-nanoseconds'];
      final multiplier = wait['uniform-random-multiplier-nanoseconds'];
      return _integerError(base, 'base-nanoseconds', min: 0) ??
          _integerError(
            multiplier,
            'uniform-random-multiplier-nanoseconds',
            unsigned64: true,
          ) ??
          _timeSpecPairError(
            base is int || base is String ? '$base' : '',
            multiplier is int || multiplier is String ? '$multiplier' : '',
          );
    }
    return null;
  }

  Map<String, Object?> _recordValue(_EntryDraft row) =>
      row.definition ??
      switch (_initialAt(row.initialPath)) {
        final Map<String, Object?> value => value,
        _ => const <String, Object?>{},
      };

  Widget _records(
    _Scope parent,
    String key,
    _RecordFields fields, {
    String? Function(Map<String, Object?>)? validate,
  }) {
    _register(parent, key);
    final original = _originalField(
      parent,
      key,
      (value) =>
          value is List && value.every((item) => item is Map<String, Object?>),
    );
    if (original != null) return original;
    final draft = parent.data.putIfAbsent(
      key,
      () => _initialCollection(parent, key),
    ) as _CollectionDraft;
    final identity = '${parent.identity}/$key';
    final ownerType = _type;
    final scroll = _recordScrolls.putIfAbsent(identity, ScrollController.new);
    final indices = {
      for (final (index, row) in draft.rows.indexed)
        ValueKey('proxy-row:$identity/${row.id}'): index,
    };
    BuildContext? fieldContext;
    return DefinitionValidationTarget(
      reveal: () async {
        final index = draft.rows.indexWhere((row) => row.id == draft.errorId);
        if (!mounted ||
            !parent.active ||
            !draft.enabled ||
            draft.editing ||
            _saving ||
            _type != ownerType ||
            !identical(parent.data[key], draft) ||
            index < 0 ||
            fieldContext == null ||
            validate?.call(_recordValue(draft.rows[index])) == null) {
          return null;
        }
        return DefinitionFormBody.revealListRow(
          context: fieldContext!,
          controller: scroll,
          index: index,
          count: draft.rows.length,
          rowKey: ValueKey('proxy-row:$identity/${draft.rows[index].id}'),
        );
      },
      child: FormField<bool>(
        key: ValueKey('proxy-collection:$identity'),
        initialValue: draft.enabled,
        validator: (_) {
          draft.errorId = null;
          if (!parent.active || !draft.enabled || _preserveField(parent, key)) {
            return null;
          }
          for (final row in draft.rows) {
            final error = validate?.call(_recordValue(row));
            if (error != null) {
              draft.errorId = row.id;
              return error;
            }
          }
          return null;
        },
        onSaved: (_) {
          if (!parent.active) return;
          if (_hasOriginal(parent, key) && !_changedField(identity)) return;
          if (draft.enabled) {
            _put(
              [...parent.path, key],
              [
                for (final row in draft.rows)
                  _copyProxyDraft(_recordValue(row)),
              ],
            );
          } else {
            _removeField([...parent.path, key]);
          }
        },
        builder: (field) {
          fieldContext = field.context;
          bool canAct() =>
              mounted &&
              field.mounted &&
              parent.active &&
              !_saving &&
              !draft.editing &&
              _type == ownerType &&
              identical(parent.data[key], draft) &&
              DefinitionFormInteraction.canAct(field.context);
          Future<void> edit(_EntryDraft? row) async {
            if (!canAct() ||
                !draft.expanded ||
                row != null && (!draft.enabled || !draft.rows.contains(row))) {
              return;
            }
            final route = ModalRoute.of(context)!;
            final id = row?.id ?? 'r$_rowSequence';
            FocusManager.instance.primaryFocus?.unfocus();
            draft.editing = true;
            field.didChange(draft.enabled);
            try {
              final result = await Navigator.of(context)
                  .push<Map<String, Object?>>(
                    MaterialPageRoute(
                      builder: (_) => ProxyFormPage._record(
                        initialType: ownerType.raw,
                        initialDefinition: row == null
                            ? const <String, Object?>{}
                            : _copyProxyDraft(_recordValue(row)),
                        originalValueText: row?.initialPath == null
                            ? null
                            : (path) => widget.originalValueText?.call([
                                ...row!.initialPath!,
                                ...path,
                              ]),
                        fields: fields,
                        identity: '$identity/$id',
                        title: key,
                        onSave: (_) async {},
                      ),
                    ),
                  );
              if (!mounted ||
                  !field.mounted ||
                  result == null ||
                  _saving ||
                  !parent.active ||
                  !draft.expanded ||
                  !DefinitionFormInteraction.canAct(field.context) ||
                  _type != ownerType ||
                  !route.isActive ||
                  !identical(parent.data[key], draft) ||
                  row != null &&
                      (!draft.enabled || !draft.rows.contains(row))) {
                return;
              }
              final target = row ?? _EntryDraft('r${_rowSequence++}');
              target.definition = _copyProxyDraft(result);
              if (row == null) draft.rows.add(target);
              draft.enabled = true;
              _touched.add(identity);
              field.didChange(true);
            } finally {
              draft.editing = false;
              if (mounted && field.mounted) {
                field.didChange(draft.enabled);
              }
            }
          }

          Widget item(int index, {bool prototype = false}) {
            final row = draft.rows[index];
            final label = '$key ${index + 1}';
            return ListTile(
              key: prototype ? null : ValueKey('proxy-row:$identity/${row.id}'),
              contentPadding: EdgeInsets.zero,
              title: Tooltip(
                message: label,
                excludeFromSemantics: true,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              onTap:
                  !prototype &&
                      parent.active &&
                      draft.enabled &&
                      !draft.editing &&
                      !_saving
                  ? () => edit(row)
                  : null,
              trailing: SizedBox(
                width: 96,
                child: Row(
                  children: [
                    IconButton(
                      key: prototype
                          ? null
                          : ValueKey('proxy-edit:$identity/${row.id}'),
                      tooltip: _strings.definitionFormEditItem(key, index + 1),
                      color: HomePalette.of(context).editAction,
                      onPressed:
                          !prototype &&
                              parent.active &&
                              draft.enabled &&
                              !draft.editing &&
                              !_saving
                          ? () => edit(row)
                          : null,
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      key: prototype
                          ? null
                          : ValueKey('proxy-remove:$identity/${row.id}'),
                      tooltip: _strings.proxyRemoveItem(key, index + 1),
                      color: Theme.of(context).colorScheme.error,
                      onPressed:
                          !prototype &&
                              parent.active &&
                              draft.enabled &&
                              !draft.editing &&
                              !_saving
                          ? () {
                              if (!canAct() ||
                                  !draft.expanded ||
                                  !draft.enabled ||
                                  !draft.rows.contains(row)) {
                                return;
                              }
                              draft.rows.remove(row);
                              _touched.add(identity);
                              field.didChange(draft.enabled);
                            }
                          : null,
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                  ],
                ),
              ),
            );
          }

          return DefinitionFormExpansion(
            key: ValueKey('proxy-group:$identity'),
            initiallyExpanded: draft.expanded,
            onExpansionChanged: (expanded) {
              draft.expanded = expanded;
              if (!expanded && field.mounted) {
                DefinitionFormBody.unfocusWithin(field.context);
              }
            },
            maintainState: true,
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsetsDirectional.only(
              start: 12,
              top: 8,
            ),
            leading: Semantics(
              label: key,
              child: Switch(
                key: ValueKey('proxy-enable:$identity'),
                value: draft.enabled,
                onChanged: parent.active && !draft.editing && !_saving
                    ? (value) {
                        if (!canAct()) return;
                        draft.enabled = value;
                        _touched.add(identity);
                        field.didChange(value);
                      }
                    : null,
              ),
            ),
            title: Text(key),
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: DefinitionFormBody.collectionHeightOf(
                    field.context,
                  ),
                ),
                child: ListView.builder(
                  key: ValueKey('proxy-record-list:$identity'),
                  controller: scroll,
                  primary: false,
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  prototypeItem: draft.rows.isEmpty
                      ? null
                      : ExcludeFocus(
                          child: ExcludeSemantics(
                            child: item(draft.rows.length - 1, prototype: true),
                          ),
                        ),
                  itemCount: draft.rows.length,
                  findChildIndexCallback: (key) => indices[key],
                  itemBuilder: (context, index) => item(index),
                ),
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: ValueKey('proxy-add:$identity'),
                  onPressed: parent.active && !draft.editing && !_saving
                      ? () => edit(null)
                      : null,
                  style: TextButton.styleFrom(
                    iconColor: HomePalette.of(context).editAction,
                  ),
                  icon: const Icon(Icons.add),
                  label: Text(_strings.proxyAddItem(key)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  _CollectionDraft _initialCollection(_Scope parent, String key) {
    final draft = _CollectionDraft();
    final path = parent.initialPath == null
        ? null
        : [...parent.initialPath!, key];
    final source = _initialAt(path);
    if (source is List) {
      draft.enabled = true;
      for (var i = 0; i < source.length; i++) {
        draft.rows.add(
          _EntryDraft('r${_rowSequence++}', initialPath: [...path!, i]),
        );
      }
    }
    return draft;
  }

  void _put(List<Object> path, Object? value) {
    Object current = _definition;
    for (var i = 0; i < path.length; i++) {
      final key = path[i];
      final last = i == path.length - 1;
      if (current is Map<String, Object?> && key is String) {
        if (last) {
          current[key] = value;
          return;
        }
        current = current.putIfAbsent(
          key,
          () => path[i + 1] is int ? <Object?>[] : <String, Object?>{},
        )!;
      } else if (current is List && key is int) {
        while (current.length <= key) {
          current.add(null);
        }
        if (last) {
          current[key] = value;
          return;
        }
        current[key] ??= path[i + 1] is int ? <Object?>[] : <String, Object?>{};
        current = current[key] as Object;
      } else {
        throw StateError('Invalid form target');
      }
    }
  }

  Object _ensure(List<Object> path, Object value) {
    Object? current = _definition;
    for (final key in path) {
      if (current is Map<String, Object?> && key is String) {
        current = current[key];
      } else if (current is List && key is int && key < current.length) {
        current = current[key];
      } else {
        current = null;
        break;
      }
    }
    if (current is Map && value is Map || current is List && value is List) {
      return current!;
    }
    _put(path, value);
    return value;
  }
}

// Reserve the largest natural label at the current width and text scale.
Widget _selectionLabel(Set<String> labels, String selected) => Stack(
  alignment: AlignmentDirectional.topStart,
  children: [
    for (final label in labels)
      Visibility(
        maintainState: true,
        maintainAnimation: true,
        maintainSize: true,
        visible: label == selected,
        child: Text(label),
      ),
  ],
);

/// 每个带 key 的输入框按记录或类型保留并释放 controller。
class _ScalarInput extends StatefulWidget {
  const _ScalarInput({
    super.key,
    required this.label,
    required this.initial,
    required this.enabled,
    required this.onChanged,
    required this.validate,
    required this.onSaved,
    this.secret = false,
    this.multiline = false,
    this.numeric = false,
    this.signed = false,
    this.labelTrailing,
    this.unit,
    this.hint,
  });
  final String label;
  final String initial;
  final bool enabled;
  final bool secret;
  final bool multiline;
  final bool numeric;
  final bool signed;
  final Widget? labelTrailing;
  final String? unit;
  final String? hint;
  final ValueChanged<String> onChanged;
  final String? Function(String) validate;
  final ValueChanged<String> onSaved;

  @override
  State<_ScalarInput> createState() => _ScalarInputState();
}

class _ScalarInputState extends State<_ScalarInput> {
  late final _controller = TextEditingController(text: widget.initial);
  bool _revealed = false;

  @override
  Widget build(BuildContext context) => FormField<String>(
    initialValue: widget.initial,
    validator: (value) => widget.validate(value ?? ''),
    onSaved: (value) => widget.onSaved(value ?? ''),
    builder: (field) => Padding(
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
              if (widget.labelTrailing != null) widget.labelTrailing!,
            ],
          ),
          const SizedBox(height: 6),
          DefinitionFieldValidation(
            hasError: field.hasError,
            message: field.errorText,
            child: TextField(
              controller: _controller,
              enabled: widget.enabled,
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
              onChanged: (value) {
                if (!mounted ||
                    !widget.enabled ||
                    !DefinitionFormInteraction.canAct(context)) {
                  return;
                }
                widget.onChanged(value);
                field.didChange(value);
              },
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                suffixText: widget.unit,
                suffixIcon: widget.secret && !widget.multiline
                    ? IconButton(
                        onPressed: widget.enabled
                            ? () {
                                if (mounted &&
                                    widget.enabled &&
                                    DefinitionFormInteraction.canAct(context)) {
                                  setState(() => _revealed = !_revealed);
                                }
                              }
                            : null,
                        tooltip: _revealed
                            ? AppLocalizations.of(context).proxyHideSecret
                            : AppLocalizations.of(context).proxyShowSecret,
                        icon: Icon(
                          _revealed
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
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
    ),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
