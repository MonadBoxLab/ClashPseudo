import 'dart:collection';
import 'dart:convert';

import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../../model/config_text.dart';

/// Only definitions written directly in the dedicated local override body.
enum LocalYamlSection {
  proxies('proxies'),
  strategyGroups('proxy-groups'),
  proxyProviders('proxy-providers'),
  ruleProviders('rule-providers'),
  rules('rules');

  const LocalYamlSection(this.key);
  final String key;
}

enum LocalYamlEditError {
  invalidYaml,
  multipleDocuments,
  notMapping,
  duplicateKey,
  invalidStructure,
  duplicateName,
  missingDefinition,
  staleDefinition,
  aliasTarget,
  inheritedTarget,
  unsafeStructure,
  tooLarge,
  unsupportedEdit,
}

/// Group types supported for complete GUI round-tripping; other direct values remain
/// available through management.
const guiStrategyGroupTypes = {
  'select',
  'url-test',
  'fallback',
  'load-balance',
};

/// Stable error code mapped through the existing application message flow.
class LocalYamlEditException implements Exception {
  const LocalYamlEditException(this.code, [this.path = const []]);

  final LocalYamlEditError code;
  final List<Object> path;

  @override
  String toString() => 'LocalYamlEditException(${code.name})';
}

/// Transient identity from the exact original local body. Callers validate storage ID,
/// revision and epoch before using its path.
class LocalYamlDefinition {
  LocalYamlDefinition._(this.section, List<Object> path, this.value, this._body)
    : path = List.unmodifiable(path);

  final LocalYamlSection section;
  final List<Object> path;

  /// The exact name, or native rule string for [LocalYamlSection.rules].
  final String value;
  final String _body;
}

/// Pure immutable edits return a new local YAML body. Core parsing handles references
/// and protocol semantics during loading.
class LocalYamlEdit {
  LocalYamlEdit(this.body, {bool initializeEmpty = false}) {
    _checkBytes(body);
    final content = body.startsWith(_bom) ? body.substring(1) : body;
    _source = content.isEmpty && initializeEmpty ? '{}' : content;
    _normalized = _source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    _root = _parse(_normalized);
    final visited = HashSet<YamlNode>.identity();
    void collect(YamlNode node) {
      if (!visited.add(node)) {
        _shared.add(node);
      } else if (node is YamlMap) {
        for (final entry in node.nodes.entries) {
          collect(entry.key as YamlNode);
          collect(entry.value);
        }
      } else if (node is YamlList) {
        node.nodes.forEach(collect);
      }
    }

    collect(_root);
  }

  static const maxBytes = maxConfigBytes;
  // Bound both actual nesting and alias-expanded work before YamlEditor walks
  // the tree. Scalar length is governed separately by the UTF-8 body budget.
  static const _maxDepth = 64;
  static const _maxNodes = 200000;
  static const _bom = '\u{feff}';

  final String body;
  late final String _source;
  late final String _normalized;
  late final YamlMap _root;
  final _shared = HashSet<YamlNode>.identity();

  String addProxy(Map<String, Object?> definition) =>
      _addNamed(LocalYamlSection.proxies, definition);

  String addStrategyGroup(Map<String, Object?> definition) =>
      _addNamed(LocalYamlSection.strategyGroups, definition);

  String addProxyProvider(String name, Map<String, Object?> definition) =>
      _addProvider(LocalYamlSection.proxyProviders, name, definition);

  String addRuleProvider(String name, Map<String, Object?> definition) =>
      _addProvider(LocalYamlSection.ruleProviders, name, definition);

  /// Preserve native rule strings, duplicate positions, MATCH order and targets.
  String addRule(String rule) {
    final section = LocalYamlSection.rules;
    final list = _list(section);
    return _edit(
      [section.key],
      (editor) {
        if (list == null) {
          editor.update([section.key], [rule]);
        } else {
          editor.insertIntoList([section.key], 0, rule);
        }
      },
      insertBesideAlias: list == null
          ? null
          : () => _insertBesideAlias(list, rule, [section.key]),
    );
  }

  /// Enumerate direct definitions physically present in this body.
  List<LocalYamlDefinition> definitions(LocalYamlSection section) {
    final result = <LocalYamlDefinition>[];
    if (section == LocalYamlSection.proxyProviders ||
        section == LocalYamlSection.ruleProviders) {
      final map = _providers(section);
      if (map == null) return const [];
      for (final key in map.nodes.keys.cast<YamlNode>()) {
        if (_isMergeKey(key)) continue;
        final name = key.value as String;
        result.add(
          LocalYamlDefinition._(section, [section.key, name], name, body),
        );
      }
    } else {
      final list = section == LocalYamlSection.rules
          ? _list(section)
          : _namedList(section);
      if (list == null) return const [];
      for (var i = 0; i < list.length; i++) {
        final value = list[i];
        final name = section == LocalYamlSection.rules
            ? value as String
            : (value as YamlMap)['name'] as String;
        result.add(
          LocalYamlDefinition._(section, [section.key, i], name, body),
        );
      }
    }
    return List.unmodifiable(result);
  }

