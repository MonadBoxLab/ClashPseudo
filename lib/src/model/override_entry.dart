import 'messages.dart';
import 'storage_json.dart';
import 'config_entry.dart';
import 'config_text.dart';

enum OverrideMode { prepend, replace }

enum OverrideRole { localCustom, lanProxy }

const _unchangedError = Object();

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
    this.originalJson,
    this.editedFields = const {},
  }) : errorMessage = error;

  final Map<String, Object?>? originalJson;
  final Set<String> editedFields;

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
      originalJson: Map.unmodifiable(value),
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

  Map<String, Object?> toJson() =>
      preserveStorageJsonFields(originalJson, editedFields, {
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
      });

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
    originalJson: originalJson,
    editedFields: {...editedFields, 'body', 'revision', 'updatedAt', 'error'},
  );

  OverrideEntry changed({
    String? name,
    String? source,
    String? proxyName,
    bool? addNoResolve,
    bool? enabled,
    OverrideMode? mode,
    Object? error = _unchangedError,
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
    error: identical(error, _unchangedError)
        ? errorMessage
        : error as AppMessage?,
    update: update,
    originalJson: originalJson,
    editedFields: {
      ...editedFields,
      if (name != null) 'name',
      if (source != null) 'source',
      if (proxyName != null) 'proxyName',
      if (addNoResolve != null) 'addNoResolve',
      if (enabled != null) 'enabled',
      if (mode != null) 'mode',
      if (!identical(error, _unchangedError)) 'error',
    },
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
    update: UpdatePolicy.fromJson({...update.toJson(), ...policy.toJson()}),
    originalJson: originalJson,
    editedFields: {...editedFields, 'update'},
  );
}
