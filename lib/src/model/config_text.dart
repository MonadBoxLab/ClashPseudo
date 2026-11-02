import 'dart:convert';

import 'config_entry.dart';
import 'messages.dart';
import 'application_contract.dart';

const maxConfigBytes = ApplicationContract.configurationTextBytes;
const maxConfigNameBytes = ApplicationContract.configurationNameBytes;
const _bom = '\u{feff}';

int configNameBytes(String value) => utf8.encode(value).length;

bool validConfigName(String value) =>
    value.trim().isNotEmpty && configNameBytes(value) <= maxConfigNameBytes;

String configNamePrefix(String value) {
  final prefix = StringBuffer();
  var bytes = 0;
  for (final rune in value.trim().runes) {
    final scalar = String.fromCharCode(rune);
    final length = utf8.encode(scalar).length;
    if (bytes + length > maxConfigNameBytes) break;
    prefix.write(scalar);
    bytes += length;
  }
  return prefix.toString();
}

void checkConfigText(String text) {
  if (utf8.encode(text).length > maxConfigBytes) {
    throw ConfigFailure(messages.textTooLargeSave);
  }
}

String decodeConfigText(List<int> bytes) {
  if (bytes.length > maxConfigBytes) {
    throw ConfigFailure(messages.textTooLargeSave);
  }
  final bom =
      bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf;
  try {
    final text = utf8.decode(bytes);
    return bom ? '$_bom$text' : text;
  } on FormatException catch (failure) {
    throw ConfigFailure(messages.textNotUtf8.withDetail(failure));
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