  /// The direct definition with this exact name, or null. Names are unique
  /// inside a named list, so this identity is unambiguous for that body.
  LocalYamlDefinition? definitionNamed(LocalYamlSection section, String name) =>
      definitions(section).where((item) => item.value == name).firstOrNull;

  /// Remove exactly one direct definition; duplicate rules retain index-specific
  /// identities and references remain unchanged.
  String remove(LocalYamlDefinition definition) {
    if (definition._body != body) {
      throw LocalYamlEditException(
        LocalYamlEditError.staleDefinition,
        definition.path,
      );
    }
    // Definitions have immutable validated paths; the exact body is their identity.
    return _edit(
      definition.path,
      (editor) => editor.remove(definition.path),
      removeBesideAlias: () => _removeBesideAlias(definition),
    );
  }

  /// Insertion-ordered original field values.
  Map<String, Object?> definitionValue(LocalYamlDefinition definition) {
    final node = _directNode(definition);
    final value = _plain(node);
    if (value is! Map<String, Object?>) {
      throw LocalYamlEditException(LocalYamlEditError.invalidStructure, [
        definition.section.key,
        definition.path.last,
      ]);
    }
    return value;
  }

  /// Exact source of a direct field, relative to this definition. Missing fields
  /// return null; explicit null and empty containers retain their written spelling.
  /// Parser offsets refer to the normalized view, so map both boundaries back to
  /// the original body rather than serializing the parsed value.
  String? definitionOriginalValue(
    LocalYamlDefinition definition,
    List<Object> path,
  ) {
    var node = _directNode(definition);
    for (final part in path) {
      final YamlNode? child;
      if (node is YamlMap) {
        child = node.nodes[part];
      } else if (node is YamlList &&
          part is int &&
          part >= 0 &&
          part < node.length) {
        child = node.nodes[part];
      } else {
        return null;
      }
      if (child == null) return null;
      node = child;
    }
    var end = _originalOffset(node.span.end.offset);
    if (node is YamlScalar &&
        (node.style == ScalarStyle.LITERAL ||
            node.style == ScalarStyle.FOLDED) &&
        end < _source.length) {
      // Block-scalar spans end before the last content line's physical break.
      if (_source.codeUnitAt(end) == 13) {
        end++;
        if (end < _source.length && _source.codeUnitAt(end) == 10) end++;
      } else if (_source.codeUnitAt(end) == 10) {
        end++;
      }
    }
    return _source.substring(_originalOffset(node.span.start.offset), end);
  }

  /// Replace one direct named definition at its original position, preserving adjacent
  /// entries and comments. The caller supplies original fields plus intended edits.
  String replaceNamed(
    LocalYamlDefinition definition,
    Map<String, Object?> definitionValue,
  ) {
    final section = definition.section;
    if (section != LocalYamlSection.proxies &&
        section != LocalYamlSection.strategyGroups) {
      throw LocalYamlEditException(
        LocalYamlEditError.unsupportedEdit,
        definition.path,
      );
    }
    final target = _directNode(definition) as YamlMap;
    _checkValue(definitionValue);
    final name = definitionValue['name'];
    if (name is! String || name.isEmpty) {
      throw LocalYamlEditException(LocalYamlEditError.invalidStructure, [
        section.key,
        'name',
      ]);
    }
    final current = definitions(section);
    if (current.any(
      (item) => item.value == name && item.path.last != definition.path.last,
    )) {
      throw LocalYamlEditException(LocalYamlEditError.duplicateName, [
        section.key,
        name,
      ]);
    }
    // Only changed direct fields go through yaml_edit. Replacing the whole map
    // would serialize untouched values and erase their comments/scalar styles.
    // Each candidate remains local until all edits and budget checks succeed.
    final original = _plain(target) as Map<String, Object?>;
    return _replaceFields(definition.path, original, definitionValue);
  }

