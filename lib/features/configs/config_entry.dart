import '../mode/tunnel_mode.dart';
import '../strategies/strategy_choice.dart';

class ConfigEntry {
  const ConfigEntry({
    required this.id,
    required this.name,
    required this.source,
    required this.revision,
    required this.body,
    this.error,
    this.choices = const {},
  });

  final String id;
  final String name;
  final String source;
  final int revision;
  final String? body;
  final String? error;
  final Map<String, StrategyChoice> choices;

  String get displaySource {
    final uri = Uri.parse(source);
    return '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}/…';
  }

  ConfigEntry withContent(String? content, {String? error}) => ConfigEntry(
    id: id,
    name: name,
    source: source,
    revision: revision + 1,
    body: content,
    error: error,
    choices: choices,
  );

  ConfigEntry withChoice(String group, StrategyChoice choice) => ConfigEntry(
    id: id,
    name: name,
    source: source,
    revision: revision,
    body: body,
    error: error,
    choices: Map.unmodifiable({...choices, group: choice}),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'source': source,
    'revision': revision,
    'body': body,
    'error': error,
    'choices': choices.map((name, choice) => MapEntry(name, choice.toJson())),
  };

  factory ConfigEntry.fromJson(Map<String, dynamic> value) {
    final entry = ConfigEntry(
      id: value['id'] as String,
      name: value['name'] as String,
      source: value['source'] as String,
      revision: value['revision'] as int,
      body: value['body'] as String?,
      error: value['error'] as String?,
      choices: value.containsKey('choices')
          ? StrategyChoice.decode(value['choices'])
          : const {},
    );
    final uri = Uri.parse(entry.source);
    if (entry.id.isEmpty ||
        entry.name.isEmpty ||
        entry.revision < 1 ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const FormatException('Invalid configuration record');
    }
    return entry;
  }
}

class ConfigCollection {
  ConfigCollection({
    required List<ConfigEntry> entries,
    this.selectedId,
    this.mode = TunnelMode.rule,
  }) : entries = List.unmodifiable(entries);

  final List<ConfigEntry> entries;
  final String? selectedId;
  final TunnelMode mode;

  ConfigEntry? get selected => find(selectedId);

  ConfigEntry? find(String? id) {
    for (final entry in entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  ConfigCollection replace(ConfigEntry entry) => ConfigCollection(
    entries: entries.map((old) => old.id == entry.id ? entry : old).toList(),
    selectedId: selectedId,
    mode: mode,
  );
}

class ConfigFailure implements Exception {
  const ConfigFailure(this.message, {this.needsHttpConfirmation = false});

  final String message;
  final bool needsHttpConfirmation;

  @override
  String toString() => message;
}
