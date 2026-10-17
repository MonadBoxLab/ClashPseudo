import 'dart:async';

import 'package:clash_pseudo/features/configs/config_find_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

Future<void> settleFind(ConfigFindController find) async {
  if (find.value?.searching != true) return;
  final done = Completer<void>();
  void changed() {
    if (find.value?.searching != true && !done.isCompleted) done.complete();
  }

  find.addListener(changed);
  try {
    await done.future.timeout(const Duration(seconds: 15));
  } finally {
    find.removeListener(changed);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  (CodeLineEditingController, ConfigFindController) create(String text) {
    final editor = CodeLineEditingController.fromText(text);
    final find = ConfigFindController(editor);
    addTearDown(() {
      find.dispose();
      editor.dispose();
    });
    find.findMode();
    return (editor, find);
  }

  test(
    'literal case-insensitive search retains line and UTF-16 offsets',
    () async {
      final (_, find) = create('🌐A.b\na.B\n[ab]');
      find.findInputController.text = 'a.b';
      await settleFind(find);
      final result = find.value!.result!;
      expect(result.matches, [
        const CodeLineSelection(
          baseIndex: 0,
          baseOffset: 2,
          extentIndex: 0,
          extentOffset: 5,
        ),
        const CodeLineSelection(
          baseIndex: 1,
          baseOffset: 0,
          extentIndex: 1,
          extentOffset: 3,
        ),
      ]);
      find.nextMatch();
      expect(find.currentMatchSelection, result.matches[1]);
      find.nextMatch();
      expect(find.currentMatchSelection, result.matches[0]);
      find.previousMatch();
      expect(find.currentMatchSelection, result.matches[1]);
      expect(find.failed, isFalse);
    },
  );

  test('multiline matches and terminal newline have exact positions', () async {
    final (_, find) = create('x\nA\nB\nA\nB\n');
    find.findInputController.text = 'a\nb\n';
    await settleFind(find);
    expect(find.value!.result!.matches, [
      const CodeLineSelection(
        baseIndex: 1,
        baseOffset: 0,
        extentIndex: 3,
        extentOffset: 0,
      ),
      const CodeLineSelection(
        baseIndex: 3,
        baseOffset: 0,
        extentIndex: 5,
        extentOffset: 0,
      ),
    ]);
  });

  test(
    'latest query and document win without changing composing input',
    () async {
      final (editor, find) = create('old ${'x' * 1024}\n' * 16000);
      find.findInputController.text = 'old';
      await Future<void>.delayed(const Duration(milliseconds: 125));
      editor.text = 'new\nNEW\n';
      find.findInputController.text = 'missing';
      find.findInputController.text = 'new';
      await settleFind(find);
      expect(find.value!.option.pattern, 'new');
      expect(find.value!.result!.matches.length, 2);
      expect(
        identical(find.value!.result!.codeLines, editor.codeLines),
        isTrue,
      );
      expect(find.findInputController.text, 'new');
    },
  );

  test(
    'closing cancels pending results and reopening searches current text',
    () async {
      final (editor, find) = create('marker\n' * 16000);
      find.findInputController.text = 'marker';
      await Future<void>.delayed(const Duration(milliseconds: 125));
      find.close();
      editor.text = 'no match';
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(find.value, isNull);
      find.findMode();
      await settleFind(find);
      expect(find.value!.result, isNull);
      expect(find.failed, isFalse);
    },
  );

  test('sixteen mebibyte frequent matches are complete', () async {
    final line = 'find-marker ${'a' * 1011}\n';
    expect(line.length, 1024);
    final (_, find) = create(line * 16384);
    find.findInputController.text = 'find-marker';
    await settleFind(find);
    expect(find.value!.result!.matches.length, 16384);
    expect(find.value!.result!.matches.last.baseIndex, 16383);
    expect(find.failed, isFalse);
  });

  test(
    'find-only actions cannot enable replacement or mutate content',
    () async {
      final (editor, find) = create('literal [x]');
      find.findInputController.text = '[x]';
      await settleFind(find);
      find.toggleRegex();
      find.toggleCaseSensitive();
      find.replaceMode();
      find.replaceInputController.text = 'replacement';
      find.replaceMatch();
      find.replaceAllMatches();
      expect(find.value!.option.regex, isFalse);
      expect(find.value!.option.caseSensitive, isFalse);
      expect(find.value!.replaceMode, isFalse);
      expect(editor.text, 'literal [x]');
    },
  );
}