  String _replaceFields(
    List<Object> base,
    Map<String, Object?> original,
    Map<String, Object?> replacement,
  ) {
    var result = body;
    for (final key in original.keys) {
      if (replacement.containsKey(key)) continue;
      final path = [...base, key];
      result = LocalYamlEdit(result)
          ._edit(path, (editor) => editor.remove(path));
    }
    for (final entry in replacement.entries) {
      final old = original[entry.key];
      if (original.containsKey(entry.key) && _sameValue(old, entry.value)) {
        continue;
      }
      final path = [...base, entry.key];
      if (old is Map<String, Object?> && entry.value is Map<String, Object?>) {
        result = LocalYamlEdit(result)
            ._replaceFields(path, old, entry.value as Map<String, Object?>);
      } else {
        result = LocalYamlEdit(result)
            ._edit(path, (editor) => editor.update(path, entry.value));
      }
    }
    return result;
  }

  /// Rename a provider through its public scalar span to retain mapping position,
  /// comments and untouched nested fields.
  String replaceProvider(
    LocalYamlDefinition definition,
    String name,
    Map<String, Object?> value,
  ) {
    final section = definition.section;
    if (section != LocalYamlSection.proxyProviders &&
        section != LocalYamlSection.ruleProviders) {
      throw LocalYamlEditException(
        LocalYamlEditError.unsupportedEdit,
        definition.path,
      );
    }
    final original = definitionValue(definition);
    _checkValue(value);
    if (name.isEmpty) {
      throw LocalYamlEditException(
        LocalYamlEditError.invalidStructure,
        definition.path,
      );
    }
    if (name == definition.value) {
      return _replaceFields(definition.path, original, value);
    }
    final providers = _providers(section)!;
    if (providers.containsKey(name)) {
      throw LocalYamlEditException(LocalYamlEditError.duplicateName, [
        section.key,
        name,
      ]);
    }
    _rejectInherited(providers, name, [section.key, name]);
    final key = providers.nodes.keys.cast<YamlNode>().singleWhere(
      (key) => key.value == definition.value,
    );
    if (_shared.contains(key)) {
      throw LocalYamlEditException(
        LocalYamlEditError.aliasTarget,
        definition.path,
      );
    }
    final escape = String.fromCharCode(0x5c);
    final encoded = jsonEncode(name)
        .replaceAll(String.fromCharCode(0x2028), '${escape}u2028')
        .replaceAll(String.fromCharCode(0x2029), '${escape}u2029');
    final renamed = _applyEdit(
      SourceEdit(key.span.start.offset, key.span.length, encoded),
    );
    return LocalYamlEdit(renamed)
        ._replaceFields([section.key, name], original, value);
  }

  String replaceRule(LocalYamlDefinition definition, String rule) {
    if (definition.section != LocalYamlSection.rules) {
      throw LocalYamlEditException(
        LocalYamlEditError.unsupportedEdit,
        definition.path,
      );
    }
    _directNode(definition);
    return rule == definition.value
        ? body
        : _edit(
            definition.path,
            (editor) => editor.update(definition.path, rule),
          );
  }

  static bool _sameValue(Object? left, Object? right) {
    if (identical(left, right)) return true;
    if (left is Map && right is Map) {
      return left.length == right.length &&
          left.keys.every(
            (key) =>
                right.containsKey(key) && _sameValue(left[key], right[key]),
          );
    }
    if (left is List && right is List) {
      if (left.length != right.length) return false;
      for (var index = 0; index < left.length; index++) {
        if (!_sameValue(left[index], right[index])) return false;
      }
      return true;
    }
    return left.runtimeType == right.runtimeType && left == right;
  }

  YamlNode _directNode(LocalYamlDefinition definition) {
    final section = definition.section;
    if (definition._body != body) {
      throw LocalYamlEditException(
        LocalYamlEditError.staleDefinition,
        definition.path,
      );
    }
    final YamlNode node;
    if (section == LocalYamlSection.proxyProviders ||
        section == LocalYamlSection.ruleProviders) {
      final map = _providers(section)!;
      if (_shared.contains(map)) {
        throw LocalYamlEditException(
          LocalYamlEditError.aliasTarget,
          definition.path,
        );
      }
      node = map.nodes[definition.path.last]!;
    } else {
      final list = section == LocalYamlSection.rules
          ? _list(section)!
          : _namedList(section)!;
      node = list.nodes[definition.path.last as int];
    }
    // Require physically written direct fields for editing; shared alias and
    // merge-backed targets retain their original text.
    if (_shared.contains(node)) {
      throw LocalYamlEditException(
        LocalYamlEditError.aliasTarget,
        definition.path,
      );
    }
    if (node is YamlMap &&
        node.nodes.keys.any((key) => _isMergeKey(key as YamlNode))) {
      throw LocalYamlEditException(
        LocalYamlEditError.inheritedTarget,
        definition.path,
      );
    }
    if (_hasSharedChild(node)) {
      throw LocalYamlEditException(
        LocalYamlEditError.aliasTarget,
        definition.path,
      );
    }
    return node;
  }

