import 'dart:developer';
import 'dart:ui' as ui;

import 'package:clash_pseudo/src/features/configs/config_editor_limits.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import '../../support/editor_ime.dart';
import '../../support/editor_input_samples.dart';

Future<CodeLineEditingController> _show(WidgetTester tester) async {
  final controller = CodeLineEditingController.fromText('a');
  final focus = FocusNode();
  addTearDown(controller.dispose);
  addTearDown(focus.dispose);
  controller.selection = const CodeLineSelection.collapsed(index: 0, offset: 1);
  controller.acceptValue = (before, candidate) =>
      firstOversizedCodeLine(candidate.codeLines, previous: before.codeLines) ==
      null;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CodeEditor(
          controller: controller,
          focusNode: focus,
          autocompleteSymbols: false,
          chunkAnalyzer: const NonCodeChunkAnalyzer(),
        ),
      ),
    ),
  );
  focus.requestFocus();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  expect(tester.testTextInput.hasAnyClients, isTrue);
  return controller;
}

Future<void> _insert(
  WidgetTester tester,
  String text, {
  bool paint = true,
  String? remote,
}) async {
  final old = remote ?? tester.testTextInput.editingState!['text'] as String;
  await sendEditorDeltas(tester, [
    editorDelta(
      old,
      start: old.length,
      end: old.length,
      text: text,
      caret: old.length + text.length,
    ),
  ], paint: paint);
}

