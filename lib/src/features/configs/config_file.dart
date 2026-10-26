import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import 'config_entry.dart';
import 'config_text.dart';
import '../../l10n/messages.dart';

// Android merges type groups and ignores an unfiltered group beside filters.
// Provider MIME labels can omit YAML; validate the selected bytes instead.
Future<XFile?> selectConfigFile() => openFile();

Future<String> readConfigFile(XFile file) async {
  if (await file.length() > maxConfigBytes) {
    throw ConfigFailure(messages.textTooLargeImport);
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in file.openRead()) {
    if (bytes.length + chunk.length > maxConfigBytes) {
      throw ConfigFailure(messages.textTooLargeImport);
    }
    bytes.add(chunk);
  }
  return decodeConfigText(bytes.takeBytes());
}

String configFileName(String name) {
  final dot = name.lastIndexOf('.');
  final stem = (dot > 0 ? name.substring(0, dot) : name).trim();
  return stem.isEmpty ? localizedMessages.localConfig : configNamePrefix(stem);
}