  static Object? _plain(YamlNode node) {
    if (node is YamlMap) {
      final result = <String, Object?>{};
      for (final entry in node.nodes.entries) {
        final key = (entry.key as YamlNode).value;
        if (key is! String) {
          throw const LocalYamlEditException(
            LocalYamlEditError.invalidStructure,
          );
        }
        result[key] = _plain(entry.value);
      }
      return result;
    }
    if (node is YamlList) {
      return <Object?>[for (final child in node.nodes) _plain(child)];
    }
    return node.value;
  }

  String _addNamed(LocalYamlSection section, Map<String, Object?> definition) {
    _checkValue(definition);
    final name = definition['name'];
    if (name is! String || name.isEmpty) {
      throw LocalYamlEditException(LocalYamlEditError.invalidStructure, [
        section.key,
        'name',
      ]);
    }
    final list = _namedList(section);
    if (list != null && list.any((item) => item['name'] == name)) {
      throw LocalYamlEditException(LocalYamlEditError.duplicateName, [
        section.key,
        name,
      ]);
    }
    return _edit(
      [section.key],
      (editor) {
        if (list == null) {
          editor.update([section.key], [definition]);
        } else {
          editor.insertIntoList([section.key], 0, definition);
        }
      },
      insertBesideAlias: list == null
          ? null
          : () => _insertBesideAlias(list, definition, [section.key]),
    );
  }

  String _addProvider(
    LocalYamlSection section,
    String name,
    Map<String, Object?> definition,
  ) {
    _checkValue(definition);
    if (name.isEmpty) {
      throw LocalYamlEditException(LocalYamlEditError.invalidStructure, [
        section.key,
      ]);
    }
    final map = _providers(section);
    if (map != null) {
      if (map.containsKey(name)) {
        throw LocalYamlEditException(LocalYamlEditError.duplicateName, [
          section.key,
          name,
        ]);
      }
      _rejectInherited(map, name, [section.key, name]);
    }
    return _edit(
      [section.key, name],
      (editor) {
        final key = _providerKey(name);
        if (map == null) {
          editor.update([section.key], {key: definition});
        } else {
          editor.update([section.key, key], definition);
        }
      },
      insertBesideAlias: map == null
          ? null
          : () => _insertBesideAlias(map, definition, [
              section.key,
              name,
            ], key: name),
    );
  }

  YamlNode? _section(LocalYamlSection section) {
    final node = _root.nodes[section.key];
    if (node == null) _rejectInherited(_root, section.key, [section.key]);
    return node;
  }

  YamlList? _list(LocalYamlSection section) {
    final node = _section(section);
    if (node == null) return null;
    if (node is! YamlList) {
      throw LocalYamlEditException(LocalYamlEditError.invalidStructure, [
        section.key,
      ]);
    }
    if (section == LocalYamlSection.rules &&
        node.any((rule) => rule is! String)) {
      throw LocalYamlEditException(LocalYamlEditError.invalidStructure, [
        section.key,
      ]);
    }
    return node;
  }

  YamlList? _namedList(LocalYamlSection section) {
    final list = _list(section);
    if (list == null) return null;
    final names = <String>{};
    for (var i = 0; i < list.length; i++) {
      final item = list[i];
      final path = <Object>[section.key, i, 'name'];
      if (item is! YamlMap) {
        throw LocalYamlEditException(LocalYamlEditError.invalidStructure, path);
      }
      if (!item.containsKey('name')) _rejectInherited(item, 'name', path);
      final name = item['name'];
      if (name is! String || name.isEmpty) {
        throw LocalYamlEditException(LocalYamlEditError.invalidStructure, path);
      }
      if (!names.add(name)) {
        throw LocalYamlEditException(LocalYamlEditError.duplicateName, path);
      }
    }
    return list;
  }

  YamlMap? _providers(LocalYamlSection section) {
    final node = _section(section);
    if (node == null) return null;
    if (node is! YamlMap) {
      throw LocalYamlEditException(LocalYamlEditError.invalidStructure, [
        section.key,
      ]);
    }
    for (final key in node.nodes.keys.cast<YamlNode>()) {
      if (_isMergeKey(key)) continue;
      if (key.value == '' || node.nodes[key] is! YamlMap) {
        throw LocalYamlEditException(LocalYamlEditError.invalidStructure, [
          section.key,
          key.value as String,
        ]);
      }
    }
    return node;
  }

  static Object _providerKey(String name) => name == '<<'
      ? wrapAsYamlNode(name, scalarStyle: ScalarStyle.DOUBLE_QUOTED)
      : name;

