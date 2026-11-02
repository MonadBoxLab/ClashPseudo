import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/configs/editor/config_text_page.dart';
import 'package:flutter/material.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import 'editor_fakes.dart' show EditorApp;

void main() {
  Future<EditorApp> mountToolbar(
    WidgetTester tester,
    ValueNotifier<bool> reduced, {
    String text = 'fixture',
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final app = EditorApp();
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [AppTaskNavigatorObserver()],
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        builder: (context, child) => ValueListenableBuilder<bool>(
          valueListenable: reduced,
          builder: (context, value, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: value),
            child: child!,
          ),
          child: child,
        ),
        home: ConfigTextPage(app: app, initialText: text),
      ),
    );
    await tester.pumpAndSettle();
    return app;
  }

  testWidgets('reduced narrow find height changes without an AnimatedSize', (
    tester,
  ) async {
    final reduced = ValueNotifier(true);
    addTearDown(reduced.dispose);
    final app = await mountToolbar(tester, reduced);
    final toolbar = find.byKey(const ValueKey('editor-toolbar-size'));
    final input = find.byType(TextField, skipOffstage: false);
    final inputState = tester.state(input);
    final editor = find.byType(CodeEditor);
    final editorState = tester.state(editor);
    final controller = tester.widget<CodeEditor>(editor).controller!;
    expect(tester.getSize(toolbar).height, 56);
    for (var cycle = 0; cycle < 3; cycle++) {
      await tester.tap(find.byTooltip('Find'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final countHeight = tester
          .getSize(find.byKey(const ValueKey('editor-find-counter')))
          .height;
      expect(tester.getSize(toolbar).height, 56 + countHeight);
      expect(
        tester.widget<SizedBox>(toolbar).child,
        isNot(isA<AnimatedSize>()),
      );
      expect(tester.state(input), same(inputState));
      await tester.tap(find.byTooltip('Close find'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(toolbar).height, 56);
      expect(tester.state(input), same(inputState));
      expect(tester.state(editor), same(editorState));
      expect(tester.widget<CodeEditor>(editor).controller, same(controller));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(app.commands, isEmpty);
  });

  testWidgets(
    'changing reduced motion during find preserves live editor state',
    (tester) async {
      final reduced = ValueNotifier(false);
      addTearDown(reduced.dispose);
      final original = List.generate(
        80,
        (index) => 'fixture line $index',
      ).join('\n');
      final app = await mountToolbar(tester, reduced, text: original);
      final toolbar = find.byKey(const ValueKey('editor-toolbar-size'));
      final editor = find.byType(CodeEditor);
      final editorState = tester.state(editor);
      final widget = tester.widget<CodeEditor>(editor);
      final controller = widget.controller!;
      controller.text = '$original\nextra';
      controller.selection = const CodeLineSelection.collapsed(
        index: 0,
        offset: 2,
      );
      widget.focusNode!.requestFocus();
      await tester.pump();
      await tester.tap(find.byTooltip('Find'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 48));
      expect(tester.getSize(toolbar).height, greaterThan(56));
      expect(tester.getSize(toolbar).height, lessThan(104));
      expect(tester.takeException(), isNull);
      final input = find.byType(TextField, skipOffstage: false);
      final inputState = tester.state(input);
      final field = tester.widget<TextField>(input);
      final query = field.controller!;
      final queryFocus = field.focusNode!;
      final editable = find.descendant(
        of: input,
        matching: find.byType(EditableText),
      );
      final editableState = tester.state(editable);
      await tester.showKeyboard(input);
      const composing = TextEditingValue(
        text: 'zzz',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 0, end: 3),
      );
      tester.testTextInput.updateEditingValue(composing);
      controller.composing = const TextRange(start: 0, end: 2);
      await tester.pump();
      final body = controller.value;
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
      expect(controller.canUndo, isTrue);
      final canRedo = controller.canRedo;
      for (final value in [true, false, true, false]) {
        tester.testTextInput.log.clear();
        reduced.value = value;
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(tester.getSize(toolbar).height, 104);
        final child = tester.widget<SizedBox>(toolbar).child;
        if (value) {
          expect(child, isNot(isA<AnimatedSize>()));
        } else {
          expect(child, isA<AnimatedSize>());
          expect(
            (child! as AnimatedSize).duration,
            const Duration(milliseconds: 160),
          );
        }
        expect(tester.state(editor), same(editorState));
        expect(tester.widget<CodeEditor>(editor).controller, same(controller));
        expect(
          tester.widget<CodeEditor>(editor).focusNode,
          same(widget.focusNode),
        );
        expect(tester.state(input), same(inputState));
        expect(tester.state(editable), same(editableState));
        expect(tester.widget<TextField>(input).controller, same(query));
        expect(tester.widget<TextField>(input).focusNode, same(queryFocus));
        expect(queryFocus.hasFocus, isTrue);
        expect(query.value, composing);
        expect(tester.testTextInput.hasAnyClients, isTrue);
        expect(
          tester.testTextInput.log.where(
            (call) =>
                call.method == 'TextInput.setClient' ||
                call.method == 'TextInput.clearClient',
          ),
          isEmpty,
        );
        expect(controller.codeLines, same(body.codeLines));
        expect(controller.selection, body.selection);
        expect(controller.composing, body.composing);
        expect(controller.canUndo, isTrue);
        expect(controller.canRedo, canRedo);
        expect(scroller.position, same(position));
        expect(position.pixels, offset);
      }
      controller.undo();
      expect(controller.text, original);
      controller.redo();
      expect(controller.text, '$original\nextra');
      await tester.tap(find.byTooltip('Close find'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 48));
      expect(tester.getSize(toolbar).height, greaterThan(56));
      expect(tester.getSize(toolbar).height, lessThan(104));
      reduced.value = true;
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(toolbar).height, 56);
      reduced.value = false;
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Find'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 48));
      expect(tester.getSize(toolbar).height, greaterThan(56));
      expect(tester.getSize(toolbar).height, lessThan(104));
      expect(tester.state(input), same(inputState));
      expect(tester.state(editor), same(editorState));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(app.commands, isEmpty);
    },
  );

  testWidgets('focused page disposal before delayed cursor callback', (
    tester,
  ) async {
    final app = EditorApp();
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: ConfigTextPage(app: app, initialText: 'fixture'),
      ),
    );
    await tester.pumpAndSettle();
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    editor.focusNode!.requestFocus();
    await tester.pump();
    expect(editor.focusNode!.hasFocus, isTrue);
    editor.controller!.selectAll();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 101));
    expect(tester.takeException(), isNull);
  });

  testWidgets('immediate back after focus releases the editor normally', (
    tester,
  ) async {
    final app = EditorApp();
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) =>
                    ConfigTextPage(app: app, initialText: 'fixture'),
              ),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    editor.focusNode!.requestFocus();
    await tester.pump();
    editor.controller!.selectAll();
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 101));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(find.byType(ConfigTextPage), findsNothing);
    expect(app.commands, isEmpty);
  });

  testWidgets(
    'focus, select and leave in one frame disposes without a late cursor callback',
    (tester) async {
      final app = EditorApp();
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) =>
                      ConfigTextPage(app: app, initialText: 'fixture'),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
      editor.focusNode!.requestFocus();
      expect(editor.focusNode!.hasFocus, isTrue);
      editor.controller!.selectAll();
      // Dispose while the 100ms blink callback is pending and verify cancellation.
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 101));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(ConfigTextPage), findsNothing);
      expect(app.commands, isEmpty);
    },
  );
}
