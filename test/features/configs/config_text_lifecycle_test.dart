import 'package:clash_pseudo/src/features/configs/config_text_page.dart';
import 'package:flutter/material.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import 'editor_fakes.dart' show EditorApp;

void main() {
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