  static bool _isMergeKey(YamlNode key) =>
      key is YamlScalar && key.style == ScalarStyle.PLAIN && key.value == '<<';

  /// Inspect only the requested key's merge contributions.
  static void _rejectInherited(YamlMap map, String key, List<Object> path) {
    for (final entry in map.nodes.entries) {
      if (!_isMergeKey(entry.key as YamlNode)) continue;
      final merge = entry.value;
      final sources = merge is YamlList ? merge.nodes : [merge];
      for (final source in sources) {
        if (source is! YamlMap) {
          throw LocalYamlEditException(
            LocalYamlEditError.inheritedTarget,
            path,
          );
        }
        if (source.containsKey(key)) {
          throw LocalYamlEditException(
            LocalYamlEditError.inheritedTarget,
            path,
          );
        }
        _rejectInherited(source, key, path);
      }
    }
  }

  String _edit(
    List<Object> path,
    void Function(YamlEditor) operation, {
    SourceEdit Function()? insertBesideAlias,
    SourceEdit Function()? removeBesideAlias,
  }) {
    try {
      final editor = YamlEditor(_normalized);
      SourceEdit edit;
      try {
        operation(editor);
        edit = editor.edits.single;
      } on AliasException {
        if (insertBesideAlias == null) rethrow;
        edit = insertBesideAlias();
      } on AssertionError {
        final projection = insertBesideAlias ?? removeBesideAlias;
        if (projection == null) rethrow;
        edit = projection();
      } on ArgumentError {
        final projection = insertBesideAlias ?? removeBesideAlias;
        if (projection == null) rethrow;
        edit = projection();
      }
      // Each operation is a single target-path insert/remove. Only the package's
      // replacement is adapted; untouched original bytes and mixed endings stay
      // intact. The normalized editor view avoids CRLF offset/deletion quirks.
      return _applyEdit(_nativeCompatibleEdit(edit));
    } on AliasException {
      throw LocalYamlEditException(LocalYamlEditError.aliasTarget, path);
    } on YamlException {
      throw LocalYamlEditException(LocalYamlEditError.unsupportedEdit, path);
    } on ArgumentError {
      throw LocalYamlEditException(LocalYamlEditError.unsupportedEdit, path);
    } on AssertionError {
      // Convert yaml_edit assertions to a stable application error code, preserving
      // the original body.
      throw LocalYamlEditException(LocalYamlEditError.unsupportedEdit, path);
    } on StackOverflowError {
      throw LocalYamlEditException(LocalYamlEditError.unsafeStructure, path);
    }
  }

  String _applyEdit(SourceEdit edit) {
    final replacement = edit.replacement.replaceAll('\n', _newline);
    final start = _originalOffset(edit.offset);
    final end = _originalOffset(edit.offset + edit.length);
    final changed = _source.replaceRange(start, end, replacement);
    final result = '${body.startsWith(_bom) ? _bom : ''}$changed';
    _checkBytes(result);
    _parse(changed);
    return result;
  }

  /// Adapt scanner differences only within newly created scalar spans identified by the
  /// public parser.
  SourceEdit _nativeCompatibleEdit(SourceEdit edit) {
    if (!edit.replacement.contains(r'\/') &&
        !edit.replacement.contains('?') &&
        !edit.replacement.contains(':')) {
      return edit;
    }
    final candidate = edit.apply(_normalized);
    final root = _parse(candidate);
    final visited = HashSet<YamlNode>.identity();
    final changes = <SourceEdit>[];
    final slashEscape = RegExp(r'(?<!\\)(?:\\\\)*\\/');
    void visit(YamlNode node, {bool inFlow = false}) {
      if (!visited.add(node)) return;
      if (node is YamlMap) {
        final flow = inFlow || node.style == CollectionStyle.FLOW;
        for (final entry in node.nodes.entries) {
          visit(entry.key as YamlNode, inFlow: flow);
          visit(entry.value, inFlow: flow);
        }
      } else if (node is YamlList) {
        final flow = inFlow || node.style == CollectionStyle.FLOW;
        for (final child in node.nodes) {
          visit(child, inFlow: flow);
        }
      } else if (node is YamlScalar &&
          node.value is String &&
          node.span.start.offset >= edit.offset &&
          node.span.end.offset <= edit.offset + edit.replacement.length) {
        final before = node.span.text;
        var after = before;
        if (inFlow &&
            node.style == ScalarStyle.PLAIN &&
            ((node.value as String).contains('?') ||
                (node.value as String).startsWith(':'))) {
          // Dart accepts these flow-plain strings; the fixed native scanner
          // rejects them. Serialize only this new scalar with the public API.
          final scalar = YamlEditor('null')
            ..update(
              [],
              wrapAsYamlNode(
                node.value,
                scalarStyle: ScalarStyle.DOUBLE_QUOTED,
              ),
            );
          after = scalar.edits.single.replacement;
        } else if (node.style != ScalarStyle.DOUBLE_QUOTED) {
          return;
        }
        after = after.replaceAllMapped(slashEscape, (match) {
          // yaml_edit emits JSON's optional slash escape. Remove only the final
          // backslash of an odd run; preceding pairs encode literal backslashes.
          final escaped = match.group(0)!;
          return '${escaped.substring(0, escaped.length - 2)}/';
        });
        if (after == before) return;
        if (loadYamlNode(after).value != node.value) {
          throw const LocalYamlEditException(
            LocalYamlEditError.unsupportedEdit,
          );
        }
        changes.add(
          SourceEdit(
            node.span.start.offset - edit.offset,
            before.length,
            after,
          ),
        );
      }
    }

    visit(root);
    changes.sort((a, b) => b.offset.compareTo(a.offset));
    var replacement = edit.replacement;
    for (final change in changes) {
      replacement = change.apply(replacement);
    }
    return SourceEdit(edit.offset, edit.length, replacement);
  }

