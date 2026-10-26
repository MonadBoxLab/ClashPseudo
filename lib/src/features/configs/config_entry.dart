import '../../l10n/messages.dart';
import '../../model/application_contract.dart';
import '../mode/tunnel_mode.dart';
import '../strategies/strategy_choice.dart';
import 'config_text.dart';

enum ConfigKind { remote, local }

// Shared with the Android command, Intent and core identity Int fields.
const maxConfigRevision = ApplicationContract.configurationRevisionMax;

/// Periodic download policy belonging to a remote target.
class UpdatePolicy {
  const UpdatePolicy({
    this.enabled = false,
    this.hours = 24,
    this.lastAttempt,
    this.lastResult,
  });

  static const intervals = [6, 12, 24];

  final bool enabled;
  final int hours;
  final DateTime? lastAttempt;
  final String? lastResult;

  factory UpdatePolicy.fromJson(Map<String, dynamic> value) {
    final policy = UpdatePolicy(
      enabled: value['enabled'] as bool,
      hours: value['hours'] as int,
      lastAttempt: value['lastAttempt'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(value['lastAttempt'] as int),
      lastResult: value['lastResult'] as String?,
    );
    if (!intervals.contains(policy.hours)) {
      throw const FormatException('Invalid update policy');
    }
    return policy;
  }

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'hours': hours,
    'lastAttempt': lastAttempt?.millisecondsSinceEpoch,
    'lastResult': lastResult,
  };

  UpdatePolicy changed({
    bool? enabled,
    int? hours,
    DateTime? lastAttempt,
    String? lastResult,
  }) => UpdatePolicy(
    enabled: enabled ?? this.enabled,
    hours: hours ?? this.hours,
    lastAttempt: lastAttempt ?? this.lastAttempt,
    lastResult: lastResult ?? this.lastResult,
  );
}

class ConfigEntry {
  const ConfigEntry({
    required this.id,
    required this.name,
    this.kind = ConfigKind.remote,
    this.source,
    this.updatedAt,
    required this.revision,
    required this.body,
    AppMessage? error,
    this.choices = const {},
    this.update = const UpdatePolicy(),
  }) : errorMessage = error;

  final String id;
  final String name;
  final ConfigKind kind;
  final String? source;
  final DateTime? updatedAt;
  final int revision;
  final String body;
  final AppMessage? errorMessage;
  String? get error => errorMessage?.text;
  final Map<String, StrategyChoice> choices;
  final UpdatePolicy update;

  bool get remote => kind == ConfigKind.remote;

  String get displaySource {
    if (!remote) return localizedMessages.localConfig;
    final uri = Uri.parse(source!);
    return '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}/…';
  }

  ConfigEntry withContent(String content, {AppMessage? error}) => ConfigEntry(
    id: id,
    name: name,
    kind: kind,
    source: source,
    updatedAt: DateTime.now(),
    revision: body == content ? revision : revision + 1,
    body: content,
    error: error,
    choices: choices,
    update: update,
  );

  ConfigEntry withChoice(String group, StrategyChoice choice) => ConfigEntry(
    id: id,
    name: name,
    kind: kind,
    source: source,
    updatedAt: updatedAt,
    revision: revision,
    body: body,
    error: errorMessage,
    choices: Map.unmodifiable({...choices, group: choice}),
    update: update,
  );

  ConfigEntry renamed(String name) => ConfigEntry(
    id: id,
    name: name,
    kind: kind,
    source: source,
    updatedAt: updatedAt,
    revision: revision,
    body: body,
    error: errorMessage,
    choices: choices,
    update: update,
  );

  ConfigEntry withSource(String source) => ConfigEntry(
    id: id,
    name: name,
    kind: kind,
    source: source,
    updatedAt: updatedAt,
    revision: revision,
    body: body,
    error: errorMessage,
    choices: choices,
    update: update,
  );

  ConfigEntry withUpdate(UpdatePolicy policy) => ConfigEntry(
    id: id,
    name: name,
    kind: kind,
    source: source,
    updatedAt: updatedAt,
    revision: revision,
    body: body,
    error: errorMessage,
    choices: choices,
    update: policy,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'source': source,
    'updatedAt': updatedAt?.millisecondsSinceEpoch,
    'revision': revision,
    'body': body,
    'error': errorMessage?.toMap(),
    'choices': choices.map((name, choice) => MapEntry(name, choice.toJson())),
    'update': update.toJson(),
  };

  factory ConfigEntry.fromJson(Map<String, dynamic> value) {
    if (value['body'] is! String) {
      throw const FormatException('Missing configuration content');
    }
    final entry = ConfigEntry(
      id: value['id'] as String,
      name: value['name'] as String,
      kind: ConfigKind.values.byName(value['kind'] as String),
      source: value['source'] as String?,
      updatedAt: value['updatedAt'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(value['updatedAt'] as int),
      revision: value['revision'] as int,
      body: value['body'] as String,
      error: AppMessage.fromNullable(value['error']),
      choices: StrategyChoice.decode(value['choices']),
      update: value['update'] == null
          ? const UpdatePolicy()
          : UpdatePolicy.fromJson(
              Map<String, dynamic>.from(value['update'] as Map),
            ),
    );
    final uri = entry.source == null ? null : Uri.parse(entry.source!);
    if (entry.id.isEmpty ||
        !validConfigName(entry.name) ||
        entry.revision < 1 ||
        entry.revision > maxConfigRevision ||
        (entry.remote
            ? uri == null ||
                  !['http', 'https'].contains(uri.scheme) ||
                  uri.host.isEmpty
            : entry.source != null)) {
      throw const FormatException('Invalid configuration record');
    }
    checkConfigText(entry.body);
    return entry;
  }
}

class ConfigCollection {
  ConfigCollection({
    required List<ConfigEntry> entries,
    this.selectedId,
    this.mode,
  }) : entries = List.unmodifiable(entries);

  final List<ConfigEntry> entries;
  final String? selectedId;
  // Saved fallback used when composed YAML omits mode.
  final TunnelMode? mode;

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
  const ConfigFailure(this.message);

  final AppMessage message;

  @override
  String toString() => message.id;
}
