import 'dart:convert';

import 'package:clash_pseudo/src/ui/configs/editor/config_editor_limits.dart';
import 'package:clash_pseudo/src/model/config_text.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

class _LengthProbe extends CodeLine {
  _LengthProbe() : super('valid');
  int reads = 0;

  @override
  int get length {
    reads++;
    return super.length;
  }
}

void main() {
  final exact = 'x' * maxEditorCodeUnits;
  for (final ending in ['\n', '\r', '\r\n']) {
    test(
      'raw admission counts logical lines, excluding $ending separators',
      () {
        expect(firstOversizedEditorLine('$exact$ending$exact$ending'), isNull);
        expect(firstOversizedEditorLine('a${ending}b$ending${exact}x'), 3);
        expect(firstOversizedEditorLine('${ending}x'), isNull);
      },
    );
  }

  test('32768 UTF-16 code units are accepted, 32769 are rejected', () {
    expect(firstOversizedEditorLine(exact), isNull);
    expect(firstOversizedEditorLine('${exact}x'), 1);
    expect(firstOversizedEditorLine(' ' * (maxEditorCodeUnits + 1)), 1);
    expect(firstOversizedEditorLine(''), isNull);
  });

  test('only the document model leading BOM is excluded', () {
    expect(firstOversizedEditorLine('\u{feff}$exact'), isNull);
    expect(firstOversizedEditorLine('\u{feff}\u{feff}$exact'), 1);
    expect(firstOversizedEditorLine('$exact\u{feff}'), 1);
    expect(firstOversizedEditorLine('\u{feff}a\r\n$exact\n${exact}x'), 3);
  });

  test(
    'astral characters count twice and combining marks count separately',
    () {
      final emoji = '🌐' * (maxEditorCodeUnits ~/ 2);
      final combining = 'e\u{301}' * (maxEditorCodeUnits ~/ 2);
      expect(emoji.length, maxEditorCodeUnits);
      expect(combining.length, maxEditorCodeUnits);
      for (final value in [emoji, combining]) {
        expect(firstOversizedEditorLine(value), isNull);
        expect(firstOversizedEditorLine('${value}x'), 1);
      }
    },
  );

  test('U+2028 and U+2029 are content, not extra logical separators', () {
    for (final separator in ['\u{2028}', '\u{2029}']) {
      expect(
        firstOversizedEditorLine('${'x' * (maxEditorCodeUnits - 1)}$separator'),
        isNull,
      );
      expect(firstOversizedEditorLine('$exact$separator'), 1);
      expect(firstOversizedEditorLine('$exact${separator}x'), 1);
    }
  });

  for (final bom in [false, true]) {
    test('a supported exact 16MiB body remains lossless, BOM=$bom', () {
      final bytes = maxConfigBytes - (bom ? 3 : 0);
      final unit = '$exact\n';
      final text =
          '${bom ? '\u{feff}' : ''}${unit * (bytes ~/ unit.length)}'
          '${'x' * (bytes % unit.length)}';
      expect(utf8.encode(text).length, maxConfigBytes);
      expect(firstOversizedEditorLine(text), isNull);
      checkConfigText(text);
      final document = ConfigTextDocument(text);
      expect(document.serialize(document.editable), text);
    });
  }

  test(
    'the editing limit does not leak into shared storage/import admission',
    () {
      final giantLine = 'x' * maxConfigBytes;
      expect(firstOversizedEditorLine(giantLine), 1);
      checkConfigText(giantLine);
      expect(decodeConfigText(utf8.encode(giantLine)), giantLine);
      final document = ConfigTextDocument(giantLine);
      expect(document.serialize(document.editable), giantLine);
    },
  );

  test(
    'candidate admission checks all folded descendants, including nesting',
    () {
      final previous = CodeLines.of([
        const CodeLine('header'),
        const CodeLine('tail'),
      ]);
      final candidate = CodeLines.of([
        const CodeLine('before'),
        CodeLine('header', [
          CodeLine(exact),
          CodeLine('nested', [CodeLine('${exact}x')]),
        ]),
        const CodeLine('tail'),
      ]);
      expect(firstOversizedCodeLine(candidate, previous: previous), 5);
      expect(firstOversizedCodeLine(CodeLines.of([CodeLine(exact)])), isNull);
    },
  );

  test('merging two previously valid lines cannot bypass the line limit', () {
    final half = 'x' * (maxEditorCodeUnits ~/ 2);
    final previous = CodeLines.of([CodeLine(half), CodeLine('${half}x')]);
    expect(firstOversizedCodeLine(previous), isNull);
    final candidate = CodeLines.of([CodeLine('$half${half}x')]);
    expect(firstOversizedCodeLine(candidate, previous: previous), 1);
  });

  test(
    'absolute rejection row includes unchanged segments and folded rows',
    () {
      final previous = CodeLines.of(
        List.generate(600, (_) => const CodeLine('valid')),
      );
      final candidate = CodeLines.from(previous);
      candidate[550] = CodeLine('header', [
        const CodeLine('nested'),
        CodeLine('${exact}x'),
      ]);
      expect(firstOversizedCodeLine(candidate, previous: previous), 553);
    },
  );

  test('accepted copy-on-write segments are not rescanned per keystroke', () {
    final probes = List.generate(600, (_) => _LengthProbe());
    final previous = CodeLines.of(probes);
    expect(firstOversizedCodeLine(previous), isNull);
    for (final line in probes) {
      line.reads = 0;
    }
    final candidate = CodeLines.from(previous);
    candidate[300] = const CodeLine('changed');
    expect(firstOversizedCodeLine(candidate, previous: previous), isNull);
    expect(probes.take(256).every((line) => line.reads == 0), isTrue);
    expect(probes.skip(512).every((line) => line.reads == 0), isTrue);
    expect(probes[299].reads, 1);
  });
}
