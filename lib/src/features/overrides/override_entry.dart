import '../../l10n/messages.dart';
import '../configs/config_entry.dart';
import '../configs/config_text.dart';

enum OverrideMode { prepend, replace }

enum OverrideRole { localCustom }

class OverrideEntry {
  const OverrideEntry({
    required this.id,
    required this.name,
    required this.kind,
    required this.revision,
    required this.body,
    this.source,
    this.role,
    this.proxyName = '',
    this.addNoResolve = false,
    this.enabled = false,
    this.mode = OverrideMode.prepend,
    this.updatedAt,
    AppMessage? error,
    this.update = const UpdatePolicy(),
  }) : errorMessage = error;

  final String id;
  final String name;
  final ConfigKind kind;
  final int revision;
  final String body;
  final String? source;
  final OverrideRole? role;
  final String proxyName;
  final bool addNoResolve;
  final bool enabled;
  final OverrideMode mode;
  final DateTime? updatedAt;
  final AppMessage? errorMessage;
  String? get error => errorMessage?.text;
  final UpdatePolicy update;

  bool get remote => kind == ConfigKind.remote;

  /// The identity captured for a remote download, including both conversion
  /// options even when the resulting YAML happens to be unchanged.
  bool sameDownloadInput(OverrideEntry other) =>
      remote &&
      other.remote &&
      id == other.id &&
      source == other.source &&
      revision == other.revision &&
      proxyName == other.proxyName &&
      addNoResolve == other.addNoResolve;

  factory OverrideEntry.fromJson(Map<String, dynamic> value) {
    if (value['body'] is! String ||
        (value.containsKey('proxyName') && value['proxyName'] is! String) ||
        (value.containsKey('addNoResolve') && value['addNoResolve'] is! bool)) {
      throw const FormatException(
        'Invalid override content or conversion options',
      );
    }
    final entry = OverrideEntry(
      id: value['id'] as String,
      name: value['name'] as String,
      kind: ConfigKind.values.byName(value['kind'] as String),
      revision: value['revision'] as int,
      body: value['body'] as String,
      source: value['source'] as String?,
      role: value['role'] == null
          ? null
          : OverrideRole.values.byName(value['role'] as String),
      proxyName: value['proxyName'] as String? ?? '',
      addNoResolve: value['addNoResolve'] as bool? ?? false,
      enabled: value['enabled'] as bool,
      mode: OverrideMode.values.byName(value['mode'] as String),
      updatedAt: value['updatedAt'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(value['updatedAt'] as int),
      error: AppMessage.fromNullable(value['error']),
      update: value['update'] == null
          ? const UpdatePolicy()
          : UpdatePolicy.fromJson(
              Map<String, dynamic>.from(value['update'] as Map),
            ),
    );
    final uri = entry.source == null ? null : Uri.tryParse(entry.source!);
    if (entry.id.isEmpty ||
        !validConfigName(entry.name) ||
        entry.revision < 1 ||
        entry.revision > maxConfigRevision ||
        (entry.role != null && entry.remote) ||
        (entry.remote
            ? uri == null ||
                  !['http', 'https'].contains(uri.scheme) ||
                  uri.host.isEmpty
            : entry.source != null)) {
      throw const FormatException('Invalid override record');
    }
    checkConfigText(entry.body);
    return entry;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'revision': revision,
    'body': body,
    'source': source,
    'role': role?.name,
    'proxyName': proxyName,
    'addNoResolve': addNoResolve,
    'enabled': enabled,
    'mode': mode.name,
    'updatedAt': updatedAt?.millisecondsSinceEpoch,
    'error': errorMessage?.toMap(),
    'update': update.toJson(),
  };

  OverrideEntry withContent(String content) => OverrideEntry(
    id: id,
    name: name,
    kind: kind,
    revision: content == body ? revision : revision + 1,
    body: content,
    source: source,
    role: role,
    proxyName: proxyName,
    addNoResolve: addNoResolve,
    enabled: enabled,
    mode: mode,
    updatedAt: DateTime.now(),
    update: update,
  );

  OverrideEntry changed({
    String? name,
    String? source,
    String? proxyName,
    bool? addNoResolve,
    bool? enabled,
    OverrideMode? mode,
    AppMessage? error,
  }) => OverrideEntry(
    id: id,
    name: name ?? this.name,
    kind: kind,
    revision: revision,
    body: body,
    source: source ?? this.source,
    role: role,
    proxyName: proxyName ?? this.proxyName,
    addNoResolve: addNoResolve ?? this.addNoResolve,
    enabled: enabled ?? this.enabled,
    mode: mode ?? this.mode,
    updatedAt: updatedAt,
    error: error,
    update: update,
  );

  OverrideEntry withUpdate(UpdatePolicy policy) => OverrideEntry(
    id: id,
    name: name,
    kind: kind,
    revision: revision,
    body: body,
    source: source,
    role: role,
    proxyName: proxyName,
    addNoResolve: addNoResolve,
    enabled: enabled,
    mode: mode,
    updatedAt: updatedAt,
    error: errorMessage,
    update: policy,
  );
}
