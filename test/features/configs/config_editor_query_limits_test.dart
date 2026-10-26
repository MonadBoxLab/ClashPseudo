import 'dart:async';

import 'package:clash_pseudo/src/features/configs/config_editor_limits.dart';
import 'package:clash_pseudo/src/features/configs/config_find_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

Future<void> _finished(ConfigFindController find) async {
  if (find.value?.searching != true) return;
  final done = Completer<void>();
  void changed() {
    if (find.value?.searching != true && !done.isCompleted) done.complete();
  }

  find.addListener(changed);
  try {
    await done.future.timeout(const Duration(seconds: 5));
  } finally {
    find.removeListener(changed);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final query in [
    'x' * maxEditorCodeUnits,
    '🌐' * (maxEditorCodeUnits ~/ 2),
    '${'é' * (maxEditorCodeUnits ~/ 2 - 1)}\u2028\u2029',
    '${'x' * (maxEditorCodeUnits - 2)}\r\n',
  ]) {
    test(
      'query boundary counts UTF-16 units, suffix=${query.codeUnitAt(query.length - 1)}',
      () async {
        expect(query.length, maxEditorCodeUnits);
        final editor = CodeLineEditingController.fromText(query);
        var rejected = 0;
        final find = ConfigFindController(
          editor,
          onQueryRejected: () => rejected++,
        );
        addTearDown(() {
          find.dispose();
          editor.dispose();
        });
        find.findMode();
        final input = TextEditingValue(
          text: query,
          selection: TextSelection.collapsed(offset: query.length),
          composing: TextRange(start: 0, end: query.length),
        );
        find.findInputController.value = input;
        await _finished(find);
        expect(find.findInputController.value, input);
        expect(find.value!.option.pattern, query);
        expect(find.failed, isFalse);
        var inputNotifications = 0;
        var resultNotifications = 0;
        find.findInputController.addListener(() => inputNotifications++);
        find.addListener(() => resultNotifications++);
        final accepted = find.value;
        find.findInputController.value = input.copyWith(
          text: '${query}x',
          selection: TextSelection.collapsed(offset: query.length + 1),
          composing: TextRange(start: 0, end: query.length + 1),
        );
        expect(rejected, 1);
        expect(find.findInputController.value, input);
        expect(find.value, same(accepted));
        expect(inputNotifications, 0);
        expect(resultNotifications, 0);
      },
    );
  }

  test(
    'exact boundary reaches the real search and returns a complete match',
    () async {
      final query = 'x' * maxEditorCodeUnits;
      final editor = CodeLineEditingController.fromText(query);
      final find = ConfigFindController(editor);
      addTearDown(() {
        find.dispose();
        editor.dispose();
      });
      find.findMode();
      find.findInputController.text = query;
      await _finished(find);
      expect(find.value!.result!.matches, [
        const CodeLineSelection(
          baseIndex: 0,
          baseOffset: 0,
          extentIndex: 0,
          extentOffset: maxEditorCodeUnits,
        ),
      ]);
    },
  );

  test('selection prefill cannot bypass programmatic query admission', () async {
    // Exercise the controller's own defense independently of page preparation.
    final editor = CodeLineEditingController.fromText(
      'x' * (maxEditorCodeUnits + 1),
    );
    var rejected = 0;
    final find = ConfigFindController(
      editor,
      onQueryRejected: () => rejected++,
    );
    addTearDown(() {
      find.dispose();
      editor.dispose();
    });
    const previous = TextEditingValue(
      text: 'old',
      selection: TextSelection.collapsed(offset: 3),
      composing: TextRange(start: 0, end: 3),
    );
    find.findInputController.value = previous;
    editor.selectAll();
    find.findMode();
    await _finished(find);
    expect(rejected, 1);
    expect(find.findInputController.text, previous.text);
    expect(find.findInputController.value.composing, previous.composing);
    expect(find.value!.option.pattern, previous.text);
    expect(editor.text.length, maxEditorCodeUnits + 1);
  });

  test(
    'a rejected query does not replace or invalidate an entered valid scan',
    () async {
      final entered = Completer<String>();
      final reply = Completer<List<CodeLineSelection>>();
      var scans = 0;
      var rejected = 0;
      final editor = CodeLineEditingController.fromText('marker');
      final find = ConfigFindController(
        editor,
        onQueryRejected: () => rejected++,
        scan: (_, query) {
          scans++;
          entered.complete(query);
          return reply.future;
        },
      );
      addTearDown(() {
        find.dispose();
        editor.dispose();
      });
      find.findMode();
      const accepted = TextEditingValue(
        text: 'marker',
        selection: TextSelection.collapsed(offset: 6),
        composing: TextRange(start: 0, end: 6),
      );
      find.findInputController.value = accepted;
      expect(
        await entered.future.timeout(const Duration(seconds: 5)),
        'marker',
      );
      final searching = find.value;
      find.findInputController.text = 'x' * (maxEditorCodeUnits + 1);
      expect(find.value, same(searching));
      expect(find.findInputController.value, accepted);
      reply.complete([
        const CodeLineSelection(
          baseIndex: 0,
          baseOffset: 0,
          extentIndex: 0,
          extentOffset: 6,
        ),
      ]);
      await _finished(find);
      expect(rejected, 1);
      expect(scans, 1);
      expect(find.value!.option.pattern, 'marker');
      expect(find.value!.result!.matches, hasLength(1));
      expect(find.findInputController.value, accepted);
    },
  );

  for (final (query, text, expected) in [
    ('${'a' * 1024}b', '${'a' * 1025}b', [1]),
    ('${'a' * 1024}${'b' * 1024}', '${'a' * 2048}${'b' * 1024}', [1024]),
    ('a' * 2048, 'a' * 4096, [0, 2048]),
    ('${'a' * 1023}🌐B', 'Z${'A' * 1023}🌐b', [1]),
    ('[a]' * 1024, 'prefix${'[A]' * 1024}suffix', [6]),
    ('${'ς' * 1024}σ', 'Σ' * 1025, [0]),
    ('s' * 1025, 'ſ${'S' * 1025}', [1]),
    ('k' * 1025, 'K${'K' * 1025}', [1]),
    ('${'a' * 32767}b', 'a' * 65536, <int>[]),
  ]) {
    test(
      'long literal pieces preserve overlap and SDK folding, units=${query.length}, prefix=${text.codeUnitAt(0)}, starts=$expected',
      () async {
        final editor = CodeLineEditingController.fromText(text);
        final find = ConfigFindController(editor);
        addTearDown(() {
          find.dispose();
          editor.dispose();
        });
        find.findMode();
        find.findInputController.text = query;
        await _finished(find);
        expect(find.failed, isFalse);
        expect(
          find.value!.result?.matches
                  .map((match) => match.startOffset)
                  .toList() ??
              [],
          expected,
        );
        for (final match
            in find.value!.result?.matches ?? <CodeLineSelection>[]) {
          expect(match.endOffset - match.startOffset, query.length);
        }
      },
    );
  }
}