void main() {
  tearDown(() {
    CodeEditorObservation.onInput = null;
    CodeEditorObservation.onPaint = null;
  });

  testWidgets(
    'collector joins the actual changed paragraph only to its exact frame timing',
    (tester) async {
      final controller = await _show(tester);
      final previous = controller.codeLines;
      final samples = EditorInputSamples();
      CodeEditorObservation.onInput = samples.input;
      CodeEditorObservation.onPaint = (document, frame, viewport, drawn) {
        // Require the original document identity when assigning drawn glyphs.
        samples.paint(previous, frame, viewport, drawn);
        samples.paint(document, frame, viewport, drawn);
      };
      await _insert(tester, 'Z');
      if (CodeEditorObservation.enabled) {
        final sample = samples.samples.single;
        expect(sample.status, 'awaiting-timing');
        expect(sample.paintObserved, isTrue);
        expect(sample.range!.startOffset, 1);
        expect(sample.range!.endOffset, 2);
        ui.FrameTiming timing(int frame) => ui.FrameTiming(
          vsyncStart: sample.startedAt,
          buildStart: sample.startedAt,
          buildFinish: sample.startedAt + 1,
          rasterStart: sample.startedAt + 2,
          rasterFinish: sample.startedAt + 1234,
          rasterFinishWallTime: 900000000,
          frameNumber: frame,
        );
        // Synthetic FrameTiming input for correlation unit tests.
        samples.timings([timing(sample.frame! + 1)]);
        expect(sample.status, 'awaiting-timing');
        samples.timings([timing(sample.frame!)]);
        expect(sample.status, 'matched');
        expect(samples.summary['p95Micros'], 1234);
        expect(samples.summary['enoughSamples'], isFalse);
      } else {
        expect(samples.samples, isEmpty);
      }
    },
  );

  testWidgets(
    'a document repaint outside the modified glyph range is not an input sample',
    (tester) async {
      await _show(tester);
      final samples = EditorInputSamples();
      CodeEditorObservation.onInput = samples.input;
      CodeEditorObservation.onPaint = (document, frame, viewport, drawn) =>
          samples.paint(
            document,
            frame,
            viewport.shift(const Offset(1000000, 1000000)),
            drawn,
          );
      await _insert(tester, 'Z');
      samples.finish();
      if (CodeEditorObservation.enabled) {
        final sample = samples.samples.single;
        expect(sample.paintObserved, isTrue);
        expect(sample.frame, isNull);
        expect(sample.status, 'changed-range-not-visible');
        expect(samples.summary['p95Micros'], isNull);
      } else {
        expect(samples.samples, isEmpty);
      }
    },
  );

  testWidgets(
    'input observation is compile-time gated and precedes the accepted text paint',
    (tester) async {
      final controller = await _show(tester);
      final before = controller.value;
      final inputs = <(int, CodeLineEditingValue, CodeLineEditingValue)>[];
      final paints = <CodeLines>[];
      CodeEditorObservation.onInput = (started, previous, accepted) {
        inputs.add((started, previous, accepted));
      };
      CodeEditorObservation.onPaint = (document, frame, viewport, drawn) {
        paints.add(document);
        expect(frame, greaterThanOrEqualTo(0));
        expect(viewport.isEmpty, isFalse);
        final paragraph = drawn.singleWhere(
          (paragraph) => paragraph.index == 0,
        );
        expect(paragraph.length, 2);
        final glyph = paragraph.getOffset(const TextPosition(offset: 0))!;
        expect(
          paragraph.getSpanForPosition(glyph)!.toPlainText(),
          contains('Z'),
        );
        final range = paragraph.getRangeRects(
          const TextRange(start: 1, end: 2),
        );
        expect(
          range.any((rect) => rect.shift(paragraph.offset).overlaps(viewport)),
          isTrue,
        );
      };
      await _insert(tester, 'Z', paint: false);
      expect(controller.text, 'aZ');
      expect(inputs.length, CodeEditorObservation.enabled ? 1 : 0);
      expect(paints, isEmpty);
      await tester.pump();
      if (CodeEditorObservation.enabled) {
        expect(inputs.single.$1, lessThanOrEqualTo(Timeline.now));
        expect(inputs.single.$2, same(before));
        expect(inputs.single.$3, same(controller.value));
        expect(paints, contains(same(controller.codeLines)));
      } else {
        expect(paints, isEmpty);
      }
    },
  );

  testWidgets(
    'coalesced inputs never acquire a paint for an overwritten document version',
    (tester) async {
      final controller = await _show(tester);
      final inputs = <CodeLines>[];
      final paints = <CodeLines>[];
      CodeEditorObservation.onInput = (_, previous, accepted) =>
          inputs.add(accepted.codeLines);
      CodeEditorObservation.onPaint = (document, frame, viewport, drawn) =>
          paints.add(document);
      final remote = tester.testTextInput.editingState!['text'] as String;
      await _insert(tester, 'X', paint: false);
      final superseded = controller.codeLines;
      // Retain the simulated IME's accepted proposal while observing SDK
      // setEditingState echoes separately.
      await _insert(tester, 'Y', paint: false, remote: '${remote}X');
      final latest = controller.codeLines;
      expect(paints, isEmpty);
      await tester.pump();
      expect(controller.text, 'aXY');
      expect(inputs.length, CodeEditorObservation.enabled ? 2 : 0);
      expect(
        paints.any((document) => identical(document, superseded)),
        isFalse,
      );
      if (CodeEditorObservation.enabled) {
        expect(paints.any((document) => identical(document, latest)), isTrue);
      }
    },
  );

  testWidgets(
    'programmatic changes and nontext deltas cannot masquerade as accepted IME text',
    (tester) async {
      final controller = await _show(tester);
      var acceptedInputs = 0;
      CodeEditorObservation.onInput = (_, previous, accepted) =>
          acceptedInputs++;
      controller.replaceSelection('programmatic');
      await tester.pump(const Duration(milliseconds: 20));
      final old = tester.testTextInput.editingState!['text'] as String;
      await sendEditorDeltas(tester, [editorDelta(old, caret: 1)]);
      expect(acceptedInputs, 0);
      expect(controller.text, 'aprogrammatic');
    },
  );

  testWidgets(
    'rejection cannot emit an accepted version or replace its actual paragraph',
    (tester) async {
      final controller = await _show(tester);
      final before = controller.value;
      var acceptedInputs = 0;
      final paints = <CodeLines>[];
      CodeEditorObservation.onInput = (_, previous, accepted) =>
          acceptedInputs++;
      CodeEditorObservation.onPaint = (document, frame, viewport, drawn) =>
          paints.add(document);
      await _insert(tester, 'x' * maxEditorCodeUnits);
      expect(controller.value, same(before));
      expect(acceptedInputs, 0);
      expect(
        paints.every((document) => identical(document, before.codeLines)),
        isTrue,
      );
      expect(tester.testTextInput.editingState!['text'], endsWith('a'));
    },
  );
}
