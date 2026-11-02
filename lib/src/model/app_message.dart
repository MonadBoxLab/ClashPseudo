/// Application-owned message descriptor carried across storage and engines by ARB key
/// and named arguments.
class AppMessage {
  const AppMessage(this.id, {this.detail}) : args = const {};

  AppMessage.withArgs(this.id, Map<String, Object?> args, {this.detail})
    : args = Map.unmodifiable(args);

  final String id;
  final Map<String, Object?> args;
  final String? detail;

  AppMessage withDetail(Object? error) {
    final text = error?.toString();
    if (text == null || text.isEmpty || text == detail) return this;
    return AppMessage.withArgs(
      id,
      args,
      detail: detail == null ? text : '$detail\n$text',
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    if (detail != null) 'detail': detail,
    'args': {
      for (final entry in args.entries)
        entry.key: entry.value is AppMessage
            ? (entry.value! as AppMessage).toMap()
            : entry.value,
    },
  };

  static AppMessage? fromNullable(Object? value) =>
      value == null ? null : fromMap(value);

  static AppMessage fromMap(Object? value) => _decode(value, 0);

  static AppMessage _decode(Object? value, int depth) {
    if (depth > 4 || value is! Map) {
      throw const FormatException('Invalid application message');
    }
    final id = value['id'];
    final args = value['args'];
    if (id is! String || id.isEmpty || args is! Map) {
      throw const FormatException('Invalid application message');
    }
    final decoded = <String, Object?>{};
    for (final entry in args.entries) {
      if (entry.key is! String) {
        throw const FormatException('Invalid message argument');
      }
      final argument = entry.value;
      if (argument is Map) {
        decoded[entry.key as String] = _decode(argument, depth + 1);
      } else if (argument is String || argument is int || argument is bool) {
        decoded[entry.key as String] = argument;
      } else {
        throw const FormatException('Invalid message argument');
      }
    }
    final detail = value['detail'];
    if (detail != null && detail is! String) {
      throw const FormatException('Invalid message detail');
    }
    return AppMessage.withArgs(id, decoded, detail: detail as String?);
  }

  @override
  bool operator ==(Object other) =>
      other is AppMessage &&
      id == other.id &&
      detail == other.detail &&
      args.length == other.args.length &&
      args.entries.every((entry) => other.args[entry.key] == entry.value);

  @override
  int get hashCode => Object.hash(
    id,
    detail,
    Object.hashAllUnordered(
      args.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
  );

  @override
  String toString() => detail == null ? id : '$id: $detail';
}

/// Encodes only the message values in the existing MethodChannel result shape.
Object? encodeAppMessages(Object? value) => switch (value) {
  AppMessage message => message.toMap(),
  Map value => {
    for (final entry in value.entries)
      entry.key: encodeAppMessages(entry.value),
  },
  List value => value.map(encodeAppMessages).toList(),
  _ => value,
};
