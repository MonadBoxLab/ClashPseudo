import 'dart:convert';
import 'dart:io';

import '../features/configs/config_entry.dart';
import '../features/mode/tunnel_mode.dart';
import '../features/overrides/override_entry.dart';
import '../features/overrides/override_store.dart';
import '../l10n/messages.dart';
import '../model/app_preferences.dart';
import '../model/application_contract.dart';

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
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(
        jsonEncode({
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
        }),
        flush: true,
      );
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
