import 'package:clash_pseudo/src/features/configs/config_editor_limits.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import '../../support/editor_ime.dart';

int _stateWrites(WidgetTester tester) => tester.testTextInput.log
    .where((call) => call.method == 'TextInput.setEditingState')
    .length;

Future<void> _show(
  WidgetTester tester,
  CodeLineEditingController controller,
) async {
  final focus = FocusNode();
  addTearDown(focus.dispose);
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
  // The existing input client retries a missing caret once, 10 ms after layout.
  await tester.pump(const Duration(milliseconds: 20));
  expect(tester.testTextInput.hasAnyClients, isTrue);
  expect(tester.testTextInput.setClientArgs!['enableDeltaModel'], isTrue);
  expect(tester.testTextInput.editingState!['text'], startsWith('\u200b'));
}

CodeLineEditingController _controller(
  String text, {
  CodeLineSelection? selection,
  CodeLineValueAcceptance? accept,
}) {
  final controller = CodeLineEditingController.fromText(text);
  if (selection != null) controller.selection = selection;
  controller.clearHistory();
  controller.acceptValue =
      accept ??
      (current, candidate) =>
          firstOversizedCodeLine(
            candidate.codeLines,
            previous: current.codeLines,
          ) ==
          null;
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  testWidgets(
    'accepted boundary composing is preserved; overflow corrects the actual IME',
    (tester) async {
      final initial = 'x' * (maxEditorCodeUnits - 1);
      final controller = _controller(
        initial,
        selection: const CodeLineSelection.collapsed(
          index: 0,
          offset: maxEditorCodeUnits - 1,
        ),
      );
      await _show(tester, controller);
      var notifications = 0;
      controller.addListener(() => notifications++);
      final old = tester.testTextInput.editingState!['text'] as String;
      await sendEditorDeltas(tester, [
        editorDelta(
          old,
          start: old.length,
          end: old.length,
          text: 'y',
          caret: old.length + 1,
          composingStart: 1,
          composingEnd: old.length + 1,
        ),
      ]);
      expect(controller.codeLines.first.length, maxEditorCodeUnits);
      expect(
        controller.composing,
        const TextRange(start: 0, end: maxEditorCodeUnits),
      );
      expect(notifications, 1);
      final before = controller.value;
      final previous = controller.preValue;
      final writes = _stateWrites(tester);
      final acceptedRemote = '${old}y';
      notifications = 0;
      await sendEditorDeltas(tester, [
        editorDelta(
          acceptedRemote,
          start: acceptedRemote.length,
          end: acceptedRemote.length,
          text: 'z',
          caret: acceptedRemote.length + 1,
          composingStart: 1,
          composingEnd: acceptedRemote.length + 1,
        ),
      ]);
      expect(identical(controller.value, before), isTrue);
      expect(identical(controller.preValue, previous), isTrue);
      expect(notifications, 0);
      expect(_stateWrites(tester), writes + 1);
      expect(tester.testTextInput.editingState!['text'], acceptedRemote);
      expect(tester.testTextInput.editingState!['composingBase'], 1);
      expect(
        tester.testTextInput.editingState!['composingExtent'],
        acceptedRemote.length,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a rejected batch never publishes its initially valid deletion', (
    tester,
  ) async {
    var checks = 0;
    final controller = _controller(
      'abc',
      selection: const CodeLineSelection.collapsed(index: 0, offset: 3),
      accept: (current, candidate) {
        checks++;
        return firstOversizedCodeLine(
              candidate.codeLines,
              previous: current.codeLines,
            ) ==
            null;
      },
    );
    await _show(tester, controller);
    final old = tester.testTextInput.editingState!['text'] as String;
    final before = controller.value;
    final previous = controller.preValue;
    var notifications = 0;
    controller.addListener(() => notifications++);
    checks = 0;
    await sendEditorDeltas(tester, [
      editorDelta(old, start: 1, end: old.length, caret: 1),
      editorDelta(
        '\u200b',
        start: 1,
        end: 1,
        text: 'x' * (maxEditorCodeUnits + 1),
        caret: maxEditorCodeUnits + 2,
      ),
    ]);
    expect(checks, 1);
    expect(notifications, 0);
    expect(identical(controller.value, before), isTrue);
    expect(identical(controller.preValue, previous), isTrue);
    expect(controller.canUndo, isFalse);
    expect(tester.testTextInput.editingState!['text'], old);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'stale second oldText rejects the whole batch and forces correction',
    (tester) async {
      var checks = 0;
      final controller = _controller(
        'abc',
        accept: (current, candidate) {
          checks++;
          return true;
        },
      );
      await _show(tester, controller);
      final old = tester.testTextInput.editingState!['text'] as String;
      final before = controller.value;
      final writes = _stateWrites(tester);
      checks = 0;
      await sendEditorDeltas(tester, [
        editorDelta(
          old,
          start: old.length,
          end: old.length,
          text: 'x',
          caret: old.length + 1,
        ),
        editorDelta('${old}STALE', start: 1, end: 1, text: 'z', caret: 2),
      ]);
      expect(checks, 0);
      expect(identical(controller.value, before), isTrue);
      expect(controller.canUndo, isFalse);
      expect(_stateWrites(tester), writes + 1);
      expect(tester.testTextInput.editingState!['text'], old);
    },
  );

  testWidgets(
    'only the final batch candidate is admitted, not an oversized intermediate',
    (tester) async {
      var checks = 0;
      final body = 'x' * maxEditorCodeUnits;
      final controller = _controller(
        body,
        selection: const CodeLineSelection.collapsed(
          index: 0,
          offset: maxEditorCodeUnits,
        ),
        accept: (current, candidate) {
          checks++;
          return firstOversizedCodeLine(
                candidate.codeLines,
                previous: current.codeLines,
              ) ==
              null;
        },
      );
      await _show(tester, controller);
      final old = tester.testTextInput.editingState!['text'] as String;
      checks = 0;
      await sendEditorDeltas(tester, [
        editorDelta(
          old,
          start: old.length,
          end: old.length,
          text: 'y',
          caret: old.length + 1,
        ),
        editorDelta(
          '${old}y',
          start: old.length,
          end: old.length + 1,
          caret: old.length,
        ),
      ]);
      expect(checks, 1);
      expect(controller.text, body);
      expect(controller.canUndo, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a newline plus subsequent insertion is one complete publication',
    (tester) async {
      var checks = 0;
      final controller = _controller(
        'abc',
        selection: const CodeLineSelection.collapsed(index: 0, offset: 3),
        accept: (current, candidate) {
          checks++;
          return true;
        },
      );
      await _show(tester, controller);
      final old = tester.testTextInput.editingState!['text'] as String;
      checks = 0;
      var notifications = 0;
      controller.addListener(() => notifications++);
      await sendEditorDeltas(tester, [
        editorDelta(
          old,
          start: old.length,
          end: old.length,
          text: '\n',
          caret: old.length + 1,
        ),
        editorDelta(
          '$old\n',
          start: old.length + 1,
          end: old.length + 1,
          text: 'Z',
          caret: old.length + 2,
          composingStart: old.length + 1,
          composingEnd: old.length + 2,
        ),
      ]);
      expect(controller.text, 'abc\nZ');
      expect(
        controller.selection,
        const CodeLineSelection.collapsed(index: 1, offset: 1),
      );
      expect(controller.composing, const TextRange(start: 0, end: 1));
      expect(checks, 1);
      expect(notifications, 1);
      expect(tester.testTextInput.editingState!['text'], '\u200bZ');
      controller.undo();
      expect(controller.text, 'abc');
    },
  );

  for (final reverse in [false, true]) {
    testWidgets(
      'multiline selection maps the final input window atomically, reverse=$reverse',
      (tester) async {
        final controller = _controller(
          'abcDEF\nqqXYZ',
          selection: reverse
              ? const CodeLineSelection(
                  baseIndex: 1,
                  baseOffset: 2,
                  extentIndex: 0,
                  extentOffset: 3,
                )
              : const CodeLineSelection(
                  baseIndex: 0,
                  baseOffset: 3,
                  extentIndex: 1,
                  extentOffset: 2,
                ),
        );
        await _show(tester, controller);
        final old = tester.testTextInput.editingState!['text'] as String;
        final start = reverse ? 1 : 4;
        final end = reverse ? 3 : 7;
        final caret = start + 3;
        var notifications = 0;
        controller.addListener(() => notifications++);
        await sendEditorDeltas(tester, [
          editorDelta(
            old,
            start: start,
            end: end,
            text: 'x\ny',
            caret: caret,
            composingStart: caret - 1,
            composingEnd: caret,
          ),
        ]);
        expect(controller.text, 'abcx\nyXYZ');
        expect(
          controller.selection,
          const CodeLineSelection.collapsed(index: 1, offset: 1),
        );
        expect(controller.composing, const TextRange(start: 0, end: 1));
        expect(notifications, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'prefix deletion plus insertion reuses backspace without a partial merge',
    (tester) async {
      var checks = 0;
      final controller = _controller(
        'prev\nchild',
        selection: const CodeLineSelection.collapsed(index: 1, offset: 0),
        accept: (current, candidate) {
          checks++;
          return true;
        },
      );
      await _show(tester, controller);
      final old = tester.testTextInput.editingState!['text'] as String;
      checks = 0;
      var notifications = 0;
      controller.addListener(() => notifications++);
      await sendEditorDeltas(tester, [
        editorDelta(old, start: 0, end: 1, caret: 0),
        editorDelta('child', start: 0, end: 0, text: 'X', caret: 1),
      ]);
      expect(controller.text, 'prevXchild');
      expect(
        controller.selection,
        const CodeLineSelection.collapsed(index: 0, offset: 5),
      );
      expect(checks, 1);
      expect(notifications, 1);
      controller.undo();
      expect(controller.text, 'prev\nchild');
      await tester.pump(const Duration(milliseconds: 20));
    },
  );

  testWidgets(
    'prefix backspace cannot publish an oversized line or pollute history',
    (tester) async {
      final half = 'x' * (maxEditorCodeUnits ~/ 2);
      final controller = _controller(
        '$half\n${half}x',
        selection: const CodeLineSelection.collapsed(index: 1, offset: 0),
      );
      await _show(tester, controller);
      final old = tester.testTextInput.editingState!['text'] as String;
      final before = controller.value;
      final previous = controller.preValue;
      final writes = _stateWrites(tester);
      await sendEditorDeltas(tester, [
        editorDelta(old, start: 0, end: 1, caret: 0),
      ]);
      expect(identical(controller.value, before), isTrue);
      expect(identical(controller.preValue, previous), isTrue);
      expect(controller.canUndo, isFalse);
      expect(_stateWrites(tester), writes + 1);
      expect(tester.testTextInput.editingState!['text'], old);
    },
  );

  testWidgets(
    'nontext selection before the mobile prefix never deletes document text',
    (tester) async {
      final controller = _controller(
        'prev\nchild',
        selection: const CodeLineSelection.collapsed(index: 1, offset: 0),
      );
      await _show(tester, controller);
      final old = tester.testTextInput.editingState!['text'] as String;
      await sendEditorDeltas(tester, [editorDelta(old, caret: 0)]);
      expect(controller.text, 'prev\nchild');
      expect(
        controller.selection,
        const CodeLineSelection.collapsed(index: 1, offset: 0),
      );
      expect(controller.canUndo, isFalse);
    },
  );

  testWidgets(
    'a lost writable authority rejects IME input before the next UI frame',
    (tester) async {
      var writable = true;
      final controller = _controller(
        'safe',
        accept: (current, candidate) =>
            identical(current.codeLines, candidate.codeLines) || writable,
      );
      await _show(tester, controller);
      final old = tester.testTextInput.editingState!['text'] as String;
      final before = controller.value;
      writable = false;
      final writes = _stateWrites(tester);
      await sendEditorDeltas(tester, [
        editorDelta(
          old,
          start: old.length,
          end: old.length,
          text: 'x',
          caret: old.length + 1,
        ),
      ]);
      expect(identical(controller.value, before), isTrue);
      expect(controller.canUndo, isFalse);
      expect(_stateWrites(tester), writes + 1);
      expect(tester.testTextInput.editingState!['text'], old);
    },
  );
}
