enum ContributorKind { config, plugin }

/// Identity and display metadata from one loaded composition input. Role describes the
/// source; storage identity controls writing.
class SourceContribution {
  const SourceContribution._({
    required this.kind,
    required this.id,
    required this.revision,
    required this.name,
    required this.role,
    required this.path,
  });

  final ContributorKind kind;
  final String? id;
  final int? revision;
  final String? name;
  final String? role;
  final String path;

  bool get isLocalCustom =>
      kind == ContributorKind.plugin && role == 'localCustom';

  factory SourceContribution.fromMap(Map<String, dynamic> value) {
    if (value.keys.any(
      (key) => !const {
        'kind',
        'id',
        'revision',
        'name',
        'role',
        'path',
      }.contains(key),
    )) {
      throw const FormatException('Unexpected provenance contribution field');
    }
    final kind = switch (value['kind']) {
      'config' => ContributorKind.config,
      'plugin' => ContributorKind.plugin,
      _ => throw const FormatException('Unknown provenance kind'),
    };
    final id = value['id'];
    final revision = value['revision'];
    final name = value['name'];
    final role = value['role'];
    final path = value['path'];
    if ((id != null && (id is! String || id.isEmpty)) ||
        (revision != null && (revision is! int || revision < 1)) ||
        (name != null && (name is! String || name.trim().isEmpty)) ||
        (role != null && role != 'localCustom') ||
        (kind == ContributorKind.config && role != null) ||
        ((id == null) != (revision == null)) ||
        (id == null && name != null) ||
        (kind == ContributorKind.plugin &&
            (id == null || revision == null || name == null)) ||
        path is! String ||
        !_definitionPath(path)) {
      throw const FormatException('Invalid provenance contribution');
    }
    return SourceContribution._(
      kind: kind,
      id: id as String?,
      revision: revision as int?,
      name: name as String?,
      role: role as String?,
      path: path,
    );
  }

  static bool _definitionPath(String path) {
    if (!path.startsWith('/') || RegExp(r'~(?![01])').hasMatch(path)) {
      return false;
    }
    final parts = path
        .substring(1)
        .split('/')
        .map((part) => part.replaceAll('~1', '/').replaceAll('~0', '~'))
        .toList(growable: false);
    bool index(String value) {
      final parsed = int.tryParse(value);
      return parsed != null && parsed >= 0 && parsed.toString() == value;
    }

    return switch (parts) {
      ['proxies' || 'proxy-groups' || 'rules', final position] => index(
        position,
      ),
      ['proxy-providers' || 'rule-providers', _] => true,
      ['sub-rules', final scope, final position] =>
        scope.isNotEmpty && index(position),
      _ => false,
    };
  }

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    if (id != null) 'id': id,
    if (revision != null) 'revision': revision,
    if (name != null) 'name': name,
    if (role != null) 'role': role,
    'path': path,
  };
}

/// Minimal contributor projection in actual composition order.
class DefinitionProvenance {
  DefinitionProvenance._(List<SourceContribution> contributors)
    : contributors = List.unmodifiable(contributors);

  final List<SourceContribution> contributors;

  Iterable<SourceContribution> get plugins =>
      contributors.where((source) => source.kind == ContributorKind.plugin);

  static DefinitionProvenance? fromValue(Object? value, {String? section}) {
    if (value == null) return null;
    if (value is! Map ||
        value.keys.any((key) => key != 'contributors') ||
        value['contributors'] is! List ||
        (value['contributors'] as List).isEmpty) {
      throw const FormatException('Invalid definition provenance');
    }
    final contributors = <SourceContribution>[];
    final identities = <(ContributorKind, String?)>{};
    final raw = value['contributors'] as List;
    for (var index = 0; index < raw.length; index++) {
      final item = raw[index];
      if (item is! Map || item.keys.any((key) => key is! String)) {
        throw const FormatException('Invalid provenance contributor');
      }
      final source = SourceContribution.fromMap(
        Map<String, dynamic>.from(item),
      );
      if ((section != null && source.path.split('/')[1] != section) ||
          !identities.add((source.kind, source.id)) ||
          (source.kind == ContributorKind.config && index != raw.length - 1)) {
        throw const FormatException('Invalid provenance contributor order');
      }
      contributors.add(source);
    }
    return DefinitionProvenance._(contributors);
  }

  Map<String, Object?> toJson() => {
    'contributors': [for (final source in contributors) source.toJson()],
  };
}