  /// If an unrelated sibling alias blocks insertion, serialize the new entry in a
  /// separate public YamlEditor and insert at the public collection boundary. Preserve
  /// existing values; require an independently owned target collection.
  SourceEdit _insertBesideAlias(
    YamlNode collection,
    Object? value,
    List<Object> path, {
    String? key,
  }) {
    if (_shared.contains(collection)) {
      throw LocalYamlEditException(LocalYamlEditError.aliasTarget, path);
    }
    if (!_hasSharedChild(collection)) {
      throw LocalYamlEditException(LocalYamlEditError.unsupportedEdit, path);
    }
    final entryEditor = YamlEditor(key == null ? '[]' : '{}');
    if (key == null) {
      entryEditor.insertIntoList([], 0, value);
    } else {
      entryEditor.update([_providerKey(key)], value);
    }
    final entry = entryEditor.edits.single.replacement;
    SourceEdit checked(SourceEdit edit) {
      edit = _nativeCompatibleEdit(edit);
      final candidate = edit.apply(_normalized);
      _checkBytes('${body.startsWith(_bom) ? _bom : ''}$candidate');
      final actual = _parse(candidate).nodes[path.first];
      if (collection is YamlMap) {
        if (actual is! YamlMap ||
            actual.length != collection.length + 1 ||
            !actual.containsKey(key)) {
          throw LocalYamlEditException(
            LocalYamlEditError.unsupportedEdit,
            path,
          );
        }
      } else {
        if (actual is! YamlList ||
            actual.length != (collection as YamlList).length + 1 ||
            (value is String && actual.first != value) ||
            (value is Map &&
                (actual.first is! YamlMap ||
                    actual.first['name'] != value['name']))) {
          throw LocalYamlEditException(
            LocalYamlEditError.unsupportedEdit,
            path,
          );
        }
      }
      return edit;
    }

    if (collection is YamlMap) {
      final end = collection.span.end.offset;
      if (collection.style == CollectionStyle.FLOW) {
        if (_normalized.codeUnitAt(end - 1) != 125) {
          throw LocalYamlEditException(
            LocalYamlEditError.unsupportedEdit,
            path,
          );
        }
        return checked(
          SourceEdit(end - 1, 0, '${collection.isEmpty ? '' : ', '}$entry'),
        );
      }
      // A root block mapping ends at the next root token or EOF; preserve surrounding
      // comments, spacing and line endings.
      if (end < _normalized.length && collection.span.end.column != 0) {
        throw LocalYamlEditException(LocalYamlEditError.unsupportedEdit, path);
      }
      final firstKey = collection.nodes.keys.first as YamlNode;
      final startColumn = collection.span.start.column;
      final int indent;
      if (_shared.contains(firstKey)) {
        // Use this mapping's physical indicator column when the alias key span refers
        // to its anchor.
        if (_normalized.codeUnitAt(collection.span.start.offset) == 38) {
          throw LocalYamlEditException(LocalYamlEditError.aliasTarget, path);
        }
        indent = startColumn;
      } else {
        final firstColumn = firstKey.span.start.column;
        indent = startColumn < firstColumn ? startColumn : firstColumn;
      }
      final separator = end > 0 && _normalized.codeUnitAt(end - 1) != 10
          ? '\n'
          : '';
      return checked(SourceEdit(end, 0, '$separator${' ' * indent}$entry\n'));
    }
    final list = collection as YamlList;
    final start = list.span.start.offset;
    if (list.style == CollectionStyle.FLOW) {
      if (_normalized.codeUnitAt(start) != 91) {
        throw LocalYamlEditException(LocalYamlEditError.aliasTarget, path);
      }
      return checked(
        SourceEdit(start + 1, 0, '$entry${list.isEmpty ? '' : ', '}'),
      );
    }
    if (_normalized.codeUnitAt(start) != 45) {
      // Use public parser spans to locate sequence indicators following anchor/tag
      // properties.
      throw LocalYamlEditException(LocalYamlEditError.aliasTarget, path);
    }
    final indent = list.span.start.column;
    return checked(SourceEdit(start - indent, 0, '${' ' * indent}- $entry\n'));
  }

