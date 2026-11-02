import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';

import 'dart:async';

import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/config_text.dart';
import 'package:clash_pseudo/src/ui/configs/editor/config_text_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import 'editor_fakes.dart';

void main() {
  final zh = lookupAppLocalizations(const Locale('zh'));
  const local = ConfigEntry(
    id: 'local',
    name: 'Local',
    kind: ConfigKind.local,
    revision: 1,
    body: '\u{feff}a\r\nb\r\n',
  );
  late EditorApp app;

  // Inject the store projection independently from the operation's receipt.
  void publishSavedBody() {
    final entry = app.collection.entries.single;
    app.collection = app.collection.replace(
      ConfigEntry(
        id: entry.id,
        name: entry.name,
        kind: entry.kind,
        revision: 2,
        body: app.commands.last['body']! as String,
      ),
    );
    app.updateState(app.state);
  }

  Future<void> show(
    WidgetTester tester, {
    ConfigEntry? entry = local,
    String initial = '',
    ThemeData? theme,
    double scale = 1,
  }) async {
    app = EditorApp(entries: [?entry]);
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [AppTaskNavigatorObserver()],
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: theme ?? AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => ConfigTextPage(
                    app: app,
                    entry: entry,
                    initialText: initial,
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('editor semantics follow actual focus and readonly state', (
    tester,
  ) async {
    await show(tester);
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    Semantics semantics() => tester.widget<Semantics>(
      find
          .ancestor(
            of: find.byType(CodeEditor),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics && widget.properties.textField == true,
            ),
          )
          .first,
    );
    expect(semantics().properties.readOnly, isFalse);
    expect(semantics().properties.focused, editor.focusNode!.hasFocus);
    editor.focusNode!.requestFocus();
    await tester.pump();
    expect(editor.focusNode!.hasFocus, isTrue);
    expect(semantics().properties.focused, isTrue);
    editor.focusNode!.unfocus();
    await tester.pumpAndSettle();
    expect(editor.focusNode!.hasFocus, isFalse);
    expect(semantics().properties.focused, isFalse);
    app.pending = Completer<AppSnapshot?>();
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(semantics().properties.readOnly, isTrue);
    app.pending!.complete(const AppSnapshot(configStatus: 'notSaved'));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(SnackBar),
            matching: find.byType(IconButton),
          )
          .last,
    );
    await tester.pumpAndSettle();
    expect(semantics().properties.readOnly, isFalse);
  });

  testWidgets('empty text is ready and unchanged BOM CRLF saves verbatim', (
    tester,
  ) async {
    await show(tester);
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    expect(editor.controller!.text, 'a\nb\n');
    expect(editor.autocompleteSymbols, isFalse);
    app.outcome = const AppSnapshot(
      configStatus: 'saved',
      resultSuccess: true,
      targetId: 'local',
      savedRevision: 1,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(app.commands.single['body'], local.body);
    expect(find.byType(ConfigTextPage), findsNothing);
    await show(tester, entry: null);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!.text,
      '',
    );
  });

  for (final modifier in [
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.metaLeft,
  ]) {
    testWidgets('focused editor task shortcuts use $modifier', (tester) async {
      await show(tester);
      final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
      editor.focusNode!.requestFocus();
      await tester.pump();
      Future<void> key(LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(modifier);
        await tester.pumpAndSettle();
      }

      await key(LogicalKeyboardKey.keyF);
      expect(find.byTooltip(zh.closeFind), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byTooltip(zh.find), findsOneWidget);
      editor.focusNode!.requestFocus();
      await tester.pump();
      app.pending = Completer<AppSnapshot?>();
      await key(LogicalKeyboardKey.keyS);
      expect(app.commands, hasLength(1));
      expect(app.commands.single['body'], local.body);
      await key(LogicalKeyboardKey.keyS);
      expect(app.commands, hasLength(1));
      app.pending!.complete(
        const AppSnapshot(
          configStatus: 'saved',
          resultSuccess: true,
          targetId: 'local',
          savedRevision: 1,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ConfigTextPage), findsNothing);
    });
  }

  testWidgets('dirty return can stay or discard once', (tester) async {
    await show(tester);
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    editor.controller!.text = 'changed';
    await tester.pump();
    expect(find.text('未保存修改'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(editor.controller!.text, 'changed');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(find.byType(ConfigTextPage), findsNothing);
    expect(app.commands, isEmpty);
  });

  testWidgets('accepted save disables edits until final correlated result', (
    tester,
  ) async {
    await show(tester);
    app.pending = Completer<AppSnapshot?>();
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(tester.widget<CodeEditor>(find.byType(CodeEditor)).readOnly, isTrue);
    expect(find.byType(ConfigTextPage), findsOneWidget);
    publishSavedBody();
    app.pending!.complete(
      const AppSnapshot(
        configStatus: 'applyFailed',
        targetId: 'local',
        savedRevision: 2,
        resultMessage: AppMessage('configSavedApplyReleasePending'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      tester.widget<CodeEditor>(find.byType(CodeEditor)).readOnly,
      isFalse,
    );
    expect(find.text('已保存，应用未完成'), findsOneWidget);
    expect(find.byKey(const ValueKey('editor-input-notice')), findsNothing);
    final retainedEditor = tester.state(find.byType(CodeEditor));
    await tester.tap(
      find
          .descendant(
            of: find.byType(SnackBar),
            matching: find.byType(TextButton),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('已保存，应用未完成'),
      ),
      findsOneWidget,
    );
    expect(app.commands, hasLength(1));
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(CodeEditor)), same(retainedEditor));
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存修改？'), findsNothing);
  });

  testWidgets('remote readonly keeps copy and rejects edit shortcuts', (
    tester,
  ) async {
    await show(
      tester,
      entry: const ConfigEntry(
        id: 'remote',
        name: 'Remote',
        source: 'https://fixture.test/config',
        revision: 1,
        body: 'original',
      ),
    );
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    expect(editor.readOnly, isTrue);
    expect(find.text('保存'), findsNothing);
    editor.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(editor.controller!.text, 'original');
    editor.controller!.selectAll();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(editor.controller!.text, 'original');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(editor.controller!.text, 'original');
    await tester.tap(find.byTooltip('查找'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'original');
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'origina',
    );
    await tester.tap(find.byTooltip('关闭查找'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存修改？'), findsNothing);
    expect(app.commands, isEmpty);
  });

  testWidgets('save lock guards mobile keys and releases after failure', (
    tester,
  ) async {
    await show(tester);
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    editor.focusNode!.requestFocus();
    editor.controller!.selectAll();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(editor.controller!.text, '');
    editor.controller!.text = 'retained';
    app.pending = Completer<AppSnapshot?>();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    editor.focusNode!.requestFocus();
    editor.controller!.selectAll();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(editor.controller!.text, 'retained');
    app.pending!.complete(const AppSnapshot(configStatus: 'notSaved'));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(SnackBar),
            matching: find.byType(IconButton),
          )
          .last,
    );
    await tester.pumpAndSettle();
    editor.focusNode!.requestFocus();
    editor.controller!.selectAll();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(editor.controller!.text, '');
  });

  testWidgets('failed write retains input and permits retry', (tester) async {
    await show(tester);
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    editor.controller!.text = 'unsaved';
    app.outcome = const AppSnapshot(
      configStatus: 'notSaved',
      targetId: 'local',
      resultMessage: AppMessage('configSaveFailed'),
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(SnackBar),
            matching: find.byType(IconButton),
          )
          .last,
    );
    await tester.pumpAndSettle();
    expect(editor.controller!.text, 'unsaved');
    expect(find.text('未保存修改'), findsOneWidget);
    expect(
      tester.widget<CodeEditor>(find.byType(CodeEditor)).readOnly,
      isFalse,
    );
    expect(app.commands, hasLength(1));
  });

  testWidgets('unknown result locks resubmission but retains editable draft', (
    tester,
  ) async {
    await show(tester);
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    editor.controller!.text = 'uncertain';
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(SnackBar),
            matching: find.byType(IconButton),
          )
          .last,
    );
    await tester.pumpAndSettle();
    expect(editor.controller!.text, 'uncertain');
    expect(find.text('结果未确认'), findsOneWidget);
    expect(
      tester.widget<CodeEditor>(find.byType(CodeEditor)).readOnly,
      isFalse,
    );
    editor.controller!.replaceSelection(' kept');
    expect(editor.controller!.text, contains(' kept'));
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, zh.save))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(app.commands, hasLength(1));
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('离开'));
    await tester.pumpAndSettle();
    expect(find.byType(ConfigTextPage), findsNothing);
  });

  for (final leave in [false, true]) {
    testWidgets(
      'save reply keeps the covering leave confirmation leave=$leave',
      (tester) async {
        await show(tester);
        final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
        editor.controller!.text = 'retained draft\n';
        await tester.pump(const Duration(milliseconds: 200));
        app.pending = Completer<AppSnapshot?>();
        await tester.tap(find.text(zh.save));
        await tester.pump();
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.text(zh.leaveBodyTitle), findsOneWidget);
        final confirmation = tester.element(find.byType(AlertDialog));
        publishSavedBody();
        app.pending!.complete(
          const AppSnapshot(
            configStatus: 'saved',
            resultSuccess: true,
            targetId: 'local',
            savedRevision: 2,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(tester.element(find.byType(AlertDialog)), same(confirmation));
        expect(editor.controller!.text, 'retained draft\n');
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(leave ? zh.leave : zh.cancel),
          ),
        );
        await tester.pumpAndSettle();
        if (leave) {
          expect(find.byType(ConfigTextPage), findsNothing);
          expect(find.text('打开'), findsOneWidget);
        } else {
          expect(find.byType(ConfigTextPage), findsOneWidget);
          expect(find.byType(AlertDialog), findsNothing);
          app.pending = Completer<AppSnapshot?>();
          await tester.tap(find.text(zh.save));
          await tester.pump();
          expect(app.commands.last['id'], 'local');
          expect(app.commands.last['revision'], 2);
          expect(app.commands.last['storageEpoch'], 0);
          expect(app.commands.last['body'], '\u{feff}retained draft\r\n');
          app.pending!.complete(const AppSnapshot(configStatus: 'notSaved'));
          await tester.pumpAndSettle();
          await tester.tap(
            find
                .descendant(
                  of: find.byType(SnackBar),
                  matching: find.byType(IconButton),
                )
                .last,
          );
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final unknown in [false, true]) {
    testWidgets(
      'save reply waits for the leave decision before feedback unknown=$unknown',
      (tester) async {
        await show(tester);
        final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
        editor.controller!.text = 'retained draft\n';
        await tester.pump(const Duration(milliseconds: 200));
        app.pending = Completer<AppSnapshot?>();
        await tester.tap(find.text(zh.save));
        await tester.pump();
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        final confirmation = tester.element(find.byType(AlertDialog));
        app.pending!.complete(
          unknown
              ? null
              : const AppSnapshot(
                  configStatus: 'notSaved',
                  resultMessage: AppMessage('configSaveFailed'),
                ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(tester.element(find.byType(AlertDialog)), same(confirmation));
        expect(find.text(zh.leaveBodyTitle), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(zh.cancel),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(SnackBar), findsOneWidget);
        expect(
          find.text(unknown ? zh.saveUnconfirmed : zh.configSaveFailed),
          findsOneWidget,
        );
        await tester.tap(
          find
              .descendant(
                of: find.byType(SnackBar),
                matching: find.byType(IconButton),
              )
              .last,
        );
        await tester.pumpAndSettle();
        expect(editor.controller!.text, 'retained draft\n');
        expect(
          tester.widget<CodeEditor>(find.byType(CodeEditor)).readOnly,
          isFalse,
        );
        expect(
          tester
                  .widget<TextButton>(find.widgetWithText(TextButton, zh.save))
                  .onPressed ==
              null,
          unknown,
        );
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'save reply during the editor exit animation cannot pop its successor',
    (tester) async {
      await show(tester);
      final finder = find.byType(ConfigTextPage);
      final editorState = tester.state(finder);
      final navigator = Navigator.of(tester.element(finder));
      final route = ModalRoute.of(tester.element(finder))!;
      tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!.text =
          'retained\n';
      await tester.pump(const Duration(milliseconds: 200));
      app.pending = Completer<AppSnapshot?>();
      await tester.tap(find.text(zh.save));
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(zh.leave),
        ),
      );
      await tester.pump();
      expect(route.isActive, isFalse);
      expect(
        editorState.mounted,
        isTrue,
        reason: 'The reply must arrive before editor disposal, not after pumpAndSettle.',
      );
      final successor = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Successor route')),
      );
      unawaited(navigator.push(successor));
      await tester.pump();
      expect(editorState.mounted, isTrue);
      app.pending!.complete(
        const AppSnapshot(
          configStatus: 'saved',
          resultSuccess: true,
          targetId: 'local',
          savedRevision: 2,
        ),
      );
      await tester.pump();
      expect(successor.isActive, isTrue);
      await tester.pumpAndSettle();
      expect(find.text('Successor route'), findsOneWidget);
      expect(navigator.canPop(), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late saved result after leaving does not pop another route', (
    tester,
  ) async {
    await show(tester);
    app.pending = Completer<AppSnapshot?>();
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('离开'));
    await tester.pumpAndSettle();
    app.pending!.complete(
      const AppSnapshot(
        configStatus: 'saved',
        resultSuccess: true,
        targetId: 'local',
        savedRevision: 2,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('打开'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mixed newline confirmation preserves later edits as dirty', (
    tester,
  ) async {
    await show(
      tester,
      entry: const ConfigEntry(
        id: 'local',
        name: 'Mixed',
        kind: ConfigKind.local,
        revision: 1,
        body: '\u{feff}a\r\nb\nc\r\n',
      ),
    );
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    editor.controller!.text = 'submitted\n';
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('统一换行格式？'), findsOneWidget);
    editor.controller!.text = 'later\n';
    app.outcome = const AppSnapshot(
      configStatus: 'saved',
      resultSuccess: true,
      targetId: 'local',
      savedRevision: 2,
    );
    await tester.tap(find.text('统一并保存'));
    await tester.pumpAndSettle();
    publishSavedBody();
    expect(app.commands.single['body'], '\u{feff}submitted\r\n');
    expect(find.byType(ConfigTextPage), findsOneWidget);
    await tester.tap(
      find
          .descendant(
            of: find.byType(SnackBar),
            matching: find.byType(IconButton),
          )
          .last,
    );
    await tester.pumpAndSettle();
    expect(editor.controller!.text, 'later\n');
    expect(find.text('未保存修改'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(app.commands, hasLength(2));
    expect(app.commands.last['revision'], 2);
    expect(app.commands.last['body'], '\u{feff}later\r\n');
    expect(find.byType(ConfigTextPage), findsNothing);
  });

  testWidgets(
    'oversized input is retained, rejected and recovers when restored',
    (tester) async {
      await show(tester, entry: null);
      await tester.tap(find.byTooltip('自动换行'));
      await tester.pump();
      final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
      final text = '${('${'a' * 4095}\n') * (maxConfigBytes ~/ 4096)}x';
      editor.controller!.text = text;
      await tester.pump(const Duration(milliseconds: 160));
      for (
        var i = 0;
        i < 500 && find.text('超过 16 MiB · 未截断').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(find.text('超过 16 MiB · 未截断'), findsOneWidget);
      expect(editor.controller!.text, text);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(app.commands, isEmpty);
      expect(find.text('配置正文超过 16 MiB，未保存。'), findsOneWidget);
      await tester.tap(
        find
            .descendant(
              of: find.byType(SnackBar),
              matching: find.byType(IconButton),
            )
            .last,
      );
      await tester.pumpAndSettle();
      editor.controller!.text = '';
      await tester.pump(const Duration(milliseconds: 160));
      expect(find.text('超过 16 MiB · 未截断'), findsNothing);
      expect(find.text('配置正文'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存修改？'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'literal find navigates matches and restores selection without edits',
    (tester) async {
      await show(tester, entry: null, initial: 'a.b\naXb\na.b\n');
      final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
      final selection = editor.controller!.selection;
      await tester.tap(find.byTooltip('查找'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'a.b');
      for (
        var i = 0;
        i < 500 && editor.findController!.value?.result?.matches.length != 2;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await tester.pump();
      final search = editor.findController!;
      expect(search.value!.option.regex, isFalse);
      expect(search.value!.result!.matches, hasLength(2));
      final index = search.value!.result!.index;
      expect(find.text('${index + 1}/2'), findsOneWidget);
      await tester.tap(find.byTooltip('下一个'));
      await tester.pump();
      expect(search.value!.result!.index, (index + 1) % 2);
      await tester.tap(find.byTooltip('上一个'));
      await tester.pump();
      expect(search.value!.result!.index, index);
      await tester.tap(find.byTooltip('关闭查找'));
      await tester.pumpAndSettle();
      expect(editor.controller!.selection, selection);
      expect(editor.controller!.text, 'a.b\naXb\na.b\n');
      expect(editor.focusNode!.hasFocus, isFalse);
      expect(find.text('未保存修改'), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存修改？'), findsNothing);
    },
  );

  for (final width in [320.0, 411.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('large find count stays readable and stable $width $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await show(tester, entry: null, initial: 'x\n' * 16383, scale: scale);
        final editorFinder = find.byType(CodeEditor);
        final editor = tester.widget<CodeEditor>(editorFinder);
        final before = tester.getRect(editorFinder);
        await tester.tap(find.byTooltip('查找'));
        await tester.pumpAndSettle();
        final opened = tester.getRect(editorFinder);
        expect(opened.left, before.left);
        expect(opened.right, before.right);
        expect(opened.bottom, before.bottom);
        await tester.enterText(find.byType(TextField), 'x');
        for (
          var i = 0;
          i < 500 &&
              editor.findController!.value?.result?.matches.length != 16383;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 20));
          expect(tester.getRect(editorFinder), opened);
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(editor.findController!.value!.result!.matches, hasLength(16383));
        await tester.tap(find.byTooltip('上一个'));
        await tester.pumpAndSettle();
        expect(editor.findController!.value!.result!.index, 16382);
        final label = find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              widget.data?.replaceAll('\n', '') == '16383/16383',
        );
        expect(label, findsOneWidget);
        final text = tester.widget<Text>(label);
        final context = tester.element(label);
        final painter = TextPainter(
          text: TextSpan(
            text: text.data,
            style: DefaultTextStyle.of(context).style.merge(text.style),
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: text.maxLines,
        )..layout(maxWidth: tester.getSize(label).width);
        expect(painter.didExceedMaxLines, isFalse);
        expect(painter.height, lessThanOrEqualTo(tester.getSize(label).height));
        painter.dispose();
        expect(tester.getRect(editorFinder), opened);
        await tester.tap(find.byTooltip('关闭查找'));
        for (var frame = 0; frame < 14; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final closing = tester.getRect(editorFinder);
          expect(closing.left, before.left);
          expect(closing.right, before.right);
          expect(closing.bottom, before.bottom);
          expect(closing.top, inInclusiveRange(before.top, opened.top));
          expect(tester.state(editorFinder).mounted, isTrue);
          expect(
            tester.widget<CodeEditor>(editorFinder).controller,
            same(editor.controller),
          );
          expect(tester.takeException(), isNull);
        }
        expect(tester.getRect(editorFinder), before);
      });
    }
  }

  for (final dark in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'save action retains geometry through apply states $dark $scale',
        (tester) async {
          tester.view.physicalSize = const Size(320, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final entry = local.renamed('长配置名称 English 🌐 ' * 4);
          await show(
            tester,
            entry: entry,
            theme: dark ? AppTheme.dark : AppTheme.light,
            scale: scale,
          );
          final action = find.descendant(
            of: find.byType(AppBar),
            matching: find.byType(TextButton),
          );
          final buttonRect = tester.getRect(action);
          final titleRect = tester.getRect(find.text(entry.name));
          final editorRect = tester.getRect(find.byType(CodeEditor));
          Future<void> checkFrames() async {
            for (final ms in [0, 16, 80, 180]) {
              await tester.pump(Duration(milliseconds: ms));
              expect(tester.getRect(action), buttonRect);
              expect(tester.getRect(find.text(entry.name)), titleRect);
              expect(tester.getRect(find.byType(CodeEditor)), editorRect);
              expect(tester.takeException(), isNull);
            }
          }

          const running = AppSnapshot(
            phase: 'RUNNING',
            configId: 'local',
            revision: 1,
          );
          app.updateState(running);
          await checkFrames();
          expect(find.text('保存并应用'), findsOneWidget);
          expect(find.text('保存'), findsNothing);
          app.pending = Completer<AppSnapshot?>();
          await tester.tap(action);
          await checkFrames();
          expect(tester.widget<TextButton>(action).onPressed, isNull);
          for (final phase in ['STOPPING', 'STOPPED', 'STARTING', 'STOPPED']) {
            app.updateState(AppSnapshot(phase: phase, configId: 'local'));
            await checkFrames();
          }
          publishSavedBody();
          app.pending!.complete(
            const AppSnapshot(
              configStatus: 'applyFailed',
              targetId: 'local',
              savedRevision: 2,
              resultMessage: AppMessage('configSavedApplyReleasePending'),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(SnackBar), findsOneWidget);
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.text('已保存，应用未完成'), findsOneWidget);
          await tester.tap(
            find
                .descendant(
                  of: find.byType(SnackBar),
                  matching: find.byType(IconButton),
                )
                .last,
          );
          await tester.pumpAndSettle();
          await checkFrames();
          expect(find.text('保存'), findsOneWidget);
          expect(find.text('保存并应用'), findsNothing);
          expect(tester.widget<TextButton>(action).onPressed, isNotNull);
          app.updateState(running);
          await checkFrames();
          app.pending = Completer<AppSnapshot?>();
          await tester.tap(action);
          await checkFrames();
          app.pending!.complete(
            const AppSnapshot(
              configStatus: 'applied',
              resultSuccess: true,
              targetId: 'local',
              savedRevision: 2,
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(ConfigTextPage), findsNothing);
          expect(app.commands, hasLength(2));
        },
      );
      testWidgets(
        'search toolbar keeps editor position dark=$dark scale=$scale',
        (tester) async {
          tester.view.physicalSize = const Size(320, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await show(
            tester,
            entry: ConfigEntry(
              id: local.id,
              name: local.name,
              kind: local.kind,
              revision: local.revision,
              body:
                  '${local.body}'
                  '${List.generate(80, (index) => 'fixture line $index').join('\r\n')}\r\n',
            ),
            theme: dark ? AppTheme.dark : AppTheme.light,
            scale: scale,
          );
          final editor = find.byType(CodeEditor);
          final editorState = tester.state(editor);
          final editorWidget = tester.widget<CodeEditor>(editor);
          final controller = editorWidget.controller!;
          controller.text = '${controller.text}\nextra';
          controller.selection = const CodeLineSelection.collapsed(
            index: 2,
            offset: 2,
          );
          await tester.pump(const Duration(milliseconds: 200));
          final scroller = tester
              .stateList<ScrollableState>(
                find.descendant(of: editor, matching: find.byType(Scrollable)),
              )
              .singleWhere(
                (state) => state.widget.axisDirection == AxisDirection.down,
              );
          final position = scroller.position;
          expect(position.maxScrollExtent, greaterThan(200));
          position.jumpTo(200);
          await tester.pump();
          final offset = position.pixels;
          var body = controller.value;
          final canUndo = controller.canUndo;
          final canRedo = controller.canRedo;
          expect(canUndo, isTrue);
          final toolbar = find.byKey(const ValueKey('editor-toolbar-size'));
          final counter = find.byKey(
            const ValueKey('editor-find-counter'),
            skipOffstage: false,
          );
          final closed = tester.getRect(toolbar);
          final before = tester.getRect(editor);
          final expandedHeight = 56 + tester.getSize(counter).height;
          expect(expandedHeight, greaterThan(closed.height));
          final input = find.byType(TextField, skipOffstage: false);
          final inputState = tester.state(input);
          final field = tester.widget<TextField>(input);
          final query = field.controller!;
          final queryFocus = field.focusNode!;
          final editable = find.descendant(
            of: input,
            matching: find.byType(EditableText, skipOffstage: false),
            skipOffstage: false,
          );
          final editableState = tester.state(editable);
          var expectedQuery = query.value;
          void checkFrame(
            String phase, {
            bool? queryFocused,
            bool checkIme = false,
          }) {
            final currentToolbar = tester.getRect(toolbar);
            final currentEditor = tester.getRect(editor);
            final details =
                '$phase: toolbar=$currentToolbar, editor=$currentEditor, '
                'scroll=${position.pixels}, expandedHeight=$expandedHeight';
            expect(tester.takeException(), isNull, reason: details);
            expect(currentToolbar.top, closed.top, reason: details);
            expect(currentEditor.left, before.left, reason: details);
            expect(currentEditor.right, before.right, reason: details);
            expect(currentEditor.bottom, before.bottom, reason: details);
            expect(
              currentEditor.top,
              closeTo(currentToolbar.bottom, 0.001),
              reason: details,
            );
            expect(
              currentEditor.height + currentToolbar.height,
              closeTo(before.height + closed.height, 0.001),
              reason: details,
            );
            expect(
              currentToolbar.height,
              inInclusiveRange(closed.height - 0.001, expandedHeight + 0.001),
              reason: details,
            );
            expect(tester.state(editor), same(editorState), reason: details);
            final current = tester.widget<CodeEditor>(editor);
            expect(current.controller, same(controller), reason: details);
            expect(
              current.focusNode,
              same(editorWidget.focusNode),
              reason: details,
            );
            expect(controller.codeLines, same(body.codeLines), reason: details);
            expect(controller.selection, body.selection, reason: details);
            expect(controller.composing, body.composing, reason: details);
            expect(controller.canUndo, canUndo, reason: details);
            expect(controller.canRedo, canRedo, reason: details);
            expect(tester.state(input), same(inputState), reason: details);
            expect(
              tester.state(editable),
              same(editableState),
              reason: details,
            );
            expect(tester.widget<TextField>(input).controller, same(query));
            expect(tester.widget<TextField>(input).focusNode, same(queryFocus));
            expect(query.value, expectedQuery, reason: details);
            if (queryFocused != null) {
              expect(queryFocus.hasFocus, queryFocused, reason: details);
            }
            expect(scroller.position, same(position), reason: details);
            expect(position.pixels, offset, reason: details);
            if (checkIme) {
              expect(
                tester.testTextInput.hasAnyClients,
                isTrue,
                reason: details,
              );
              expect(
                tester.testTextInput.log.where(
                  (call) =>
                      call.method == 'TextInput.setClient' ||
                      call.method == 'TextInput.clearClient',
                ),
                isEmpty,
                reason: details,
              );
            }
            for (final tooltip in [
              zh.previousMatch,
              zh.nextMatch,
              zh.closeFind,
            ]) {
              final button = find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == tooltip,
                skipOffstage: false,
              );
              final size = tester.getSize(button);
              expect(size.width, greaterThanOrEqualTo(48), reason: details);
              expect(size.height, greaterThanOrEqualTo(48), reason: details);
            }
          }

          checkFrame('closed initial', queryFocused: false);
          await tester.tap(find.byTooltip(zh.find));
          await tester.pump();
          expectedQuery = query.value;
          expect(expectedQuery.text, isEmpty);
          expect(
            expectedQuery.selection,
            const TextSelection.collapsed(offset: 0),
          );
          checkFrame('expand first frame');
          expect(tester.getSize(toolbar).height, closed.height);
          await tester.showKeyboard(input);
          const composing = TextEditingValue(
            text: 'zz\u{1f33a}',
            selection: TextSelection.collapsed(offset: 4),
            composing: TextRange(start: 0, end: 4),
          );
          tester.testTextInput.updateEditingValue(composing);
          controller.composing = const TextRange(start: 0, end: 2);
          body = controller.value;
          expectedQuery = composing;
          await tester.pump();
          tester.testTextInput.log.clear();
          var previousHeight = closed.height;
          for (var i = 0; i < 14; i++) {
            await tester.pump(const Duration(milliseconds: 16));
            checkFrame('expand frame $i', queryFocused: true, checkIme: true);
            final height = tester.getSize(toolbar).height;
            expect(height, greaterThanOrEqualTo(previousHeight));
            if (i == 0 || i == 4) {
              expect(height, greaterThan(closed.height));
              expect(height, lessThan(expandedHeight));
            }
            previousHeight = height;
          }
          expect(previousHeight, closeTo(expandedHeight, 0.001));
          await tester.tap(find.byTooltip(zh.closeFind));
          await tester.pump();
          expectedQuery = query.value;
          expect(expectedQuery.text, composing.text);
          expect(expectedQuery.selection, composing.selection);
          checkFrame('collapse first frame', queryFocused: false);
          expect(
            tester.getSize(toolbar).height,
            closeTo(expandedHeight, 0.001),
          );
          await tester.pump(const Duration(milliseconds: 48));
          checkFrame('collapse before reversal', queryFocused: false);
          final reversingHeight = tester.getSize(toolbar).height;
          expect(reversingHeight, greaterThan(closed.height));
          expect(reversingHeight, lessThan(expandedHeight));
          await tester.tap(find.byTooltip(zh.find));
          await tester.pump();
          expectedQuery = query.value;
          expect(expectedQuery.text, composing.text);
          expect(
            expectedQuery.selection,
            const TextSelection(baseOffset: 0, extentOffset: 4),
          );
          checkFrame('reverse first frame');
          expect(
            tester.getSize(toolbar).height,
            closeTo(reversingHeight, 0.001),
          );
          await tester.showKeyboard(input);
          tester.testTextInput.updateEditingValue(composing);
          expectedQuery = composing;
          await tester.pump();
          tester.testTextInput.log.clear();
          previousHeight = reversingHeight;
          for (var i = 0; i < 14; i++) {
            await tester.pump(const Duration(milliseconds: 16));
            checkFrame(
              'reverse expand frame $i',
              queryFocused: true,
              checkIme: true,
            );
            final height = tester.getSize(toolbar).height;
            expect(height, greaterThanOrEqualTo(previousHeight));
            previousHeight = height;
          }
          expect(previousHeight, closeTo(expandedHeight, 0.001));
          await tester.tap(find.byTooltip(zh.closeFind));
          await tester.pump();
          expectedQuery = query.value;
          expect(expectedQuery.text, composing.text);
          expect(expectedQuery.selection, composing.selection);
          checkFrame('final collapse first frame', queryFocused: false);
          previousHeight = tester.getSize(toolbar).height;
          for (var i = 0; i < 14; i++) {
            await tester.pump(const Duration(milliseconds: 16));
            checkFrame('final collapse frame $i', queryFocused: false);
            final height = tester.getSize(toolbar).height;
            expect(height, lessThanOrEqualTo(previousHeight));
            previousHeight = height;
          }
          expect(previousHeight, closeTo(closed.height, 0.001));
          expect(tester.getRect(editor), before);
          expect(app.commands, isEmpty);
        },
      );
    }
  }
}
