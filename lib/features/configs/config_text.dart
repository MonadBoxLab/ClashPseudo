import 'dart:convert';

import 'config_entry.dart';

const maxConfigBytes = 16 * 1024 * 1024;
const _bom = '\u{feff}';

void checkConfigText(String text) {
  if (utf8.encode(text).length > maxConfigBytes) {
    throw const ConfigFailure('配置正文超过 16 MiB，未保存。');
  }
}

String decodeConfigText(List<int> bytes) {
  if (bytes.length > maxConfigBytes) {
    throw const ConfigFailure('配置正文超过 16 MiB，未保存。');
  }
  final bom =
      bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf;
  try {
    final text = utf8.decode(bytes);
    return bom ? '$_bom$text' : text;
  } on FormatException {
    throw const ConfigFailure('配置正文不是有效的 UTF-8 文本。');
  }
}

class ConfigTextDocument {
  ConfigTextDocument(this.original) {
    final counts = <String, int>{};
    for (final match in RegExp(r'\r\n|\r|\n').allMatches(original)) {
      final ending = match.group(0)!;
      counts[ending] = (counts[ending] ?? 0) + 1;
    }
    mixed = counts.length > 1;
    var preferred = '\n';
    var maximum = 0;
    for (final entry in counts.entries) {
      if (entry.value > maximum) {
        maximum = entry.value;
        preferred = entry.key;
      }
    }
    newline = preferred;
  }

  final String original;
  late final bool mixed;
  late final String newline;
  bool get bom => original.startsWith(_bom);
  late final String editable = (bom ? original.substring(1) : original)
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');

  String serialize(String edited) {
    if (edited == editable) return original;
    final text = '${bom ? _bom : ''}${edited.replaceAll('\n', newline)}';
    checkConfigText(text);
    return text;
  }
}
