import 'dart:ui' show FrameTiming;

import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import '../../support/editor_input_samples.dart';

CodeLineEditingValue _value(String text) =>
    CodeLineEditingValue(codeLines: CodeLines.fromText(text));

// Synthetic timestamps test correlation arithmetic.
FrameTiming _timing(int frame, int finish) => FrameTiming(
  vsyncStart: finish - 10,
  buildStart: finish - 9,
  buildFinish: finish - 8,
  rasterStart: finish - 7,
  rasterFinish: finish,
  rasterFinishWallTime: 900000000,
  frameNumber: frame,
);

void main() {
  for (final (caseIndex, (before, after, positions)) in [
    ('a', 'aZ', [0, 1, 0, 2]),
    ('foo\nbar', 'foo\nbaXr', [1, 2, 1, 3]),
    ('a\nb', 'a\nb\nc', [1, 1, 2, 1]),
    ('a\nb', 'ab', [0, 1, 0, 1]),
    ('🌐a', '🌐Xa', [0, 2, 0, 3]),
    ('abc', 'ac', [0, 1, 0, 1]),
    ('abc', '', [0, 0, 0, 0]),
    ('a\nb\nc', 'a\nc', [1, 0, 1, 1]),
  ].indexed) {
    test(
      'changed range retains exact UTF-16 and line boundaries: case=$caseIndex, $positions',
      () {
        final result = changedRange(
          _value(before).codeLines,
          _value(after).codeLines,
        )!;
        expect([
          result.startIndex,
          result.startOffset,
          result.endIndex,
          result.endOffset,
        ], positions);
      },
    );
  }

  test('shared segment prefix is skipped without joining the document', () {
    final before = CodeLineEditingController.fromText(
      '${'shared\n' * 1000}target',
    );
    addTearDown(before.dispose);
    final old = before.codeLines;
    before.selection = const CodeLineSelection.collapsed(
      index: 1000,
      offset: 6,
    );
    before.replaceSelection('X');
    expect(
      identical(
        old.segments.first.codeLines,
        before.codeLines.segments.first.codeLines,
      ),
      isTrue,
    );
    final range = changedRange(old, before.codeLines)!;
    expect(range.startIndex, 1000);
    expect(range.startOffset, 6);
    expect(range.endIndex, 1000);
    expect(range.endOffset, 7);
  });

  test(
    'exact frame pairing cannot use another frame or callback receipt time',
    () {
      final samples = EditorInputSamples();
      samples.input(1000, _value('a'), _value('aZ'));
      final sample = samples.samples.single;
      // Input from the paint-join boundary; real hook coverage is in
      // editor_observation_test.dart. This fixture tests only the timing join.
      sample.frame = 42;
      sample.status = 'awaiting-timing';
      samples.timings([_timing(43, 999999)]);
      expect(sample.status, 'awaiting-timing');
      samples.timings([_timing(42, 3000)]);
      expect(sample.status, 'matched');
      expect(sample.rasterFinish, 3000);
      expect(samples.summary['p95Micros'], 2000);
      expect(samples.summary['enoughSamples'], isFalse);
    },
  );

  test(
    'negative elapsed time is an explicit clock failure, never a fast sample',
    () {
      final samples = EditorInputSamples();
      samples.input(3000, _value('a'), _value('aZ'));
      final sample = samples.samples.single;
      sample.frame = 42;
      sample.status = 'awaiting-timing';
      samples.timings([_timing(42, 2000)]);
      expect(sample.status, 'clock-mismatch');
      expect(samples.summary['matchedInputs'], 0);
      expect(samples.summary['p95Micros'], isNull);
    },
  );

  test(
    'coalescing, missing paints and missing timings remain separate outcomes',
    () {
      final samples = EditorInputSamples();
      final a = _value('a');
      final b = _value('ab');
      final c = _value('abc');
      samples.input(1000, a, b);
      samples.input(2000, b, c);
      expect(samples.samples.first.status, 'coalesced');
      samples.samples.last.frame = 42;
      samples.samples.last.status = 'awaiting-timing';
      samples.input(3000, _value('other'), _value('otherZ'));
      samples.finish();
      expect(samples.summary['outcomes'], {
        'coalesced': 1,
        'missing-frame-timing': 1,
        'missing-text-paint': 1,
      });
      expect(samples.summary['p95Micros'], isNull);
    },
  );

  test('capacity is reported and disqualifies the run rather than silently sampling', () {
    final samples = EditorInputSamples(maximumSamples: 2);
    samples.input(1, _value('a'), _value('b'));
    samples.input(2, _value('a'), _value('b'));
    samples.input(3, _value('a'), _value('b'));
    expect(samples.samples, hasLength(2));
    expect(samples.summary['overflow'], 1);
    expect(samples.summary['acceptedInputs'], 3);
    expect(samples.summary['enoughSamples'], isFalse);
  });

  test('p95 is nearest rank over matched input-to-raster durations, not an average', () {
    final samples = EditorInputSamples();
    for (var index = 1; index <= 100; index++) {
      samples.input(10000, _value('a'), _value('b'));
      final sample = samples.samples.last;
      sample.frame = index;
      sample.status = 'awaiting-timing';
      samples.timings([_timing(index, 10000 + index * 1000)]);
    }
    expect(samples.summary['matchedInputs'], 100);
    expect(samples.summary['p95Micros'], 95000);
    expect(samples.summary['enoughSamples'], isTrue);
  });
}