  bool _hasSharedChild(YamlNode node) {
    if (node is YamlMap) {
      return node.nodes.entries.any(
        (entry) =>
            _shared.contains(entry.key) ||
            _shared.contains(entry.value) ||
            _hasSharedChild(entry.value),
      );
    }
    return node is YamlList &&
        node.nodes.any(
          (child) => _shared.contains(child) || _hasSharedChild(child),
        );
  }

  /// A following alias reports its anchor's span. Apply public remove to the original
  /// target beside a synthetic sibling, then project only that bounded edit.
  SourceEdit _removeBesideAlias(LocalYamlDefinition definition) {
    final path = definition.path;
    final collection = _root.nodes[definition.section.key]!;
    final YamlNode node;
    final YamlNode firstNode;
    final Object localKey;
    final String sentinel;
    if (_shared.contains(collection)) {
      throw LocalYamlEditException(LocalYamlEditError.aliasTarget, path);
    }
    if (collection is YamlList && collection.style == CollectionStyle.BLOCK) {
      if (!collection.nodes.any(_shared.contains)) {
        throw LocalYamlEditException(LocalYamlEditError.unsupportedEdit, path);
      }
      node = collection.nodes[path.last as int];
      firstNode = node;
      localKey = 0;
      sentinel = '- null';
    } else if (collection is YamlMap &&
        collection.style == CollectionStyle.BLOCK) {
      if (!collection.nodes.keys.any(_shared.contains)) {
        throw LocalYamlEditException(LocalYamlEditError.unsupportedEdit, path);
      }
      node = collection.nodes[path.last]!;
      firstNode = collection.nodes.keys.cast<YamlNode>().firstWhere(
        (key) => key.value == path.last,
      );
      localKey = path.last;
      sentinel =
          '0: null'; // A numeric key cannot collide with a provider name.
    } else {
      throw LocalYamlEditException(LocalYamlEditError.unsupportedEdit, path);
    }
    if (_shared.contains(node) || _shared.contains(firstNode)) {
      throw LocalYamlEditException(LocalYamlEditError.aliasTarget, path);
    }
    var tokenStart = firstNode.span.start.offset;
    if (collection is YamlList) {
      tokenStart = _normalized.lastIndexOf('-', tokenStart - 1);
    }
    if (tokenStart < 0) {
      throw LocalYamlEditException(LocalYamlEditError.unsupportedEdit, path);
    }
    final start = _normalized.lastIndexOf('\n', tokenStart - 1) + 1;
    var indent = 0;
    while (start + indent < tokenStart &&
        _normalized.codeUnitAt(start + indent) == 32) {
      indent++;
    }
    if (collection is YamlList && start + indent != tokenStart) {
      throw LocalYamlEditException(LocalYamlEditError.unsupportedEdit, path);
    }
    var end = node.span.end.offset;
    final endLineStart = end - node.span.end.column;
    if (_normalized.substring(endLineStart, end).trim().isEmpty) {
      end = endLineStart; // Never consume the next entry's leading indentation.
    } else {
      final newline = _normalized.indexOf('\n', end);
      end = newline == -1 ? _normalized.length : newline + 1;
    }
    // Preserve public remove's association of adjacent blank lines within the target's
    // bounded edit.
    while (end < _normalized.length) {
      final newline = _normalized.indexOf('\n', end);
      if (newline == -1 ||
          _normalized.substring(end, newline).trim().isNotEmpty) {
        break;
      }
      end = newline + 1;
    }
    if (end <= start || _normalized.codeUnitAt(end - 1) != 10) {
      throw LocalYamlEditException(LocalYamlEditError.unsupportedEdit, path);
    }
    const header = 'items:\n';
    final target = _normalized.substring(start, end);
    final isolated = YamlEditor('$header$target${' ' * indent}$sentinel\n');
    isolated.remove(['items', localKey]);
    final edit = isolated.edits.single;
    final relativeStart = edit.offset - header.length;
    if (edit.replacement.isNotEmpty ||
        relativeStart < 0 ||
        relativeStart + edit.length > target.length) {
      throw LocalYamlEditException(LocalYamlEditError.unsupportedEdit, path);
    }
    final projected = SourceEdit(start + relativeStart, edit.length, '');
    final actual = _parse(projected.apply(_normalized))
        .nodes[definition.section.key];
    if (collection is YamlList) {
      if (actual is! YamlList || actual.length != collection.length - 1) {
        throw LocalYamlEditException(LocalYamlEditError.unsupportedEdit, path);
      }
    } else if (actual is! YamlMap ||
        actual.containsKey(path.last) ||
        actual.length != (collection as YamlMap).length - 1) {
      throw LocalYamlEditException(LocalYamlEditError.unsupportedEdit, path);
    }
    return projected;
  }

