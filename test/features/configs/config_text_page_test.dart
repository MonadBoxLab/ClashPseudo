import 'dart:async';

import 'package:clash_pseudo/app/app_controller.dart';
import 'package:clash_pseudo/app/app_theme.dart';
import 'package:clash_pseudo/features/configs/config_entry.dart';
import 'package:clash_pseudo/features/configs/config_text.dart';
import 'package:clash_pseudo/features/configs/config_text_page.dart';
import 'package:clash_pseudo/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

class EditorApp extends AppController {
  EditorApp() : super(AppBridge()) {
    loading = false;
    configsLoaded = true;
    state = const AppSnapshot(phase: 'STOPPED');
  }
  final commands = <Map<String, Object?>>[];
  Completer<AppSnapshot?>? pending;
  AppSnapshot? outcome;

  void updateState(AppSnapshot value) {
    state = value;
    notifyListeners();
  }

  @override
  Future<AppSnapshot?> saveLocal(Map<String, Object?> command) async {
    commands.add(command);
    return pending == null ? outcome : pending!.future;
  }
}

void main() {
  const local = ConfigEntry(
    id: 'local',
    name: 'Local',
    kind: ConfigKind.local,
    revision: 1,
    body: '\u{feff}a\r\nb\r\n',
  );
  late EditorApp app;

  Future<void> show(
    WidgetTester tester, {
    ConfigEntry? entry = local,
    String initial = '',
    ThemeData? theme,
    double scale = 1,
  }) async {
    app = EditorApp();
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
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
    await tester.tap(find.text('关闭'));
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
    app.pending!.complete(
      const AppSnapshot(
        configStatus: 'applyFailed',
        targetId: 'local',
        savedRevision: 2,
        resultMessage: '新正文已保存，启动失败。',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已保存，应用未完成'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<CodeEditor>(find.byType(CodeEditor)).readOnly,
      isFalse,
    );
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
    await tester.tap(find.text('关闭'));
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
      resultMessage: '写入失败',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(editor.controller!.text, 'unsaved');
    expect(find.text('未保存修改'), findsOneWidget);
    expect(
      tester.widget<CodeEditor>(find.byType(CodeEditor)).readOnly,
      isFalse,
    );
    expect(app.commands, hasLength(1));
  });

  testWidgets('unknown result locks resubmission but allows leaving', (
    tester,
  ) async {
    await show(tester);
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    editor.controller!.text = 'uncertain';
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(editor.controller!.text, 'uncertain');
    expect(find.text('结果未确认'), findsOneWidget);
    expect(tester.widget<CodeEditor>(find.byType(CodeEditor)).readOnly, isTrue);
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(app.commands, hasLength(1));
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('离开'));
    await tester.pumpAndSettle();
    expect(find.byType(ConfigTextPage), findsNothing);
  });

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
    expect(find.text('统一混合换行？'), findsOneWidget);
    editor.controller!.text = 'later\n';
    app.outcome = const AppSnapshot(
      configStatus: 'saved',
      targetId: 'local',
      savedRevision: 2,
    );
    await tester.tap(find.text('统一并保存'));
    await tester.pumpAndSettle();
    expect(app.commands.single['body'], '\u{feff}submitted\r\n');
    expect(find.byType(ConfigTextPage), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(editor.controller!.text, 'later\n');
    expect(find.text('未保存修改'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(app.commands.last['revision'], 2);
    expect(app.commands.last['body'], '\u{feff}later\r\n');
    expect(find.byType(ConfigTextPage), findsNothing);
  });

  testWidgets(
    'oversized input is retained, rejected and recovers when restored',
    (tester) async {
      await show(tester, entry: null);
      await tester.tap(find.byTooltip('软换行'));
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
      await tester.tap(find.text('关闭'));
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
        await tester.enterText(find.byType(TextField), 'x');
        for (
          var i = 0;
          i < 500 &&
              editor.findController!.value?.result?.matches.length != 16383;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 20));
          expect(tester.getRect(editorFinder), before);
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
        expect(tester.getRect(editorFinder), before);
        await tester.tap(find.byTooltip('关闭查找'));
        for (var frame = 0; frame < 14; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.getRect(editorFinder), before);
          expect(tester.takeException(), isNull);
        }
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
          app.pending!.complete(
            const AppSnapshot(
              configStatus: 'applyFailed',
              targetId: 'local',
              savedRevision: 2,
              resultMessage: '正文已保存，启动失败。',
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('已保存，应用未完成'), findsOneWidget);
          await tester.tap(find.text('关闭'));
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
            theme: dark ? AppTheme.dark : AppTheme.light,
            scale: scale,
          );
          final before = tester.getRect(find.byType(CodeEditor));
          await tester.tap(find.byTooltip('查找'));
          for (var i = 0; i < 14; i++) {
            await tester.pump(const Duration(milliseconds: 16));
            expect(tester.getRect(find.byType(CodeEditor)), before);
            expect(tester.takeException(), isNull);
          }
          await tester.tap(find.byTooltip('关闭查找'));
          await tester.pump();
          expect(tester.getRect(find.byType(CodeEditor)), before);
        },
      );
    }
  }
}
