import 'package:clash_pseudo/features/configs/config_text_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import 'config_text_page_test.dart' show EditorApp;

void main() {
  testWidgets('immediate back after focus releases the editor normally', (
    tester,
  ) async {
    final app = EditorApp();
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
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

  testWidgets('focused editor disposal before delayed cursor callback', (
    tester,
  ) async {
    final app = EditorApp();
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
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
}