  int _originalOffset(int offset) {
    var normalized = 0;
    var original = 0;
    while (normalized < offset) {
      if (_source.codeUnitAt(original) == 13 &&
          original + 1 < _source.length &&
          _source.codeUnitAt(original + 1) == 10) {
        original++;
      }
      original++;
      normalized++;
    }
    return original;
  }

  String get _newline {
    final counts = <String, int>{};
    for (final match in RegExp(r'\r\n|\r|\n').allMatches(_source)) {
      final ending = match.group(0)!;
      counts[ending] = (counts[ending] ?? 0) + 1;
    }
    var preferred = '\n';
    var maximum = 0;
    for (final entry in counts.entries) {
      if (entry.value > maximum) {
        preferred = entry.key;
        maximum = entry.value;
      }
    }
    return preferred;
  }

  static void _checkBytes(String text) {
    if (utf8.encode(text).length > maxBytes) {
      throw const LocalYamlEditException(LocalYamlEditError.tooLarge);
    }
  }

  static YamlMap _parse(String text) {
    try {
      final root = loadYamlNode(text);
      if (root is! YamlMap) {
        throw const LocalYamlEditException(LocalYamlEditError.notMapping);
      }
      _checkValue(root);
      return root;
    } on YamlException catch (error) {
      final code = error.message == 'Duplicate mapping key.'
          ? LocalYamlEditError.duplicateKey
          : error.message == 'Only expected one document.'
          ? LocalYamlEditError.multipleDocuments
          : error.message == 'Self-referential collections are not supported.'
          ? LocalYamlEditError.unsafeStructure
          : LocalYamlEditError.invalidYaml;
      throw LocalYamlEditException(code);
    } on StackOverflowError {
      throw const LocalYamlEditException(LocalYamlEditError.unsafeStructure);
    }
  }

  /// Memoized public YAML value sizes bound alias-DAG work; active identities detect
  /// caller-built cycles.
  static void _checkValue(Object? value) {
    final active = HashSet<Object>.identity();
    final sizes = HashMap<Object, ({int nodes, int height})>.identity();
    ({int nodes, int height}) visit(Object? value, int depth) {
      if (depth > _maxDepth) {
        throw const LocalYamlEditException(LocalYamlEditError.unsafeStructure);
      }
      if (value is YamlScalar) return visit(value.value, depth);
      if (value == null || value is String || value is num || value is bool) {
        return (nodes: 1, height: 0);
      }
      if (value is! Map && value is! List) {
        throw const LocalYamlEditException(LocalYamlEditError.invalidStructure);
      }
      final previous = sizes[value];
      if (previous != null) {
        if (depth + previous.height > _maxDepth) {
          throw const LocalYamlEditException(
            LocalYamlEditError.unsafeStructure,
          );
        }
        return previous;
      }
      if (!active.add(value)) {
        throw const LocalYamlEditException(LocalYamlEditError.unsafeStructure);
      }
      var nodes = 1;
      var height = 0;
      final Iterable<Object?> children;
      if (value is Map) {
        if (value.keys.any((key) => key is! String)) {
          throw const LocalYamlEditException(
            LocalYamlEditError.invalidStructure,
          );
        }
        nodes += value.length;
        children = value.values.cast<Object?>();
      } else {
        children = (value as List).cast<Object?>();
      }
      for (final child in children) {
        final size = visit(child, depth + 1);
        nodes += size.nodes;
        if (size.height + 1 > height) height = size.height + 1;
        if (nodes > _maxNodes) {
          throw const LocalYamlEditException(
            LocalYamlEditError.unsafeStructure,
          );
        }
      }
      active.remove(value);
      return sizes[value] = (nodes: nodes, height: height);
    }

    visit(value, 0);
  }
}
