import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import 'config_entry.dart';
import 'config_text.dart';

// Android merges type groups and ignores an unfiltered group beside filters.
// Provider MIME labels can omit YAML; validate the selected bytes instead.
Future<XFile?> selectConfigFile() => openFile();

Future<String> readConfigFile(XFile file) async {
  if (await file.length() > maxConfigBytes) {
    throw const ConfigFailure('配置正文超过 16 MiB，未导入。');
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in file.openRead()) {
    if (bytes.length + chunk.length > maxConfigBytes) {
      throw const ConfigFailure('配置正文超过 16 MiB，未导入。');
    }
    bytes.add(chunk);
  }
  return decodeConfigText(bytes.takeBytes());
}

String configFileName(String name) {
  final dot = name.lastIndexOf('.');
  final stem = (dot > 0 ? name.substring(0, dot) : name).trim();
  return stem.isEmpty ? '本地配置' : String.fromCharCodes(stem.runes.take(80));
}
