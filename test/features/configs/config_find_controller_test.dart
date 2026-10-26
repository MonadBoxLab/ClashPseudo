import 'dart:async';

import 'package:clash_pseudo/src/features/configs/config_find_controller.dart';
import 'package:flutter/widgets.dart';
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

  (CodeLineEditingController, ConfigFindController) create(
    String text, {
    Future<List<CodeLineSelection>> Function(CodeLines, String)? scan,
  }) {
    final editor = CodeLineEditingController.fromText(text);
    final find = ConfigFindController(editor, scan: scan);
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
    'an entered old scan cannot publish over the latest query and document',
    () async {
      final entered = Completer<(CodeLines, String)>();
      final latestEntered = Completer<(CodeLines, String)>();
      final oldReply = Completer<List<CodeLineSelection>>();
      final latestReply = Completer<List<CodeLineSelection>>();
      var scans = 0;
      final (editor, find) = create(
        'old document',
        scan: (lines, pattern) {
          scans++;
          if (scans == 1) {
            entered.complete((lines, pattern));
            return oldReply.future;
          }
          latestEntered.complete((lines, pattern));
          return latestReply.future;
        },
      );
      find.findInputController.text = 'old';
      final old = await entered.future.timeout(const Duration(seconds: 5));
      expect(old.$2, 'old');
      expect(old.$1, same(editor.codeLines));
      final published = <CodeLines>[];
      find.addListener(() {
        if (find.value?.result case final result?) {
          published.add(result.codeLines);
        }
      });
      editor.text = 'new\nNEW\n';
      find.findInputController.text = 'missing';
      const input = TextEditingValue(
        text: 'nEw',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 0, end: 3),
      );
      find.findInputController.value = input;
      expect(input.composing.isCollapsed, isFalse);
      expect(find.findInputController.value, input);
      expect(scans, 1);
      oldReply.complete([
        const CodeLineSelection(
          baseIndex: 0,
          baseOffset: 0,
          extentIndex: 0,
          extentOffset: 3,
        ),
      ]);
      final latest = await latestEntered.future.timeout(
        const Duration(seconds: 5),
      );
      expect(latest.$2, 'nEw');
      expect(latest.$1, same(editor.codeLines));
      expect(latest.$1, isNot(same(old.$1)));
      expect(find.value!.searching, isTrue);
      expect(find.value!.result, isNull);
      expect(published, isEmpty);
      expect(find.findInputController.value, input);
      latestReply.complete([
        const CodeLineSelection(
          baseIndex: 0,
          baseOffset: 0,
          extentIndex: 0,
          extentOffset: 3,
        ),
        const CodeLineSelection(
          baseIndex: 1,
          baseOffset: 0,
          extentIndex: 1,
          extentOffset: 3,
        ),
      ]);
      await settleFind(find);
      expect(scans, 2);
      expect(find.value!.option.pattern, 'nEw');
      expect(find.value!.result!.matches, hasLength(2));
      expect(published, [same(editor.codeLines)]);
      expect(find.findInputController.value, input);
    },
  );

  test('closing discards an already entered scan before reopening', () async {
    final entered = Completer<void>();
    final oldReply = Completer<List<CodeLineSelection>>();
    var scans = 0;
    final (editor, find) = create(
      'marker',
      scan: (_, _) {
        scans++;
        if (scans == 1) {
          entered.complete();
          return oldReply.future;
        }
        return Future.value([]);
      },
    );
    find.findInputController.text = 'marker';
    await entered.future.timeout(const Duration(seconds: 5));
    expect(scans, 1);
    find.close();
    editor.text = 'no match';
    oldReply.complete([
      const CodeLineSelection(
        baseIndex: 0,
        baseOffset: 0,
        extentIndex: 0,
        extentOffset: 6,
      ),
    ]);
    await oldReply.future;
    await Future<void>.value();
    expect(find.value, isNull);
    expect(scans, 1);
    find.findMode();
    await settleFind(find);
    expect(scans, 2);
    expect(find.value!.result, isNull);
    expect(find.failed, isFalse);
  });

  test('dispose rejects the result of an already entered scan', () async {
    final entered = Completer<void>();
    final oldReply = Completer<List<CodeLineSelection>>();
    final editor = CodeLineEditingController.fromText('marker');
    final find = ConfigFindController(
      editor,
      scan: (_, _) {
        entered.complete();
        return oldReply.future;
      },
    );
    var disposed = false;
    addTearDown(() {
      if (!disposed) {
        find.dispose();
        editor.dispose();
      }
    });
    find.findMode();
    find.findInputController.text = 'marker';
    await entered.future.timeout(const Duration(seconds: 5));
    final last = find.value;
    var lateNotifications = 0;
    find.addListener(() => lateNotifications++);
    find.dispose();
    editor.dispose();
    disposed = true;
    oldReply.complete([
      const CodeLineSelection(
        baseIndex: 0,
        baseOffset: 0,
        extentIndex: 0,
        extentOffset: 6,
      ),
    ]);
    await oldReply.future;
    await Future<void>.value();
    expect(find.value, same(last));
    expect(lateNotifications, 0);
  });

  test(
    'ordinary input preserves a non-empty composing range through a real scan',
    () async {
      final (_, find) = create('prefix 🌐new suffix');
      const input = TextEditingValue(
        text: '🌐new',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 2, end: 5),
      );
      expect(input.composing.isValid, isTrue);
      expect(input.composing.isCollapsed, isFalse);
      find.findInputController.value = input;
      expect(find.findInputController.value, input);
      await settleFind(find);
      expect(find.findInputController.value, input);
      expect(find.value!.result!.matches, hasLength(1));
      const composingOnly = TextEditingValue(
        text: '🌐new',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      );
      find.findInputController.value = composingOnly;
      await Future<void>.value();
      expect(find.findInputController.value, composingOnly);
      expect(find.value!.searching, isFalse);
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
