import '../mode/tunnel_mode.dart';
import '../strategies/strategy_choice.dart';

enum ConfigKind { remote, local }

class ConfigEntry {
  const ConfigEntry({
    required this.id,
    required this.name,
    this.kind = ConfigKind.remote,
    this.source,
    this.updatedAt,
    required this.revision,
    required this.body,
    this.error,
    this.choices = const {},
  });

  final String id;
  final String name;
  final ConfigKind kind;
  final String? source;
  final DateTime? updatedAt;
  final int revision;
  final String? body;
  final String? error;
  final Map<String, StrategyChoice> choices;

  bool get remote => kind == ConfigKind.remote;

  String get displaySource {
    if (!remote) return '本地配置';
    final uri = Uri.parse(source!);
    return '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}/…';
  }

  ConfigEntry withContent(String? content, {String? error}) => ConfigEntry(
    id: id,
    name: name,
    kind: kind,
    source: source,
    updatedAt: content == null ? updatedAt : DateTime.now(),
    revision: body == content ? revision : revision + 1,
    body: content,
    error: error,
    choices: choices,
  );

  ConfigEntry withChoice(String group, StrategyChoice choice) => ConfigEntry(
    id: id,
    name: name,
    kind: kind,
    source: source,
    updatedAt: updatedAt,
    revision: revision,
    body: body,
    error: error,
    choices: Map.unmodifiable({...choices, group: choice}),
  );

  ConfigEntry renamed(String name) => ConfigEntry(
    id: id,
    name: name,
    kind: kind,
    source: source,
    updatedAt: updatedAt,
    revision: revision,
    body: body,
    error: error,
    choices: choices,
  );

  ConfigEntry withSource(String source) => ConfigEntry(
    id: id,
    name: name,
    kind: kind,
    source: source,
    updatedAt: updatedAt,
    revision: revision,
    body: body,
    error: error,
    choices: choices,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'source': source,
    'updatedAt': updatedAt?.millisecondsSinceEpoch,
    'revision': revision,
    'body': body,
    'error': error,
    'choices': choices.map((name, choice) => MapEntry(name, choice.toJson())),
  };

  factory ConfigEntry.fromJson(Map<String, dynamic> value) {
    final entry = ConfigEntry(
      id: value['id'] as String,
      name: value['name'] as String,
      kind: ConfigKind.values.byName(value['kind'] as String),
      source: value['source'] as String?,
      updatedAt: value['updatedAt'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(value['updatedAt'] as int),
      revision: value['revision'] as int,
      body: value['body'] as String?,
      error: value['error'] as String?,
      choices: StrategyChoice.decode(value['choices']),
    );
    final uri = entry.source == null ? null : Uri.parse(entry.source!);
    if (entry.id.isEmpty ||
        entry.name.trim().isEmpty ||
        entry.revision < 1 ||
        (entry.remote
            ? uri == null ||
                  !['http', 'https'].contains(uri.scheme) ||
                  uri.host.isEmpty
            : entry.source != null)) {
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
