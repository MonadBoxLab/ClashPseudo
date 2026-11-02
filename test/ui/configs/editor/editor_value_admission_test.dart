import 'dart:async';

import 'package:clash_pseudo/src/ui/configs/editor/config_editor_limits.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

bool _bounded(CodeLineEditingValue current, CodeLineEditingValue candidate) =>
    firstOversizedCodeLine(candidate.codeLines, previous: current.codeLines) ==
    null;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'acceptance runs before value, previous value, history and listeners',
    () {
      late CodeLineEditingController controller;
      var admitted = 0;
      var notifications = 0;
      controller = CodeLineEditingController.fromText('abc');
      addTearDown(controller.dispose);
      final original = controller.value;
      final previous = controller.preValue;
      controller.acceptValue = (current, candidate) {
        admitted++;
        expect(identical(controller.value, original), isTrue);
        expect(identical(current, original), isTrue);
        expect(identical(controller.preValue, previous), isTrue);
        expect(controller.canUndo, isFalse);
        expect(notifications, 0);
        return _bounded(current, candidate);
      };
      controller.addListener(() => notifications++);
      controller.text = 'accepted';
      expect(admitted, 1);
      expect(notifications, 1);
      expect(controller.text, 'accepted');
      expect(identical(controller.preValue, original), isTrue);
      expect(controller.canUndo, isTrue);
    },
  );

  test(
    'rejected replacement preserves text, selection, composing and history',
    () {
      final controller = CodeLineEditingController.fromText('abc');
      addTearDown(controller.dispose);
      controller.selection = const CodeLineSelection.collapsed(
        index: 0,
        offset: 3,
      );
      controller.composing = const TextRange(start: 1, end: 3);
      controller.clearHistory();
      controller.acceptValue = _bounded;
      final before = controller.value;
      final previous = controller.preValue;
      var notifications = 0;
      controller.addListener(() => notifications++);
      controller.replaceSelection('x' * maxEditorCodeUnits);
      expect(identical(controller.value, before), isTrue);
      expect(identical(controller.preValue, previous), isTrue);
      expect(controller.selection, before.selection);
      expect(controller.composing, before.composing);
      expect(controller.canUndo, isFalse);
      expect(controller.canRedo, isFalse);
      expect(notifications, 0);
    },
  );

  test(
    'programmatic assignment and folded descendants share the same admission',
    () {
      final controller = CodeLineEditingController.fromText('safe')
        ..acceptValue = _bounded;
      addTearDown(controller.dispose);
      final before = controller.value;
      controller.text = 'x' * (maxEditorCodeUnits + 1);
      expect(identical(controller.value, before), isTrue);
      controller.value = CodeLineEditingValue(
        codeLines: CodeLines.of([
          CodeLine('header', [
            CodeLine('nested', [CodeLine('x' * (maxEditorCodeUnits + 1))]),
          ]),
        ]),
      );
      expect(identical(controller.value, before), isTrue);
      expect(controller.canUndo, isFalse);
    },
  );

  test(
    'asynchronous programmatic assignment cannot bypass admission',
    () async {
      final rejected = Completer<void>();
      final controller = CodeLineEditingController.fromText('safe');
      addTearDown(controller.dispose);
      controller.acceptValue = (current, candidate) {
        final allowed = _bounded(current, candidate);
        if (!allowed) rejected.complete();
        return allowed;
      };
      final before = controller.value;
      controller.textAsync = 'x' * (maxEditorCodeUnits + 1);
      await rejected.future.timeout(const Duration(seconds: 10));
      expect(identical(controller.value, before), isTrue);
      expect(controller.canUndo, isFalse);
    },
  );

  test(
    'deleting either side of a newline cannot publish an oversized merge',
    () {
      final half = 'x' * (maxEditorCodeUnits ~/ 2);
      final controller = CodeLineEditingController.fromText('$half\n${half}x')
        ..acceptValue = _bounded;
      addTearDown(controller.dispose);
      controller.selection = const CodeLineSelection.collapsed(
        index: 1,
        offset: 0,
      );
      final backward = controller.value;
      controller.deleteBackward();
      expect(identical(controller.value, backward), isTrue);
      controller.selection = CodeLineSelection.collapsed(
        index: 0,
        offset: half.length,
      );
      final forward = controller.value;
      controller.deleteForward();
      expect(identical(controller.value, forward), isTrue);
      expect(controller.text, '$half\n${half}x');
    },
  );

  test(
    'indent is refused at the boundary, while shortening remains possible',
    () {
      final controller = CodeLineEditingController.fromText(
        'x' * maxEditorCodeUnits,
      )..acceptValue = _bounded;
      addTearDown(controller.dispose);
      final before = controller.value;
      controller.applyIndent();
      expect(identical(controller.value, before), isTrue);
      controller.selection = const CodeLineSelection.collapsed(
        index: 0,
        offset: maxEditorCodeUnits,
      );
      controller.deleteBackward();
      expect(controller.text.length, maxEditorCodeUnits - 1);
      controller.replaceSelection('y');
      expect(controller.text.length, maxEditorCodeUnits);
    },
  );

  test('refused Undo and Redo never move their history nodes', () {
    var allowed = true;
    final controller = CodeLineEditingController.fromText('one');
    addTearDown(controller.dispose);
    controller.acceptValue = (current, candidate) =>
        allowed && _bounded(current, candidate);
    controller.text = 'two';
    controller.text = 'three';
    final latest = controller.value;
    allowed = false;
    controller.undo();
    expect(identical(controller.value, latest), isTrue);
    expect(controller.canUndo, isTrue);
    expect(controller.canRedo, isFalse);
    allowed = true;
    controller.undo();
    expect(controller.text, 'two');
    final middle = controller.value;
    allowed = false;
    controller.redo();
    expect(identical(controller.value, middle), isTrue);
    expect(controller.canRedo, isTrue);
    allowed = true;
    controller.redo();
    expect(controller.text, 'three');
  });

  test('refused edits do not poison the next line history boundary', () {
    final controller = CodeLineEditingController.fromText('a\nb')
      ..acceptValue = _bounded;
    addTearDown(controller.dispose);
    controller.edit(
      const TextEditingValue(
        text: 'ax',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    controller.selection = const CodeLineSelection.collapsed(
      index: 1,
      offset: 1,
    );
    controller.edit(
      TextEditingValue(
        text: 'x' * (maxEditorCodeUnits + 1),
        selection: const TextSelection.collapsed(
          offset: maxEditorCodeUnits + 1,
        ),
      ),
    );
    controller.edit(
      const TextEditingValue(
        text: 'by',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    expect(controller.text, 'ax\nby');
    controller.undo();
    expect(controller.text, 'ax\nb');
  });

  test(
    'delegate forwards the optional admission instead of adding another owner',
    () {
      final actual = CodeLineEditingController.fromText('safe');
      final delegate = CodeLineEditingControllerDelegate(delegate: actual)
        ..acceptValue = _bounded;
      addTearDown(delegate.dispose);
      expect(identical(actual.acceptValue, delegate.acceptValue), isTrue);
      delegate.text = 'x' * (maxEditorCodeUnits + 1);
      expect(delegate.text, 'safe');
      expect(actual.canUndo, isFalse);
    },
  );

  for (final change in ['none', 'text', 'selection', 'authority', 'disposed']) {
    testWidgets(
      'delayed clipboard respects actual value and authority: $change',
      (tester) async {
        final clipboard = Completer<Map<String, Object?>>();
        var requests = 0;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.getData') {
              requests++;
              return clipboard.future;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final controller = CodeLineEditingController.fromText('safe')
          ..acceptValue = _bounded;
        controller.selection = const CodeLineSelection.collapsed(
          index: 0,
          offset: 4,
        );
        controller.paste();
        await tester.pump();
        expect(requests, 1);
        switch (change) {
          case 'text':
            controller.text = 'new dirty text';
          case 'selection':
            controller.selection = const CodeLineSelection.collapsed(
              index: 0,
              offset: 0,
            );
          case 'authority':
            controller.acceptValue = (current, candidate) =>
                _bounded(current, candidate);
          case 'disposed':
            controller.dispose();
        }
        final before = controller.value;
        clipboard.complete({'text': '-clipboard'});
        await tester.pump();
        if (change == 'none') {
          expect(controller.text, 'safe-clipboard');
        } else {
          expect(identical(controller.value, before), isTrue);
        }
        expect(tester.takeException(), isNull);
        if (change != 'disposed') controller.dispose();
      },
    );
  }
}
