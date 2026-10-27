import 'dart:async';

import 'package:clash_pseudo/src/app/app_shell.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/configs/config_text_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import 'editor_fakes.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late EditorApp app;
  String? clipboard;
  const original = '\u{feff}a\r\nb\r\n';

  setUp(() {
    clipboard = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            clipboard = (call.arguments as Map)['text'] as String;
          case 'Clipboard.getData':
            return {'text': clipboard};
          case 'Clipboard.hasStrings':
            return {'value': clipboard?.isNotEmpty ?? false};
        }
        return null;
      },
    );
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  Future<CodeEditor> show(WidgetTester tester) async {
    const entry = ConfigEntry(
      id: 'local',
      name: 'Local',
      kind: ConfigKind.local,
      revision: 1,
      body: original,
    );
    app = EditorApp(entries: [entry]);
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => ConfigTextPage(app: app, entry: entry),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    final focus = tester.widget<Focus>(
      find.descendant(
        of: find.byType(CodeEditor),
        matching: find.byWidgetPredicate(
          (widget) => widget is Focus && widget.debugLabel == 'CodeEditor',
        ),
      ),
    );
    // 移动分支保留其Backspace／Enter处理，明确区分桌面测试路径。
    expect(focus.onKeyEvent, isNotNull);
    editor.focusNode!.requestFocus();
    await tester.pump();
    return editor;
  }

  Future<void> key(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    LogicalKeyboardKey modifier = LogicalKeyboardKey.controlLeft,
    bool shift = false,
  }) async {
    await tester.sendKeyDownEvent(modifier);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(modifier);
    await tester.pumpAndSettle();
  }

  Future<void> settleFind(
    WidgetTester tester,
    CodeFindController controller,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (controller.value?.searching == true &&
        DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pumpAndSettle();
    expect(controller.value?.searching, isFalse);
  }

  Future<CodeEditor> showWideShell(WidgetTester tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(3408, 2272);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    app = EditorApp(
      entries: const [
        ConfigEntry(
          id: 'local',
          name: 'Local',
          kind: ConfigKind.local,
          revision: 1,
          body: original,
        ),
      ],
    );
    addTearDown(app.dispose);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        theme: ThemeData.dark(),
        home: AppShell(controller: app),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('Configs'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit configuration'));
    await tester.pumpAndSettle();
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    expect(editor.readOnly, isFalse);
    return editor;
  }

  testWidgets('Android wide shell routes clipboard keys to the focused body', (
    tester,
  ) async {
    final editor = await showWideShell(tester);
    editor.focusNode!.requestFocus();
    await tester.pump();
    await key(tester, LogicalKeyboardKey.keyF);
    await tester.enterText(find.byType(TextField), 'a');
    await settleFind(tester, editor.findController!);
    expect(find.text('1/1'), findsOneWidget);
    editor.focusNode!.requestFocus();
    editor.controller!.selection = const CodeLineSelection(
      baseIndex: 0,
      baseOffset: 0,
      extentIndex: 0,
      extentOffset: 1,
    );
    await tester.pump();
    await key(tester, LogicalKeyboardKey.keyX);
    expect(editor.controller!.text, '\nb\n');
    await settleFind(tester, editor.findController!);
    expect(find.text('0/0'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.keyV);
    expect(editor.controller!.text, 'a\nb\n');
    await key(tester, LogicalKeyboardKey.keyZ);
    expect(editor.controller!.text, '\nb\n');
    await key(tester, LogicalKeyboardKey.keyZ, shift: true);
    expect(editor.controller!.text, 'a\nb\n');
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'Android system back closes find then guards the owning shell editor',
    (tester) async {
      final editor = await showWideShell(tester);
      final strings = AppLocalizations.of(
        tester.element(find.byType(ConfigTextPage)),
      );
      editor.controller!.text = 'retained draft';
      editor.focusNode!.requestFocus();
      await tester.pump();
      await key(tester, LogicalKeyboardKey.keyF);
      expect(find.byTooltip(strings.closeFind), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byTooltip(strings.closeFind), findsNothing);
      expect(find.byType(ConfigTextPage), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(editor.controller!.text, 'retained draft');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text(strings.continueEditing));
      await tester.pumpAndSettle();
      expect(find.byType(ConfigTextPage), findsOneWidget);
      expect(editor.controller!.text, 'retained draft');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text(strings.discard));
      await tester.pumpAndSettle();
      expect(find.byType(ConfigTextPage), findsNothing);
      expect(find.byType(AppShell), findsOneWidget);
      expect(app.commands, isEmpty);
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(
        (rail.destinations[rail.selectedIndex!].label as Text).data,
        'Configs',
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      final overview = tester.widget<NavigationRail>(
        find.byType(NavigationRail),
      );
      expect(
        (overview.destinations[overview.selectedIndex!].label as Text).data,
        strings.overview,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  test('selection and composing retain text history until an actual edit', () {
    final controller = CodeLineEditingController.fromText('one');
    addTearDown(controller.dispose);
    controller.composing = const TextRange(start: 0, end: 3);
    expect(controller.canUndo, isFalse);
    controller.text = 'two';
    controller.undo();
    expect(controller.text, 'one');
    controller.selection = const CodeLineSelection.collapsed(
      index: 0,
      offset: 2,
    );
    controller.composing = const TextRange(start: 0, end: 3);
    controller.clearComposing();
    expect(controller.canRedo, isTrue);
    controller.redo();
    expect(controller.text, 'two');
    controller.undo();
    expect(controller.text, 'one');
    controller.replaceSelection('!');
    expect(controller.text, 'on!e');
    expect(controller.canRedo, isFalse);
  });

  testWidgets('Android clipboard and history shortcuts respect readonly', (
    tester,
  ) async {
    final editor = await show(tester);
    final controller = editor.controller!;
    controller.selection = const CodeLineSelection(
      baseIndex: 0,
      baseOffset: 0,
      extentIndex: 0,
      extentOffset: 1,
    );
    await tester.pump();
    await key(tester, LogicalKeyboardKey.keyC);
    expect(clipboard, 'a');
    expect(controller.text, 'a\nb\n');
    await key(tester, LogicalKeyboardKey.keyX);
    expect(clipboard, 'a');
    expect(controller.text, '\nb\n');
    await key(tester, LogicalKeyboardKey.keyV);
    expect(controller.text, 'a\nb\n');
    await key(tester, LogicalKeyboardKey.keyZ);
    expect(controller.text, '\nb\n');
    await key(tester, LogicalKeyboardKey.keyZ, shift: true);
    expect(controller.text, 'a\nb\n');

    app.pending = Completer<AppSnapshot?>();
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(tester.widget<CodeEditor>(find.byType(CodeEditor)).readOnly, isTrue);
    editor.focusNode!.requestFocus();
    await tester.pump();
    controller.selectAll();
    await tester.pump();
    final before = controller.value;
    clipboard = 'replacement';
    for (final action in [
      LogicalKeyboardKey.keyX,
      LogicalKeyboardKey.keyV,
      LogicalKeyboardKey.keyZ,
    ]) {
      await key(tester, action);
      expect(controller.value, same(before));
    }
    for (final action in [
      LogicalKeyboardKey.backspace,
      LogicalKeyboardKey.enter,
    ]) {
      await tester.sendKeyEvent(action);
      await tester.pump();
      expect(controller.value, same(before));
    }
    await key(tester, LogicalKeyboardKey.keyZ, shift: true);
    expect(controller.value, same(before));
    expect(clipboard, 'replacement');
    await key(tester, LogicalKeyboardKey.keyC);
    expect(clipboard, 'a\nb\n');
    app.pending!.complete(const AppSnapshot(configStatus: 'notSaved'));
    await tester.pumpAndSettle();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Android backspace and enter act once per down or repeat', (
    tester,
  ) async {
    final editor = await show(tester);
    final controller = editor.controller!;
    controller.text = 'abc\nb\n';
    controller.selection = const CodeLineSelection(
      baseIndex: 0,
      baseOffset: 3,
      extentIndex: 0,
      extentOffset: 3,
    );
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(controller.text, 'ab\nb\n');
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(controller.text, 'a\nb\n');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(controller.text, 'a\nb\n');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(controller.text, 'a\n\nb\n');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.text, 'a\n\nb\n');
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'Android explicit edits commit composing before clipboard and history',
    (tester) async {
      final editor = await show(tester);
      final controller = editor.controller!;
      controller.text = 'original';
      controller.selection = const CodeLineSelection.collapsed(
        index: 0,
        offset: 8,
      );
      controller.composing = const TextRange(start: 0, end: 8);
      clipboard = 'x';
      await tester.pump();
      await key(tester, LogicalKeyboardKey.keyV);
      expect(controller.text, 'originalx');
      expect(controller.composing, TextRange.empty);
      controller.composing = const TextRange(start: 0, end: 9);
      await key(tester, LogicalKeyboardKey.keyZ);
      expect(controller.text, 'original');
      controller.composing = const TextRange(start: 0, end: 8);
      await key(tester, LogicalKeyboardKey.keyZ, shift: true);
      expect(controller.text, 'originalx');
      controller.selection = const CodeLineSelection(
        baseIndex: 0,
        baseOffset: 0,
        extentIndex: 0,
        extentOffset: 8,
      );
      controller.composing = const TextRange(start: 0, end: 8);
      await key(tester, LogicalKeyboardKey.keyX);
      expect(controller.text, 'x');
      expect(controller.composing, TextRange.empty);
      expect(clipboard, 'original');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Android selection toolbar survives rebuild as one owned overlay',
    (tester) async {
      final editor = await show(tester);
      final toolbar = editor.toolbarController!;
      final visibility = ValueNotifier(true);
      addTearDown(visibility.dispose);
      void open(CodeEditor current) => current.toolbarController!.show(
        context: tester.element(find.byType(CodeEditor)),
        controller: current.controller!,
        anchors: const TextSelectionToolbarAnchors(
          primaryAnchor: Offset(150, 250),
        ),
        renderRect: tester.getRect(find.byType(CodeEditor)),
        layerLink: LayerLink(),
        visibility: visibility,
      );
      open(editor);
      await tester.pumpAndSettle();
      expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
      app.updateState(app.state);
      await tester.pumpAndSettle();
      final rebuilt = tester.widget<CodeEditor>(find.byType(CodeEditor));
      expect(rebuilt.toolbarController, same(toolbar));
      open(rebuilt);
      await tester.pumpAndSettle();
      expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(ConfigTextPage), findsNothing);
      expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Android stale selection menu closes and revokes editing actions',
    (tester) async {
      final editor = await show(tester);
      editor.controller!.selectAll();
      await tester.pump();
      final visibility = ValueNotifier(true);
      addTearDown(visibility.dispose);
      editor.toolbarController!.show(
        context: tester.element(find.byType(CodeEditor)),
        controller: editor.controller!,
        anchors: const TextSelectionToolbarAnchors(
          primaryAnchor: Offset(150, 250),
        ),
        renderRect: tester.getRect(find.byType(CodeEditor)),
        layerLink: LayerLink(),
        visibility: visibility,
      );
      await tester.pumpAndSettle();
      final menu = tester.widget<AdaptiveTextSelectionToolbar>(
        find.byType(AdaptiveTextSelectionToolbar),
      );
      final cut = menu.buttonItems!
          .singleWhere((item) => item.type == ContextMenuButtonType.cut)
          .onPressed;
      final paste = menu.buttonItems!
          .singleWhere((item) => item.type == ContextMenuButtonType.paste)
          .onPressed;
      app.collection = app.collection.replace(
        const ConfigEntry(
          id: 'local',
          name: 'Local',
          kind: ConfigKind.local,
          revision: 2,
          body: 'new source',
        ),
      );
      app.updateState(app.state);
      await tester.pumpAndSettle();
      expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
      clipboard = 'replacement';
      cut!();
      paste!();
      await tester.pumpAndSettle();
      expect(editor.controller!.text, 'a\nb\n');
      expect(clipboard, 'replacement');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final modifier in [
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.metaLeft,
  ]) {
    testWidgets('Android task shortcuts retain page actions with $modifier', (
      tester,
    ) async {
      final editor = await show(tester);
      await key(tester, LogicalKeyboardKey.keyF, modifier: modifier);
      expect(find.byTooltip('关闭查找'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byTooltip('查找'), findsOneWidget);
      editor.focusNode!.requestFocus();
      await tester.pump();
      app.pending = Completer<AppSnapshot?>();
      await key(tester, LogicalKeyboardKey.keyS, modifier: modifier);
      expect(app.commands.single['body'], original);
      await key(tester, LogicalKeyboardKey.keyS, modifier: modifier);
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
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}
