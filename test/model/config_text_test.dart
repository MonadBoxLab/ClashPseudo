import 'dart:convert';

import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/config_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final original in [
    '',
    ' ',
    'a\n',
    'a\r\nb\r\n',
    'a\rb\r',
    '\u{feff}中文🌐\r\n',
    'a\nb\r\nc\r',
    '\u{feff}\u{feff}a',
  ]) {
    test('unchanged text preserves exact bytes ${jsonEncode(original)}', () {
      final decoded = decodeConfigText(utf8.encode(original));
      expect(decoded, original);
      final document = ConfigTextDocument(decoded);
      expect(document.serialize(document.editable), original);
    });
  }

  test('edited text preserves BOM and CRLF', () {
    final document = ConfigTextDocument('\u{feff}a\r\nb\r\n');
    expect(document.editable, 'a\nb\n');
    expect(document.serialize('a\nc\n'), '\u{feff}a\r\nc\r\n');
    expect(document.mixed, isFalse);
  });

  test('mixed newline majority and first-seen tie are deterministic', () {
    final majority = ConfigTextDocument('a\r\nb\nc\n');
    expect(majority.mixed, isTrue);
    expect(majority.newline, '\n');
    final tie = ConfigTextDocument('a\r\nb\nc');
    expect(tie.newline, '\r\n');
    expect(tie.serialize('a\nb\nc\nd'), 'a\r\nb\r\nc\r\nd');
  });

  test('strict UTF-8 rejects malformed bytes rather than replacing them', () {
    expect(() => decodeConfigText([0xc3, 0x28]), throwsA(isA<ConfigFailure>()));
    expect(() => decodeConfigText([0xef, 0xbb]), throwsA(isA<ConfigFailure>()));
  });

  test(
    '16 MiB includes multibyte text and BOM, exact boundary is accepted',
    () {
      final boundary = '\u{feff}${'中' * ((maxConfigBytes - 4) ~/ 3)}a';
      expect(utf8.encode(boundary).length, maxConfigBytes);
      checkConfigText(boundary);
      expect(decodeConfigText(utf8.encode(boundary)), boundary);
      expect(
        () => checkConfigText('${boundary}a'),
        throwsA(isA<ConfigFailure>()),
      );
      expect(
        () => decodeConfigText(utf8.encode('${boundary}a')),
        throwsA(isA<ConfigFailure>()),
      );
    },
  );
}
