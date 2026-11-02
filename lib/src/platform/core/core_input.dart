import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../model/config_entry.dart';
import '../../model/config_text.dart';
import '../../model/tunnel_mode.dart';
import '../../model/override_entry.dart';
import '../../logic/overrides/override_store.dart';
import '../../model/messages.dart';
import '../../model/app_preferences.dart';
import '../../model/application_contract.dart';

const maxPreparationOptionsBytes =
    ApplicationContract.configurationPreparationOptionsBytes;
const _maxOverrideJsonBytes =
    ApplicationContract.configurationOverrideJsonBytes;

class CoreInput {
  CoreInput(this.file);
  final File file;

  static String compositionOf(
    String id,
    int revision,
    Iterable<OverrideEntry> parts,
  ) => jsonEncode([
    id,
    revision,
    for (final part in parts)
      if (part.enabled) [part.id, part.revision, part.mode.name],
  ]);

  Future<void> write(
    ConfigEntry entry,
    TunnelMode? mode, {
    TunnelMode? routingOverride,
    List<OverrideEntry> overrides = const [],
    AppPreferences preferences = const AppPreferences(),
    bool vpnIntent = true,
    bool? lanIntent,
  }) async {
    final members = overrides
        .where((entry) => entry.enabled)
        .toList(growable: false);
    if (entry.name.trim().isEmpty ||
        members.any((part) => part.name.trim().isEmpty)) {
      throw const FormatException('Missing loaded input name');
    }
    final fragments = enabledOverrides(members);
    // Capture all display metadata with the same objects as the body identity,
    // before any I/O can yield to a changed caller collection.
    final parts = [
      for (var index = 0; index < fragments.length; index++)
        {
          ...fragments[index],
          'name': members[index].name,
          'role': members[index].role?.name,
          'source': members[index].source,
        },
    ];
    final sourceMetadata = [
      entry.id,
      entry.name,
      if (entry.source != null) entry.source!,
      for (final part in members) ...[
        part.id,
        part.name,
        if (part.source != null) part.source!,
      ],
    ];
    if (sourceMetadata.any(
      (value) => value.runes.any((unit) => unit >= 0xd800 && unit <= 0xdfff),
    )) {
      throw const ConfigFailure(AppMessage('preparationMetadataInvalid'));
    }
    final composition = compositionOf(entry.id, entry.revision, members);
    // Required static fields give a lower bound before generation, purpose and network
    // are added. Reject known overflow before reconnect reaches Stop; final JSON is
    // checked after encoding.
    _checkJsonBytes(
      {
        'composition': composition,
        'routingOverride': routingOverride?.name ?? '',
        'mainOrigin': {
          'id': entry.id,
          'revision': entry.revision,
          'name': entry.name,
        },
      },
      maxPreparationOptionsBytes,
      const AppMessage('preparationOptionsTooLarge'),
    );
    _checkJsonBytes(
      parts,
      _maxOverrideJsonBytes,
      const AppMessage('preparationFragmentsTooLarge'),
    );
    await writeRecord({
      'inputId': newInputId(),
      'vpnIntent': vpnIntent,
      'lanIntent':
          lanIntent ??
          members.any((part) => part.role == OverrideRole.lanProxy),
      'id': entry.id,
      'name': entry.name,
      'revision': entry.revision,
      'source': entry.source,
      'mode': mode?.name,
      'routingOverride': routingOverride?.name,
      'body': entry.body,
      'composition': composition,
      'overrides': parts,
      'access': preferences.access.name,
      'packages': preferences.packages,
      'choices': entry.choices.map(
        (name, choice) => MapEntry(name, choice.toJson()),
      ),
    });
  }

  static String newInputId() {
    final random = Random.secure();
    return List.generate(
      4,
      (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
    ).join();
  }

  Future<void> writeRecord(Map<String, dynamic> record) async {
    final body = record['body'];
    if (record['inputId'] is! String ||
        (record['inputId'] as String).isEmpty ||
        body is! String ||
        record['overrides'] is! List) {
      throw const FormatException('装载记录缺少输入身份或正文');
    }
    checkConfigText(body);
    for (final part in record['overrides'] as List) {
      checkConfigText((part as Map)['body'] as String);
    }
    _checkJsonBytes(
      record['overrides'],
      _maxOverrideJsonBytes,
      const AppMessage('preparationFragmentsTooLarge'),
    );
    _checkJsonBytes(
      {
        'composition': record['composition'],
        'routingOverride': record['routingOverride'] ?? '',
        'mainOrigin': {
          'id': record['id'],
          'revision': record['revision'],
          'name': record['name'],
        },
      },
      maxPreparationOptionsBytes,
      const AppMessage('preparationOptionsTooLarge'),
    );
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(jsonEncode(record), flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> clear() async {
    if (await file.exists()) await file.delete();
  }
}

void _checkJsonBytes(Object? value, int maximum, AppMessage message) {
  final encoder = JsonUtf8Encoder().startChunkedConversion(
    _JsonByteLimit(maximum, message),
  );
  encoder.add(value);
  encoder.close();
}

class _JsonByteLimit implements Sink<List<int>> {
  _JsonByteLimit(this.maximum, this.message);

  final int maximum;
  final AppMessage message;
  int length = 0;

  @override
  void add(List<int> bytes) {
    length += bytes.length;
    if (length > maximum) throw ConfigFailure(message);
  }

  @override
  void close() {}
}
